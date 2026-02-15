import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../models/layer_area_info.dart';

final class _NativeAreaStatsResult extends ffi.Struct {
  @ffi.Double()
  external double totalSolidArea;

  @ffi.Double()
  external double largestArea;

  @ffi.Double()
  external double smallestArea;

  @ffi.Int32()
  external int minX;

  @ffi.Int32()
  external int minY;

  @ffi.Int32()
  external int maxX;

  @ffi.Int32()
  external int maxY;

  @ffi.Int32()
  external int areaCount;
}

typedef _NativeProcessLayersBatch = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8> inputBlob,
  ffi.Int32 inputBlobLen,
  ffi.Pointer<ffi.Int32> inputOffsets,
  ffi.Pointer<ffi.Int32> inputLengths,
  ffi.Int32 count,
  ffi.Int32 layerIndexBase,
  ffi.Int32 encryptionKey,
  ffi.Int32 srcWidth,
  ffi.Int32 height,
  ffi.Int32 outWidth,
  ffi.Int32 channels,
  ffi.Double xPixelSizeMm,
  ffi.Double yPixelSizeMm,
  ffi.Int32 pngLevel,
  ffi.Int32 threadCount,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>> outBlob,
  ffi.Pointer<ffi.Int32> outBlobLen,
  ffi.Pointer<ffi.Pointer<ffi.Int32>> outOffsets,
  ffi.Pointer<ffi.Pointer<ffi.Int32>> outLengths,
  ffi.Pointer<ffi.Pointer<_NativeAreaStatsResult>> outAreas,
);

typedef _DartProcessLayersBatch = int Function(
  ffi.Pointer<ffi.Uint8> inputBlob,
  int inputBlobLen,
  ffi.Pointer<ffi.Int32> inputOffsets,
  ffi.Pointer<ffi.Int32> inputLengths,
  int count,
  int layerIndexBase,
  int encryptionKey,
  int srcWidth,
  int height,
  int outWidth,
  int channels,
  double xPixelSizeMm,
  double yPixelSizeMm,
  int pngLevel,
  int threadCount,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>> outBlob,
  ffi.Pointer<ffi.Int32> outBlobLen,
  ffi.Pointer<ffi.Pointer<ffi.Int32>> outOffsets,
  ffi.Pointer<ffi.Pointer<ffi.Int32>> outLengths,
  ffi.Pointer<ffi.Pointer<_NativeAreaStatsResult>> outAreas,
);

typedef _NativeSetProcessBatchThreads = ffi.Void Function(ffi.Int32 threads);
typedef _DartSetProcessBatchThreads = void Function(int threads);

typedef _NativeSetProcessBatchAnalytics = ffi.Void Function(ffi.Int32 enabled);
typedef _DartSetProcessBatchAnalytics = void Function(int enabled);

typedef _NativeGetProcessLastBackend = ffi.Int32 Function();
typedef _DartGetProcessLastBackend = int Function();

typedef _NativeGetProcessLastGpuAttempts = ffi.Int32 Function();
typedef _DartGetProcessLastGpuAttempts = int Function();

typedef _NativeGetProcessLastGpuSuccesses = ffi.Int32 Function();
typedef _DartGetProcessLastGpuSuccesses = int Function();

typedef _NativeGetProcessLastGpuFallbacks = ffi.Int32 Function();
typedef _DartGetProcessLastGpuFallbacks = int Function();

typedef _NativeGetProcessLastCudaError = ffi.Int32 Function();
typedef _DartGetProcessLastCudaError = int Function();

typedef _NativeGetProcessLastThreadCount = ffi.Int32 Function();
typedef _DartGetProcessLastThreadCount = int Function();

typedef _NativeGetProcessLastThreadStats = ffi.Void Function(
  ffi.Pointer<ffi.Int64> outTotalNs,
  ffi.Pointer<ffi.Int64> outDecodeNs,
  ffi.Pointer<ffi.Int64> outScanlineNs,
  ffi.Pointer<ffi.Int64> outCompressNs,
  ffi.Pointer<ffi.Int64> outPngNs,
  ffi.Pointer<ffi.Int32> outLayers,
  ffi.Int32 maxCount,
);
typedef _DartGetProcessLastThreadStats = void Function(
  ffi.Pointer<ffi.Int64> outTotalNs,
  ffi.Pointer<ffi.Int64> outDecodeNs,
  ffi.Pointer<ffi.Int64> outScanlineNs,
  ffi.Pointer<ffi.Int64> outCompressNs,
  ffi.Pointer<ffi.Int64> outPngNs,
  ffi.Pointer<ffi.Int32> outLayers,
  int maxCount,
);

