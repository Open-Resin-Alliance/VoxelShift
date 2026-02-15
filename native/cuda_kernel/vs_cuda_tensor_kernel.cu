// ── VoxelShift CUDA Kernel Module ────────────────────────────────────────────
//
// Provides GPU-accelerated scanline building for PNG generation.
//
// Two APIs:
//   1) Single-layer:  vs_cuda_tensor_build_scanlines()
//      Per-thread CUDA stream & device buffers (thread_local).
//      Good for the existing per-thread worker model.
//
//   2) Mega-batch:    vs_cuda_tensor_build_scanlines_batch()
//      Process N layers in a SINGLE kernel launch with one H2D + one D2H
//      transfer. Shared device buffers (global, caller-serialized).
//      Amortizes PCIe overhead across many layers.
//
// Also provides:
//   - vs_cuda_tensor_init()               Device init + diagnostics
//   - vs_cuda_tensor_device_name()        GPU name string
//   - vs_cuda_tensor_vram_bytes()         Total VRAM
//   - vs_cuda_tensor_has_tensor_cores()   Tensor core detection
//   - vs_cuda_tensor_compute_capability() SM version
//   - vs_cuda_tensor_last_error_code()    Last CUDA error

#include <cuda_runtime.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

#ifdef _WIN32
#define VS_CUDA_EXPORT __declspec(dllexport)
#else
#define VS_CUDA_EXPORT __attribute__((visibility("default")))
#endif

// ── Error tracking ──────────────────────────────────────────────────────────

static thread_local int32_t g_last_cuda_error_code = 0;

/**
 * @brief Record last CUDA error and return failure.
 */
static inline int _fail_cuda(cudaError_t err) {
  g_last_cuda_error_code = (int32_t)err;
  return 0;
}

// ── Device info cache ───────────────────────────────────────────────────────

static int g_device_inited = 0;
static int g_device_ok = 0;
static char g_device_name[256] = {0};
static int64_t g_device_vram = 0;
static int32_t g_device_sm_major = 0;
static int32_t g_device_sm_minor = 0;
static int32_t g_device_has_tensor = 0;
static int32_t g_device_mp_count = 0;

/**
 * @brief Initialize CUDA device properties once and cache results.
 */
static int _ensure_device_init() {
  if (g_device_inited) return g_device_ok;
  g_device_inited = 1;

  int count = 0;
  cudaError_t err = cudaGetDeviceCount(&count);
  if (err != cudaSuccess || count == 0) {
    g_last_cuda_error_code = (int32_t)err;
    g_device_ok = 0;
    return 0;
  }

  cudaDeviceProp prop;
  err = cudaGetDeviceProperties(&prop, 0);
  if (err != cudaSuccess) {
    g_last_cuda_error_code = (int32_t)err;
    g_device_ok = 0;
    return 0;
  }

  strncpy(g_device_name, prop.name, sizeof(g_device_name) - 1);
  g_device_name[sizeof(g_device_name) - 1] = '\0';
  g_device_vram = (int64_t)prop.totalGlobalMem;
  g_device_sm_major = prop.major;
  g_device_sm_minor = prop.minor;
  g_device_mp_count = prop.multiProcessorCount;

  // Tensor cores: Volta (7.0+) for FP16, Turing (7.5+) for INT8,
  // Ampere (8.0+) for TF32/BF16/INT8 enhanced.
  g_device_has_tensor = (prop.major >= 7) ? 1 : 0;

  g_device_ok = 1;
  return 1;
}

// ── Global VRAM budget tracking ─────────────────────────────────────────────
// Atomic counter of bytes currently allocated for per-thread TLS buffers.
// Prevents VRAM exhaustion when many host threads call ensure() concurrently.

#include <atomic>

static std::atomic<int64_t> g_tls_vram_allocated{0};

// VRAM headroom for OS/display/batch buffers/etc.
// Windows desktop compositor + display driver typically consume 1.5-3 GB on a
// 10 GB card. Be generous to avoid pressure on the driver.
static constexpr int64_t VRAM_HEADROOM = 2560LL * 1024 * 1024; // 2.5 GB

