/**
 * @file zip_writer.c
 * @brief Minimal ZIP (store-only) writer for NanoDLP output.
 *
 * Implements a small ZIP writer that stores files without compression.
 * The Dart layer performs PNG compression already; this writer just
 * packages entries and writes the central directory.
 */
#include "voxelshift_native.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/**
 * @brief In-memory entry metadata for central directory emission.
 */
typedef struct ZipEntryRecord {
  char* name;
  uint32_t crc32;
  uint32_t comp_size;
  uint32_t uncomp_size;
  uint32_t local_header_offset;
} ZipEntryRecord;

/**
 * @brief Opaque ZIP writer context.
 */
typedef struct VsZipWriter {
  FILE* file;
  ZipEntryRecord* entries;
  int32_t count;
  int32_t capacity;
  int failed;
} VsZipWriter;

static uint32_t _crc32_table[256];
static int _crc32_init = 0;

/**
 * @brief Initialize CRC32 lookup table (lazy).
 */
static void _init_crc32_table(void) {
  if (_crc32_init) return;
  for (uint32_t i = 0; i < 256; i++) {
    uint32_t c = i;
    for (int k = 0; k < 8; k++) {
      c = (c & 1u) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
    }
    _crc32_table[i] = c;
  }
  _crc32_init = 1;
}

/**
 * @brief Compute CRC32 for a byte buffer.
 */
