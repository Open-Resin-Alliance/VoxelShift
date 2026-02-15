/**
 * @file voxelshift_native.h
 * @brief C API surface used by the Flutter/Dart layer via FFI.
 *
 * This header declares all native entry points for decoding CTB layers,
 * building PNG scanlines, recompressing PNGs, processing batches, and
 * optionally leveraging GPU backends. All functions use C ABI and return
 * simple success/failure codes suitable for FFI calls.
 */
#ifndef VOXELSHIFT_NATIVE_H
#define VOXELSHIFT_NATIVE_H

#include <stdint.h>
#include "config.h"

#ifdef _WIN32
  #define VS_EXPORT __declspec(dllexport)
#else
  #define VS_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

/// Result structure for per-layer connected-component area statistics.
typedef struct AreaStatsResult {
  double total_solid_area;
  double largest_area;
  double smallest_area;
  int32_t min_x;
  int32_t min_y;
  int32_t max_x;
  int32_t max_y;
  int32_t area_count;
} AreaStatsResult;

/// Compute 8-connected island area statistics for a decoded greyscale layer.
///
/// Returns 1 on success, 0 on failure.
VS_EXPORT int compute_layer_area_stats(
    const uint8_t* pixels,
    int32_t width,
    int32_t height,
    double x_pixel_size_mm,
    double y_pixel_size_mm,
    AreaStatsResult* out_result);

/// Decrypt (when encrypted) and decode NanoDLP CTB RLE data into greyscale pixels.
///
/// Returns 1 on success, 0 on failure.
VS_EXPORT int decrypt_and_decode_layer(
    const uint8_t* data,
    int32_t data_len,
    int32_t layer_index,
    int32_t encryption_key,
    int32_t pixel_count,
    uint8_t* out_pixels);

/// Build PNG scanlines from decoded greyscale pixels and apply PNG Up filter.
///
/// channels = 3 for RGB output (8-bit panel), channels = 1 for greyscale
/// output (3-bit subpixel path).
///
/// Returns 1 on success, 0 on failure.
VS_EXPORT int build_png_scanlines(
  const uint8_t* grey_pixels,
  int32_t src_width,
  int32_t height,
  int32_t out_width,
  int32_t channels,
  uint8_t* out_scanlines,
  int32_t out_len);

/// Recompress PNG IDAT payload to a target zlib level.
///
/// Allocates output bytes with malloc and stores pointer/length in out params.
/// Caller must release via [free_native_buffer].
///
/// Returns 1 on success, 0 on failure.
VS_EXPORT int recompress_png_idat(
    const uint8_t* png_data,
    int32_t png_len,
    int32_t level,
    uint8_t** out_data,
    int32_t* out_len);

/// Recompress multiple PNG payloads in one native call.
///
/// Input is represented as one concatenated byte blob plus per-item
/// offset/length arrays.
///
/// Output is returned the same way and must be released by
/// [free_native_buffer] / [free_native_int_buffer].
///
/// Returns 1 on success, 0 on failure.
VS_EXPORT int recompress_png_batch(
  const uint8_t* input_blob,
  int32_t input_blob_len,
  const int32_t* input_offsets,
  const int32_t* input_lengths,
  int32_t count,
  int32_t level,
  uint8_t** out_blob,
  int32_t* out_blob_len,
  int32_t** out_offsets,
  int32_t** out_lengths);

/// Configure native worker thread count for recompress_png_batch.
///
/// threads <= 0 resets to auto mode (based on CPU count).
VS_EXPORT void set_recompress_batch_threads(int32_t threads);

/// Release a heap buffer returned from native APIs.
VS_EXPORT void free_native_buffer(uint8_t* buffer);

/// Release a heap int32 buffer returned from native APIs.
VS_EXPORT void free_native_int_buffer(int32_t* buffer);