/**
 * @brief Compute VRAM budget available for TLS/batch buffers.
 */
static int64_t _vram_budget_for_tls() {
  if (!g_device_ok) return 0;
  const int64_t budget = g_device_vram - VRAM_HEADROOM;
  return budget > 0 ? budget : 0;
}

// ── Per-thread single-layer buffers ─────────────────────────────────────────

struct ThreadCudaBuffers {
  uint8_t* d_src = nullptr;
  size_t d_src_cap = 0;
  uint8_t* d_scanlines = nullptr;
  size_t d_scanlines_cap = 0;
  cudaStream_t stream = nullptr;
  int64_t vram_held = 0;         // bytes we've charged against the budget

  ~ThreadCudaBuffers() {
    if (d_src) cudaFree(d_src);
    if (d_scanlines) cudaFree(d_scanlines);
    if (stream) cudaStreamDestroy(stream);
    if (vram_held > 0) g_tls_vram_allocated.fetch_sub(vram_held);
  }

  /**
   * @brief Ensure per-thread device buffers are large enough.
   *
   * Reserves VRAM budget optimistically before allocating to prevent
   * global VRAM exhaustion with many host threads.
   */
  bool ensure(size_t src_len, size_t scanlines_len) {
    if (!stream) {
      const cudaError_t err = cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking);
      if (err != cudaSuccess) {
        g_last_cuda_error_code = (int32_t)err;
        stream = nullptr;
        return false;
      }
    }

    // Calculate total new VRAM needed beyond what we already hold
    const size_t new_src = (src_len > d_src_cap) ? src_len : 0;
    const size_t new_scan = (scanlines_len > d_scanlines_cap) ? scanlines_len : 0;
    const int64_t delta = (int64_t)new_src + (int64_t)new_scan
                        - (int64_t)(new_src ? d_src_cap : 0)
                        - (int64_t)(new_scan ? d_scanlines_cap : 0);

    // Budget check: try to reserve the VRAM
    if (delta > 0) {
      const int64_t budget = _vram_budget_for_tls();
      // Optimistic atomic reserve
      const int64_t prev = g_tls_vram_allocated.fetch_add(delta);
      if (prev + delta > budget) {
        // Over budget — give it back and refuse
        g_tls_vram_allocated.fetch_sub(delta);
        g_last_cuda_error_code = 2; // cudaErrorMemoryAllocation
        return false;
      }
      vram_held += delta;
    }

    if (src_len > d_src_cap) {
      if (d_src) { cudaFree(d_src); d_src = nullptr; d_src_cap = 0; }
      cudaError_t err = cudaMalloc((void**)&d_src, src_len);
      if (err != cudaSuccess) {
        g_last_cuda_error_code = (int32_t)err;
        // Release the budget we just reserved
        if (delta > 0) { g_tls_vram_allocated.fetch_sub(delta); vram_held -= delta; }
        return false;
      }
      d_src_cap = src_len;
    }

    if (scanlines_len > d_scanlines_cap) {
      if (d_scanlines) { cudaFree(d_scanlines); d_scanlines = nullptr; d_scanlines_cap = 0; }
      cudaError_t err = cudaMalloc((void**)&d_scanlines, scanlines_len);
      if (err != cudaSuccess) {
        g_last_cuda_error_code = (int32_t)err;
        // Release the budget we just reserved
        if (delta > 0) { g_tls_vram_allocated.fetch_sub(delta); vram_held -= delta; }
        return false;
      }
      d_scanlines_cap = scanlines_len;
    }

    return d_src != nullptr && d_scanlines != nullptr;
  }
};

static thread_local ThreadCudaBuffers g_tls;

// ── Global batch buffers (caller-serialized, NOT thread-safe) ───────────────

struct BatchCudaBuffers {
  uint8_t* d_src = nullptr;
  size_t d_src_cap = 0;
  uint8_t* d_dst = nullptr;
  size_t d_dst_cap = 0;
  cudaStream_t stream = nullptr;
  bool initialized = false;
  int64_t vram_held = 0;  // Track our share of the global VRAM budget