static uint32_t _crc32_compute(const uint8_t* data, int32_t len) {
  _init_crc32_table();
  uint32_t c = 0xFFFFFFFFu;
  for (int32_t i = 0; i < len; i++) {
    c = _crc32_table[(c ^ data[i]) & 0xFFu] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFFu;
}

/**
 * @brief Write a little-endian 16-bit value to a file.
 */
static int _write_u16(FILE* f, uint16_t v) {
  const uint8_t b[2] = {(uint8_t)(v & 0xFFu), (uint8_t)((v >> 8) & 0xFFu)};
  return fwrite(b, 1, 2, f) == 2;
}

/**
 * @brief Write a little-endian 32-bit value to a file.
 */
static int _write_u32(FILE* f, uint32_t v) {
  const uint8_t b[4] = {
      (uint8_t)(v & 0xFFu),
      (uint8_t)((v >> 8) & 0xFFu),
      (uint8_t)((v >> 16) & 0xFFu),
      (uint8_t)((v >> 24) & 0xFFu)};
  return fwrite(b, 1, 4, f) == 4;
}

/**
 * @brief Current file position as a 32-bit value.
 */
static uint32_t _tell_u32(FILE* f) {
  const long p = ftell(f);
  if (p < 0) return 0;
  return (uint32_t)p;
}

/**
 * @brief Ensure the entry array has room for another record.
 */
static int _ensure_capacity(VsZipWriter* w) {
  if (w->count < w->capacity) return 1;
  const int32_t next = (w->capacity == 0) ? 32 : (w->capacity * 2);
  ZipEntryRecord* grown = (ZipEntryRecord*)realloc(w->entries, sizeof(ZipEntryRecord) * next);
  if (!grown) return 0;
  w->entries = grown;
  w->capacity = next;
  return 1;
}

/**
 * @brief Duplicate an entry name on the heap.
 */
static char* _dup_name(const char* name) {
  const size_t n = strlen(name);
  char* out = (char*)malloc(n + 1);
  if (!out) return NULL;
  memcpy(out, name, n + 1);
  return out;
}

/**
 * @brief Write a ZIP local file header for a stored file.
 */
static int _write_local_file_header(
    FILE* f,
    const char* name,
    uint32_t crc,
    uint32_t size) {
  const uint16_t name_len = (uint16_t)strlen(name);
  if (!_write_u32(f, 0x04034B50u)) return 0;
  if (!_write_u16(f, 20)) return 0;          // version needed to extract
  if (!_write_u16(f, 0)) return 0;           // flags
  if (!_write_u16(f, 0)) return 0;           // method: store
  if (!_write_u16(f, 0)) return 0;           // mod time
  if (!_write_u16(f, 0)) return 0;           // mod date
  if (!_write_u32(f, crc)) return 0;
  if (!_write_u32(f, size)) return 0;
  if (!_write_u32(f, size)) return 0;
  if (!_write_u16(f, name_len)) return 0;
  if (!_write_u16(f, 0)) return 0;           // extra len
  if (fwrite(name, 1, name_len, f) != name_len) return 0;
  return 1;
}

/**
 * @brief Write a central directory record for a stored file.
 */
static int _write_central_dir_entry(FILE* f, const ZipEntryRecord* e) {
  const uint16_t name_len = (uint16_t)strlen(e->name);
  if (!_write_u32(f, 0x02014B50u)) return 0;
  if (!_write_u16(f, 20)) return 0;          // version made by
  if (!_write_u16(f, 20)) return 0;          // version needed to extract
  if (!_write_u16(f, 0)) return 0;           // flags
  if (!_write_u16(f, 0)) return 0;           // method: store
  if (!_write_u16(f, 0)) return 0;           // mod time
  if (!_write_u16(f, 0)) return 0;           // mod date
  if (!_write_u32(f, e->crc32)) return 0;
  if (!_write_u32(f, e->comp_size)) return 0;
  if (!_write_u32(f, e->uncomp_size)) return 0;
  if (!_write_u16(f, name_len)) return 0;
  if (!_write_u16(f, 0)) return 0;           // extra len
  if (!_write_u16(f, 0)) return 0;           // file comment len
  if (!_write_u16(f, 0)) return 0;           // disk number start
  if (!_write_u16(f, 0)) return 0;           // internal attrs
  if (!_write_u32(f, 0)) return 0;           // external attrs
  if (!_write_u32(f, e->local_header_offset)) return 0;
  if (fwrite(e->name, 1, name_len, f) != name_len) return 0;
  return 1;
}

/**
 * @brief Write the ZIP end-of-central-directory record.
 */
static int _write_end_of_central_dir(FILE* f, uint16_t entry_count,
                                     uint32_t cd_size, uint32_t cd_offset) {
  if (!_write_u32(f, 0x06054B50u)) return 0;
  if (!_write_u16(f, 0)) return 0;   // disk num
  if (!_write_u16(f, 0)) return 0;   // start disk num
  if (!_write_u16(f, entry_count)) return 0;
  if (!_write_u16(f, entry_count)) return 0;
  if (!_write_u32(f, cd_size)) return 0;
  if (!_write_u32(f, cd_offset)) return 0;
  if (!_write_u16(f, 0)) return 0;   // comment len
  return 1;
}

/**
 * @brief Release writer resources and close the file.
 */
static void _free_writer(VsZipWriter* w) {
  if (!w) return;
  if (w->entries) {
    for (int32_t i = 0; i < w->count; i++) {
      free(w->entries[i].name);
    }
    free(w->entries);
  }
  if (w->file) {
    fclose(w->file);
  }
  free(w);
}

/**
 * @brief Create a ZIP writer and open the output file.
 */
int64_t vs_zip_open(const char* output_path) {
  if (!output_path || output_path[0] == '\0') return 0;

  VsZipWriter* w = (VsZipWriter*)calloc(1, sizeof(VsZipWriter));
  if (!w) return 0;

  w->file = fopen(output_path, "wb");
  if (!w->file) {
    free(w);
    return 0;
  }

  return (int64_t)(intptr_t)w;
}

/**
 * @brief Add one stored entry to the ZIP archive.
 */
int vs_zip_add_file(
    int64_t handle,
    const char* name,
    const uint8_t* data,
    int32_t data_len) {
  VsZipWriter* w = (VsZipWriter*)(intptr_t)handle;
  if (!w || !w->file || !name || !data || data_len < 0 || w->failed) {
    return 0;
  }

  if (strlen(name) > 0xFFFFu) {
    w->failed = 1;
    return 0;
  }

  if (!_ensure_capacity(w)) {
    w->failed = 1;
    return 0;
  }

  const uint32_t offset = _tell_u32(w->file);
  const uint32_t crc = _crc32_compute(data, data_len);
  const uint32_t size = (uint32_t)data_len;

  if (!_write_local_file_header(w->file, name, crc, size)) {
    w->failed = 1;
    return 0;
  }

  if (size > 0 && fwrite(data, 1, size, w->file) != size) {
    w->failed = 1;
    return 0;
  }

  ZipEntryRecord* e = &w->entries[w->count];
  e->name = _dup_name(name);
  if (!e->name) {
    w->failed = 1;
    return 0;
  }
  e->crc32 = crc;
  e->comp_size = size;
  e->uncomp_size = size;
  e->local_header_offset = offset;
  w->count++;

  return 1;
}

/**
 * @brief Finalize the ZIP file and write the central directory.
 */
int vs_zip_close(int64_t handle) {
  VsZipWriter* w = (VsZipWriter*)(intptr_t)handle;
  if (!w || !w->file || w->failed) {
    _free_writer(w);
    return 0;
  }

  if (w->count > 0xFFFF) {
    _free_writer(w);
    return 0;
  }

  const uint32_t cd_start = _tell_u32(w->file);

  for (int32_t i = 0; i < w->count; i++) {
    if (!_write_central_dir_entry(w->file, &w->entries[i])) {
      _free_writer(w);
      return 0;
    }
  }

  const uint32_t cd_end = _tell_u32(w->file);
  const uint32_t cd_size = cd_end - cd_start;

  if (!_write_end_of_central_dir(w->file, (uint16_t)w->count, cd_size, cd_start)) {
    _free_writer(w);
    return 0;
  }

  _free_writer(w);
  return 1;
}

/**
 * @brief Abort the ZIP writer and release resources.
 */
void vs_zip_abort(int64_t handle) {
  VsZipWriter* w = (VsZipWriter*)(intptr_t)handle;
  _free_writer(w);
}