typedef _NativeGetProcessLastGpuBatchOk = ffi.Int32 Function();
typedef _DartGetProcessLastGpuBatchOk = int Function();

// ── Phased batch (CPU+GPU hybrid pipeline) ──────────────────────────────────

typedef _NativeProcessLayersBatchPhased = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8> inputBlob,
  ffi.Int32 inputBlobLen,
  ffi.Pointer<ffi.Int32> inputOffsets,
  ffi.Pointer<ffi.Int32> inputLengths,
  ffi.Int32 count,
  ffi.Int32 layerIndexBase,
  ffi.Int32 encryptionKey,
  ffi.Int32 srcWidth,
  ffi.Int32 height,
  ffi.Int32 outWidth,
  ffi.Int32 channels,
  ffi.Double xPixelSizeMm,
  ffi.Double yPixelSizeMm,
  ffi.Int32 pngLevel,
  ffi.Int32 threadCount,
  ffi.Int32 useGpuBatch,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>> outBlob,
  ffi.Pointer<ffi.Int32> outBlobLen,
  ffi.Pointer<ffi.Pointer<ffi.Int32>> outOffsets,
  ffi.Pointer<ffi.Pointer<ffi.Int32>> outLengths,
  ffi.Pointer<ffi.Pointer<_NativeAreaStatsResult>> outAreas,
);

typedef _DartProcessLayersBatchPhased = int Function(
  ffi.Pointer<ffi.Uint8> inputBlob,
  int inputBlobLen,
  ffi.Pointer<ffi.Int32> inputOffsets,
  ffi.Pointer<ffi.Int32> inputLengths,
  int count,
  int layerIndexBase,
  int encryptionKey,
  int srcWidth,
  int height,
  int outWidth,
  int channels,
  double xPixelSizeMm,
  double yPixelSizeMm,
  int pngLevel,
  int threadCount,
  int useGpuBatch,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>> outBlob,
  ffi.Pointer<ffi.Int32> outBlobLen,
  ffi.Pointer<ffi.Pointer<ffi.Int32>> outOffsets,
  ffi.Pointer<ffi.Pointer<ffi.Int32>> outLengths,
  ffi.Pointer<ffi.Pointer<_NativeAreaStatsResult>> outAreas,
);

// ── CUDA device info ────────────────────────────────────────────────────────

typedef _NativeGpuCudaInit = ffi.Int32 Function();
typedef _DartGpuCudaInit = int Function();

typedef _NativeGpuCudaDeviceName = ffi.Pointer<Utf8> Function();
typedef _DartGpuCudaDeviceName = ffi.Pointer<Utf8> Function();

typedef _NativeGpuCudaVram = ffi.Int64 Function();
typedef _DartGpuCudaVram = int Function();

typedef _NativeGpuCudaI32 = ffi.Int32 Function();
typedef _DartGpuCudaI32 = int Function();

typedef _NativeFreeBuffer = ffi.Void Function(ffi.Pointer<ffi.Uint8> buffer);
typedef _DartFreeBuffer = void Function(ffi.Pointer<ffi.Uint8> buffer);

typedef _NativeFreeIntBuffer = ffi.Void Function(ffi.Pointer<ffi.Int32> buffer);
typedef _DartFreeIntBuffer = void Function(ffi.Pointer<ffi.Int32> buffer);

typedef _NativeFreeAreaBuffer = ffi.Void Function(ffi.Pointer<_NativeAreaStatsResult> buffer);
typedef _DartFreeAreaBuffer = void Function(ffi.Pointer<_NativeAreaStatsResult> buffer);

class NativeBatchLayerResult {
  final Uint8List pngBytes;
  final LayerAreaInfo areaInfo;

  const NativeBatchLayerResult({
    required this.pngBytes,
    required this.areaInfo,
  });
}