  ~BatchCudaBuffers() {
    if (d_src) cudaFree(d_src);
    if (d_dst) cudaFree(d_dst);
    if (stream) cudaStreamDestroy(stream);
    if (vram_held > 0) g_tls_vram_allocated.fetch_sub(vram_held);
  }

  /**
   * @brief Ensure batch device buffers are large enough.
   *
   * Uses the shared VRAM budget to prevent excessive allocations.
   */
  bool ensure(size_t src_len, size_t dst_len) {
    if (!initialized) {
      cudaError_t err = cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking);
      if (err != cudaSuccess) { g_last_cuda_error_code = (int32_t)err; return false; }
      initialized = true;
    }

    // Calculate net VRAM delta if we grow either buffer
    const int64_t src_delta = (src_len > d_src_cap) ? ((int64_t)src_len - (int64_t)d_src_cap) : 0;
    const int64_t dst_delta = (dst_len > d_dst_cap) ? ((int64_t)dst_len - (int64_t)d_dst_cap) : 0;
    const int64_t total_delta = src_delta + dst_delta;

    // Budget check before any allocation
    if (total_delta > 0) {
      const int64_t budget = _vram_budget_for_tls();
      const int64_t prev = g_tls_vram_allocated.fetch_add(total_delta);
      if (prev + total_delta > budget) {
        // Over budget — give it back and refuse
        g_tls_vram_allocated.fetch_sub(total_delta);
        g_last_cuda_error_code = (int32_t)cudaErrorMemoryAllocation;
        return false;
      }
      vram_held += total_delta;
    }

    // Now allocate (budget is reserved)
    if (src_len > d_src_cap) {
      if (d_src) { cudaFree(d_src); d_src = nullptr; d_src_cap = 0; }
      cudaError_t err = cudaMalloc((void**)&d_src, src_len);
      if (err != cudaSuccess) {
        if (total_delta > 0) {
          g_tls_vram_allocated.fetch_sub(total_delta);
          vram_held -= total_delta;
        }
        g_last_cuda_error_code = (int32_t)err;
        return false;
      }
      d_src_cap = src_len;
    }

    if (dst_len > d_dst_cap) {
      if (d_dst) { cudaFree(d_dst); d_dst = nullptr; d_dst_cap = 0; }
      cudaError_t err = cudaMalloc((void**)&d_dst, dst_len);
      if (err != cudaSuccess) {
        if (total_delta > 0) {
          g_tls_vram_allocated.fetch_sub(total_delta);
          vram_held -= total_delta;
        }
        g_last_cuda_error_code = (int32_t)err;
        return false;
      }
      d_dst_cap = dst_len;
    }

    return d_src && d_dst;
  }
};

static BatchCudaBuffers g_batch;

// ── Device helper (bounds-checked pixel read) ───────────────────────────────

__device__ __forceinline__ uint8_t sample_or_zero(
    const uint8_t* src,
    int32_t src_row,
    int32_t idx,
    int32_t src_width) {
  return (idx >= 0 && idx < src_width) ? src[src_row + idx] : 0;
}

// ── Single-layer kernels ────────────────────────────────────────────────────