/// Hint current native thread priority for UI friendliness.
///
/// On Windows, when [background] is non-zero, sets current thread to
/// THREAD_PRIORITY_BELOW_NORMAL. When zero, restores THREAD_PRIORITY_NORMAL.
///
/// Returns 1 on success, 0 on failure/unsupported platform.
VS_EXPORT int set_current_thread_background_priority(int32_t background);

  /// Decode a layer and build PNG scanlines in one native call.
  ///
  /// Writes decoded greyscale pixels to [out_pixels] and Up-filtered PNG
  /// scanlines to [out_scanlines].
  ///
  /// Returns 1 on success, 0 on failure.
  VS_EXPORT int decode_and_build_png_scanlines(
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
    int32_t out_len);

  /// Decode a layer, compute area stats, and build PNG scanlines in one call.
  ///
  /// Returns 1 on success, 0 on failure.
  VS_EXPORT int decode_build_scanlines_and_area(
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
    int32_t out_len);

  /// Process multiple layers in one native call using internal native
  /// worker threads.
  ///
  /// Each layer is decoded, area stats are computed, scanlines are built,
  /// and final PNG bytes are produced.
  ///
  /// Output buffers must be freed by:
  ///   - [free_native_buffer] for out_blob
  ///   - [free_native_int_buffer] for out_offsets/out_lengths
  ///   - [free_native_area_buffer] for out_areas
  ///
  /// Returns 1 on success, 0 on failure.
  VS_EXPORT int process_layers_batch(
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
    AreaStatsResult** out_areas);

  /// Configure default thread count for process_layers_batch.
  ///
  /// threads <= 0 resets to auto mode.
  VS_EXPORT void set_process_layers_batch_threads(int32_t threads);

  /// Enable or disable analytics collection for process_layers_batch.
  ///
  /// When enabled, per-thread timing stats are recorded for the last batch.
  VS_EXPORT void set_process_layers_batch_analytics(int32_t enabled);

  /// Number of threads used by the most recent batch (0 if unavailable).
  VS_EXPORT int32_t process_layers_last_thread_count(void);

  /// Fill per-thread timing stats for the most recent batch.
  ///
  /// Arrays must be pre-allocated with length >= max_count.
  VS_EXPORT void process_layers_last_thread_stats(
    int64_t* out_total_ns,
    int64_t* out_decode_ns,
    int64_t* out_scanline_ns,
    int64_t* out_compress_ns,
    int64_t* out_png_ns,
    int32_t* out_layers,
    int32_t max_count);

  /// Returns backend used by the most recent process_layers_batch call.
  ///
  /// 0 = CPU, 1 = OpenCL GPU, 2 = Metal GPU, 3 = CUDA/Tensor GPU.
  VS_EXPORT int32_t process_layers_last_backend(void);

  /// Returns number of layers in last process_layers_batch call that attempted
  /// a GPU scanline build path.
  VS_EXPORT int32_t process_layers_last_gpu_attempts(void);

  /// Returns number of layers in last process_layers_batch call that were
  /// successfully built on GPU.
  VS_EXPORT int32_t process_layers_last_gpu_successes(void);

  /// Returns number of layers in last process_layers_batch call that attempted
  /// GPU but fell back to CPU scanline build.
  VS_EXPORT int32_t process_layers_last_gpu_fallbacks(void);

  /// Returns last CUDA error code observed during process_layers_batch.
  ///
  /// 0 means no CUDA error captured (or unavailable).
  VS_EXPORT int32_t process_layers_last_cuda_error(void);

  /// Returns 1 if the most recent phased batch used GPU mega-batch successfully.
  VS_EXPORT int32_t process_layers_last_gpu_batch_ok(void);

  /// Process multiple layers using the PHASED pipeline.
  ///
  /// Phase 1: [All CPU cores] Parallel decode + area stats
  /// Phase 2: [GPU mega-batch] Build scanlines (or CPU fallback)
  /// Phase 3: [All CPU cores] Parallel zlib compress + PNG wrap
  ///
  /// When use_gpu_batch is non-zero and a GPU backend is active,
  /// Phase 2 runs as a single GPU call that processes ALL layers at once.
  ///
  /// Returns 1 on success, 0 on failure.
  VS_EXPORT int process_layers_batch_phased(
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
    AreaStatsResult** out_areas);

  /// Release a heap AreaStatsResult buffer returned from native APIs.
  VS_EXPORT void free_native_area_buffer(AreaStatsResult* buffer);

  /// Set whether optional GPU acceleration is enabled (1) or disabled (0).
  VS_EXPORT void set_gpu_acceleration_enabled(int32_t enabled);

  /// Set preferred GPU backend.
  ///
  /// 0 = auto, 1 = OpenCL, 2 = Metal, 3 = CUDA/Tensor.
  VS_EXPORT void set_gpu_backend_preference(int32_t backend_code);

  /// Returns 1 if backend is available on this system.
  ///
  /// backend_code: 1 = OpenCL, 2 = Metal, 3 = CUDA/Tensor.
  VS_EXPORT int gpu_backend_available(int32_t backend_code);

  /// Returns 1 when a supported GPU backend is detected and acceleration is enabled.
  VS_EXPORT int gpu_acceleration_active(void);

  /// Returns backend code: 0 = none, 1 = OpenCL, 2 = Metal, 3 = CUDA/Tensor.
  VS_EXPORT int32_t gpu_acceleration_backend(void);

  /// Initialize CUDA device and return success.
  VS_EXPORT int gpu_cuda_info_init(void);

  /// GPU device name string (empty if unavailable).
  VS_EXPORT const char* gpu_cuda_info_device_name(void);

  /// Total GPU VRAM in bytes.
  VS_EXPORT int64_t gpu_cuda_info_vram_bytes(void);

  /// 1 if GPU has tensor cores (compute capability >= 7.0).
  VS_EXPORT int32_t gpu_cuda_info_has_tensor_cores(void);

  /// Compute capability as major*10 + minor (e.g., 86 for SM 8.6).
  VS_EXPORT int32_t gpu_cuda_info_compute_capability(void);

  /// Number of streaming multiprocessors.
  VS_EXPORT int32_t gpu_cuda_info_multiprocessor_count(void);

  /// Max concurrent per-layer CUDA operations that fit in VRAM.
  /// Returns 0 if CUDA is unavailable or dimensions are invalid.
  VS_EXPORT int32_t gpu_cuda_info_max_concurrent_layers(
    int32_t src_width,
    int32_t height,
    int32_t out_width,
    int32_t channels);

  /// Open a ZIP writer. Returns opaque handle, or 0 on failure.
  VS_EXPORT int64_t vs_zip_open(const char* output_path);

  /// Add one stored file entry to the ZIP archive.
  ///
  /// Returns 1 on success, 0 on failure.
  VS_EXPORT int vs_zip_add_file(
    int64_t handle,
    const char* name,
    const uint8_t* data,
    int32_t data_len);

  /// Finalize ZIP (write central directory and close file).
  ///
  /// Returns 1 on success, 0 on failure.
  VS_EXPORT int vs_zip_close(int64_t handle);

  /// Abort ZIP writer and close underlying file without finalization.
  VS_EXPORT void vs_zip_abort(int64_t handle);

#ifdef __cplusplus
}
#endif

#endif // VOXELSHIFT_NATIVE_H