class NativeThreadStats {
  final int layers;
  final int totalNs;
  final int decodeNs;
  final int scanlineNs;
  final int compressNs;
  final int pngNs;

  const NativeThreadStats({
    required this.layers,
    required this.totalNs,
    required this.decodeNs,
    required this.scanlineNs,
    required this.compressNs,
    required this.pngNs,
  });
}

class NativeLayerBatchProcess {
  NativeLayerBatchProcess._();

  static final NativeLayerBatchProcess instance = NativeLayerBatchProcess._();

  ffi.DynamicLibrary? _lib;
  _DartProcessLayersBatch? _processBatch;
  _DartSetProcessBatchThreads? _setBatchThreads;
  _DartSetProcessBatchAnalytics? _setBatchAnalytics;
  _DartGetProcessLastBackend? _getLastBackend;
  _DartGetProcessLastGpuAttempts? _getLastGpuAttempts;
  _DartGetProcessLastGpuSuccesses? _getLastGpuSuccesses;
  _DartGetProcessLastGpuFallbacks? _getLastGpuFallbacks;
  _DartGetProcessLastCudaError? _getLastCudaError;
  _DartGetProcessLastThreadCount? _getLastThreadCount;
  _DartGetProcessLastThreadStats? _getLastThreadStats;
  _DartGetProcessLastGpuBatchOk? _getLastGpuBatchOk;
  _DartProcessLayersBatchPhased? _processBatchPhased;
  _DartGpuCudaInit? _cudaInit;
  _DartGpuCudaDeviceName? _cudaDeviceName;
  _DartGpuCudaVram? _cudaVram;
  _DartGpuCudaI32? _cudaHasTensorCores;
  _DartGpuCudaI32? _cudaComputeCap;
  _DartGpuCudaI32? _cudaMpCount;
  int Function(int, int, int, int)? _cudaMaxConcurrent;
  _DartFreeBuffer? _freeBuffer;
  _DartFreeIntBuffer? _freeIntBuffer;
  _DartFreeAreaBuffer? _freeAreaBuffer;
  bool _initTried = false;

  bool get available {
    _ensureInit();
    return _processBatch != null &&
        _freeBuffer != null &&
        _freeIntBuffer != null &&
        _freeAreaBuffer != null;
  }

  void setBatchThreads(int threads) {
    _ensureInit();
    final fn = _setBatchThreads;
    if (fn == null) return;
    try {
      fn(threads);
    } catch (_) {}
  }

  void setAnalyticsEnabled(bool enabled) {
    _ensureInit();
    final fn = _setBatchAnalytics;
    if (fn == null) return;
    try {
      fn(enabled ? 1 : 0);
    } catch (_) {}
  }

  int get lastBackendCode {
    _ensureInit();
    final fn = _getLastBackend;
    if (fn == null) return 0;
    try {
      return fn();
    } catch (_) {
      return 0;
    }
  }

  String get lastBackendName {
    switch (lastBackendCode) {
      case 1:
        return 'GPU OpenCL';
      case 2:
        return 'GPU Metal';
      case 3:
        return 'GPU CUDA/Tensor';
      default:
        return 'CPU Native';
    }
  }

  int get lastGpuAttempts {
    _ensureInit();
    final fn = _getLastGpuAttempts;
    if (fn == null) return 0;
    try {
      return fn();
    } catch (_) {
      return 0;
    }
  }

  int get lastGpuSuccesses {
    _ensureInit();
    final fn = _getLastGpuSuccesses;
    if (fn == null) return 0;
    try {
      return fn();
    } catch (_) {
      return 0;
    }
  }

  int get lastGpuFallbacks {
    _ensureInit();
    final fn = _getLastGpuFallbacks;
    if (fn == null) return 0;
    try {
      return fn();
    } catch (_) {
      return 0;
    }
  }