__global__ void build_scanlines_rgb_up_kernel(
    const uint8_t* src,
    int32_t src_width,
    int32_t out_width,
    int32_t pad_left,
    uint8_t* dst_scanlines,
    int32_t scanline_size,
    int32_t height) {
  const int32_t x = (int32_t)(blockIdx.x * blockDim.x + threadIdx.x);
  const int32_t y = (int32_t)(blockIdx.y * blockDim.y + threadIdx.y);
  if (x >= out_width || y >= height) return;

  const int32_t src_row = y * src_width;
  const int32_t dst_row = y * scanline_size;
  if (x == 0) dst_scanlines[dst_row] = 2; // Up filter type byte

  const int32_t dst_base = dst_row + 1 + x * 3;
  const int32_t si = x * 3 - pad_left;

  const uint8_t c0 = sample_or_zero(src, src_row, si, src_width);
  const uint8_t c1 = sample_or_zero(src, src_row, si + 1, src_width);
  const uint8_t c2 = sample_or_zero(src, src_row, si + 2, src_width);

  uint8_t p0 = 0, p1 = 0, p2 = 0;
  if (y > 0) {
    const int32_t prev_row = (y - 1) * src_width;
    p0 = sample_or_zero(src, prev_row, si, src_width);
    p1 = sample_or_zero(src, prev_row, si + 1, src_width);
    p2 = sample_or_zero(src, prev_row, si + 2, src_width);
  }

  dst_scanlines[dst_base + 0] = (uint8_t)(((int32_t)c0 - (int32_t)p0) & 0xFF);
  dst_scanlines[dst_base + 1] = (uint8_t)(((int32_t)c1 - (int32_t)p1) & 0xFF);
  dst_scanlines[dst_base + 2] = (uint8_t)(((int32_t)c2 - (int32_t)p2) & 0xFF);
}

__global__ void build_scanlines_gray_up_kernel(
    const uint8_t* src,
    int32_t src_width,
    int32_t out_width,
    int32_t pad_left,
    uint8_t* dst_scanlines,
    int32_t scanline_size,
    int32_t height) {
  const int32_t x = (int32_t)(blockIdx.x * blockDim.x + threadIdx.x);
  const int32_t y = (int32_t)(blockIdx.y * blockDim.y + threadIdx.y);
  if (x >= out_width || y >= height) return;

  const int32_t src_row = y * src_width;
  const int32_t dst_row = y * scanline_size;
  if (x == 0) dst_scanlines[dst_row] = 2;

  const int32_t si = x * 2 - pad_left;
  const uint8_t a = sample_or_zero(src, src_row, si, src_width);
  const uint8_t b = sample_or_zero(src, src_row, si + 1, src_width);
  const uint8_t cur = (uint8_t)(((int32_t)a + (int32_t)b) >> 1);

  uint8_t prev = 0;
  if (y > 0) {
    const int32_t prev_row = (y - 1) * src_width;
    const uint8_t pa = sample_or_zero(src, prev_row, si, src_width);
    const uint8_t pb = sample_or_zero(src, prev_row, si + 1, src_width);
    prev = (uint8_t)(((int32_t)pa + (int32_t)pb) >> 1);
  }

  dst_scanlines[dst_row + 1 + x] =
      (uint8_t)(((int32_t)cur - (int32_t)prev) & 0xFF);
}

// ── Mega-batch kernels (3D grid: x, y, layer) ──────────────────────────────

__global__ void build_scanlines_batch_rgb_up_kernel(
    const uint8_t* src,         // all layers' pixels concatenated
    int32_t src_width,
    int32_t out_width,
    int32_t pad_left,
    uint8_t* dst_scanlines,     // all layers' scanlines concatenated
    int32_t scanline_size,
    int32_t height,
    int64_t layer_stride_in,    // src_width * height
    int64_t layer_stride_out,   // scanline_size * height
    int32_t layer_count) {
  const int32_t x = (int32_t)(blockIdx.x * blockDim.x + threadIdx.x);
  const int32_t y = (int32_t)(blockIdx.y * blockDim.y + threadIdx.y);
  const int32_t layer = (int32_t)blockIdx.z;
  if (x >= out_width || y >= height || layer >= layer_count) return;

  const int64_t src_base = (int64_t)layer * layer_stride_in;
  const int64_t dst_base = (int64_t)layer * layer_stride_out;
  const int32_t src_row = y * src_width;
  const int32_t dst_row = y * scanline_size;

  if (x == 0) dst_scanlines[dst_base + dst_row] = 2;

  const int32_t dst_off = dst_row + 1 + x * 3;
  const int32_t si = x * 3 - pad_left;

  const uint8_t c0 = sample_or_zero(src + src_base, src_row, si, src_width);
  const uint8_t c1 = sample_or_zero(src + src_base, src_row, si + 1, src_width);
  const uint8_t c2 = sample_or_zero(src + src_base, src_row, si + 2, src_width);

  uint8_t p0 = 0, p1 = 0, p2 = 0;
  if (y > 0) {
    const int32_t prev_row = (y - 1) * src_width;
    p0 = sample_or_zero(src + src_base, prev_row, si, src_width);
    p1 = sample_or_zero(src + src_base, prev_row, si + 1, src_width);
    p2 = sample_or_zero(src + src_base, prev_row, si + 2, src_width);
  }

  dst_scanlines[dst_base + dst_off + 0] = (uint8_t)(((int32_t)c0 - (int32_t)p0) & 0xFF);
  dst_scanlines[dst_base + dst_off + 1] = (uint8_t)(((int32_t)c1 - (int32_t)p1) & 0xFF);
  dst_scanlines[dst_base + dst_off + 2] = (uint8_t)(((int32_t)c2 - (int32_t)p2) & 0xFF);
}

