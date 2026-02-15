/**
 * @file rle_decode.c
 * @brief Native CTB decrypt + RLE decode (UVtools-compatible).
 *
 * This module performs optional per-layer decryption and expands CTB
 * run-length encoding into greyscale pixel buffers.
 */
#include "voxelshift_native.h"

/**
 * @brief Read one byte from the encoded stream and update decryption state.
 *
 * When encryption is enabled, the byte is XORed with the evolving key.
 * The key is updated every 4 bytes according to CTB rules.
 */
static uint8_t read_byte(
    const uint8_t* data,
    int* n,
    int32_t data_len,
    int encrypted,
    uint32_t* key,
    uint32_t init,
    int* key_byte_index,
    int* ok) {
  if (*n >= data_len) {
    *ok = 0;
    return 0;
  }

  uint8_t value = data[(*n)++];
  if (!encrypted) return value;

  const uint8_t k = (uint8_t)((*key >> (8 * (*key_byte_index))) & 0xFFu);
  value ^= k;

  (*key_byte_index)++;
  if (((*key_byte_index) & 3) == 0) {
    *key = *key + init;
    *key_byte_index = 0;
  }

  return value;
}

/**
 * @brief Decode a CTB layer into greyscale pixels, with optional decryption.
 *
 * The output buffer is fully overwritten; any incomplete data is treated
 * as zero-filled. This matches the Dart fallback behavior to keep
 * deterministic output across platforms.
 */
int decrypt_and_decode_layer(
    const uint8_t* data,
    int32_t data_len,
    int32_t layer_index,
    int32_t encryption_key,
    int32_t pixel_count,
    uint8_t* out_pixels) {
  if (!data || data_len <= 0 || pixel_count <= 0 || !out_pixels) {
    return 0;
  }

  for (int32_t i = 0; i < pixel_count; i++) {
    out_pixels[i] = 0;
  }

  const int encrypted = encryption_key != 0;
  uint32_t key = 0;
  uint32_t init = 0;
  int key_byte_index = 0;

  if (encrypted) {
    init = ((uint32_t)encryption_key * 0x2d83cdacu + 0xd8a83423u);
    key = ((uint32_t)layer_index * 0x1e1530cdu + 0xec3d47cdu);
    key = key * init;
  }

  int n = 0;
  int pixel = 0;
  int ok = 1;

  while (n < data_len && pixel < pixel_count && ok) {
    uint8_t code = read_byte(
        data, &n, data_len, encrypted, &key, init, &key_byte_index, &ok);
    if (!ok) break;

    int stride = 1;

    if ((code & 0x80u) != 0) {
      code &= 0x7Fu;

      uint8_t slen = read_byte(
          data, &n, data_len, encrypted, &key, init, &key_byte_index, &ok);
      if (!ok) break;

      if ((slen & 0x80u) == 0) {
        stride = slen;
      } else if ((slen & 0xC0u) == 0x80u) {
        const uint8_t b0 = read_byte(
            data, &n, data_len, encrypted, &key, init, &key_byte_index, &ok);
        if (!ok) break;
        stride = ((slen & 0x3Fu) << 8) + b0;
      } else if ((slen & 0xE0u) == 0xC0u) {
        const uint8_t b0 = read_byte(
            data, &n, data_len, encrypted, &key, init, &key_byte_index, &ok);
        const uint8_t b1 = read_byte(
            data, &n, data_len, encrypted, &key, init, &key_byte_index, &ok);
        if (!ok) break;
        stride = ((slen & 0x1Fu) << 16) + (b0 << 8) + b1;
      } else if ((slen & 0xF0u) == 0xE0u) {
        const uint8_t b0 = read_byte(
            data, &n, data_len, encrypted, &key, init, &key_byte_index, &ok);
        const uint8_t b1 = read_byte(
            data, &n, data_len, encrypted, &key, init, &key_byte_index, &ok);
        const uint8_t b2 = read_byte(
            data, &n, data_len, encrypted, &key, init, &key_byte_index, &ok);
        if (!ok) break;
        stride = ((slen & 0x0Fu) << 24) + (b0 << 16) + (b1 << 8) + b2;
      }
    }

    const uint8_t pixel_value = code == 0 ? 0 : (uint8_t)((code << 1) | 1);

    int end = pixel + stride;
    if (end > pixel_count) end = pixel_count;

    if (pixel_value != 0) {
      for (int i = pixel; i < end; i++) {
        out_pixels[i] = pixel_value;
      }
    }

    pixel = end;
  }

  return 1;
}