  List<NativeThreadStats> getLastThreadStats() {
    _ensureInit();
    final countFn = _getLastThreadCount;
    final statsFn = _getLastThreadStats;
    if (countFn == null || statsFn == null) return const [];
    int count = 0;
    try {
      count = countFn();
    } catch (_) {
      return const [];
    }
    if (count <= 0) return const [];

    final totalPtr = malloc<ffi.Int64>(count);
    final decodePtr = malloc<ffi.Int64>(count);
    final scanPtr = malloc<ffi.Int64>(count);
    final compressPtr = malloc<ffi.Int64>(count);
    final pngPtr = malloc<ffi.Int64>(count);
    final layersPtr = malloc<ffi.Int32>(count);

    try {
      statsFn(
        totalPtr,
        decodePtr,
        scanPtr,
        compressPtr,
        pngPtr,
        layersPtr,
        count,
      );

      final stats = <NativeThreadStats>[];
      for (int i = 0; i < count; i++) {
        stats.add(NativeThreadStats(
          layers: layersPtr[i],
          totalNs: totalPtr[i],
          decodeNs: decodePtr[i],
          scanlineNs: scanPtr[i],
          compressNs: compressPtr[i],
          pngNs: pngPtr[i],
        ));
      }
      return stats;
    } catch (_) {
      return const [];
    } finally {
      malloc.free(totalPtr);
      malloc.free(decodePtr);
      malloc.free(scanPtr);
      malloc.free(compressPtr);
      malloc.free(pngPtr);
      malloc.free(layersPtr);
    }
  }

  int get lastCudaError {
    _ensureInit();
    final fn = _getLastCudaError;
    if (fn == null) return 0;
    try {
      return fn();
    } catch (_) {
      return 0;
    }
  }

  int get lastGpuBatchOk {
    _ensureInit();
    final fn = _getLastGpuBatchOk;
    if (fn == null) return 0;
    try {
      return fn();
    } catch (_) {
      return 0;
    }
  }

  bool get phasedAvailable {
    _ensureInit();
    return _processBatchPhased != null &&
        _freeBuffer != null &&
        _freeIntBuffer != null &&
        _freeAreaBuffer != null;
  }

  // ── CUDA device info ──────────────────────────────────────────────────

  bool cudaInit() {
    _ensureInit();
    final fn = _cudaInit;
    if (fn == null) return false;
    try {
      return fn() != 0;
    } catch (_) {
      return false;
    }
  }

  String get cudaDeviceName {
    _ensureInit();
    final fn = _cudaDeviceName;
    if (fn == null) return '';
    try {
      final ptr = fn();
      if (ptr == ffi.nullptr) return '';
      return ptr.toDartString();
    } catch (_) {
      return '';
    }
  }

  int get cudaVramBytes {
    _ensureInit();
    final fn = _cudaVram;
    if (fn == null) return 0;
    try {
      return fn();
    } catch (_) {
      return 0;
    }
  }

  bool get cudaHasTensorCores {
    _ensureInit();
    final fn = _cudaHasTensorCores;
    if (fn == null) return false;
    try {
      return fn() != 0;
    } catch (_) {
      return false;
    }
  }

  int get cudaComputeCapability {
    _ensureInit();
    final fn = _cudaComputeCap;
    if (fn == null) return 0;
    try {
      return fn();
    } catch (_) {
      return 0;
    }
  }

  int get cudaMultiprocessorCount {
    _ensureInit();
    final fn = _cudaMpCount;
    if (fn == null) return 0;
    try {
      return fn();
    } catch (_) {
      return 0;
    }
  }

  /// Max concurrent per-layer CUDA operations that fit in VRAM.
  /// Returns 0 if CUDA unavailable or dimensions invalid.
  int cudaMaxConcurrentLayers({
    required int srcWidth,
    required int height,
    required int outWidth,
    required int channels,
  }) {
    _ensureInit();
    final fn = _cudaMaxConcurrent;
    if (fn == null) return 0;
    try {
      return fn(srcWidth, height, outWidth, channels);
    } catch (_) {
      return 0;
    }
  }