__global__ void build_scanlines_batch_gray_up_kernel(
    const uint8_t* src,
    int32_t src_width,
    int32_t out_width,
    int32_t pad_left,
    uint8_t* dst_scanlines,
    int32_t scanline_size,
    int32_t height,
    int64_t layer_stride_in,
    int64_t layer_stride_out,
    int32_t layer_count) {
  const int32_t x = (int32_t)(blockIdx.x * blockDim.x + threadIdx.x);
  const int32_t y = (int32_t)(blockIdx.y * blockDim.y + threadIdx.y);
  const int32_t layer = (int32_t)blockIdx.z;
  if (x >= out_width || y >= height || layer >= layer_count) return;

  const int64_t src_base = (int64_t)layer * layer_stride_in;
  const int64_t dst_base = (int64_t)layer * layer_stride_out;
  const int32_t src_row = y * src_width;
  const int32_t dst_row = y * scanline_size;

  if (x == 0) dst_scanlines[dst_base + dst_row] = 2;

  const int32_t si = x * 2 - pad_left;
  const uint8_t a = sample_or_zero(src + src_base, src_row, si, src_width);
  const uint8_t b = sample_or_zero(src + src_base, src_row, si + 1, src_width);
  const uint8_t cur = (uint8_t)(((int32_t)a + (int32_t)b) >> 1);

  uint8_t prev = 0;
  if (y > 0) {
    const int32_t prev_row = (y - 1) * src_width;
    const uint8_t pa = sample_or_zero(src + src_base, prev_row, si, src_width);
    const uint8_t pb = sample_or_zero(src + src_base, prev_row, si + 1, src_width);
    prev = (uint8_t)(((int32_t)pa + (int32_t)pb) >> 1);
  }

  dst_scanlines[dst_base + dst_row + 1 + x] =
      (uint8_t)(((int32_t)cur - (int32_t)prev) & 0xFF);
}

// ═══════════════════════════════════════════════════════════════════════════
// PUBLIC API
// ═══════════════════════════════════════════════════════════════════════════

// ── Device init & diagnostics ───────────────────────────────────────────────

extern "C" VS_CUDA_EXPORT int vs_cuda_tensor_init(void) {
  return _ensure_device_init();
}

extern "C" VS_CUDA_EXPORT const char* vs_cuda_tensor_device_name(void) {
  _ensure_device_init();
  return g_device_name;
}

extern "C" VS_CUDA_EXPORT int64_t vs_cuda_tensor_vram_bytes(void) {
  _ensure_device_init();
  return g_device_vram;
}

extern "C" VS_CUDA_EXPORT int32_t vs_cuda_tensor_has_tensor_cores(void) {
  _ensure_device_init();
  return g_device_has_tensor;
}

extern "C" VS_CUDA_EXPORT int32_t vs_cuda_tensor_compute_capability(void) {
  _ensure_device_init();
  return g_device_sm_major * 10 + g_device_sm_minor;
}

extern "C" VS_CUDA_EXPORT int32_t vs_cuda_tensor_multiprocessor_count(void) {
  _ensure_device_init();
  return g_device_mp_count;
}

