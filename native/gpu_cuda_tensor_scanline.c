/**
 * @file gpu_cuda_tensor_scanline.c
 * @brief Dynamic loader for the CUDA/Tensor scanline kernel DLL.
 *
 * This module loads the CUDA kernel library at runtime and resolves
 * optional exports for device info and batch processing. It provides
 * thin wrappers that return 0 when the DLL is missing or incomplete.
 */
#include "voxelshift_native.h"

#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
typedef HMODULE vs_lib_handle;
static vs_lib_handle vs_dlopen(const char* name) { return LoadLibraryA(name); }
static void* vs_dlsym(vs_lib_handle h, const char* sym) { return (void*)GetProcAddress(h, sym); }

static int vs_get_exe_dir(char* out_dir, size_t out_len) {
  if (!out_dir || out_len == 0) return 0;
  DWORD n = GetModuleFileNameA(NULL, out_dir, (DWORD)out_len);
  if (n == 0 || n >= out_len) return 0;
  for (size_t i = n; i > 0; i--) {
    char c = out_dir[i - 1];
    if (c == '\\' || c == '/') {
      out_dir[i - 1] = '\0';
      return 1;
    }
  }
  return 0;
}

static vs_lib_handle vs_dlopen_in_dir(const char* dir, const char* lib) {
  if (!dir || !lib) return 0;
  char path[2048];
  size_t d = strlen(dir);
  size_t l = strlen(lib);
  if (d + 1 + l + 1 > sizeof(path)) return 0;
  memcpy(path, dir, d);
  path[d] = '\\';
  memcpy(path + d + 1, lib, l);
  path[d + 1 + l] = '\0';
  return vs_dlopen(path);
}
#else
#include <dlfcn.h>
typedef void* vs_lib_handle;
static vs_lib_handle vs_dlopen(const char* name) { return dlopen(name, RTLD_LAZY); }
static void* vs_dlsym(vs_lib_handle h, const char* sym) { return dlsym(h, sym); }
#endif

// ── Function pointer types for all CUDA DLL exports ─────────────────────────

typedef int (*cuda_tensor_scanline_fn)(
    const uint8_t* grey_pixels,
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels,
    uint8_t* out_scanlines,
    int32_t out_len);

typedef int (*cuda_tensor_batch_fn)(
    const uint8_t* pixels_blob,
    int32_t layer_count,
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels,
    uint8_t* out_scanlines_blob,
    int32_t scanlines_per_layer_bytes);

typedef int (*cuda_tensor_init_fn)(void);
typedef int32_t (*cuda_tensor_i32_fn)(void);
typedef int64_t (*cuda_tensor_i64_fn)(void);
typedef const char* (*cuda_tensor_str_fn)(void);

typedef int32_t (*cuda_tensor_max_concurrent_fn)(
    int32_t src_width, int32_t height,
    int32_t out_width, int32_t channels);

static int g_loaded = 0;
static int g_available = 0;

// Single-layer
static cuda_tensor_scanline_fn g_fn = 0;

// Mega-batch
static cuda_tensor_batch_fn g_batch_fn = 0;

// Device info
static cuda_tensor_init_fn g_init_fn = 0;
static cuda_tensor_str_fn g_device_name_fn = 0;
static cuda_tensor_i64_fn g_vram_fn = 0;
static cuda_tensor_i32_fn g_tensor_cores_fn = 0;
static cuda_tensor_i32_fn g_compute_cap_fn = 0;
static cuda_tensor_i32_fn g_mp_count_fn = 0;

// Error
static cuda_tensor_i32_fn g_last_error_fn = 0;

// Max concurrent layers
static cuda_tensor_max_concurrent_fn g_max_concurrent_fn = 0;

/**
 * @brief Load the CUDA kernel DLL and resolve exported symbols.
 */
