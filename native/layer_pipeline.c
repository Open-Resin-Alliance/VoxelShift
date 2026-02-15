/**
 * @file layer_pipeline.c
 * @brief Native layer processing pipeline (decode → scanlines → PNG).
 *
 * Provides a multi-threaded batch processor with optional GPU acceleration
 * and an alternate phased pipeline. Handles CTB RLE decode, area stats,
 * scanline construction, zlib compression, and PNG wrapping.
 */
#include "voxelshift_native.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
typedef CRITICAL_SECTION vs_mutex;
static void vs_mutex_init(vs_mutex* m) { InitializeCriticalSection(m); }
static void vs_mutex_lock(vs_mutex* m) { EnterCriticalSection(m); }
static void vs_mutex_unlock(vs_mutex* m) { LeaveCriticalSection(m); }
static void vs_mutex_destroy(vs_mutex* m) { DeleteCriticalSection(m); }
static int32_t _cpu_threads(void) {
  DWORD n = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
  if (n == 0) n = 1;
  return (int32_t)n;
}
#else
#include <dlfcn.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
typedef pthread_mutex_t vs_mutex;
static void vs_mutex_init(vs_mutex* m) { pthread_mutex_init(m, NULL); }
static void vs_mutex_lock(vs_mutex* m) { pthread_mutex_lock(m); }
static void vs_mutex_unlock(vs_mutex* m) { pthread_mutex_unlock(m); }
static void vs_mutex_destroy(vs_mutex* m) { pthread_mutex_destroy(m); }
static int32_t _cpu_threads(void) {
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  if (n < 1) n = 1;
  return (int32_t)n;
}
typedef void* vs_lib_handle;
static vs_lib_handle vs_dlopen(const char* name) { return dlopen(name, RTLD_LAZY); }
static void* vs_dlsym(vs_lib_handle h, const char* sym) { return dlsym(h, sym); }
#endif

typedef int (*compress2_fn)(unsigned char*, unsigned long*, const unsigned char*, unsigned long, int);

int gpu_opencl_build_scanlines(
  const uint8_t* grey_pixels,
  int32_t src_width,
  int32_t height,
  int32_t out_width,
  int32_t channels,
  uint8_t* out_scanlines,
  int32_t out_len);

int gpu_cuda_tensor_build_scanlines(
  const uint8_t* grey_pixels,
  int32_t src_width,
  int32_t height,
  int32_t out_width,
  int32_t channels,
  uint8_t* out_scanlines,
  int32_t out_len);

int gpu_cuda_tensor_build_scanlines_batch(
  const uint8_t* pixels_blob,
  int32_t layer_count,
  int32_t src_width,
  int32_t height,
  int32_t out_width,
  int32_t channels,
  uint8_t* out_scanlines_blob,
  int32_t scanlines_per_layer_bytes);

int gpu_cuda_tensor_init(void);
const char* gpu_cuda_tensor_device_name(void);
int64_t gpu_cuda_tensor_vram_bytes(void);
int32_t gpu_cuda_tensor_has_tensor_cores(void);
int32_t gpu_cuda_tensor_compute_capability(void);
int32_t gpu_cuda_tensor_multiprocessor_count(void);
int32_t gpu_cuda_tensor_last_error_code(void);
int32_t gpu_cuda_tensor_max_concurrent_layers(
    int32_t src_width, int32_t height,
    int32_t out_width, int32_t channels);

typedef struct ZlibApi {
  int loaded;
  int available;
  compress2_fn compress2_ptr;
} ZlibApi;

static ZlibApi g_zlib = {0, 0, NULL};
static int32_t g_process_layers_batch_threads = 0;
static int32_t g_last_process_layers_backend = 0; // 0 CPU, 1 OpenCL, 2 Metal, 3 CUDA/Tensor
static int32_t g_last_process_layers_gpu_attempts = 0;
static int32_t g_last_process_layers_gpu_successes = 0;
static int32_t g_last_process_layers_gpu_fallbacks = 0;
static int32_t g_last_process_layers_cuda_error = 0;
static int32_t g_process_layers_analytics_enabled = 0;
static int32_t g_last_process_layers_thread_count = 0;

typedef struct ProcessThreadMetrics {
  int64_t total_ns;
  int64_t decode_ns;
  int64_t scanline_ns;
  int64_t compress_ns;
  int64_t png_ns;
  int32_t layers;
} ProcessThreadMetrics;

static ProcessThreadMetrics* g_last_thread_metrics = NULL;
static int32_t g_last_thread_capacity = 0;

#ifdef _WIN32
static uint64_t _now_ns(void) {
  static LARGE_INTEGER freq;
  static int initialized = 0;
  if (!initialized) {
    QueryPerformanceFrequency(&freq);
    initialized = 1;
  }
  LARGE_INTEGER counter;
  QueryPerformanceCounter(&counter);
  return (uint64_t)((counter.QuadPart * 1000000000ULL) / freq.QuadPart);
}
#else
static uint64_t _now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}
#endif

/**
 * @brief Override the default worker count for process_layers_batch.
 * @param threads <= 0 resets to auto (CPU-count based).
 */
void set_process_layers_batch_threads(int32_t threads) {
  g_process_layers_batch_threads = threads;
}

void set_process_layers_batch_analytics(int32_t enabled) {
  g_process_layers_analytics_enabled = enabled ? 1 : 0;
}

int32_t process_layers_last_thread_count(void) {
  return g_last_process_layers_thread_count;
}

void process_layers_last_thread_stats(
    int64_t* out_total_ns,
    int64_t* out_decode_ns,
    int64_t* out_scanline_ns,
    int64_t* out_compress_ns,
    int64_t* out_png_ns,
    int32_t* out_layers,
    int32_t max_count) {
  if (!out_total_ns || !out_decode_ns || !out_scanline_ns ||
      !out_compress_ns || !out_png_ns || !out_layers || max_count <= 0) {
    return;
  }

  const int32_t count = g_last_process_layers_thread_count;
  if (!g_last_thread_metrics || count <= 0) return;
  const int32_t n = count < max_count ? count : max_count;

  for (int32_t i = 0; i < n; i++) {
    const ProcessThreadMetrics* m = &g_last_thread_metrics[i];
    out_total_ns[i] = m->total_ns;
    out_decode_ns[i] = m->decode_ns;
    out_scanline_ns[i] = m->scanline_ns;
    out_compress_ns[i] = m->compress_ns;
    out_png_ns[i] = m->png_ns;
    out_layers[i] = m->layers;
  }
}

/**
 * @brief Backend used by the most recent batch call.
 */
int32_t process_layers_last_backend(void) {
  return g_last_process_layers_backend;
}

/**
 * @brief Number of layers that attempted GPU processing in the last batch.
 */
int32_t process_layers_last_gpu_attempts(void) {
  return g_last_process_layers_gpu_attempts;
}

/**
 * @brief Number of layers that succeeded on GPU in the last batch.
 */
int32_t process_layers_last_gpu_successes(void) {
  return g_last_process_layers_gpu_successes;
}

/**
 * @brief Number of layers that fell back to CPU in the last batch.
 */
int32_t process_layers_last_gpu_fallbacks(void) {
  return g_last_process_layers_gpu_fallbacks;
}

/**
 * @brief Last CUDA error observed during batch processing (0 if none).
 */
int32_t process_layers_last_cuda_error(void) {
  return g_last_process_layers_cuda_error;
}

static void _init_zlib(void) {
  if (g_zlib.loaded) return;
  g_zlib.loaded = 1;

  const char* candidates[] = {
#ifdef _WIN32
      "zlib1.dll", "zlib.dll",
#elif __APPLE__
      "libz.1.dylib", "libz.dylib",
#else
      "libz.so.1", "libz.so",
#endif
  };

  for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
#ifdef _WIN32
    HMODULE h = LoadLibraryA(candidates[i]);
    if (!h) continue;
    compress2_fn c2 = (compress2_fn)GetProcAddress(h, "compress2");
#else
    vs_lib_handle h = vs_dlopen(candidates[i]);
    if (!h) continue;
    compress2_fn c2 = (compress2_fn)vs_dlsym(h, "compress2");
#endif
    if (c2) {
      g_zlib.compress2_ptr = c2;
      g_zlib.available = 1;
      return;
    }
  }
}

static uint32_t _crc32_table[256];
static int _crc32_ready = 0;

