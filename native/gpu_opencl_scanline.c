/**
 * @file gpu_opencl_scanline.c
 * @brief OpenCL-based scanline builder for PNG generation.
 *
 * This module lazily loads the OpenCL runtime, compiles a small kernel,
 * and uses it to map greyscale subpixels to RGB/greyscale scanlines.
 */
#include "voxelshift_native.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
typedef HMODULE vs_lib_handle;
static vs_lib_handle vs_dlopen(const char* name) { return LoadLibraryA(name); }
static void* vs_dlsym(vs_lib_handle h, const char* sym) { return (void*)GetProcAddress(h, sym); }
typedef CRITICAL_SECTION vs_mutex;
static void vs_mutex_init(vs_mutex* m) { InitializeCriticalSection(m); }
static void vs_mutex_lock(vs_mutex* m) { EnterCriticalSection(m); }
static void vs_mutex_unlock(vs_mutex* m) { LeaveCriticalSection(m); }
#else
#include <dlfcn.h>
#include <pthread.h>
typedef void* vs_lib_handle;
static vs_lib_handle vs_dlopen(const char* name) { return dlopen(name, RTLD_LAZY); }
static void* vs_dlsym(vs_lib_handle h, const char* sym) { return dlsym(h, sym); }
typedef pthread_mutex_t vs_mutex;
static void vs_mutex_init(vs_mutex* m) { pthread_mutex_init(m, NULL); }
static void vs_mutex_lock(vs_mutex* m) { pthread_mutex_lock(m); }
static void vs_mutex_unlock(vs_mutex* m) { pthread_mutex_unlock(m); }
#endif

typedef intptr_t cl_int;
typedef uint32_t cl_uint;
typedef uint64_t cl_ulong;
typedef cl_uint cl_bool;
typedef cl_ulong cl_device_type;
typedef cl_ulong cl_mem_flags;
typedef cl_ulong cl_command_queue_properties;
typedef intptr_t cl_platform_info;
typedef intptr_t cl_device_info;
typedef intptr_t cl_program_build_info;

typedef struct _cl_platform_id* cl_platform_id;
typedef struct _cl_device_id* cl_device_id;
typedef struct _cl_context* cl_context;
typedef struct _cl_command_queue* cl_command_queue;
typedef struct _cl_program* cl_program;
typedef struct _cl_kernel* cl_kernel;
typedef struct _cl_mem* cl_mem;
typedef struct _cl_event* cl_event;

#define CL_SUCCESS 0
#define CL_TRUE 1
#define CL_DEVICE_TYPE_GPU ((cl_device_type)(1u << 2))
#define CL_MEM_READ_ONLY (1u << 2)
#define CL_MEM_WRITE_ONLY (1u << 1)
#define CL_MEM_COPY_HOST_PTR (1u << 5)

typedef cl_int (*clGetPlatformIDs_fn)(cl_uint, cl_platform_id*, cl_uint*);
typedef cl_int (*clGetDeviceIDs_fn)(cl_platform_id, cl_device_type, cl_uint, cl_device_id*, cl_uint*);
typedef cl_context (*clCreateContext_fn)(const intptr_t*, cl_uint, const cl_device_id*, void*, void*, cl_int*);
typedef cl_command_queue (*clCreateCommandQueue_fn)(cl_context, cl_device_id, cl_command_queue_properties, cl_int*);
typedef cl_program (*clCreateProgramWithSource_fn)(cl_context, cl_uint, const char**, const size_t*, cl_int*);
typedef cl_int (*clBuildProgram_fn)(cl_program, cl_uint, const cl_device_id*, const char*, void*, void*);
typedef cl_kernel (*clCreateKernel_fn)(cl_program, const char*, cl_int*);
typedef cl_mem (*clCreateBuffer_fn)(cl_context, cl_mem_flags, size_t, void*, cl_int*);
typedef cl_int (*clSetKernelArg_fn)(cl_kernel, cl_uint, size_t, const void*);
typedef cl_int (*clEnqueueNDRangeKernel_fn)(cl_command_queue, cl_kernel, cl_uint, const size_t*, const size_t*, const size_t*, cl_uint, const cl_event*, cl_event*);
typedef cl_int (*clEnqueueReadBuffer_fn)(cl_command_queue, cl_mem, cl_bool, size_t, size_t, void*, cl_uint, const cl_event*, cl_event*);
typedef cl_int (*clFinish_fn)(cl_command_queue);
typedef cl_int (*clReleaseMemObject_fn)(cl_mem);
typedef cl_int (*clReleaseKernel_fn)(cl_kernel);
typedef cl_int (*clReleaseProgram_fn)(cl_program);
typedef cl_int (*clReleaseCommandQueue_fn)(cl_command_queue);
typedef cl_int (*clReleaseContext_fn)(cl_context);

