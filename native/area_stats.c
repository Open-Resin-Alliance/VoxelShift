/**
 * @file area_stats.c
 * @brief Native connected-component area statistics for greyscale layers.
 *
 * Implements an 8-connected flood fill to compute total solid area,
 * smallest/largest island, and bounding box of all solids in a layer.
 * This mirrors the Dart logic but avoids per-layer overhead in Dart.
 */
#include "voxelshift_native.h"

#include <stdlib.h>

/**
 * @brief Bitset helper: test if a pixel index was already visited.
 * @param visited Bitset array of visited flags.
 * @param idx Linear pixel index.
 * @return Non-zero if visited, zero otherwise.
 */
static int is_visited(const uint32_t* visited, int idx) {
  return (visited[idx >> 5] & (1u << (idx & 31))) != 0;
}

/**
 * @brief Bitset helper: mark a pixel index as visited.
 * @param visited Bitset array of visited flags.
 * @param idx Linear pixel index.
 */
static void mark_visited(uint32_t* visited, int idx) {
  visited[idx >> 5] |= (1u << (idx & 31));
}

/**
 * @brief Compute 8-connected island statistics for a greyscale layer.
 *
 * The algorithm scans for unvisited solid pixels, performs a stack-based
 * flood-fill, counts pixels per island, and accumulates totals and bounds.
 *
 * @return 1 on success, 0 on failure.
 */
int compute_layer_area_stats(
    const uint8_t* pixels,
    int32_t width,
    int32_t height,
    double x_pixel_size_mm,
    double y_pixel_size_mm,
    AreaStatsResult* out_result) {
  if (!pixels || !out_result || width <= 0 || height <= 0) {
    return 0;
  }

  const int32_t pixel_count = width * height;
  const int32_t visited_words = (pixel_count + 31) >> 5;

  uint32_t* visited = (uint32_t*)calloc((size_t)visited_words, sizeof(uint32_t));
  if (!visited) {
    return 0;
  }

  int32_t* stack = NULL;
  int32_t stack_cap = 0;
  int32_t stack_len = 0;

  int min_x = width;
  int min_y = height;
  int max_x = 0;
  int max_y = 0;

  double total_area = 0.0;
  double largest_area = 0.0;
  double smallest_area = 0.0;
  int area_count = 0;

  const double pixel_area = x_pixel_size_mm * y_pixel_size_mm;

  const int dx_offsets[8] = {-1, 0, 1, -1, 1, -1, 0, 1};
  const int dy_offsets[8] = {-1, -1, -1, 0, 0, 1, 1, 1};

  for (int y = 0; y < height; y++) {
    const int row_offset = y * width;
    for (int x = 0; x < width; x++) {
      const int root_idx = row_offset + x;
      if (pixels[root_idx] == 0 || is_visited(visited, root_idx)) {
        continue;
      }

      int island_pixels = 0;

      if (stack_len >= stack_cap) {
        const int32_t new_cap = stack_cap == 0 ? 4096 : stack_cap * 2;
        int32_t* new_stack =
            (int32_t*)realloc(stack, (size_t)new_cap * sizeof(int32_t));
        if (!new_stack) {
          free(stack);
          free(visited);
          return 0;
        }
        stack = new_stack;
        stack_cap = new_cap;
      }

      stack[stack_len++] = (y << 16) | (x & 0xFFFF);
      mark_visited(visited, root_idx);
      island_pixels++;

      if (x < min_x) min_x = x;
      if (x > max_x) max_x = x;
      if (y < min_y) min_y = y;
      if (y > max_y) max_y = y;

      while (stack_len > 0) {
        const int packed = stack[--stack_len];
        const int cy = (packed >> 16) & 0xFFFF;
        const int cx = packed & 0xFFFF;

        for (int i = 0; i < 8; i++) {
          const int nx = cx + dx_offsets[i];
          const int ny = cy + dy_offsets[i];

          if (nx < 0 || nx >= width || ny < 0 || ny >= height) {
            continue;
          }

          const int n_idx = ny * width + nx;
          if (pixels[n_idx] == 0 || is_visited(visited, n_idx)) {
            continue;
          }

          mark_visited(visited, n_idx);

          if (stack_len >= stack_cap) {
            const int32_t new_cap = stack_cap == 0 ? 4096 : stack_cap * 2;
            int32_t* new_stack =
                (int32_t*)realloc(stack, (size_t)new_cap * sizeof(int32_t));
            if (!new_stack) {
              free(stack);
              free(visited);
              return 0;
            }
            stack = new_stack;
            stack_cap = new_cap;
          }

          stack[stack_len++] = (ny << 16) | (nx & 0xFFFF);
          island_pixels++;

          if (nx < min_x) min_x = nx;
          if (nx > max_x) max_x = nx;
          if (ny < min_y) min_y = ny;
          if (ny > max_y) max_y = ny;
        }
      }

      const double island_area = island_pixels * pixel_area;
      total_area += island_area;
      if (island_area > largest_area) largest_area = island_area;
      if (area_count == 0 || island_area < smallest_area) {
        smallest_area = island_area;
      }
      area_count++;
    }
  }

  free(stack);
  free(visited);

  if (area_count == 0) {
    out_result->total_solid_area = 0.0;
    out_result->largest_area = 0.0;
    out_result->smallest_area = 0.0;
    out_result->min_x = 0;
    out_result->min_y = 0;
    out_result->max_x = 0;
    out_result->max_y = 0;
    out_result->area_count = 0;
    return 1;
  }

  out_result->total_solid_area = total_area;
  out_result->largest_area = largest_area;
  out_result->smallest_area = smallest_area;
  out_result->min_x = min_x;
  out_result->min_y = min_y;
  out_result->max_x = max_x;
  out_result->max_y = max_y;
  out_result->area_count = area_count;
  return 1;
}
