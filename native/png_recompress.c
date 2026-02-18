/**
 * @file png_recompress.c
 * @brief PNG IDAT recompression (single and batch).
 *
 * Parses PNG containers, inflates the IDAT stream, and recompresses it
 * with a target zlib level. Used to shrink output size without altering
 * image content.
 */
#include "voxelshift_native.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
typedef HMODULE vs_lib_handle;
static vs_lib_handle vs_dlopen(const char *name) { return LoadLibraryA(name); }
static void *vs_dlsym(vs_lib_handle h, const char *sym) { return (void *)GetProcAddress(h, sym); }

typedef CRITICAL_SECTION vs_mutex;
static void vs_mutex_init(vs_mutex *m) { InitializeCriticalSection(m); }
static void vs_mutex_lock(vs_mutex *m) { EnterCriticalSection(m); }
static void vs_mutex_unlock(vs_mutex *m) { LeaveCriticalSection(m); }
static void vs_mutex_destroy(vs_mutex *m) { DeleteCriticalSection(m); }
#else
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>
typedef void *vs_lib_handle;
static vs_lib_handle vs_dlopen(const char *name) { return dlopen(name, RTLD_LAZY); }
static void *vs_dlsym(vs_lib_handle h, const char *sym) { return dlsym(h, sym); }

typedef pthread_mutex_t vs_mutex;
static void vs_mutex_init(vs_mutex *m) { pthread_mutex_init(m, NULL); }
static void vs_mutex_lock(vs_mutex *m) { pthread_mutex_lock(m); }
static void vs_mutex_unlock(vs_mutex *m) { pthread_mutex_unlock(m); }
static void vs_mutex_destroy(vs_mutex *m) { pthread_mutex_destroy(m); }
#endif

typedef int (*compress2_fn)(unsigned char *, unsigned long *, const unsigned char *, unsigned long, int);
typedef int (*uncompress_fn)(unsigned char *, unsigned long *, const unsigned char *, unsigned long);

typedef struct ZlibApi
{
  int loaded;
  int available;
  compress2_fn compress2_ptr;
  uncompress_fn uncompress_ptr;
} ZlibApi;

static ZlibApi g_zlib = {0, 0, NULL, NULL};
static int32_t g_recompress_batch_threads = 0;

/**
 * @brief Set default thread count for recompress_png_batch.
 */
void set_recompress_batch_threads(int32_t threads)
{
  g_recompress_batch_threads = threads;
}

/**
 * @brief Detect the number of available CPU threads.
 */
static int32_t _detect_cpu_threads(void)
{
#ifdef _WIN32
  DWORD n = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
  if (n == 0)
    n = 1;
  return (int32_t)n;
#else
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  if (n < 1)
    n = 1;
  return (int32_t)n;
#endif
}

typedef struct BatchWork
{
  const uint8_t *input_blob;
  int32_t input_blob_len;
  const int32_t *input_offsets;
  const int32_t *input_lengths;
  int32_t count;
  int32_t level;
  uint8_t **item_outputs;
  int32_t *item_sizes;

  int32_t next_index;
  int32_t failed;
  vs_mutex lock;
} BatchWork;

/**
 * @brief Claim the next batch index for a worker thread.
 */
static int _batch_take_index(BatchWork *w, int32_t *out_idx)
{
  int ok = 0;
  vs_mutex_lock(&w->lock);
  if (!w->failed && w->next_index < w->count)
  {
    *out_idx = w->next_index++;
    ok = 1;
  }
  vs_mutex_unlock(&w->lock);
  return ok;
}

/**
 * @brief Mark the batch as failed to stop other workers.
 */
static void _batch_mark_failed(BatchWork *w)
{
  vs_mutex_lock(&w->lock);
  w->failed = 1;
  vs_mutex_unlock(&w->lock);
}

/**
 * @brief Recompress a single PNG payload within a batch.
 */
