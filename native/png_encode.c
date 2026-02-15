/**
 * @file png_encode.c
 * @brief CPU scanline builder with PNG Up filter.
 *
 * Converts greyscale subpixel buffers into packed scanlines and applies
 * the PNG Up filter in-place. Used as the CPU fallback and baseline path.
 */
#include "voxelshift_native.h"

/**
 * @brief Build packed PNG scanlines and apply the Up filter in-place.
 *
 * For RGB output, three subpixels map to one RGB pixel. For greyscale
 * output, two subpixels are averaged to one pixel. The filter byte is
 * inserted per row, then the Up filter is applied bottom-to-top.
 */
int build_png_scanlines(
    const uint8_t* grey_pixels,
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels,
    uint8_t* out_scanlines,
    int32_t out_len) {
  if (!grey_pixels || !out_scanlines || src_width <= 0 || height <= 0 ||
      out_width <= 0 || (channels != 1 && channels != 3)) {
    return 0;
  }

  const int32_t bytes_per_row = out_width * channels;
  const int32_t scanline_size = 1 + bytes_per_row;
  const int32_t required_len = scanline_size * height;

  if (out_len < required_len) {
    return 0;
  }

  if (channels == 3) {
    // RGB path: 3 greyscale subpixels -> 1 RGB pixel.
    const int32_t required_subpixels = out_width * 3;
    const int32_t pad_total = required_subpixels - src_width;
    const int32_t pad_left = pad_total > 0 ? (pad_total / 2) : 0;

    for (int32_t y = 0; y < height; y++) {
      const int32_t row_offset = y * src_width;
      int32_t dst = y * scanline_size;
      out_scanlines[dst++] = 0; // placeholder filter byte

      for (int32_t x = 0; x < out_width; x++) {
        const int32_t si = x * 3 - pad_left;

        out_scanlines[dst++] =
            (si >= 0 && si < src_width) ? grey_pixels[row_offset + si] : 0;
        out_scanlines[dst++] =
            (si + 1 >= 0 && si + 1 < src_width) ? grey_pixels[row_offset + si + 1] : 0;
        out_scanlines[dst++] =
            (si + 2 >= 0 && si + 2 < src_width) ? grey_pixels[row_offset + si + 2] : 0;
      }
    }
  } else {
    // Greyscale path: average 2 subpixels -> 1 grey pixel.
    const int32_t required_subpixels = out_width * 2;
    const int32_t pad_total = required_subpixels - src_width;
    const int32_t pad_left = pad_total > 0 ? (pad_total / 2) : 0;

    for (int32_t y = 0; y < height; y++) {
      const int32_t row_offset = y * src_width;
      const int32_t dst_row = y * scanline_size;
      out_scanlines[dst_row] = 0; // placeholder filter byte

      for (int32_t x = 0; x < out_width; x++) {
        const int32_t si = x * 2 - pad_left;
        const uint8_t a =
            (si >= 0 && si < src_width) ? grey_pixels[row_offset + si] : 0;
        const uint8_t b =
            (si + 1 >= 0 && si + 1 < src_width) ? grey_pixels[row_offset + si + 1] : 0;
        out_scanlines[dst_row + 1 + x] = (uint8_t)((a + b) >> 1);
      }
    }
  }

  // Apply PNG Up filter bottom-to-top so previous row is still unmodified.
  for (int32_t y = height - 1; y >= 1; y--) {
    const int32_t cur_start = y * scanline_size;
    const int32_t prev_start = (y - 1) * scanline_size;
    out_scanlines[cur_start] = 2; // Up filter type
    for (int32_t i = 1; i <= bytes_per_row; i++) {
      out_scanlines[cur_start + i] =
          (uint8_t)((out_scanlines[cur_start + i] - out_scanlines[prev_start + i]) & 0xFF);
    }
  }

  // First row: Up with zero row above.
  out_scanlines[0] = 2;

  return 1;
}