typedef struct OpenClApi {
  int loaded;
  int available;
  vs_lib_handle lib;
  clGetPlatformIDs_fn clGetPlatformIDs_ptr;
  clGetDeviceIDs_fn clGetDeviceIDs_ptr;
  clCreateContext_fn clCreateContext_ptr;
  clCreateCommandQueue_fn clCreateCommandQueue_ptr;
  clCreateProgramWithSource_fn clCreateProgramWithSource_ptr;
  clBuildProgram_fn clBuildProgram_ptr;
  clCreateKernel_fn clCreateKernel_ptr;
  clCreateBuffer_fn clCreateBuffer_ptr;
  clSetKernelArg_fn clSetKernelArg_ptr;
  clEnqueueNDRangeKernel_fn clEnqueueNDRangeKernel_ptr;
  clEnqueueReadBuffer_fn clEnqueueReadBuffer_ptr;
  clFinish_fn clFinish_ptr;
  clReleaseMemObject_fn clReleaseMemObject_ptr;
  clReleaseKernel_fn clReleaseKernel_ptr;
  clReleaseProgram_fn clReleaseProgram_ptr;
  clReleaseCommandQueue_fn clReleaseCommandQueue_ptr;
  clReleaseContext_fn clReleaseContext_ptr;
} OpenClApi;

typedef struct OpenClRuntime {
  int initialized;
  int ready;
  cl_context context;
  cl_command_queue queue;
  cl_program program;
  cl_kernel kernel;
  cl_device_id device;
  vs_mutex lock;
} OpenClRuntime;

static OpenClApi g_cl = {0};
static OpenClRuntime g_rt = {0};

/**
 * @brief OpenCL kernel source for mapping subpixels to output pixels.
 */
static const char* k_scanline_kernel_src =
    "__kernel void map_pixels(__global const uchar* src, int src_width, int out_width, int channels, int pad_left, __global uchar* dst) {\n"
    "  const size_t x = get_global_id(0);\n"
    "  const size_t y = get_global_id(1);\n"
    "  if ((int)x >= out_width) return;\n"
    "  const int src_row = (int)y * src_width;\n"
    "  const int dst_base = ((int)y * out_width + (int)x) * channels;\n"
    "  if (channels == 3) {\n"
    "    const int si = (int)x * 3 - pad_left;\n"
    "    const uchar a = (si >= 0 && si < src_width) ? src[src_row + si] : (uchar)0;\n"
    "    const uchar b = (si + 1 >= 0 && si + 1 < src_width) ? src[src_row + si + 1] : (uchar)0;\n"
    "    const uchar c = (si + 2 >= 0 && si + 2 < src_width) ? src[src_row + si + 2] : (uchar)0;\n"
    "    dst[dst_base + 0] = a;\n"
    "    dst[dst_base + 1] = b;\n"
    "    dst[dst_base + 2] = c;\n"
    "  } else {\n"
    "    const int si = (int)x * 2 - pad_left;\n"
    "    const uchar a = (si >= 0 && si < src_width) ? src[src_row + si] : (uchar)0;\n"
    "    const uchar b = (si + 1 >= 0 && si + 1 < src_width) ? src[src_row + si + 1] : (uchar)0;\n"
    "    dst[dst_base] = (uchar)(((int)a + (int)b) >> 1);\n"
    "  }\n"
    "}\n";

/**
 * @brief Resolve OpenCL symbols from the runtime library.
 */