static void _batch_process_one(BatchWork *w, int32_t i)
{
  const int32_t off = w->input_offsets[i];
  const int32_t len = w->input_lengths[i];

  if (off < 0 || len <= 0 || off + len > w->input_blob_len)
  {
    _batch_mark_failed(w);
    return;
  }

  uint8_t *recompressed = NULL;
  int32_t recompressed_len = 0;
  const int ok = recompress_png_idat(
      w->input_blob + off,
      len,
      w->level,
      &recompressed,
      &recompressed_len);

  if (!ok || !recompressed || recompressed_len <= 0)
  {
    _batch_mark_failed(w);
    return;
  }

  w->item_outputs[i] = recompressed;
  w->item_sizes[i] = recompressed_len;
}

#ifdef _WIN32
static DWORD WINAPI _batch_worker_proc(LPVOID arg)
{
  BatchWork *w = (BatchWork *)arg;
  int32_t idx;
  while (_batch_take_index(w, &idx))
  {
    _batch_process_one(w, idx);
  }
  return 0;
}
#else
static void *_batch_worker_proc(void *arg)
{
  BatchWork *w = (BatchWork *)arg;
  int32_t idx;
  while (_batch_take_index(w, &idx))
  {
    _batch_process_one(w, idx);
  }
  return NULL;
}
#endif

/**
 * @brief Load zlib symbols from the platform runtime.
 *
 * On Windows, looks first in the application directory, then system paths.
 * This ensures bundled zlib.dll is found before any system installation.
 */
static void _init_zlib(void)
{
  if (g_zlib.loaded)
    return;
  g_zlib.loaded = 1;

#ifdef _WIN32
  // Windows: prioritize bundled zlib.dll in app directory
  const char *candidates[] = {
      "zlib1.dll", // Try current directory first (where bundled DLL is)
      "zlib.dll",  // Alternative name
      "zlib1.dll", // Try system paths via LoadLibraryA search order
      "zlib.dll",
  };
#elif __APPLE__
  const char *candidates[] = {
      "libz.1.dylib",
      "libz.dylib",
  };
#else
  const char *candidates[] = {
      "libz.so.1",
      "libz.so",
  };
#endif

  for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++)
  {
    vs_lib_handle h = vs_dlopen(candidates[i]);
    if (!h)
      continue;

    compress2_fn c2 = (compress2_fn)vs_dlsym(h, "compress2");
    uncompress_fn uc = (uncompress_fn)vs_dlsym(h, "uncompress");

    if (c2 && uc)
    {
      g_zlib.compress2_ptr = c2;
      g_zlib.uncompress_ptr = uc;
      g_zlib.available = 1;
      return;
    }
  }
}

