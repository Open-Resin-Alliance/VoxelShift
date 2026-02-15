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

typedef _ComputeAreaNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8> pixels,
  ffi.Int32 width,
  ffi.Int32 height,
  ffi.Double xPixelSizeMm,
  ffi.Double yPixelSizeMm,
  ffi.Pointer<_NativeAreaStatsResult> outResult,
);

typedef _ComputeAreaDart = int Function(
  ffi.Pointer<ffi.Uint8> pixels,
  int width,
  int height,
  double xPixelSizeMm,
  double yPixelSizeMm,
  ffi.Pointer<_NativeAreaStatsResult> outResult,
);

class NativeAreaStats {
  NativeAreaStats._();

  static final NativeAreaStats instance = NativeAreaStats._();

  ffi.DynamicLibrary? _lib;
  _ComputeAreaDart? _compute;
  bool _initTried = false;

  bool get available {
    _ensureInit();
    return _compute != null;
  }

  LayerAreaInfo? compute(
    Uint8List greyPixels,
    int width,
    int height,
    double xPixelSizeMm,
    double yPixelSizeMm,
  ) {
    _ensureInit();
    final fn = _compute;
    if (fn == null) return null;

    final pixelsPtr = malloc<ffi.Uint8>(greyPixels.length);
    final outPtr = malloc<_NativeAreaStatsResult>();

    try {
      pixelsPtr.asTypedList(greyPixels.length).setAll(0, greyPixels);

      final ok = fn(
        pixelsPtr,
        width,
        height,
        xPixelSizeMm,
        yPixelSizeMm,
        outPtr,
      );

      if (ok == 0) return null;

      final out = outPtr.ref;
      return LayerAreaInfo(
        totalSolidArea: out.totalSolidArea,
        largestArea: out.largestArea,
        smallestArea: out.smallestArea,
        minX: out.minX,
        minY: out.minY,
        maxX: out.maxX,
        maxY: out.maxY,
        areaCount: out.areaCount,
      );
    } catch (_) {
      return null;
    } finally {
      malloc.free(pixelsPtr);
      malloc.free(outPtr);
    }
  }

  void _ensureInit() {
    if (_initTried) return;
    _initTried = true;

    try {
      _lib = _openLibrary();
      if (_lib == null) return;

      _compute = _lib!
          .lookupFunction<_ComputeAreaNative, _ComputeAreaDart>('compute_layer_area_stats');
    } catch (_) {
      _compute = null;
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
