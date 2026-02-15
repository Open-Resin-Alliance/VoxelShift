/**
 * @file gpu_accel.c
 * @brief GPU backend detection and enablement policy.
 *
 * This module dynamically detects CUDA/Tensor, OpenCL, or Metal support
 * by probing runtime libraries and minimal symbols. It exposes simple
 * toggles and queries consumed by the higher-level pipeline to decide
 * whether GPU acceleration should be used.
 */
#include "voxelshift_native.h"

#include <stdint.h>
#include <stddef.h>

#ifdef _WIN32
#include <windows.h>
typedef HMODULE vs_lib_handle;
static vs_lib_handle vs_dlopen(const char* name) { return LoadLibraryA(name); }
static void* vs_dlsym(vs_lib_handle h, const char* sym) { return (void*)GetProcAddress(h, sym); }
#else
#include <dlfcn.h>
typedef void* vs_lib_handle;
static vs_lib_handle vs_dlopen(const char* name) { return dlopen(name, RTLD_LAZY); }
static void* vs_dlsym(vs_lib_handle h, const char* sym) { return dlsym(h, sym); }
#endif

int gpu_cuda_tensor_kernel_available(void);

static int32_t g_gpu_enabled = 1;
static int32_t g_gpu_backend = -1; // -1 unknown, 0 none, 1 opencl, 2 metal, 3 cuda/tensor
static int32_t g_gpu_backend_preference = 0; // 0 auto

/**
 * @brief Detect CUDA/Tensor availability by probing the CUDA driver.
 * @return 3 if a CUDA-capable driver is found, otherwise 0.
 */
static int32_t _detect_cuda_tensor(void) {
#ifdef VOXELSHIFT_DISABLE_CUDA
  return 0;
#endif
  if (!gpu_cuda_tensor_kernel_available()) {
    return 0;
  }

#ifdef __APPLE__
  return 0;
#else
#ifdef _WIN32
  const char* cands[] = {"nvcuda.dll"};
#else
  const char* cands[] = {"libcuda.so.1", "libcuda.so"};
#endif

  for (size_t i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
    vs_lib_handle h = vs_dlopen(cands[i]);
    if (!h) continue;
    if (vs_dlsym(h, "cuInit") != NULL) {
      return 3;
    }
  }

  return 0;
#endif
}

/**
 * @brief Detect OpenCL availability by probing the OpenCL ICD library.
 * @return 1 if a compatible OpenCL runtime is found, otherwise 0.
 */
static int32_t _detect_opencl(void) {
#ifdef _WIN32
  const char* cands[] = {"OpenCL.dll"};
#else
  const char* cands[] = {"libOpenCL.so.1", "libOpenCL.so"};
#endif
  for (size_t i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
    vs_lib_handle h = vs_dlopen(cands[i]);
    if (!h) continue;
    // Minimal symbol probe.
    if (vs_dlsym(h, "clGetPlatformIDs") != NULL) {
      return 1;
    }
  }
  return 0;
}

/**
 * @brief Detect Metal availability on macOS.
 * @return 2 when Metal is available, otherwise 0.
 */
static int32_t _detect_metal(void) {
#ifdef __APPLE__
  // Metal.framework exports MTLCreateSystemDefaultDevice.
  vs_lib_handle h = vs_dlopen("/System/Library/Frameworks/Metal.framework/Metal");
  if (!h) return 0;
  void* sym = vs_dlsym(h, "MTLCreateSystemDefaultDevice");
  return sym != NULL ? 2 : 0;
#else
  return 0;
#endif
}

#ifdef VOXELSHIFT_DISABLE_GPU
/**
 * @brief Report whether a given GPU backend is available on this system.
 * @param backend_code 1=OpenCL, 2=Metal, 3=CUDA/Tensor
 * @return 1 if available, 0 otherwise.
 */
int gpu_backend_available(int32_t backend_code) {
  (void)backend_code;
  return 0;
}
#else
int gpu_backend_available(int32_t backend_code) {
  if (backend_code == 1) return _detect_opencl() == 1 ? 1 : 0;
  if (backend_code == 2) return _detect_metal() == 2 ? 1 : 0;
  if (backend_code == 3) return _detect_cuda_tensor() == 3 ? 1 : 0;
  return 0;
}
#endif

/**
 * @brief Set preferred GPU backend for auto-selection.
 * @param backend_code 0=auto, 1=OpenCL, 2=Metal, 3=CUDA/Tensor
 */
void set_gpu_backend_preference(int32_t backend_code) {
  if (backend_code < 0 || backend_code > 3) {
    backend_code = 0;
  }
  g_gpu_backend_preference = backend_code;
  g_gpu_backend = -1;
}

/**
 * @brief Resolve the active backend based on preference and availability.
 */
static void _ensure_backend_detected(void) {
  if (g_gpu_backend >= 0) return;

  if (g_gpu_backend_preference == 2 && _detect_metal() == 2) {
    g_gpu_backend = 2;
    return;
  }
  if (g_gpu_backend_preference == 3 && _detect_cuda_tensor() == 3) {
    g_gpu_backend = 3;
    return;
  }
  if (g_gpu_backend_preference == 1 && _detect_opencl() == 1) {
    g_gpu_backend = 1;
    return;
  }

  // Prefer Metal on macOS, then CUDA/Tensor, then OpenCL.
  const int32_t metal = _detect_metal();
  if (metal == 2) {
    g_gpu_backend = 2;
    return;
  }

  const int32_t cuda_tensor = _detect_cuda_tensor();
  if (cuda_tensor == 3) {
    g_gpu_backend = 3;
    return;
  }

  if (_detect_opencl()) {
    g_gpu_backend = 1;
    return;
  }

  g_gpu_backend = 0;
}

/**
 * @brief Enable or disable GPU acceleration globally.
 * @param enabled Non-zero to enable, zero to disable.
 */
void set_gpu_acceleration_enabled(int32_t enabled) {
#ifdef VOXELSHIFT_DISABLE_GPU
  g_gpu_enabled = 0;
  (void)enabled;
#else
  g_gpu_enabled = enabled ? 1 : 0;
#endif
}

/**
 * @brief Check whether GPU acceleration is currently active.
 * @return 1 if enabled and a backend is selected, otherwise 0.
 */
int gpu_acceleration_active(void) {
#ifdef VOXELSHIFT_DISABLE_GPU
  return 0;
#else
  _ensure_backend_detected();
  return (g_gpu_enabled && g_gpu_backend != 0) ? 1 : 0;
#endif
}

/**
 * @brief Get the currently selected GPU backend code.
 * @return 0=none, 1=OpenCL, 2=Metal, 3=CUDA/Tensor.
 */
int32_t gpu_acceleration_backend(void) {
  _ensure_backend_detected();
  return g_gpu_backend;
}