static void _load_cuda_tensor_hook(void) {
  if (g_loaded) return;
  g_loaded = 1;

#ifdef _WIN32
  const char* libs[] = {
      "libvoxelshift_cuda_kernel.dll",
      "voxelshift_cuda_kernel.dll",
  };
#else
  const char* libs[] = {
      "libvoxelshift_cuda_kernel.so",
  };
#endif

  for (size_t i = 0; i < sizeof(libs) / sizeof(libs[0]); i++) {
    vs_lib_handle h = vs_dlopen(libs[i]);
#ifdef _WIN32
    if (!h) {
      char exe_dir[1024];
      if (vs_get_exe_dir(exe_dir, sizeof(exe_dir))) {
        h = vs_dlopen_in_dir(exe_dir, libs[i]);
      }
    }
#endif
    if (!h) continue;
    g_fn = (cuda_tensor_scanline_fn)vs_dlsym(h, "vs_cuda_tensor_build_scanlines");
    if (g_fn) {
      // Resolve all optional exports
      g_batch_fn = (cuda_tensor_batch_fn)vs_dlsym(h, "vs_cuda_tensor_build_scanlines_batch");
      g_init_fn = (cuda_tensor_init_fn)vs_dlsym(h, "vs_cuda_tensor_init");
      g_device_name_fn = (cuda_tensor_str_fn)vs_dlsym(h, "vs_cuda_tensor_device_name");
      g_vram_fn = (cuda_tensor_i64_fn)vs_dlsym(h, "vs_cuda_tensor_vram_bytes");
      g_tensor_cores_fn = (cuda_tensor_i32_fn)vs_dlsym(h, "vs_cuda_tensor_has_tensor_cores");
      g_compute_cap_fn = (cuda_tensor_i32_fn)vs_dlsym(h, "vs_cuda_tensor_compute_capability");
      g_mp_count_fn = (cuda_tensor_i32_fn)vs_dlsym(h, "vs_cuda_tensor_multiprocessor_count");
      g_last_error_fn = (cuda_tensor_i32_fn)vs_dlsym(h, "vs_cuda_tensor_last_error_code");
      g_max_concurrent_fn = (cuda_tensor_max_concurrent_fn)vs_dlsym(h, "vs_cuda_tensor_max_concurrent_layers");
      g_available = 1;
      return;
    }
  }
}

/**
 * @brief Check if the CUDA kernel DLL is available and loaded.
 */
int gpu_cuda_tensor_kernel_available(void) {
#ifdef VOXELSHIFT_DISABLE_CUDA
  return 0;
#else
  _load_cuda_tensor_hook();
  return g_available;
#endif
}

/**
 * @brief Invoke the CUDA single-layer scanline builder.
 */
int gpu_cuda_tensor_build_scanlines(
    const uint8_t* grey_pixels,
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels,
    uint8_t* out_scanlines,
    int32_t out_len) {
  _load_cuda_tensor_hook();
  if (!g_available || !g_fn) return 0;
  return g_fn(grey_pixels, src_width, height, out_width, channels, out_scanlines, out_len);
}

/**
 * @brief Invoke the CUDA mega-batch scanline builder.
 */
int gpu_cuda_tensor_build_scanlines_batch(
    const uint8_t* pixels_blob,
    int32_t layer_count,
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels,
    uint8_t* out_scanlines_blob,
    int32_t scanlines_per_layer_bytes) {
  _load_cuda_tensor_hook();
  if (!g_available || !g_batch_fn) return 0;
  return g_batch_fn(pixels_blob, layer_count, src_width, height, out_width,
                    channels, out_scanlines_blob, scanlines_per_layer_bytes);
}

/**
 * @brief Initialize CUDA device state inside the kernel DLL.
 */
int gpu_cuda_tensor_init(void) {
  _load_cuda_tensor_hook();
  if (!g_available || !g_init_fn) return 0;
  return g_init_fn();
}

/**
 * @brief Get CUDA device name string.
 */
const char* gpu_cuda_tensor_device_name(void) {
  _load_cuda_tensor_hook();
  if (!g_available || !g_device_name_fn) return "";
  return g_device_name_fn();
}

/**
 * @brief Get total device VRAM in bytes.
 */
int64_t gpu_cuda_tensor_vram_bytes(void) {
  _load_cuda_tensor_hook();
  if (!g_available || !g_vram_fn) return 0;
  return g_vram_fn();
}

/**
 * @brief Check tensor core support (compute capability >= 7.0).
 */
int32_t gpu_cuda_tensor_has_tensor_cores(void) {
  _load_cuda_tensor_hook();
  if (!g_available || !g_tensor_cores_fn) return 0;
  return g_tensor_cores_fn();
}

/**
 * @brief Get device compute capability as major*10 + minor.
 */
int32_t gpu_cuda_tensor_compute_capability(void) {
  _load_cuda_tensor_hook();
  if (!g_available || !g_compute_cap_fn) return 0;
  return g_compute_cap_fn();
}

/**
 * @brief Get number of streaming multiprocessors.
 */
int32_t gpu_cuda_tensor_multiprocessor_count(void) {
  _load_cuda_tensor_hook();
  if (!g_available || !g_mp_count_fn) return 0;
  return g_mp_count_fn();
}

/**
 * @brief Retrieve last CUDA error code from the kernel DLL.
 */
int32_t gpu_cuda_tensor_last_error_code(void) {
  _load_cuda_tensor_hook();
  if (!g_available || !g_last_error_fn) return 0;
  return g_last_error_fn();
}

/**
 * @brief Compute how many concurrent per-layer CUDA ops fit in VRAM.
 */
int32_t gpu_cuda_tensor_max_concurrent_layers(
    int32_t src_width, int32_t height,
    int32_t out_width, int32_t channels) {
  _load_cuda_tensor_hook();
  if (!g_available || !g_max_concurrent_fn) return 0;
  return g_max_concurrent_fn(src_width, height, out_width, channels);
}