static int _load_opencl_symbols(void) {
  if (g_cl.loaded) return g_cl.available;
  g_cl.loaded = 1;

#ifdef _WIN32
  const char* cands[] = {"OpenCL.dll"};
#else
  const char* cands[] = {"libOpenCL.so.1", "libOpenCL.so"};
#endif

  for (size_t i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
    g_cl.lib = vs_dlopen(cands[i]);
    if (!g_cl.lib) continue;

    g_cl.clGetPlatformIDs_ptr = (clGetPlatformIDs_fn)vs_dlsym(g_cl.lib, "clGetPlatformIDs");
    g_cl.clGetDeviceIDs_ptr = (clGetDeviceIDs_fn)vs_dlsym(g_cl.lib, "clGetDeviceIDs");
    g_cl.clCreateContext_ptr = (clCreateContext_fn)vs_dlsym(g_cl.lib, "clCreateContext");
    g_cl.clCreateCommandQueue_ptr = (clCreateCommandQueue_fn)vs_dlsym(g_cl.lib, "clCreateCommandQueue");
    g_cl.clCreateProgramWithSource_ptr = (clCreateProgramWithSource_fn)vs_dlsym(g_cl.lib, "clCreateProgramWithSource");
    g_cl.clBuildProgram_ptr = (clBuildProgram_fn)vs_dlsym(g_cl.lib, "clBuildProgram");
    g_cl.clCreateKernel_ptr = (clCreateKernel_fn)vs_dlsym(g_cl.lib, "clCreateKernel");
    g_cl.clCreateBuffer_ptr = (clCreateBuffer_fn)vs_dlsym(g_cl.lib, "clCreateBuffer");
    g_cl.clSetKernelArg_ptr = (clSetKernelArg_fn)vs_dlsym(g_cl.lib, "clSetKernelArg");
    g_cl.clEnqueueNDRangeKernel_ptr = (clEnqueueNDRangeKernel_fn)vs_dlsym(g_cl.lib, "clEnqueueNDRangeKernel");
    g_cl.clEnqueueReadBuffer_ptr = (clEnqueueReadBuffer_fn)vs_dlsym(g_cl.lib, "clEnqueueReadBuffer");
    g_cl.clFinish_ptr = (clFinish_fn)vs_dlsym(g_cl.lib, "clFinish");
    g_cl.clReleaseMemObject_ptr = (clReleaseMemObject_fn)vs_dlsym(g_cl.lib, "clReleaseMemObject");
    g_cl.clReleaseKernel_ptr = (clReleaseKernel_fn)vs_dlsym(g_cl.lib, "clReleaseKernel");
    g_cl.clReleaseProgram_ptr = (clReleaseProgram_fn)vs_dlsym(g_cl.lib, "clReleaseProgram");
    g_cl.clReleaseCommandQueue_ptr = (clReleaseCommandQueue_fn)vs_dlsym(g_cl.lib, "clReleaseCommandQueue");
    g_cl.clReleaseContext_ptr = (clReleaseContext_fn)vs_dlsym(g_cl.lib, "clReleaseContext");

    if (g_cl.clGetPlatformIDs_ptr &&
        g_cl.clGetDeviceIDs_ptr &&
        g_cl.clCreateContext_ptr &&
        g_cl.clCreateCommandQueue_ptr &&
        g_cl.clCreateProgramWithSource_ptr &&
        g_cl.clBuildProgram_ptr &&
        g_cl.clCreateKernel_ptr &&
        g_cl.clCreateBuffer_ptr &&
        g_cl.clSetKernelArg_ptr &&
        g_cl.clEnqueueNDRangeKernel_ptr &&
        g_cl.clEnqueueReadBuffer_ptr &&
        g_cl.clFinish_ptr &&
        g_cl.clReleaseMemObject_ptr &&
        g_cl.clReleaseKernel_ptr &&
        g_cl.clReleaseProgram_ptr &&
        g_cl.clReleaseCommandQueue_ptr &&
        g_cl.clReleaseContext_ptr) {
      g_cl.available = 1;
      return 1;
    }
  }

  g_cl.available = 0;
  return 0;
}

/**
 * @brief Initialize OpenCL context, queue, and kernel (locked).
 */