// ── Single-layer API (per-thread stream, FIXED) ─────────────────────────────

/**
 * @brief Build PNG scanlines for a single layer on the GPU.
 */
extern "C" VS_CUDA_EXPORT int vs_cuda_tensor_build_scanlines(
    const uint8_t* grey_pixels,
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels,
    uint8_t* out_scanlines,
    int32_t out_len) {
  g_last_cuda_error_code = 0;

  if (!_ensure_device_init()) return 0;

  if (!grey_pixels || !out_scanlines || src_width <= 0 || height <= 0 ||
      out_width <= 0 || (channels != 1 && channels != 3)) {
    return 0;
  }

  const int32_t bytes_per_row = out_width * channels;
  const int32_t scanline_size = 1 + bytes_per_row;
  const int32_t required_len = scanline_size * height;
  if (out_len < required_len) return 0;

  const int32_t required_subpixels = out_width * channels;
  const int32_t pad_total = required_subpixels - src_width;
  const int32_t pad_left = pad_total > 0 ? (pad_total / 2) : 0;

  const size_t in_len = (size_t)src_width * (size_t)height;
  const size_t out_scanlines_len = (size_t)required_len;

  if (!g_tls.ensure(in_len, out_scanlines_len)) return 0;

  // ── FIX: All operations on the SAME stream (g_tls.stream) ──
  cudaError_t err;

  err = cudaMemcpyAsync(g_tls.d_src, grey_pixels, in_len,
                        cudaMemcpyHostToDevice, g_tls.stream);
  if (err != cudaSuccess) return _fail_cuda(err);

  const dim3 block(32, 8);
  const dim3 grid((unsigned int)((out_width + block.x - 1) / block.x),
                  (unsigned int)((height + block.y - 1) / block.y));

  if (channels == 3) {
    build_scanlines_rgb_up_kernel<<<grid, block, 0, g_tls.stream>>>(
        g_tls.d_src, src_width, out_width, pad_left,
        g_tls.d_scanlines, scanline_size, height);
  } else {
    build_scanlines_gray_up_kernel<<<grid, block, 0, g_tls.stream>>>(
        g_tls.d_src, src_width, out_width, pad_left,
        g_tls.d_scanlines, scanline_size, height);
  }

  err = cudaGetLastError();
  if (err != cudaSuccess) return _fail_cuda(err);

  err = cudaMemcpyAsync(out_scanlines, g_tls.d_scanlines, out_scanlines_len,
                        cudaMemcpyDeviceToHost, g_tls.stream);
  if (err != cudaSuccess) return _fail_cuda(err);

  err = cudaStreamSynchronize(g_tls.stream);
  if (err != cudaSuccess) return _fail_cuda(err);

  return 1;
}

// ── Mega-batch API (process N layers in one kernel launch) ──────────────────
//
// Input:  pixels_blob = layer0_pixels ∥ layer1_pixels ∥ ... (concatenated)
// Output: scanlines_blob = layer0_scanlines ∥ layer1_scanlines ∥ ...
//
// Each layer has identical dimensions. Caller serializes access.

/**
 * @brief Build PNG scanlines for multiple layers in one GPU call.
 */