static void _init_crc32_table(void) {
  if (_crc32_ready) return;
  for (uint32_t i = 0; i < 256; i++) {
    uint32_t c = i;
    for (int k = 0; k < 8; k++) {
      c = (c & 1u) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
    }
    _crc32_table[i] = c;
  }
  _crc32_ready = 1;
}

static uint32_t _crc32_type_and_data(const uint8_t type[4], const uint8_t* data, size_t len) {
  _init_crc32_table();
  uint32_t c = 0xFFFFFFFFu;
  for (int i = 0; i < 4; i++) {
    c = _crc32_table[(c ^ type[i]) & 0xFFu] ^ (c >> 8);
  }
  for (size_t i = 0; i < len; i++) {
    c = _crc32_table[(c ^ data[i]) & 0xFFu] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFFu;
}

static uint32_t _crc32_bytes(const uint8_t* data, size_t len) {
  _init_crc32_table();
  uint32_t c = 0xFFFFFFFFu;
  for (size_t i = 0; i < len; i++) {
    c = _crc32_table[(c ^ data[i]) & 0xFFu] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFFu;
}

static void _write_u32_be(uint8_t* p, uint32_t v) {
  p[0] = (uint8_t)((v >> 24) & 0xFFu);
  p[1] = (uint8_t)((v >> 16) & 0xFFu);
  p[2] = (uint8_t)((v >> 8) & 0xFFu);
  p[3] = (uint8_t)(v & 0xFFu);
}

/**
 * @brief Build a full PNG file from an IDAT payload.
 */
static uint8_t* _build_png_from_idat(
    int32_t width,
    int32_t height,
    int32_t channels,
    const uint8_t* idat,
    size_t idat_len,
    int32_t* out_png_len) {
  const uint8_t sig[8] = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
  const uint8_t color_type = channels == 3 ? 2 : 0;

  uint8_t ihdr[13];
  _write_u32_be(ihdr + 0, (uint32_t)width);
  _write_u32_be(ihdr + 4, (uint32_t)height);
  ihdr[8] = 8;
  ihdr[9] = color_type;
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  const size_t out_size = 8 + (12 + 13) + (12 + idat_len) + 12;
  uint8_t* out = (uint8_t*)malloc(out_size);
  if (!out) return NULL;

  size_t w = 0;
  memcpy(out + w, sig, 8); w += 8;

  _write_u32_be(out + w, 13); w += 4;
  out[w++] = 'I'; out[w++] = 'H'; out[w++] = 'D'; out[w++] = 'R';
  memcpy(out + w, ihdr, 13); w += 13;
  {
    const uint8_t t[4] = {'I','H','D','R'};
    _write_u32_be(out + w, _crc32_type_and_data(t, ihdr, 13));
    w += 4;
  }

  _write_u32_be(out + w, (uint32_t)idat_len); w += 4;
  out[w++] = 'I'; out[w++] = 'D'; out[w++] = 'A'; out[w++] = 'T';
  memcpy(out + w, idat, idat_len); w += idat_len;
  {
    const uint8_t t[4] = {'I','D','A','T'};
    _write_u32_be(out + w, _crc32_type_and_data(t, idat, idat_len));
    w += 4;
  }

  _write_u32_be(out + w, 0); w += 4;
  out[w++] = 'I'; out[w++] = 'E'; out[w++] = 'N'; out[w++] = 'D';
  {
    const uint8_t t[4] = {'I','E','N','D'};
    _write_u32_be(out + w, _crc32_bytes(t, 4));
    w += 4;
  }

  *out_png_len = (int32_t)w;
  return out;
}

/**
 * @brief Build scanlines using GPU when available, otherwise CPU.
 *
 * Updates backend usage counters and returns 1 on success.
 */
static int _build_scanlines_auto(
    const uint8_t* pixels,
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels,
    int32_t allow_gpu,
    uint8_t* scanlines,
    int32_t scanlines_len,
    int32_t* out_backend_used,
    int32_t* out_gpu_attempted,
    int32_t* out_gpu_succeeded) {
  if (out_backend_used) *out_backend_used = 0;
  if (out_gpu_attempted) *out_gpu_attempted = 0;
  if (out_gpu_succeeded) *out_gpu_succeeded = 0;

  if (allow_gpu && gpu_acceleration_active()) {
    const int32_t backend = gpu_acceleration_backend();

    if ((backend == 1 || backend == 3) && out_gpu_attempted) {
      *out_gpu_attempted = 1;
    }

    if (backend == 3) {
      if (gpu_cuda_tensor_build_scanlines(
              pixels,
              src_width,
              height,
              out_width,
              channels,
              scanlines,
              scanlines_len)) {
        if (out_backend_used) *out_backend_used = 3;
        if (out_gpu_succeeded) *out_gpu_succeeded = 1;
        return 1;
      }
    }

    if (backend == 1) {
      if (gpu_opencl_build_scanlines(
              pixels,
              src_width,
              height,
              out_width,
              channels,
              scanlines,
              scanlines_len)) {
        if (out_backend_used) *out_backend_used = 1;
        if (out_gpu_succeeded) *out_gpu_succeeded = 1;
        return 1;
      }
    }
  }

  return build_png_scanlines(
      pixels,
      src_width,
      height,
      out_width,
      channels,
      scanlines,
      scanlines_len);
}

typedef struct ProcessBatchWork {
  const uint8_t* input_blob;
  int32_t input_blob_len;
  const int32_t* input_offsets;
  const int32_t* input_lengths;
  int32_t count;
  int32_t layer_index_base;
  int32_t encryption_key;
  int32_t src_width;
  int32_t height;
  int32_t out_width;
  int32_t channels;
  double x_pixel_size_mm;
  double y_pixel_size_mm;
  int32_t png_level;
  int32_t allow_gpu;
  int32_t used_gpu;
  int32_t gpu_attempts;
  int32_t gpu_successes;
  int32_t gpu_fallbacks;
  int32_t last_cuda_error;

  uint8_t** out_items;
  int32_t* out_sizes;
  AreaStatsResult* out_areas;

  int32_t next_index;
  int32_t failed;
  vs_mutex lock;

  int32_t analytics_enabled;
  ProcessThreadMetrics* thread_metrics;
  int32_t thread_metrics_count;
} ProcessBatchWork;

typedef struct ProcessThreadScratch {
  uint8_t* pixels;
  uint8_t* scanlines;
  uint8_t* compressed;
  unsigned long compressed_cap;
} ProcessThreadScratch;

static int _take_process_range(
    ProcessBatchWork* w,
    int32_t claim,
    int32_t* out_start,
    int32_t* out_end) {
  int ok = 0;
  vs_mutex_lock(&w->lock);
  if (!w->failed && w->next_index < w->count) {
    const int32_t start = w->next_index;
    int32_t end = start + claim;
    if (end > w->count) end = w->count;
    w->next_index = end;
    *out_start = start;
    *out_end = end;
    ok = 1;
  }
  vs_mutex_unlock(&w->lock);
  return ok;
}

static void _set_process_failed(ProcessBatchWork* w) {
  vs_mutex_lock(&w->lock);
  w->failed = 1;
  vs_mutex_unlock(&w->lock);
}

static int _init_process_thread_scratch(
    ProcessBatchWork* w,
    ProcessThreadScratch* s) {
  const int32_t pixel_count = w->src_width * w->height;
  const int32_t bytes_per_row = w->out_width * w->channels;
  const int32_t scanline_size = 1 + bytes_per_row;
  const int32_t scanlines_len = scanline_size * w->height;

  if (pixel_count <= 0 || scanlines_len <= 0) return 0;

  s->pixels = (uint8_t*)malloc((size_t)pixel_count);
  s->scanlines = (uint8_t*)malloc((size_t)scanlines_len);
  s->compressed_cap =
      (unsigned long)scanlines_len + ((unsigned long)scanlines_len / 1000u) + 64u;
  s->compressed = (uint8_t*)malloc((size_t)s->compressed_cap);

  if (!s->pixels || !s->scanlines || !s->compressed) {
    free(s->pixels);
    free(s->scanlines);
    free(s->compressed);
    s->pixels = NULL;
    s->scanlines = NULL;
    s->compressed = NULL;
    s->compressed_cap = 0;
    return 0;
  }

  return 1;
}

static void _free_process_thread_scratch(ProcessThreadScratch* s) {
  free(s->pixels);
  free(s->scanlines);
  free(s->compressed);
  s->pixels = NULL;
  s->scanlines = NULL;
  s->compressed = NULL;
  s->compressed_cap = 0;
}

static void _process_one_layer(
    ProcessBatchWork* w,
    int32_t i,
    ProcessThreadScratch* s,
    int32_t thread_index) {
  const int analytics = w->analytics_enabled &&
      w->thread_metrics != NULL &&
      thread_index >= 0 &&
      thread_index < w->thread_metrics_count;
  uint64_t t_start = 0;
  uint64_t t_decode = 0;
  uint64_t t_scanline = 0;
  uint64_t t_compress = 0;
  uint64_t t_png = 0;
  if (analytics) t_start = _now_ns();
  const int32_t off = w->input_offsets[i];
  const int32_t len = w->input_lengths[i];

  if (off < 0 || len <= 0 || off + len > w->input_blob_len) {
    _set_process_failed(w);
    return;
  }

  const int32_t pixel_count = w->src_width * w->height;
  const int32_t bytes_per_row = w->out_width * w->channels;
  const int32_t scanline_size = 1 + bytes_per_row;
  const int32_t scanlines_len = scanline_size * w->height;

  if (pixel_count <= 0 || scanlines_len <= 0) {
    _set_process_failed(w);
    return;
  }
  uint8_t* pixels = s->pixels;
  uint8_t* scanlines = s->scanlines;
  uint8_t* compressed = s->compressed;
  if (!pixels || !scanlines || !compressed || s->compressed_cap == 0) {
    _set_process_failed(w);
    return;
  }

  uint64_t t0 = 0;
  if (analytics) t0 = _now_ns();
  const int ok_decode = decrypt_and_decode_layer(
      w->input_blob + off,
      len,
      w->layer_index_base + i,
      w->encryption_key,
      pixel_count,
      pixels);
  if (!ok_decode) {
    _set_process_failed(w);
    return;
  }

  if (!compute_layer_area_stats(
          pixels,
          w->src_width,
          w->height,
          w->x_pixel_size_mm,
          w->y_pixel_size_mm,
          &w->out_areas[i])) {
    _set_process_failed(w);
    return;
  }
  if (analytics) t_decode += (_now_ns() - t0);

  int32_t backend_used = 0;
  int32_t gpu_attempted = 0;
  int32_t gpu_succeeded = 0;

  if (analytics) t0 = _now_ns();
  if (!_build_scanlines_auto(
          pixels,
          w->src_width,
          w->height,
          w->out_width,
          w->channels,
          w->allow_gpu,
          scanlines,
          scanlines_len,
          &backend_used,
          &gpu_attempted,
          &gpu_succeeded)) {
    _set_process_failed(w);
    return;
  }
  if (analytics) t_scanline += (_now_ns() - t0);

  if (backend_used == 1 || backend_used == 3 || gpu_attempted) {
    vs_mutex_lock(&w->lock);
    if (backend_used == 1 || backend_used == 3) {
      w->used_gpu = backend_used;
    }
    w->gpu_attempts += gpu_attempted;
    w->gpu_successes += gpu_succeeded;
    if (gpu_attempted && !gpu_succeeded) {
      w->gpu_fallbacks += 1;
      if (backend_used == 0) {
        const int32_t err = gpu_cuda_tensor_last_error_code();
        if (err != 0) {
          w->last_cuda_error = err;
        }
      }
    }
    vs_mutex_unlock(&w->lock);
  }

  int32_t level = w->png_level;
  if (level < 0) level = 0;
  if (level > 9) level = 9;

  if (analytics) t0 = _now_ns();
  unsigned long comp_len = s->compressed_cap;
  const int ok_comp = g_zlib.compress2_ptr(
      compressed,
      &comp_len,
      scanlines,
      (unsigned long)scanlines_len,
      level);

  if (ok_comp != 0 || comp_len == 0) {
    _set_process_failed(w);
    return;
  }
  if (analytics) t_compress += (_now_ns() - t0);

  int32_t png_len = 0;
  if (analytics) t0 = _now_ns();
  uint8_t* png = _build_png_from_idat(
      w->out_width,
      w->height,
      w->channels,
      compressed,
      (size_t)comp_len,
      &png_len);

  if (!png || png_len <= 0) {
    free(png);
    _set_process_failed(w);
    return;
  }
  if (analytics) t_png += (_now_ns() - t0);

  w->out_items[i] = png;
  w->out_sizes[i] = png_len;

  if (analytics) {
    ProcessThreadMetrics* m = &w->thread_metrics[thread_index];
    m->layers += 1;
    m->total_ns += (_now_ns() - t_start);
    m->decode_ns += t_decode;
    m->scanline_ns += t_scanline;
    m->compress_ns += t_compress;
    m->png_ns += t_png;
  }
}

#ifdef _WIN32
typedef struct ProcessThreadParams {
  ProcessBatchWork* work;
  int32_t thread_index;
} ProcessThreadParams;

static DWORD WINAPI _process_batch_worker(LPVOID arg) {
  ProcessThreadParams* p = (ProcessThreadParams*)arg;
  ProcessBatchWork* w = p->work;
  const int32_t thread_index = p->thread_index;
  ProcessThreadScratch s = {0};
  if (!_init_process_thread_scratch(w, &s)) {
    _set_process_failed(w);
    return 0;
  }

  int32_t start, end;
  while (_take_process_range(w, 4, &start, &end)) {
    for (int32_t idx = start; idx < end; idx++) {
      _process_one_layer(w, idx, &s, thread_index);
    }
  }

  _free_process_thread_scratch(&s);
  return 0;
}
#else
typedef struct ProcessThreadParams {
  ProcessBatchWork* work;
  int32_t thread_index;
} ProcessThreadParams;

static void* _process_batch_worker(void* arg) {
  ProcessThreadParams* p = (ProcessThreadParams*)arg;
  ProcessBatchWork* w = p->work;
  const int32_t thread_index = p->thread_index;
  ProcessThreadScratch s = {0};
  if (!_init_process_thread_scratch(w, &s)) {
    _set_process_failed(w);
    return NULL;
  }

  int32_t start, end;
  while (_take_process_range(w, 4, &start, &end)) {
    for (int32_t idx = start; idx < end; idx++) {
      _process_one_layer(w, idx, &s, thread_index);
    }
  }

  _free_process_thread_scratch(&s);
  return NULL;
}
#endif

/**
 * @brief Decode a CTB layer and build PNG scanlines in one call.
 */
int decode_and_build_png_scanlines(
    const uint8_t* data,
    int32_t data_len,
    int32_t layer_index,
    int32_t encryption_key,
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels,
    uint8_t* out_pixels,
    int32_t pixel_count,
    uint8_t* out_scanlines,
    int32_t out_len) {
  if (!data || data_len <= 0 || src_width <= 0 || height <= 0 ||
      out_width <= 0 || (channels != 1 && channels != 3) || !out_pixels ||
      pixel_count <= 0 || !out_scanlines || out_len <= 0) {
    return 0;
  }

  if (pixel_count != src_width * height) {
    return 0;
  }

  const int ok_decode = decrypt_and_decode_layer(
      data,
      data_len,
      layer_index,
      encryption_key,
      pixel_count,
      out_pixels);
  if (!ok_decode) {
    return 0;
  }

  const int ok_scanlines = build_png_scanlines(
      out_pixels,
      src_width,
      height,
      out_width,
      channels,
      out_scanlines,
      out_len);
  if (!ok_scanlines) {
    return 0;
  }

  return 1;
}

/**
 * @brief Decode a CTB layer, compute area stats, and build scanlines.
 */
int decode_build_scanlines_and_area(
    const uint8_t* data,
    int32_t data_len,
    int32_t layer_index,
    int32_t encryption_key,
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels,
    double x_pixel_size_mm,
    double y_pixel_size_mm,
    AreaStatsResult* out_area,
    uint8_t* out_scanlines,
    int32_t out_len) {
  if (!data || data_len <= 0 || src_width <= 0 || height <= 0 ||
      out_width <= 0 || (channels != 1 && channels != 3) || !out_area ||
      !out_scanlines || out_len <= 0) {
    return 0;
  }

  const int32_t pixel_count = src_width * height;
  if (pixel_count <= 0) {
    return 0;
  }

  uint8_t* pixels = (uint8_t*)malloc((size_t)pixel_count);
  if (!pixels) {
    return 0;
  }

  const int ok_decode = decrypt_and_decode_layer(
      data,
      data_len,
      layer_index,
      encryption_key,
      pixel_count,
      pixels);
  if (!ok_decode) {
    free(pixels);
    return 0;
  }

  const int ok_area = compute_layer_area_stats(
      pixels,
      src_width,
      height,
      x_pixel_size_mm,
      y_pixel_size_mm,
      out_area);
  if (!ok_area) {
    free(pixels);
    return 0;
  }

  const int ok_scanlines = build_png_scanlines(
      pixels,
      src_width,
      height,
      out_width,
      channels,
      out_scanlines,
      out_len);

  free(pixels);
  if (!ok_scanlines) {
    return 0;
  }

  return 1;
}

/**
 * @brief Process multiple layers with internal native worker threads.
 */
int process_layers_batch(
    const uint8_t* input_blob,
    int32_t input_blob_len,
    const int32_t* input_offsets,
    const int32_t* input_lengths,
    int32_t count,
    int32_t layer_index_base,
    int32_t encryption_key,
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels,
    double x_pixel_size_mm,
    double y_pixel_size_mm,
    int32_t png_level,
    int32_t thread_count,
    uint8_t** out_blob,
    int32_t* out_blob_len,
    int32_t** out_offsets,
    int32_t** out_lengths,
    AreaStatsResult** out_areas) {
  if (!input_blob || input_blob_len <= 0 || !input_offsets || !input_lengths ||
      count <= 0 || src_width <= 0 || height <= 0 || out_width <= 0 ||
      (channels != 1 && channels != 3) || !out_blob || !out_blob_len ||
      !out_offsets || !out_lengths || !out_areas) {
    return 0;
  }

  _init_zlib();
  if (!g_zlib.available) return 0;

  uint8_t** item_outputs = (uint8_t**)calloc((size_t)count, sizeof(uint8_t*));
  int32_t* item_sizes = (int32_t*)calloc((size_t)count, sizeof(int32_t));
  int32_t* offs = (int32_t*)malloc((size_t)count * sizeof(int32_t));
  int32_t* lens = (int32_t*)malloc((size_t)count * sizeof(int32_t));
  AreaStatsResult* areas = (AreaStatsResult*)malloc((size_t)count * sizeof(AreaStatsResult));

  if (!item_outputs || !item_sizes || !offs || !lens || !areas) {
    free(item_outputs); free(item_sizes); free(offs); free(lens); free(areas);
    return 0;
  }

  ProcessBatchWork work;
  work.input_blob = input_blob;
  work.input_blob_len = input_blob_len;
  work.input_offsets = input_offsets;
  work.input_lengths = input_lengths;
  work.count = count;
  work.layer_index_base = layer_index_base;
  work.encryption_key = encryption_key;
  work.src_width = src_width;
  work.height = height;
  work.out_width = out_width;
  work.channels = channels;
  work.x_pixel_size_mm = x_pixel_size_mm;
  work.y_pixel_size_mm = y_pixel_size_mm;
  work.png_level = png_level;
  work.out_items = item_outputs;
  work.out_sizes = item_sizes;
  work.out_areas = areas;
  work.allow_gpu = 0;
  work.used_gpu = 0;
  work.gpu_attempts = 0;
  work.gpu_successes = 0;
  work.gpu_fallbacks = 0;
  work.last_cuda_error = 0;
  work.next_index = 0;
  work.failed = 0;
  work.analytics_enabled = g_process_layers_analytics_enabled;
  work.thread_metrics = NULL;
  work.thread_metrics_count = 0;
  vs_mutex_init(&work.lock);

  int32_t threads = thread_count > 0 ? thread_count :
      (g_process_layers_batch_threads > 0 ? g_process_layers_batch_threads : _cpu_threads());
  if (threads < 1) threads = 1;
  if (threads > count) threads = count;

  // Hybrid mode: keep CPU decode/area/zlib multithreaded while GPU handles
  // scanline mapping. This gives better throughput than forcing a single
  // worker in most real jobs.
  work.allow_gpu = 1;

  if (threads == 1) {
    if (work.analytics_enabled) {
      if (g_last_thread_metrics) {
        free(g_last_thread_metrics);
        g_last_thread_metrics = NULL;
        g_last_thread_capacity = 0;
      }
      g_last_thread_metrics = (ProcessThreadMetrics*)calloc(
          1, sizeof(ProcessThreadMetrics));
      if (g_last_thread_metrics) {
        g_last_thread_capacity = 1;
        work.thread_metrics = g_last_thread_metrics;
        work.thread_metrics_count = 1;
      }
    }
    ProcessThreadScratch s = {0};
    if (!_init_process_thread_scratch(&work, &s)) {
      vs_mutex_destroy(&work.lock);
      free(item_outputs); free(item_sizes); free(offs); free(lens); free(areas);
      return 0;
    }

    for (int32_t i = 0; i < count; i++) {
      _process_one_layer(&work, i, &s, 0);
      if (work.failed) break;
    }

    _free_process_thread_scratch(&s);
  } else {
#ifdef _WIN32
    HANDLE* hs = (HANDLE*)malloc((size_t)threads * sizeof(HANDLE));
    ProcessThreadParams* params =
        (ProcessThreadParams*)malloc((size_t)threads * sizeof(ProcessThreadParams));
    if (!hs) {
      vs_mutex_destroy(&work.lock);
      free(item_outputs); free(item_sizes); free(offs); free(lens); free(areas);
      return 0;
    }
    if (!params) {
      free(hs);
      vs_mutex_destroy(&work.lock);
      free(item_outputs); free(item_sizes); free(offs); free(lens); free(areas);
      return 0;
    }
    if (work.analytics_enabled) {
      if (g_last_thread_metrics) {
        free(g_last_thread_metrics);
        g_last_thread_metrics = NULL;
        g_last_thread_capacity = 0;
      }
      g_last_thread_metrics = (ProcessThreadMetrics*)calloc(
          (size_t)threads, sizeof(ProcessThreadMetrics));
      if (g_last_thread_metrics) {
        g_last_thread_capacity = threads;
        work.thread_metrics = g_last_thread_metrics;
        work.thread_metrics_count = threads;
      }
    }
    int32_t started = 0;
    for (int32_t t = 0; t < threads; t++) {
      params[t].work = &work;
      params[t].thread_index = t;
      hs[t] = CreateThread(NULL, 0, _process_batch_worker, &params[t], 0, NULL);
      if (hs[t]) started++;
    }
    if (started == 0) {
      free(hs);
      vs_mutex_destroy(&work.lock);
      free(item_outputs); free(item_sizes); free(offs); free(lens); free(areas);
      return 0;
    }
    WaitForMultipleObjects((DWORD)started, hs, TRUE, INFINITE);
    for (int32_t t = 0; t < threads; t++) if (hs[t]) CloseHandle(hs[t]);
    free(hs);
    free(params);
#else
    pthread_t* ts = (pthread_t*)malloc((size_t)threads * sizeof(pthread_t));
    ProcessThreadParams* params =
        (ProcessThreadParams*)malloc((size_t)threads * sizeof(ProcessThreadParams));
    if (!ts) {
      vs_mutex_destroy(&work.lock);
      free(item_outputs); free(item_sizes); free(offs); free(lens); free(areas);
      return 0;
    }
    if (!params) {
      free(ts);
      vs_mutex_destroy(&work.lock);
      free(item_outputs); free(item_sizes); free(offs); free(lens); free(areas);
      return 0;
    }
    if (work.analytics_enabled) {
      if (g_last_thread_metrics) {
        free(g_last_thread_metrics);
        g_last_thread_metrics = NULL;
        g_last_thread_capacity = 0;
      }
      g_last_thread_metrics = (ProcessThreadMetrics*)calloc(
          (size_t)threads, sizeof(ProcessThreadMetrics));
      if (g_last_thread_metrics) {
        g_last_thread_capacity = threads;
        work.thread_metrics = g_last_thread_metrics;
        work.thread_metrics_count = threads;
      }
    }
    int32_t started = 0;
    for (int32_t t = 0; t < threads; t++) {
      params[t].work = &work;
      params[t].thread_index = t;
      if (pthread_create(&ts[t], NULL, _process_batch_worker, &params[t]) == 0) started++;
    }
    if (started == 0) {
      free(ts);
      free(params);
      vs_mutex_destroy(&work.lock);
      free(item_outputs); free(item_sizes); free(offs); free(lens); free(areas);
      return 0;
    }
    for (int32_t t = 0; t < started; t++) pthread_join(ts[t], NULL);
    free(ts);
    free(params);
#endif
  }

  vs_mutex_destroy(&work.lock);

  if (work.failed) {
    for (int32_t i = 0; i < count; i++) {
      if (item_outputs[i]) free(item_outputs[i]);
    }
    free(item_outputs); free(item_sizes); free(offs); free(lens); free(areas);
    return 0;
  }

  g_last_process_layers_backend = work.used_gpu;
  g_last_process_layers_gpu_attempts = work.gpu_attempts;
  g_last_process_layers_gpu_successes = work.gpu_successes;
  g_last_process_layers_gpu_fallbacks = work.gpu_fallbacks;
  g_last_process_layers_cuda_error = work.last_cuda_error;
  g_last_process_layers_thread_count = threads;

  int64_t total_len = 0;
  for (int32_t i = 0; i < count; i++) {
    if (!item_outputs[i] || item_sizes[i] <= 0) {
      for (int32_t j = 0; j < count; j++) if (item_outputs[j]) free(item_outputs[j]);
      free(item_outputs); free(item_sizes); free(offs); free(lens); free(areas);
      return 0;
    }
    offs[i] = (int32_t)total_len;
    lens[i] = item_sizes[i];
    total_len += item_sizes[i];
  }

  if (total_len <= 0 || total_len > 0x7FFFFFFF) {
    for (int32_t i = 0; i < count; i++) free(item_outputs[i]);
    free(item_outputs); free(item_sizes); free(offs); free(lens); free(areas);
    return 0;
  }

  uint8_t* blob = (uint8_t*)malloc((size_t)total_len);
  if (!blob) {
    for (int32_t i = 0; i < count; i++) free(item_outputs[i]);
    free(item_outputs); free(item_sizes); free(offs); free(lens); free(areas);
    return 0;
  }

  int32_t cur = 0;
  for (int32_t i = 0; i < count; i++) {
    memcpy(blob + cur, item_outputs[i], (size_t)item_sizes[i]);
    cur += item_sizes[i];
    free(item_outputs[i]);
  }

  free(item_outputs);
  free(item_sizes);

  *out_blob = blob;
  *out_blob_len = (int32_t)total_len;
  *out_offsets = offs;
  *out_lengths = lens;
  *out_areas = areas;
  return 1;
}

void free_native_area_buffer(AreaStatsResult* buffer) {
  free(buffer);
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASED PIPELINE (CPU+GPU HYBRID)
// ═══════════════════════════════════════════════════════════════════════════
//
// Instead of each thread doing all steps for one layer, we split into phases:
//
//   Phase 1  [All CPU cores]  Decode + area stats for chunk of layers
//   Phase 2  [GPU batch call] Build scanlines for all decoded layers at once
//            OR [CPU fallback] Multi-threaded scanline build
//   Phase 3  [All CPU cores]  zlib compress + PNG wrap
//
// This design:
//   - Keeps ALL CPU cores busy during decode and compress (the bottleneck)
//   - Uses GPU for scanlines in ONE mega-batch (amortizes PCIe overhead)
//   - Frees decoded pixels progressively to limit memory
// ═══════════════════════════════════════════════════════════════════════════

// ── Phase 1 worker: Decode + Area Stats ─────────────────────────────────────

typedef struct DecodePhaseWork {
  const uint8_t* input_blob;
  int32_t input_blob_len;
  const int32_t* input_offsets;
  const int32_t* input_lengths;
  int32_t count;
  int32_t layer_index_base;
  int32_t encryption_key;
  int32_t src_width;
  int32_t height;
  double x_pixel_size_mm;
  double y_pixel_size_mm;

  uint8_t** out_pixels;         // pre-allocated pixel buffers
  AreaStatsResult* out_areas;

  int32_t next_index;
  int32_t failed;
  vs_mutex lock;
} DecodePhaseWork;

static int _take_decode_range(DecodePhaseWork* w, int32_t claim,
                               int32_t* out_start, int32_t* out_end) {
  int ok = 0;
  vs_mutex_lock(&w->lock);
  if (!w->failed && w->next_index < w->count) {
    *out_start = w->next_index;
    int32_t end = w->next_index + claim;
    if (end > w->count) end = w->count;
    w->next_index = end;
    *out_end = end;
    ok = 1;
  }
  vs_mutex_unlock(&w->lock);
  return ok;
}

static void _decode_one_layer(DecodePhaseWork* w, int32_t i) {
  const int32_t off = w->input_offsets[i];
  const int32_t len = w->input_lengths[i];
  if (off < 0 || len <= 0 || off + len > w->input_blob_len) {
    vs_mutex_lock(&w->lock); w->failed = 1; vs_mutex_unlock(&w->lock);
    return;
  }

  const int32_t pixel_count = w->src_width * w->height;
  if (!decrypt_and_decode_layer(
          w->input_blob + off, len,
          w->layer_index_base + i, w->encryption_key,
          pixel_count, w->out_pixels[i])) {
    vs_mutex_lock(&w->lock); w->failed = 1; vs_mutex_unlock(&w->lock);
    return;
  }

  if (!compute_layer_area_stats(
          w->out_pixels[i], w->src_width, w->height,
          w->x_pixel_size_mm, w->y_pixel_size_mm,
          &w->out_areas[i])) {
    vs_mutex_lock(&w->lock); w->failed = 1; vs_mutex_unlock(&w->lock);
    return;
  }
}

#ifdef _WIN32
static DWORD WINAPI _decode_phase_worker(LPVOID arg) {
  DecodePhaseWork* w = (DecodePhaseWork*)arg;
  int32_t start, end;
  while (_take_decode_range(w, 4, &start, &end)) {
    for (int32_t i = start; i < end; i++) _decode_one_layer(w, i);
  }
  return 0;
}
#else
static void* _decode_phase_worker(void* arg) {
  DecodePhaseWork* w = (DecodePhaseWork*)arg;
  int32_t start, end;
  while (_take_decode_range(w, 4, &start, &end)) {
    for (int32_t i = start; i < end; i++) _decode_one_layer(w, i);
  }
  return NULL;
}
#endif

static int _run_decode_phase(DecodePhaseWork* w, int32_t threads) {
  vs_mutex_init(&w->lock);
  w->next_index = 0;
  w->failed = 0;

  if (threads <= 1 || w->count <= 1) {
    for (int32_t i = 0; i < w->count && !w->failed; i++) {
      _decode_one_layer(w, i);
    }
  } else {
    if (threads > w->count) threads = w->count;
#ifdef _WIN32
    HANDLE* hs = (HANDLE*)malloc((size_t)threads * sizeof(HANDLE));
    if (!hs) { vs_mutex_destroy(&w->lock); return 0; }
    int32_t started = 0;
    for (int32_t t = 0; t < threads; t++) {
      hs[t] = CreateThread(NULL, 0, _decode_phase_worker, w, 0, NULL);
      if (hs[t]) started++;
    }
    if (started > 0)
      WaitForMultipleObjects((DWORD)started, hs, TRUE, INFINITE);
    for (int32_t t = 0; t < threads; t++) if (hs[t]) CloseHandle(hs[t]);
    free(hs);
    if (started == 0) { vs_mutex_destroy(&w->lock); return 0; }
#else
    pthread_t* ts = (pthread_t*)malloc((size_t)threads * sizeof(pthread_t));
    if (!ts) { vs_mutex_destroy(&w->lock); return 0; }
    int32_t started = 0;
    for (int32_t t = 0; t < threads; t++) {
      if (pthread_create(&ts[t], NULL, _decode_phase_worker, w) == 0) started++;
    }
    if (started > 0)
      for (int32_t t = 0; t < started; t++) pthread_join(ts[t], NULL);
    free(ts);
    if (started == 0) { vs_mutex_destroy(&w->lock); return 0; }
#endif
  }

  vs_mutex_destroy(&w->lock);
  return w->failed ? 0 : 1;
}

// ── Phase 3 worker: Compress + PNG Wrap ─────────────────────────────────────

typedef struct CompressPhaseWork {
  uint8_t** scanlines;       // per-layer scanline buffers
  int32_t scanlines_len;     // bytes per layer
  int32_t count;
  int32_t out_width;
  int32_t height;
  int32_t channels;
  int32_t png_level;

  uint8_t** out_items;       // output PNG buffers
  int32_t* out_sizes;

  int32_t next_index;
  int32_t failed;
  vs_mutex lock;
} CompressPhaseWork;

static int _take_compress_range(CompressPhaseWork* w, int32_t claim,
                                 int32_t* out_start, int32_t* out_end) {
  int ok = 0;
  vs_mutex_lock(&w->lock);
  if (!w->failed && w->next_index < w->count) {
    *out_start = w->next_index;
    int32_t end = w->next_index + claim;
    if (end > w->count) end = w->count;
    w->next_index = end;
    *out_end = end;
    ok = 1;
  }
  vs_mutex_unlock(&w->lock);
  return ok;
}

static void _compress_one_layer(CompressPhaseWork* w, int32_t i) {
  int32_t level = w->png_level;
  if (level < 0) level = 0;
  if (level > 9) level = 9;

  unsigned long comp_cap =
      (unsigned long)w->scanlines_len +
      ((unsigned long)w->scanlines_len / 1000u) + 64u;
  uint8_t* compressed = (uint8_t*)malloc((size_t)comp_cap);
  if (!compressed) {
    vs_mutex_lock(&w->lock); w->failed = 1; vs_mutex_unlock(&w->lock);
    return;
  }

  unsigned long comp_len = comp_cap;
  const int ok_comp = g_zlib.compress2_ptr(
      compressed, &comp_len,
      w->scanlines[i], (unsigned long)w->scanlines_len,
      level);
  if (ok_comp != 0 || comp_len == 0) {
    free(compressed);
    vs_mutex_lock(&w->lock); w->failed = 1; vs_mutex_unlock(&w->lock);
    return;
  }

  int32_t png_len = 0;
  uint8_t* png = _build_png_from_idat(
      w->out_width, w->height, w->channels,
      compressed, (size_t)comp_len, &png_len);
  free(compressed);

  if (!png || png_len <= 0) {
    free(png);
    vs_mutex_lock(&w->lock); w->failed = 1; vs_mutex_unlock(&w->lock);
    return;
  }

  w->out_items[i] = png;
  w->out_sizes[i] = png_len;
}

#ifdef _WIN32
static DWORD WINAPI _compress_phase_worker(LPVOID arg) {
  CompressPhaseWork* w = (CompressPhaseWork*)arg;
  int32_t start, end;
  while (_take_compress_range(w, 4, &start, &end)) {
    for (int32_t i = start; i < end; i++) _compress_one_layer(w, i);
  }
  return 0;
}
#else
static void* _compress_phase_worker(void* arg) {
  CompressPhaseWork* w = (CompressPhaseWork*)arg;
  int32_t start, end;
  while (_take_compress_range(w, 4, &start, &end)) {
    for (int32_t i = start; i < end; i++) _compress_one_layer(w, i);
  }
  return NULL;
}
#endif

static int _run_compress_phase(CompressPhaseWork* w, int32_t threads) {
  vs_mutex_init(&w->lock);
  w->next_index = 0;
  w->failed = 0;

  if (threads <= 1 || w->count <= 1) {
    for (int32_t i = 0; i < w->count && !w->failed; i++) {
      _compress_one_layer(w, i);
    }
  } else {
    if (threads > w->count) threads = w->count;
#ifdef _WIN32
    HANDLE* hs = (HANDLE*)malloc((size_t)threads * sizeof(HANDLE));
    if (!hs) { vs_mutex_destroy(&w->lock); return 0; }
    int32_t started = 0;
    for (int32_t t = 0; t < threads; t++) {
      hs[t] = CreateThread(NULL, 0, _compress_phase_worker, w, 0, NULL);
      if (hs[t]) started++;
    }
    if (started > 0)
      WaitForMultipleObjects((DWORD)started, hs, TRUE, INFINITE);
    for (int32_t t = 0; t < threads; t++) if (hs[t]) CloseHandle(hs[t]);
    free(hs);
    if (started == 0) { vs_mutex_destroy(&w->lock); return 0; }
#else
    pthread_t* ts = (pthread_t*)malloc((size_t)threads * sizeof(pthread_t));
    if (!ts) { vs_mutex_destroy(&w->lock); return 0; }
    int32_t started = 0;
    for (int32_t t = 0; t < threads; t++) {
      if (pthread_create(&ts[t], NULL, _compress_phase_worker, w) == 0) started++;
    }
    if (started > 0)
      for (int32_t t = 0; t < started; t++) pthread_join(ts[t], NULL);
    free(ts);
    if (started == 0) { vs_mutex_destroy(&w->lock); return 0; }
#endif
  }

  vs_mutex_destroy(&w->lock);
  return w->failed ? 0 : 1;
}

// ── Phase 2 helper: CPU scanline fallback ───────────────────────────────────

typedef struct ScanlinePhaseWork {
  uint8_t** pixels;
  int32_t count;
  int32_t src_width;
  int32_t height;
  int32_t out_width;
  int32_t channels;
  uint8_t** out_scanlines;
  int32_t scanlines_len;
  int32_t next_index;
  int32_t failed;
  vs_mutex lock;
} ScanlinePhaseWork;

static int _take_scanline_range(ScanlinePhaseWork* w, int32_t claim,
                                 int32_t* out_start, int32_t* out_end) {
  int ok = 0;
  vs_mutex_lock(&w->lock);
  if (!w->failed && w->next_index < w->count) {
    *out_start = w->next_index;
    int32_t end = w->next_index + claim;
    if (end > w->count) end = w->count;
    w->next_index = end;
    *out_end = end;
    ok = 1;
  }
  vs_mutex_unlock(&w->lock);
  return ok;
}

static void _scanline_one_layer(ScanlinePhaseWork* w, int32_t i) {
  if (!build_png_scanlines(
          w->pixels[i], w->src_width, w->height,
          w->out_width, w->channels,
          w->out_scanlines[i], w->scanlines_len)) {
    vs_mutex_lock(&w->lock); w->failed = 1; vs_mutex_unlock(&w->lock);
  }
}

#ifdef _WIN32
static DWORD WINAPI _scanline_phase_worker(LPVOID arg) {
  ScanlinePhaseWork* w = (ScanlinePhaseWork*)arg;
  int32_t start, end;
  while (_take_scanline_range(w, 4, &start, &end)) {
    for (int32_t i = start; i < end; i++) _scanline_one_layer(w, i);
  }
  return 0;
}
#else
static void* _scanline_phase_worker(void* arg) {
  ScanlinePhaseWork* w = (ScanlinePhaseWork*)arg;
  int32_t start, end;
  while (_take_scanline_range(w, 4, &start, &end)) {
    for (int32_t i = start; i < end; i++) _scanline_one_layer(w, i);
  }
  return NULL;
}
#endif

static int _run_scanline_phase_cpu(ScanlinePhaseWork* w, int32_t threads) {
  vs_mutex_init(&w->lock);
  w->next_index = 0;
  w->failed = 0;

  if (threads <= 1 || w->count <= 1) {
    for (int32_t i = 0; i < w->count && !w->failed; i++) {
      _scanline_one_layer(w, i);
    }
  } else {
    if (threads > w->count) threads = w->count;
#ifdef _WIN32
    HANDLE* hs = (HANDLE*)malloc((size_t)threads * sizeof(HANDLE));
    if (!hs) { vs_mutex_destroy(&w->lock); return 0; }
    int32_t started = 0;
    for (int32_t t = 0; t < threads; t++) {
      hs[t] = CreateThread(NULL, 0, _scanline_phase_worker, w, 0, NULL);
      if (hs[t]) started++;
    }
    if (started > 0)
      WaitForMultipleObjects((DWORD)started, hs, TRUE, INFINITE);
    for (int32_t t = 0; t < threads; t++) if (hs[t]) CloseHandle(hs[t]);
    free(hs);
    if (started == 0) { vs_mutex_destroy(&w->lock); return 0; }
#else
    pthread_t* ts = (pthread_t*)malloc((size_t)threads * sizeof(pthread_t));
    if (!ts) { vs_mutex_destroy(&w->lock); return 0; }
    int32_t started = 0;
    for (int32_t t = 0; t < threads; t++) {
      if (pthread_create(&ts[t], NULL, _scanline_phase_worker, w) == 0) started++;
    }
    if (started > 0)
      for (int32_t t = 0; t < started; t++) pthread_join(ts[t], NULL);
    free(ts);
    if (started == 0) { vs_mutex_destroy(&w->lock); return 0; }
#endif
  }

  vs_mutex_destroy(&w->lock);
  return w->failed ? 0 : 1;
}

// ── Phased batch entry point ────────────────────────────────────────────────

static int32_t g_last_phased_gpu_batch_ok = 0;

/**
 * @brief Whether the most recent phased batch successfully used GPU mega-batch.
 */
int32_t process_layers_last_gpu_batch_ok(void) {
  return g_last_phased_gpu_batch_ok;
}

// Process a single chunk of layers through the 3-phase pipeline.
// Returns 1 on success, 0 on failure. On success, item_outputs[0..count-1]
// and item_sizes[0..count-1] contain the PNG data for each layer, and
// areas[0..count-1] contain the area stats.
static int _phased_chunk(
    const uint8_t* input_blob,
    int32_t input_blob_len,
    const int32_t* input_offsets,
    const int32_t* input_lengths,
    int32_t count,
    int32_t layer_index_base,
    int32_t encryption_key,
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels,
    double x_pixel_size_mm,
    double y_pixel_size_mm,
    int32_t png_level,
    int32_t threads,
    int32_t use_gpu_batch,
    int32_t pixel_count,
    int32_t scanlines_len,
    uint8_t** item_outputs,
    int32_t* item_sizes,
    AreaStatsResult* areas,
    int32_t* out_gpu_batch_ok) {

  // Allocate per-layer pixel + scanline buffers for this chunk only
  uint8_t** pixels = (uint8_t**)calloc((size_t)count, sizeof(uint8_t*));
  uint8_t** scanline_bufs = (uint8_t**)calloc((size_t)count, sizeof(uint8_t*));
  if (!pixels || !scanline_bufs) {
    free(pixels); free(scanline_bufs);
    return 0;
  }

  for (int32_t i = 0; i < count; i++) {
    pixels[i] = (uint8_t*)malloc((size_t)pixel_count);
    scanline_bufs[i] = (uint8_t*)malloc((size_t)scanlines_len);
    if (!pixels[i] || !scanline_bufs[i]) {
      for (int32_t j = 0; j <= i; j++) { free(pixels[j]); free(scanline_bufs[j]); }
      free(pixels); free(scanline_bufs);
      return 0;
    }
  }

  // Phase 1: Parallel decode + area stats
  {
    DecodePhaseWork dw;
    dw.input_blob = input_blob;
    dw.input_blob_len = input_blob_len;
    dw.input_offsets = input_offsets;
    dw.input_lengths = input_lengths;
    dw.count = count;
    dw.layer_index_base = layer_index_base;
    dw.encryption_key = encryption_key;
    dw.src_width = src_width;
    dw.height = height;
    dw.x_pixel_size_mm = x_pixel_size_mm;
    dw.y_pixel_size_mm = y_pixel_size_mm;
    dw.out_pixels = pixels;
    dw.out_areas = areas;

    if (!_run_decode_phase(&dw, threads)) goto chunk_fail;
  }

  // Phase 2: Scanline build (GPU mega-batch or CPU parallel)
  {
    int gpu_batch_ok = 0;

    if (use_gpu_batch && gpu_acceleration_active()) {
      const int32_t backend = gpu_acceleration_backend();

      if (backend == 3) {
        int32_t max_layers = gpu_cuda_tensor_max_concurrent_layers(
            src_width, height, out_width, channels);
        const int32_t hard_cap = 8;
        if (max_layers <= 0 || max_layers > hard_cap) max_layers = hard_cap;

        if (count <= max_layers) {
          uint8_t* pixels_blob = (uint8_t*)malloc((size_t)pixel_count * count);
          uint8_t* scanlines_blob = (uint8_t*)malloc((size_t)scanlines_len * count);

          if (pixels_blob && scanlines_blob) {
            for (int32_t i = 0; i < count; i++) {
              memcpy(pixels_blob + (size_t)pixel_count * i, pixels[i],
                     (size_t)pixel_count);
              // Free original pixel buffer immediately to reduce peak memory.
              // The concat blob now owns this layer's pixel data.
              free(pixels[i]);
              pixels[i] = NULL;
            }

            gpu_batch_ok = gpu_cuda_tensor_build_scanlines_batch(
                pixels_blob, count, src_width, height,
                out_width, channels, scanlines_blob, scanlines_len);

            if (gpu_batch_ok) {
              for (int32_t i = 0; i < count; i++) {
                memcpy(scanline_bufs[i],
                       scanlines_blob + (size_t)scanlines_len * i,
                       (size_t)scanlines_len);
              }
            } else {
              g_last_process_layers_cuda_error =
                  gpu_cuda_tensor_last_error_code();
            }
          }

          free(pixels_blob);
          free(scanlines_blob);
        }
      }

      if (!gpu_batch_ok && (backend == 1 || backend == 3)) {
        // OpenCL or CUDA single-layer fallback
        int all_ok = 1;
        for (int32_t i = 0; i < count; i++) {
          int ok = 0;
          if (backend == 1 || backend == 3) {
            ok = (backend == 1)
              ? gpu_opencl_build_scanlines(
                    pixels[i], src_width, height,
                    out_width, channels, scanline_bufs[i], scanlines_len)
              : gpu_cuda_tensor_build_scanlines(
                    pixels[i], src_width, height,
                    out_width, channels, scanline_bufs[i], scanlines_len);
          }
          if (!ok) {
            if (!build_png_scanlines(
                    pixels[i], src_width, height,
                    out_width, channels, scanline_bufs[i], scanlines_len)) {
              all_ok = 0;
              break;
            }
          }
        }
        if (all_ok) gpu_batch_ok = 1;
      }
    }

    if (!gpu_batch_ok) {
      ScanlinePhaseWork sw2;
      sw2.pixels = pixels;
      sw2.count = count;
      sw2.src_width = src_width;
      sw2.height = height;
      sw2.out_width = out_width;
      sw2.channels = channels;
      sw2.out_scanlines = scanline_bufs;
      sw2.scanlines_len = scanlines_len;

      if (!_run_scanline_phase_cpu(&sw2, threads)) goto chunk_fail;
    }

    *out_gpu_batch_ok = gpu_batch_ok ? 1 : 0;
  }

  // Free decoded pixels (no longer needed)
  for (int32_t i = 0; i < count; i++) { free(pixels[i]); pixels[i] = NULL; }
  free(pixels); pixels = NULL;

  // Phase 3: Parallel compress + PNG wrap
  {
    CompressPhaseWork cw;
    cw.scanlines = scanline_bufs;
    cw.scanlines_len = scanlines_len;
    cw.count = count;
    cw.out_width = out_width;
    cw.height = height;
    cw.channels = channels;
    cw.png_level = png_level;
    cw.out_items = item_outputs;
    cw.out_sizes = item_sizes;

    if (!_run_compress_phase(&cw, threads)) goto chunk_fail;
  }

  for (int32_t i = 0; i < count; i++) { free(scanline_bufs[i]); }
  free(scanline_bufs);
  return 1;

chunk_fail:
  if (pixels) {
    for (int32_t i = 0; i < count; i++) free(pixels[i]);
    free(pixels);
  }
  if (scanline_bufs) {
    for (int32_t i = 0; i < count; i++) free(scanline_bufs[i]);
    free(scanline_bufs);
  }
  return 0;
}

/**
 * @brief Process layers using the phased pipeline (decode → scanlines → compress).
 */
int process_layers_batch_phased(
    const uint8_t* input_blob,
    int32_t input_blob_len,
    const int32_t* input_offsets,
    const int32_t* input_lengths,
    int32_t count,
    int32_t layer_index_base,
    int32_t encryption_key,
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels,
    double x_pixel_size_mm,
    double y_pixel_size_mm,
    int32_t png_level,
    int32_t thread_count,
    int32_t use_gpu_batch,
    uint8_t** out_blob,
    int32_t* out_blob_len,
    int32_t** out_offsets,
    int32_t** out_lengths,
    AreaStatsResult** out_areas) {
  if (!input_blob || input_blob_len <= 0 || !input_offsets || !input_lengths ||
      count <= 0 || src_width <= 0 || height <= 0 || out_width <= 0 ||
      (channels != 1 && channels != 3) || !out_blob || !out_blob_len ||
      !out_offsets || !out_lengths || !out_areas) {
    return 0;
  }

  _init_zlib();
  if (!g_zlib.available) return 0;

  g_last_phased_gpu_batch_ok = 0;
  g_last_process_layers_backend = 0;
  g_last_process_layers_gpu_attempts = 0;
  g_last_process_layers_gpu_successes = 0;
  g_last_process_layers_gpu_fallbacks = 0;
  g_last_process_layers_cuda_error = 0;

  int32_t threads = thread_count > 0 ? thread_count :
      (g_process_layers_batch_threads > 0 ? g_process_layers_batch_threads : _cpu_threads());
  if (threads < 1) threads = 1;

  const int32_t pixel_count = src_width * height;
  const int32_t bytes_per_row = out_width * channels;
  const int32_t scanline_size = 1 + bytes_per_row;
  const int32_t scanlines_len = scanline_size * height;

  // ── Compute chunk size based on memory budget ──────────────────────────
  // Peak per-layer memory during Phase 2 CUDA (after optimisation that
  // frees individual pixel buffers as they are copied into the concat blob):
  //   pixel_count  (concat blob share, persists through GPU call)
  //   scanlines_len (individual buf, receives GPU output)
  //   scanlines_len (concat blob share, receives GPU output bulk)
  // = pixel_count + 2 * scanlines_len
  // We use a slightly conservative estimate to account for transient
  // overlap during the copy loop.
  const int64_t per_layer_mem =
      (int64_t)pixel_count + (int64_t)scanlines_len * 2 + (int64_t)pixel_count / 4;
  const int64_t max_host_budget = (int64_t)8 * 1024 * 1024 * 1024; // 8 GB
  int32_t max_chunk = count;
  if (per_layer_mem > 0) {
    int64_t fit = max_host_budget / per_layer_mem;
    if (fit < 1) fit = 1;
    if (fit < max_chunk) max_chunk = (int32_t)fit;
  }
  // Also respect GPU VRAM: the kernel will reject if too large,
  // but pre-clamping avoids wasted host-side concat allocations.
  if (use_gpu_batch) {
    int64_t vram = gpu_cuda_tensor_vram_bytes();
    if (vram > 0) {
      const int64_t vram_per_layer = (int64_t)pixel_count + (int64_t)scanlines_len;
      const int64_t vram_budget = vram - (int64_t)512 * 1024 * 1024;
      if (vram_budget > 0 && vram_per_layer > 0) {
        int64_t vram_fit = vram_budget / vram_per_layer;
        if (vram_fit < 1) vram_fit = 1;
        if (vram_fit < max_chunk) max_chunk = (int32_t)vram_fit;
      }
    }
  }
  // Extra safety for CUDA mega-batch: cap batch size to keep VRAM sane.
  if (use_gpu_batch && gpu_acceleration_active() &&
      gpu_acceleration_backend() == 3) {
    int32_t max_layers = gpu_cuda_tensor_max_concurrent_layers(
        src_width, height, out_width, channels);
    const int32_t hard_cap = 8; // keep VRAM usage low on large layers
    if (max_layers <= 0 || max_layers > hard_cap) max_layers = hard_cap;
    if (max_layers < max_chunk) max_chunk = max_layers;
  }
  // Minimum sanity
  if (max_chunk < 1) max_chunk = 1;

  // ── Allocate output arrays ────────────────────────────────────────────
  uint8_t** item_outputs = (uint8_t**)calloc((size_t)count, sizeof(uint8_t*));
  int32_t* item_sizes = (int32_t*)calloc((size_t)count, sizeof(int32_t));
  int32_t* offs = (int32_t*)malloc((size_t)count * sizeof(int32_t));
  int32_t* lens = (int32_t*)malloc((size_t)count * sizeof(int32_t));
  AreaStatsResult* areas =
      (AreaStatsResult*)malloc((size_t)count * sizeof(AreaStatsResult));

  if (!item_outputs || !item_sizes || !offs || !lens || !areas) {
    free(item_outputs); free(item_sizes); free(offs); free(lens); free(areas);
    return 0;
  }

  // ── Process in chunks ─────────────────────────────────────────────────
  int any_gpu_batch_ok = 0;
  int32_t total_gpu_attempts = 0;
  int32_t total_gpu_successes = 0;
  int32_t best_backend = 0;

  for (int32_t start = 0; start < count; start += max_chunk) {
    int32_t chunk_count = count - start;
    if (chunk_count > max_chunk) chunk_count = max_chunk;

    int32_t chunk_gpu_ok = 0;
    if (!_phased_chunk(
            input_blob, input_blob_len,
            input_offsets + start,
            input_lengths + start,
            chunk_count,
            layer_index_base + start,
            encryption_key,
            src_width, height, out_width, channels,
            x_pixel_size_mm, y_pixel_size_mm,
            png_level, threads, use_gpu_batch,
            pixel_count, scanlines_len,
            item_outputs + start,
            item_sizes + start,
            areas + start,
            &chunk_gpu_ok)) {
      // Chunk failed — clean up everything
      for (int32_t i = 0; i < count; i++) {
        if (item_outputs[i]) free(item_outputs[i]);
      }
      free(item_outputs); free(item_sizes);
      free(offs); free(lens); free(areas);
      return 0;
    }

    if (chunk_gpu_ok) {
      any_gpu_batch_ok = 1;
      total_gpu_attempts += chunk_count;
      total_gpu_successes += chunk_count;
      best_backend = 3;
    }
  }

  g_last_phased_gpu_batch_ok = any_gpu_batch_ok ? 1 : 0;
  if (any_gpu_batch_ok) {
    g_last_process_layers_backend = best_backend;
    g_last_process_layers_gpu_attempts = total_gpu_attempts;
    g_last_process_layers_gpu_successes = total_gpu_successes;
    g_last_process_layers_gpu_fallbacks = 0;
  }

  // ── Assemble output blob ──────────────────────────────────────────────
  {
    int64_t total_len = 0;
    for (int32_t i = 0; i < count; i++) {
      if (!item_outputs[i] || item_sizes[i] <= 0) {
        for (int32_t j = 0; j < count; j++)
          if (item_outputs[j]) free(item_outputs[j]);
        free(item_outputs); free(item_sizes);
        free(offs); free(lens); free(areas);
        return 0;
      }
      offs[i] = (int32_t)total_len;
      lens[i] = item_sizes[i];
      total_len += item_sizes[i];
    }

    if (total_len <= 0 || total_len > 0x7FFFFFFF) {
      for (int32_t i = 0; i < count; i++) free(item_outputs[i]);
      free(item_outputs); free(item_sizes);
      free(offs); free(lens); free(areas);
      return 0;
    }

    uint8_t* blob = (uint8_t*)malloc((size_t)total_len);
    if (!blob) {
      for (int32_t i = 0; i < count; i++) free(item_outputs[i]);
      free(item_outputs); free(item_sizes);
      free(offs); free(lens); free(areas);
      return 0;
    }

    int32_t cur = 0;
    for (int32_t i = 0; i < count; i++) {
      memcpy(blob + cur, item_outputs[i], (size_t)item_sizes[i]);
      cur += item_sizes[i];
      free(item_outputs[i]);
    }

    free(item_outputs);
    free(item_sizes);

    *out_blob = blob;
    *out_blob_len = (int32_t)total_len;
    *out_offsets = offs;
    *out_lengths = lens;
    *out_areas = areas;
    return 1;
  }
}

// ── CUDA device info exports (thin wrappers) ────────────────────────────────

int gpu_cuda_info_init(void) {
  return gpu_cuda_tensor_init();
}

const char* gpu_cuda_info_device_name(void) {
  return gpu_cuda_tensor_device_name();
}

int64_t gpu_cuda_info_vram_bytes(void) {
  return gpu_cuda_tensor_vram_bytes();
}

int32_t gpu_cuda_info_has_tensor_cores(void) {
  return gpu_cuda_tensor_has_tensor_cores();
}

int32_t gpu_cuda_info_compute_capability(void) {
  return gpu_cuda_tensor_compute_capability();
}

int32_t gpu_cuda_info_multiprocessor_count(void) {
  return gpu_cuda_tensor_multiprocessor_count();
}

int32_t gpu_cuda_info_max_concurrent_layers(
    int32_t src_width, int32_t height,
    int32_t out_width, int32_t channels) {
  return gpu_cuda_tensor_max_concurrent_layers(
      src_width, height, out_width, channels);
}