  List<NativeBatchLayerResult>? processBatch({
    required List<Uint8List> rawLayers,
    required int layerIndexBase,
    required int encryptionKey,
    required int srcWidth,
    required int height,
    required int outWidth,
    required int channels,
    required double xPixelSizeMm,
    required double yPixelSizeMm,
    int pngLevel = 1,
    int threadCount = 0,
  }) {
    _ensureInit();
    final fn = _processBatch;
    final freeBytes = _freeBuffer;
    final freeInts = _freeIntBuffer;
    final freeAreas = _freeAreaBuffer;
    if (fn == null || freeBytes == null || freeInts == null || freeAreas == null) {
      return null;
    }
    if (rawLayers.isEmpty) return const <NativeBatchLayerResult>[];

    final count = rawLayers.length;
    var inputBlobLen = 0;
    for (final l in rawLayers) {
      inputBlobLen += l.length;
    }

    final inputBlobPtr = malloc<ffi.Uint8>(inputBlobLen);
    final inputOffsetsPtr = malloc<ffi.Int32>(count);
    final inputLengthsPtr = malloc<ffi.Int32>(count);

    final outBlobPtr = malloc<ffi.Pointer<ffi.Uint8>>();
    final outBlobLenPtr = malloc<ffi.Int32>();
    final outOffsetsPtr = malloc<ffi.Pointer<ffi.Int32>>();
    final outLengthsPtr = malloc<ffi.Pointer<ffi.Int32>>();
    final outAreasPtr = malloc<ffi.Pointer<_NativeAreaStatsResult>>();

    try {
      final inputBlob = inputBlobPtr.asTypedList(inputBlobLen);
      var cursor = 0;
      for (var i = 0; i < count; i++) {
        final layer = rawLayers[i];
        inputOffsetsPtr[i] = cursor;
        inputLengthsPtr[i] = layer.length;
        inputBlob.setAll(cursor, layer);
        cursor += layer.length;
      }

      outBlobPtr.value = ffi.nullptr;
      outBlobLenPtr.value = 0;
      outOffsetsPtr.value = ffi.nullptr;
      outLengthsPtr.value = ffi.nullptr;
      outAreasPtr.value = ffi.nullptr;

      final ok = fn(
        inputBlobPtr,
        inputBlobLen,
        inputOffsetsPtr,
        inputLengthsPtr,
        count,
        layerIndexBase,
        encryptionKey,
        srcWidth,
        height,
        outWidth,
        channels,
        xPixelSizeMm,
        yPixelSizeMm,
        pngLevel,
        threadCount,
        outBlobPtr,
        outBlobLenPtr,
        outOffsetsPtr,
        outLengthsPtr,
        outAreasPtr,
      );
      if (ok == 0) return null;

      final outBlob = outBlobPtr.value;
      final outBlobLen = outBlobLenPtr.value;
      final outOffsets = outOffsetsPtr.value;
      final outLengths = outLengthsPtr.value;
      final outAreas = outAreasPtr.value;

      if (outBlob == ffi.nullptr ||
          outOffsets == ffi.nullptr ||
          outLengths == ffi.nullptr ||
          outAreas == ffi.nullptr ||
          outBlobLen <= 0) {
        return null;
      }

      final blob = outBlob.asTypedList(outBlobLen);
      final result = <NativeBatchLayerResult>[];
      for (var i = 0; i < count; i++) {
        final off = outOffsets[i];
        final len = outLengths[i];
        if (off < 0 || len <= 0 || off + len > outBlobLen) {
          freeBytes(outBlob);
          freeInts(outOffsets);
          freeInts(outLengths);
          freeAreas(outAreas);
          return null;
        }

        final area = outAreas[i];
        result.add(
          NativeBatchLayerResult(
            pngBytes: Uint8List.fromList(blob.sublist(off, off + len)),
            areaInfo: LayerAreaInfo(
              totalSolidArea: area.totalSolidArea,
              largestArea: area.largestArea,
              smallestArea: area.smallestArea,
              minX: area.minX,
              minY: area.minY,
              maxX: area.maxX,
              maxY: area.maxY,
              areaCount: area.areaCount,
            ),
          ),
        );
      }

      freeBytes(outBlob);
      freeInts(outOffsets);
      freeInts(outLengths);
      freeAreas(outAreas);

      return result;
    } catch (_) {
      final outBlob = outBlobPtr.value;
      final outOffsets = outOffsetsPtr.value;
      final outLengths = outLengthsPtr.value;
      final outAreas = outAreasPtr.value;
      if (outBlob != ffi.nullptr) freeBytes(outBlob);
      if (outOffsets != ffi.nullptr) freeInts(outOffsets);
      if (outLengths != ffi.nullptr) freeInts(outLengths);
      if (outAreas != ffi.nullptr) freeAreas(outAreas);
      return null;
    } finally {
      malloc.free(inputBlobPtr);
      malloc.free(inputOffsetsPtr);
      malloc.free(inputLengthsPtr);
      malloc.free(outBlobPtr);
      malloc.free(outBlobLenPtr);
      malloc.free(outOffsetsPtr);
      malloc.free(outLengthsPtr);
      malloc.free(outAreasPtr);
    }
  }