static uint32_t _read_u32_be(const uint8_t *p)
{
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
         ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void _write_u32_be(uint8_t *p, uint32_t v)
{
  p[0] = (uint8_t)((v >> 24) & 0xFFu);
  p[1] = (uint8_t)((v >> 16) & 0xFFu);
  p[2] = (uint8_t)((v >> 8) & 0xFFu);
  p[3] = (uint8_t)(v & 0xFFu);
}

static uint32_t _crc32_table[256];
static int _crc32_ready = 0;

static void _init_crc32_table(void)
{
  if (_crc32_ready)
    return;
  for (uint32_t i = 0; i < 256; i++)
  {
    uint32_t c = i;
    for (int k = 0; k < 8; k++)
    {
      c = (c & 1u) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
    }
    _crc32_table[i] = c;
  }
  _crc32_ready = 1;
}

static uint32_t _crc32_bytes(const uint8_t *data, size_t len)
{
  _init_crc32_table();
  uint32_t c = 0xFFFFFFFFu;
  for (size_t i = 0; i < len; i++)
  {
    c = _crc32_table[(c ^ data[i]) & 0xFFu] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFFu;
}

static uint32_t _crc32_type_and_data(const uint8_t type[4], const uint8_t *data, size_t len)
{
  _init_crc32_table();
  uint32_t c = 0xFFFFFFFFu;
  for (int i = 0; i < 4; i++)
  {
    c = _crc32_table[(c ^ type[i]) & 0xFFu] ^ (c >> 8);
  }
  for (size_t i = 0; i < len; i++)
  {
    c = _crc32_table[(c ^ data[i]) & 0xFFu] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFFu;
}

static int _channels_for_color_type(uint8_t color_type)
{
  switch (color_type)
  {
  case 0:
    return 1;
  case 2:
    return 3;
  case 4:
    return 2;
  case 6:
    return 4;
  default:
    return 0;
  }
}

/**
 * @brief Recompress the IDAT payload inside a PNG file.
 */
int recompress_png_idat(
    const uint8_t *png_data,
    int32_t png_len,
    int32_t level,
    uint8_t **out_data,
    int32_t *out_len)
{
  if (!png_data || png_len < 45 || !out_data || !out_len)
  {
    return 0;
  }

  _init_zlib();
  if (!g_zlib.available)
  {
    return 0;
  }

  const uint8_t sig[8] = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
  if (memcmp(png_data, sig, 8) != 0)
  {
    return 0;
  }

  uint32_t width = 0;
  uint32_t height = 0;
  uint8_t ihdr[13];
  int have_ihdr = 0;

  uint8_t *idat = NULL;
  size_t idat_len = 0;

  int32_t offset = 8;

  while (offset + 8 <= png_len)
  {
    const uint32_t len = _read_u32_be(png_data + offset);
    const int32_t data_start = offset + 8;
    const int32_t data_end = data_start + (int32_t)len;
    const int32_t crc_end = data_end + 4;

    if (crc_end > png_len || data_end < data_start)
    {
      free(idat);
      return 0;
    }

    const uint8_t *type = png_data + offset + 4;
    const uint8_t *data = png_data + data_start;

    if (type[0] == 'I' && type[1] == 'H' && type[2] == 'D' && type[3] == 'R')
    {
      if (len < 13)
      {
        free(idat);
        return 0;
      }
      memcpy(ihdr, data, 13);
      width = _read_u32_be(data);
      height = _read_u32_be(data + 4);
      have_ihdr = 1;
    }
    else if (type[0] == 'I' && type[1] == 'D' && type[2] == 'A' && type[3] == 'T')
    {
      uint8_t *grown = (uint8_t *)realloc(idat, idat_len + len);
      if (!grown)
      {
        free(idat);
        return 0;
      }
      idat = grown;
      memcpy(idat + idat_len, data, len);
      idat_len += len;
    }
    else if (type[0] == 'I' && type[1] == 'E' && type[2] == 'N' && type[3] == 'D')
    {
      break;
    }

    offset = crc_end;
  }

  if (!have_ihdr || idat_len == 0 || width == 0 || height == 0)
  {
    free(idat);
    return 0;
  }

  const uint8_t bit_depth = ihdr[8];
  const uint8_t color_type = ihdr[9];
  const int channels = _channels_for_color_type(color_type);

  if (bit_depth != 8 || channels == 0)
  {
    free(idat);
    return 0;
  }

  const unsigned long expected_scanlines = (unsigned long)height *
                                           (unsigned long)(1 + (width * (uint32_t)channels));

  if (expected_scanlines == 0)
  {
    free(idat);
    return 0;
  }

  unsigned char *scanlines = (unsigned char *)malloc((size_t)expected_scanlines);
  if (!scanlines)
  {
    free(idat);
    return 0;
  }

  unsigned long scanlines_len = expected_scanlines;
  const int uret = g_zlib.uncompress_ptr(
      scanlines,
      &scanlines_len,
      (const unsigned char *)idat,
      (unsigned long)idat_len);
  free(idat);

  if (uret != 0 || scanlines_len == 0)
  {
    free(scanlines);
    return 0;
  }

  if (level < 0)
    level = 0;
  if (level > 9)
    level = 9;

  unsigned long comp_cap = scanlines_len + (scanlines_len / 1000u) + 64u;
  unsigned char *compressed = (unsigned char *)malloc((size_t)comp_cap);
  if (!compressed)
  {
    free(scanlines);
    return 0;
  }

  unsigned long comp_len = comp_cap;
  const int cret = g_zlib.compress2_ptr(
      compressed,
      &comp_len,
      scanlines,
      scanlines_len,
      level);
  free(scanlines);

  if (cret != 0 || comp_len == 0)
  {
    free(compressed);
    return 0;
  }

  const size_t out_size = 8 + (12 + 13) + (12 + (size_t)comp_len) + 12;
  uint8_t *out = (uint8_t *)malloc(out_size);
  if (!out)
  {
    free(compressed);
    return 0;
  }

  size_t w = 0;
  memcpy(out + w, sig, 8);
  w += 8;

  // IHDR
  _write_u32_be(out + w, 13);
  w += 4;
  out[w++] = 'I';
  out[w++] = 'H';
  out[w++] = 'D';
  out[w++] = 'R';
  memcpy(out + w, ihdr, 13);
  w += 13;
  {
    const uint8_t t[4] = {'I', 'H', 'D', 'R'};
    const uint32_t crc = _crc32_type_and_data(t, ihdr, 13);
    _write_u32_be(out + w, crc);
    w += 4;
  }

  // IDAT
  _write_u32_be(out + w, (uint32_t)comp_len);
  w += 4;
  out[w++] = 'I';
  out[w++] = 'D';
  out[w++] = 'A';
  out[w++] = 'T';
  memcpy(out + w, compressed, (size_t)comp_len);
  w += (size_t)comp_len;
  {
    const uint8_t t[4] = {'I', 'D', 'A', 'T'};
    const uint32_t crc = _crc32_type_and_data(t, compressed, (size_t)comp_len);
    _write_u32_be(out + w, crc);
    w += 4;
  }

  free(compressed);

  // IEND
  _write_u32_be(out + w, 0);
  w += 4;
  out[w++] = 'I';
  out[w++] = 'E';
  out[w++] = 'N';
  out[w++] = 'D';
  {
    const uint8_t t[4] = {'I', 'E', 'N', 'D'};
    const uint32_t crc = _crc32_bytes(t, 4);
    _write_u32_be(out + w, crc);
    w += 4;
  }

  *out_data = out;
  *out_len = (int32_t)w;
  return 1;
}

/**
 * @brief Recompress many PNGs in one native call using a worker pool.
 */
int recompress_png_batch(
    const uint8_t *input_blob,
    int32_t input_blob_len,
    const int32_t *input_offsets,
    const int32_t *input_lengths,
    int32_t count,
    int32_t level,
    uint8_t **out_blob,
    int32_t *out_blob_len,
    int32_t **out_offsets,
    int32_t **out_lengths)
{
  if (!input_blob || input_blob_len <= 0 || !input_offsets || !input_lengths ||
      count <= 0 || !out_blob || !out_blob_len || !out_offsets || !out_lengths)
  {
    return 0;
  }

  uint8_t **item_outputs = (uint8_t **)calloc((size_t)count, sizeof(uint8_t *));
  int32_t *item_sizes = (int32_t *)calloc((size_t)count, sizeof(int32_t));
  int32_t *out_offs = (int32_t *)malloc((size_t)count * sizeof(int32_t));
  int32_t *out_lens = (int32_t *)malloc((size_t)count * sizeof(int32_t));

  if (!item_outputs || !item_sizes || !out_offs || !out_lens)
  {
    free(item_outputs);
    free(item_sizes);
    free(out_offs);
    free(out_lens);
    return 0;
  }

  BatchWork work;
  work.input_blob = input_blob;
  work.input_blob_len = input_blob_len;
  work.input_offsets = input_offsets;
  work.input_lengths = input_lengths;
  work.count = count;
  work.level = level;
  work.item_outputs = item_outputs;
  work.item_sizes = item_sizes;
  work.next_index = 0;
  work.failed = 0;
  vs_mutex_init(&work.lock);

  int32_t cpu_threads = _detect_cpu_threads();
  int32_t requested = g_recompress_batch_threads > 0 ? g_recompress_batch_threads : cpu_threads;
  if (requested < 1)
    requested = 1;
  if (requested > count)
    requested = count;

  if (requested == 1)
  {
    for (int32_t i = 0; i < count; i++)
    {
      _batch_process_one(&work, i);
      if (work.failed)
        break;
    }
  }
  else
  {
#ifdef _WIN32
    HANDLE *threads = (HANDLE *)malloc((size_t)requested * sizeof(HANDLE));
    if (!threads)
    {
      vs_mutex_destroy(&work.lock);
      free(item_outputs);
      free(item_sizes);
      free(out_offs);
      free(out_lens);
      return 0;
    }

    int32_t started = 0;
    for (int32_t t = 0; t < requested; t++)
    {
      threads[t] = CreateThread(NULL, 0, _batch_worker_proc, &work, 0, NULL);
      if (threads[t])
        started++;
    }

    if (started == 0)
    {
      free(threads);
      vs_mutex_destroy(&work.lock);
      free(item_outputs);
      free(item_sizes);
      free(out_offs);
      free(out_lens);
      return 0;
    }

    WaitForMultipleObjects((DWORD)started, threads, TRUE, INFINITE);
    for (int32_t t = 0; t < requested; t++)
    {
      if (threads[t])
        CloseHandle(threads[t]);
    }
    free(threads);
#else
    pthread_t *threads = (pthread_t *)malloc((size_t)requested * sizeof(pthread_t));
    if (!threads)
    {
      vs_mutex_destroy(&work.lock);
      free(item_outputs);
      free(item_sizes);
      free(out_offs);
      free(out_lens);
      return 0;
    }

    int32_t started = 0;
    for (int32_t t = 0; t < requested; t++)
    {
      if (pthread_create(&threads[t], NULL, _batch_worker_proc, &work) == 0)
      {
        started++;
      }
    }

    if (started == 0)
    {
      free(threads);
      vs_mutex_destroy(&work.lock);
      free(item_outputs);
      free(item_sizes);
      free(out_offs);
      free(out_lens);
      return 0;
    }

    for (int32_t t = 0; t < started; t++)
    {
      pthread_join(threads[t], NULL);
    }
    free(threads);
#endif
  }

  vs_mutex_destroy(&work.lock);

  if (work.failed)
  {
    for (int32_t i = 0; i < count; i++)
    {
      if (item_outputs[i])
        free_native_buffer(item_outputs[i]);
    }
    free(item_outputs);
    free(item_sizes);
    free(out_offs);
    free(out_lens);
    return 0;
  }

  int64_t total_len = 0;
  for (int32_t i = 0; i < count; i++)
  {
    if (!item_outputs[i] || item_sizes[i] <= 0)
    {
      for (int32_t j = 0; j < count; j++)
      {
        if (item_outputs[j])
          free_native_buffer(item_outputs[j]);
      }
      free(item_outputs);
      free(item_sizes);
      free(out_offs);
      free(out_lens);
      return 0;
    }
    out_offs[i] = (int32_t)total_len;
    out_lens[i] = item_sizes[i];
    total_len += item_sizes[i];
  }

  if (total_len <= 0 || total_len > 0x7FFFFFFF)
  {
    for (int32_t i = 0; i < count; i++)
    {
      free_native_buffer(item_outputs[i]);
    }
    free(item_outputs);
    free(item_sizes);
    free(out_offs);
    free(out_lens);
    return 0;
  }

  uint8_t *blob = (uint8_t *)malloc((size_t)total_len);
  if (!blob)
  {
    for (int32_t i = 0; i < count; i++)
    {
      free_native_buffer(item_outputs[i]);
    }
    free(item_outputs);
    free(item_sizes);
    free(out_offs);
    free(out_lens);
    return 0;
  }

  int32_t cursor = 0;
  for (int32_t i = 0; i < count; i++)
  {
    memcpy(blob + cursor, item_outputs[i], (size_t)item_sizes[i]);
    cursor += item_sizes[i];
    free_native_buffer(item_outputs[i]);
  }

  free(item_outputs);
  free(item_sizes);

  *out_blob = blob;
  *out_blob_len = (int32_t)total_len;
  *out_offsets = out_offs;
  *out_lengths = out_lens;
  return 1;
}

/**
 * @brief Free a heap buffer allocated by native code.
 */
void free_native_buffer(uint8_t *buffer)
{
  free(buffer);
}

/**
 * @brief Free a heap int32 buffer allocated by native code.
 */
void free_native_int_buffer(int32_t *buffer)
{
  free(buffer);
}