static int _init_opencl_runtime_locked(void) {
  if (g_rt.initialized) return g_rt.ready;
  g_rt.initialized = 1;

  if (!_load_opencl_symbols()) {
    g_rt.ready = 0;
    return 0;
  }

  cl_uint platform_count = 0;
  if (g_cl.clGetPlatformIDs_ptr(0, NULL, &platform_count) != CL_SUCCESS || platform_count == 0) {
    g_rt.ready = 0;
    return 0;
  }

  cl_platform_id* platforms = (cl_platform_id*)malloc(sizeof(cl_platform_id) * platform_count);
  if (!platforms) {
    g_rt.ready = 0;
    return 0;
  }

  if (g_cl.clGetPlatformIDs_ptr(platform_count, platforms, NULL) != CL_SUCCESS) {
    free(platforms);
    g_rt.ready = 0;
    return 0;
  }

  cl_device_id selected_device = NULL;
  for (cl_uint i = 0; i < platform_count; i++) {
    cl_device_id dev = NULL;
    if (g_cl.clGetDeviceIDs_ptr(platforms[i], CL_DEVICE_TYPE_GPU, 1, &dev, NULL) == CL_SUCCESS && dev != NULL) {
      selected_device = dev;
      break;
    }
  }
  free(platforms);

  if (!selected_device) {
    g_rt.ready = 0;
    return 0;
  }

  cl_int err = CL_SUCCESS;
  g_rt.context = g_cl.clCreateContext_ptr(NULL, 1, &selected_device, NULL, NULL, &err);
  if (!g_rt.context || err != CL_SUCCESS) {
    g_rt.ready = 0;
    return 0;
  }

  g_rt.queue = g_cl.clCreateCommandQueue_ptr(g_rt.context, selected_device, 0, &err);
  if (!g_rt.queue || err != CL_SUCCESS) {
    g_cl.clReleaseContext_ptr(g_rt.context);
    g_rt.context = NULL;
    g_rt.ready = 0;
    return 0;
  }

  const char* srcs[] = {k_scanline_kernel_src};
  g_rt.program = g_cl.clCreateProgramWithSource_ptr(g_rt.context, 1, srcs, NULL, &err);
  if (!g_rt.program || err != CL_SUCCESS) {
    g_cl.clReleaseCommandQueue_ptr(g_rt.queue);
    g_cl.clReleaseContext_ptr(g_rt.context);
    g_rt.queue = NULL;
    g_rt.context = NULL;
    g_rt.ready = 0;
    return 0;
  }

  err = g_cl.clBuildProgram_ptr(g_rt.program, 1, &selected_device, NULL, NULL, NULL);
  if (err != CL_SUCCESS) {
    g_cl.clReleaseProgram_ptr(g_rt.program);
    g_cl.clReleaseCommandQueue_ptr(g_rt.queue);
    g_cl.clReleaseContext_ptr(g_rt.context);
    g_rt.program = NULL;
    g_rt.queue = NULL;
    g_rt.context = NULL;
    g_rt.ready = 0;
    return 0;
  }

  g_rt.kernel = g_cl.clCreateKernel_ptr(g_rt.program, "map_pixels", &err);
  if (!g_rt.kernel || err != CL_SUCCESS) {
    g_cl.clReleaseProgram_ptr(g_rt.program);
    g_cl.clReleaseCommandQueue_ptr(g_rt.queue);
    g_cl.clReleaseContext_ptr(g_rt.context);
    g_rt.kernel = NULL;
    g_rt.program = NULL;
    g_rt.queue = NULL;
    g_rt.context = NULL;
    g_rt.ready = 0;
    return 0;
  }

  g_rt.device = selected_device;
  g_rt.ready = 1;
  return 1;
}

/**
 * @brief Thread-safe runtime initialization wrapper.
 */
static int _ensure_runtime_init(void) {
  if (!g_rt.initialized) {
    vs_mutex_init(&g_rt.lock);
  }
  vs_mutex_lock(&g_rt.lock);
  const int ready = _init_opencl_runtime_locked();
  vs_mutex_unlock(&g_rt.lock);
  return ready;
}

/**
 * @brief Build PNG scanlines using OpenCL for the pixel mapping step.
 *
 * Produces Up-filtered scanlines in host memory; returns 1 on success.
 */