  /// Process layers using the PHASED pipeline (CPU+GPU hybrid).
  ///
  /// Phase 1: Parallel CPU decode + area stats
  /// Phase 2: GPU mega-batch scanlines (or CPU fallback)
  /// Phase 3: Parallel CPU compress + PNG wrap
  List<NativeBatchLayerResult>? processBatchPhased({
    required List<Uint8List> rawLayers,
    required int layerIndexBase,
    required int encryptionKey,
    required int srcWidth,
    required int height,
    required int outWidth,
    required int channels,
    required double xPixelSizeMm,
    required double yPixelSizeMm,
    int pngLevel = 1,
    int threadCount = 0,
    bool useGpuBatch = true,
  }) {
    _ensureInit();
    final fn = _processBatchPhased;
    final freeBytes = _freeBuffer;
    final freeInts = _freeIntBuffer;
    final freeAreas = _freeAreaBuffer;
    if (fn == null || freeBytes == null || freeInts == null || freeAreas == null) {
      return null;
    }
    if (rawLayers.isEmpty) return const <NativeBatchLayerResult>[];

    final count = rawLayers.length;
    var inputBlobLen = 0;
    for (final l in rawLayers) {
      inputBlobLen += l.length;
    }

    final inputBlobPtr = malloc<ffi.Uint8>(inputBlobLen);
    final inputOffsetsPtr = malloc<ffi.Int32>(count);
    final inputLengthsPtr = malloc<ffi.Int32>(count);
    final outBlobPtr = malloc<ffi.Pointer<ffi.Uint8>>();
    final outBlobLenPtr = malloc<ffi.Int32>();
    final outOffsetsPtr = malloc<ffi.Pointer<ffi.Int32>>();
    final outLengthsPtr = malloc<ffi.Pointer<ffi.Int32>>();
    final outAreasPtr = malloc<ffi.Pointer<_NativeAreaStatsResult>>();

    try {
      final inputBlob = inputBlobPtr.asTypedList(inputBlobLen);
      var cursor = 0;
      for (var i = 0; i < count; i++) {
        final layer = rawLayers[i];
        inputOffsetsPtr[i] = cursor;
        inputLengthsPtr[i] = layer.length;
        inputBlob.setAll(cursor, layer);
        cursor += layer.length;
      }

      outBlobPtr.value = ffi.nullptr;
      outBlobLenPtr.value = 0;
      outOffsetsPtr.value = ffi.nullptr;
      outLengthsPtr.value = ffi.nullptr;
      outAreasPtr.value = ffi.nullptr;

      final ok = fn(
        inputBlobPtr,
        inputBlobLen,
        inputOffsetsPtr,
        inputLengthsPtr,
        count,
        layerIndexBase,
        encryptionKey,
        srcWidth,
        height,
        outWidth,
        channels,
        xPixelSizeMm,
        yPixelSizeMm,
        pngLevel,
        threadCount,
        useGpuBatch ? 1 : 0,
        outBlobPtr,
        outBlobLenPtr,
        outOffsetsPtr,
        outLengthsPtr,
        outAreasPtr,
      );
      if (ok == 0) return null;

      final outBlob = outBlobPtr.value;
      final outBlobLen = outBlobLenPtr.value;
      final outOffsets = outOffsetsPtr.value;
      final outLengths = outLengthsPtr.value;
      final outAreas = outAreasPtr.value;

      if (outBlob == ffi.nullptr || outOffsets == ffi.nullptr ||
          outLengths == ffi.nullptr || outAreas == ffi.nullptr ||
          outBlobLen <= 0) {
        return null;
      }

      final blob = outBlob.asTypedList(outBlobLen);
      final result = <NativeBatchLayerResult>[];
      for (var i = 0; i < count; i++) {
        final off = outOffsets[i];
        final len = outLengths[i];
        if (off < 0 || len <= 0 || off + len > outBlobLen) {
          freeBytes(outBlob); freeInts(outOffsets);
          freeInts(outLengths); freeAreas(outAreas);
          return null;
        }
        final area = outAreas[i];
        result.add(NativeBatchLayerResult(
          pngBytes: Uint8List.fromList(blob.sublist(off, off + len)),
          areaInfo: LayerAreaInfo(
            totalSolidArea: area.totalSolidArea,
            largestArea: area.largestArea,
            smallestArea: area.smallestArea,
            minX: area.minX, minY: area.minY,
            maxX: area.maxX, maxY: area.maxY,
            areaCount: area.areaCount,
          ),
        ));
      }

      freeBytes(outBlob); freeInts(outOffsets);
      freeInts(outLengths); freeAreas(outAreas);
      return result;
    } catch (_) {
      final outBlob = outBlobPtr.value;
      final outOffsets = outOffsetsPtr.value;
      final outLengths = outLengthsPtr.value;
      final outAreas = outAreasPtr.value;
      if (outBlob != ffi.nullptr) freeBytes(outBlob);
      if (outOffsets != ffi.nullptr) freeInts(outOffsets);
      if (outLengths != ffi.nullptr) freeInts(outLengths);
      if (outAreas != ffi.nullptr) freeAreas(outAreas);
      return null;
    } finally {
      malloc.free(inputBlobPtr);
      malloc.free(inputOffsetsPtr);
      malloc.free(inputLengthsPtr);
      malloc.free(outBlobPtr);
      malloc.free(outBlobLenPtr);
      malloc.free(outOffsetsPtr);
      malloc.free(outLengthsPtr);
      malloc.free(outAreasPtr);
    }
  }