extern "C" VS_CUDA_EXPORT int vs_cuda_tensor_build_scanlines_batch(
    const uint8_t* pixels_blob,
    int32_t layer_count,
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels,
    uint8_t* out_scanlines_blob,
    int32_t scanlines_per_layer_bytes) {
  g_last_cuda_error_code = 0;

  if (!_ensure_device_init()) return 0;

  if (!pixels_blob || !out_scanlines_blob || layer_count <= 0 ||
      src_width <= 0 || height <= 0 || out_width <= 0 ||
      (channels != 1 && channels != 3) || scanlines_per_layer_bytes <= 0) {
    return 0;
  }

  const int32_t bytes_per_row = out_width * channels;
  const int32_t scanline_size = 1 + bytes_per_row;
  const int32_t expected_scanlines = scanline_size * height;
  if (scanlines_per_layer_bytes < expected_scanlines) return 0;

  const int32_t required_subpixels = out_width * channels;
  const int32_t pad_total = required_subpixels - src_width;
  const int32_t pad_left = pad_total > 0 ? (pad_total / 2) : 0;

  const int64_t pixels_per_layer = (int64_t)src_width * height;
  const int64_t scanlines_stride = (int64_t)scanlines_per_layer_bytes;
  const size_t total_src = (size_t)pixels_per_layer * layer_count;
  const size_t total_dst = (size_t)scanlines_stride * layer_count;

  // Check VRAM budget (use global headroom policy)
  const int64_t vram_needed = (int64_t)(total_src + total_dst);
  const int64_t vram_budget = _vram_budget_for_tls();
  if (vram_needed > vram_budget) {
    g_last_cuda_error_code = (int32_t)cudaErrorMemoryAllocation;
    return 0;
  }

  if (!g_batch.ensure(total_src, total_dst)) return 0;

  cudaError_t err;

  // Upload all layers' pixels in one transfer
  err = cudaMemcpyAsync(g_batch.d_src, pixels_blob, total_src,
                        cudaMemcpyHostToDevice, g_batch.stream);
  if (err != cudaSuccess) return _fail_cuda(err);

  // 3D grid: (out_width, height, layer_count)
  const dim3 block(32, 8, 1);
  const dim3 grid(
      (unsigned int)((out_width + block.x - 1) / block.x),
      (unsigned int)((height + block.y - 1) / block.y),
      (unsigned int)layer_count);

  if (channels == 3) {
    build_scanlines_batch_rgb_up_kernel<<<grid, block, 0, g_batch.stream>>>(
        g_batch.d_src, src_width, out_width, pad_left,
        g_batch.d_dst, scanline_size, height,
        pixels_per_layer, scanlines_stride, layer_count);
  } else {
    build_scanlines_batch_gray_up_kernel<<<grid, block, 0, g_batch.stream>>>(
        g_batch.d_src, src_width, out_width, pad_left,
        g_batch.d_dst, scanline_size, height,
        pixels_per_layer, scanlines_stride, layer_count);
  }

  err = cudaGetLastError();
  if (err != cudaSuccess) return _fail_cuda(err);

  // Download all layers' scanlines in one transfer
  err = cudaMemcpyAsync(out_scanlines_blob, g_batch.d_dst, total_dst,
                        cudaMemcpyDeviceToHost, g_batch.stream);
  if (err != cudaSuccess) return _fail_cuda(err);

  err = cudaStreamSynchronize(g_batch.stream);
  if (err != cudaSuccess) return _fail_cuda(err);

  return 1;
}

// ── Error code accessor ─────────────────────────────────────────────────────

extern "C" VS_CUDA_EXPORT int32_t vs_cuda_tensor_last_error_code(void) {
  return g_last_cuda_error_code;
}

// ── Max concurrent layer query ──────────────────────────────────────────────
// Returns how many concurrent per-layer CUDA operations can fit in VRAM
// for the given dimensions, accounting for headroom.

/**
 * @brief Estimate how many concurrent CUDA layers fit in VRAM.
 */
extern "C" VS_CUDA_EXPORT int32_t vs_cuda_tensor_max_concurrent_layers(
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels) {
  if (!_ensure_device_init()) return 0;
  if (src_width <= 0 || height <= 0 || out_width <= 0) return 0;

  const int64_t pixels_bytes = (int64_t)src_width * height;
  const int32_t scanline_size = 1 + out_width * channels;
  const int64_t scanlines_bytes = (int64_t)scanline_size * height;
  const int64_t per_layer = pixels_bytes + scanlines_bytes;
  if (per_layer <= 0) return 0;

  const int64_t budget = _vram_budget_for_tls();
  if (budget <= 0) return 0;

  const int64_t max_layers = budget / per_layer;
  if (max_layers > 0x7FFFFFFF) return 0x7FFFFFFF;
  return (int32_t)(max_layers > 0 ? max_layers : 0);
}