int gpu_opencl_build_scanlines(
    const uint8_t* grey_pixels,
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels,
    uint8_t* out_scanlines,
    int32_t out_len) {
  if (!grey_pixels || !out_scanlines || src_width <= 0 || height <= 0 || out_width <= 0 ||
      (channels != 1 && channels != 3)) {
    return 0;
  }

  const int32_t bytes_per_row = out_width * channels;
  const int32_t scanline_size = 1 + bytes_per_row;
  const int32_t required_len = scanline_size * height;
  const int32_t body_len = bytes_per_row * height;

  if (out_len < required_len || body_len <= 0) {
    return 0;
  }

  if (!_ensure_runtime_init()) {
    return 0;
  }

  uint8_t* body = (uint8_t*)malloc((size_t)body_len);
  if (!body) {
    return 0;
  }

  const int32_t required_subpixels = out_width * channels;
  const int32_t pad_total = required_subpixels - src_width;
  const int32_t pad_left = pad_total > 0 ? (pad_total / 2) : 0;

  const size_t in_len = (size_t)src_width * (size_t)height;
  const size_t out_body_len = (size_t)body_len;

  int ok = 0;
  cl_mem src_buf = NULL;
  cl_mem dst_buf = NULL;

  vs_mutex_lock(&g_rt.lock);
  if (!g_rt.ready) {
    vs_mutex_unlock(&g_rt.lock);
    free(body);
    return 0;
  }

  cl_int err = CL_SUCCESS;
  src_buf = g_cl.clCreateBuffer_ptr(
      g_rt.context,
      CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR,
      in_len,
      (void*)grey_pixels,
      &err);
  if (!src_buf || err != CL_SUCCESS) {
    goto done;
  }

  dst_buf = g_cl.clCreateBuffer_ptr(g_rt.context, CL_MEM_WRITE_ONLY, out_body_len, NULL, &err);
  if (!dst_buf || err != CL_SUCCESS) {
    goto done;
  }

  err = g_cl.clSetKernelArg_ptr(g_rt.kernel, 0, sizeof(cl_mem), &src_buf);
  err |= g_cl.clSetKernelArg_ptr(g_rt.kernel, 1, sizeof(int32_t), &src_width);
  err |= g_cl.clSetKernelArg_ptr(g_rt.kernel, 2, sizeof(int32_t), &out_width);
  err |= g_cl.clSetKernelArg_ptr(g_rt.kernel, 3, sizeof(int32_t), &channels);
  err |= g_cl.clSetKernelArg_ptr(g_rt.kernel, 4, sizeof(int32_t), &pad_left);
  err |= g_cl.clSetKernelArg_ptr(g_rt.kernel, 5, sizeof(cl_mem), &dst_buf);
  if (err != CL_SUCCESS) {
    goto done;
  }

  const size_t global[2] = {(size_t)out_width, (size_t)height};
  err = g_cl.clEnqueueNDRangeKernel_ptr(g_rt.queue, g_rt.kernel, 2, NULL, global, NULL, 0, NULL, NULL);
  if (err != CL_SUCCESS) {
    goto done;
  }

  err = g_cl.clEnqueueReadBuffer_ptr(g_rt.queue, dst_buf, CL_TRUE, 0, out_body_len, body, 0, NULL, NULL);
  if (err != CL_SUCCESS) {
    goto done;
  }

  if (g_cl.clFinish_ptr(g_rt.queue) != CL_SUCCESS) {
    goto done;
  }

  ok = 1;

done:
  if (src_buf) g_cl.clReleaseMemObject_ptr(src_buf);
  if (dst_buf) g_cl.clReleaseMemObject_ptr(dst_buf);
  vs_mutex_unlock(&g_rt.lock);

  if (!ok) {
    free(body);
    return 0;
  }

  for (int32_t y = 0; y < height; y++) {
    const int32_t dst_row = y * scanline_size;
    const int32_t src_row = y * bytes_per_row;
    out_scanlines[dst_row] = 0;
    memcpy(out_scanlines + dst_row + 1, body + src_row, (size_t)bytes_per_row);
  }
  free(body);

  for (int32_t y = height - 1; y >= 1; y--) {
    const int32_t cur_start = y * scanline_size;
    const int32_t prev_start = (y - 1) * scanline_size;
    out_scanlines[cur_start] = 2;
    for (int32_t i = 1; i <= bytes_per_row; i++) {
      out_scanlines[cur_start + i] =
          (uint8_t)((out_scanlines[cur_start + i] - out_scanlines[prev_start + i]) & 0xFF);
    }
  }
  out_scanlines[0] = 2;

  return 1;
}