  void _ensureInit() {
    if (_initTried) return;
    _initTried = true;

    try {
      _lib = _openLibrary();
      if (_lib == null) return;

      _processBatch = _lib!.lookupFunction<
          _NativeProcessLayersBatch,
          _DartProcessLayersBatch>('process_layers_batch');
      _setBatchThreads = _lib!.lookupFunction<
          _NativeSetProcessBatchThreads,
          _DartSetProcessBatchThreads>('set_process_layers_batch_threads');
      _setBatchAnalytics = _lib!.lookupFunction<
          _NativeSetProcessBatchAnalytics,
          _DartSetProcessBatchAnalytics>('set_process_layers_batch_analytics');
        _getLastBackend = _lib!.lookupFunction<
          _NativeGetProcessLastBackend,
          _DartGetProcessLastBackend>('process_layers_last_backend');
        _getLastGpuAttempts = _lib!.lookupFunction<
          _NativeGetProcessLastGpuAttempts,
          _DartGetProcessLastGpuAttempts>('process_layers_last_gpu_attempts');
        _getLastGpuSuccesses = _lib!.lookupFunction<
          _NativeGetProcessLastGpuSuccesses,
          _DartGetProcessLastGpuSuccesses>('process_layers_last_gpu_successes');
        _getLastGpuFallbacks = _lib!.lookupFunction<
          _NativeGetProcessLastGpuFallbacks,
          _DartGetProcessLastGpuFallbacks>('process_layers_last_gpu_fallbacks');
          _getLastCudaError = _lib!.lookupFunction<
            _NativeGetProcessLastCudaError,
            _DartGetProcessLastCudaError>('process_layers_last_cuda_error');
        _getLastThreadCount = _lib!.lookupFunction<
          _NativeGetProcessLastThreadCount,
          _DartGetProcessLastThreadCount>('process_layers_last_thread_count');
        _getLastThreadStats = _lib!.lookupFunction<
          _NativeGetProcessLastThreadStats,
          _DartGetProcessLastThreadStats>('process_layers_last_thread_stats');
      _freeBuffer = _lib!
          .lookupFunction<_NativeFreeBuffer, _DartFreeBuffer>('free_native_buffer');
      _freeIntBuffer = _lib!.lookupFunction<
          _NativeFreeIntBuffer,
          _DartFreeIntBuffer>('free_native_int_buffer');
      _freeAreaBuffer = _lib!.lookupFunction<
          _NativeFreeAreaBuffer,
          _DartFreeAreaBuffer>('free_native_area_buffer');

      // --- Phased pipeline + CUDA info (optional, may not be linked) ---
      try {
        _getLastGpuBatchOk = _lib!.lookupFunction<
            _NativeGetProcessLastGpuBatchOk,
            _DartGetProcessLastGpuBatchOk>('process_layers_last_gpu_batch_ok');
        _processBatchPhased = _lib!.lookupFunction<
            _NativeProcessLayersBatchPhased,
            _DartProcessLayersBatchPhased>('process_layers_batch_phased');
      } catch (_) {
        _getLastGpuBatchOk = null;
        _processBatchPhased = null;
      }

        try {
        _cudaInit = _lib!.lookupFunction<
          _NativeGpuCudaInit, _DartGpuCudaInit>('gpu_cuda_info_init');
        _cudaDeviceName = _lib!.lookupFunction<
          _NativeGpuCudaDeviceName,
          _DartGpuCudaDeviceName>('gpu_cuda_info_device_name');
        _cudaVram = _lib!.lookupFunction<
          _NativeGpuCudaVram, _DartGpuCudaVram>('gpu_cuda_info_vram_bytes');
        _cudaHasTensorCores = _lib!.lookupFunction<
          _NativeGpuCudaI32,
          _DartGpuCudaI32>('gpu_cuda_info_has_tensor_cores');
        _cudaComputeCap = _lib!.lookupFunction<
          _NativeGpuCudaI32,
          _DartGpuCudaI32>('gpu_cuda_info_compute_capability');
        _cudaMpCount = _lib!.lookupFunction<
          _NativeGpuCudaI32,
          _DartGpuCudaI32>('gpu_cuda_info_multiprocessor_count');
        _cudaMaxConcurrent = _lib!.lookupFunction<
            ffi.Int32 Function(ffi.Int32, ffi.Int32, ffi.Int32, ffi.Int32),
            int Function(int, int, int, int)>(
            'gpu_cuda_info_max_concurrent_layers');
      } catch (_) {
        _cudaInit = null;
        _cudaDeviceName = null;
        _cudaVram = null;
        _cudaHasTensorCores = null;
        _cudaComputeCap = null;
        _cudaMpCount = null;
        _cudaMaxConcurrent = null;
      }
    } catch (_) {
      _processBatch = null;
      _setBatchThreads = null;
      _setBatchAnalytics = null;
      _getLastBackend = null;
      _getLastGpuAttempts = null;
      _getLastGpuSuccesses = null;
      _getLastGpuFallbacks = null;
      _getLastCudaError = null;
      _getLastThreadCount = null;
      _getLastThreadStats = null;
      _freeBuffer = null;
      _freeIntBuffer = null;
      _freeAreaBuffer = null;
      _getLastGpuBatchOk = null;
      _processBatchPhased = null;
      _cudaInit = null;
      _cudaDeviceName = null;
      _cudaVram = null;
      _cudaHasTensorCores = null;
      _cudaComputeCap = null;
      _cudaMpCount = null;
      _cudaMaxConcurrent = null;
    }
  }

  ffi.DynamicLibrary? _openLibrary() {
    final exePath = File(Platform.resolvedExecutable).absolute.path;
    final exeDir = File(exePath).parent.path;

    if (Platform.isWindows) {
      final candidate = '$exeDir${Platform.pathSeparator}area_stats.dll';
      if (File(candidate).existsSync()) {
        return ffi.DynamicLibrary.open(candidate);
      }
      return ffi.DynamicLibrary.open('area_stats.dll');
    }

    if (Platform.isLinux) {
      final libDir = '$exeDir${Platform.pathSeparator}lib';
      final candidate = '$libDir${Platform.pathSeparator}libarea_stats.so';
      if (File(candidate).existsSync()) {
        return ffi.DynamicLibrary.open(candidate);
      }
      return ffi.DynamicLibrary.open('libarea_stats.so');
    }

    if (Platform.isMacOS) {
      final frameworksDir =
          '$exeDir${Platform.pathSeparator}..${Platform.pathSeparator}Frameworks';
      final candidate =
          '$frameworksDir${Platform.pathSeparator}libarea_stats.dylib';
      if (File(candidate).existsSync()) {
        return ffi.DynamicLibrary.open(candidate);
      }
      return ffi.DynamicLibrary.open('libarea_stats.dylib');
    }

    return null;
  }
}
