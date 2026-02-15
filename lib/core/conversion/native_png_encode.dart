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

typedef _NativeBuildScanlines = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8> greyPixels,
  ffi.Int32 srcWidth,
  ffi.Int32 height,
  ffi.Int32 outWidth,
  ffi.Int32 channels,
  ffi.Pointer<ffi.Uint8> outScanlines,
  ffi.Int32 outLen,
);

typedef _DartBuildScanlines = int Function(
  ffi.Pointer<ffi.Uint8> greyPixels,
  int srcWidth,
  int height,
  int outWidth,
  int channels,
  ffi.Pointer<ffi.Uint8> outScanlines,
  int outLen,
);

typedef _NativeDecodeAndBuildScanlines = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8> data,
  ffi.Int32 dataLen,
  ffi.Int32 layerIndex,
  ffi.Int32 encryptionKey,
  ffi.Int32 srcWidth,
  ffi.Int32 height,
  ffi.Int32 outWidth,
  ffi.Int32 channels,
  ffi.Pointer<ffi.Uint8> outPixels,
  ffi.Int32 pixelCount,
  ffi.Pointer<ffi.Uint8> outScanlines,
  ffi.Int32 outLen,
);

typedef _DartDecodeAndBuildScanlines = int Function(
  ffi.Pointer<ffi.Uint8> data,
  int dataLen,
  int layerIndex,
  int encryptionKey,
  int srcWidth,
  int height,
  int outWidth,
  int channels,
  ffi.Pointer<ffi.Uint8> outPixels,
  int pixelCount,
  ffi.Pointer<ffi.Uint8> outScanlines,
  int outLen,
);

typedef _NativeDecodeBuildAndArea = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8> data,
  ffi.Int32 dataLen,
  ffi.Int32 layerIndex,
  ffi.Int32 encryptionKey,
  ffi.Int32 srcWidth,
  ffi.Int32 height,
  ffi.Int32 outWidth,
  ffi.Int32 channels,
  ffi.Double xPixelSizeMm,
  ffi.Double yPixelSizeMm,
  ffi.Pointer<_NativeAreaStatsResult> outArea,
  ffi.Pointer<ffi.Uint8> outScanlines,
  ffi.Int32 outLen,
);

typedef _DartDecodeBuildAndArea = int Function(
  ffi.Pointer<ffi.Uint8> data,
  int dataLen,
  int layerIndex,
  int encryptionKey,
  int srcWidth,
  int height,
  int outWidth,
  int channels,
  double xPixelSizeMm,
  double yPixelSizeMm,
  ffi.Pointer<_NativeAreaStatsResult> outArea,
  ffi.Pointer<ffi.Uint8> outScanlines,
  int outLen,
);

class NativeDecodeScanlineResult {
  final Uint8List greyPixels;
  final Uint8List scanlines;

  const NativeDecodeScanlineResult({
    required this.greyPixels,
    required this.scanlines,
  });
}

class NativeDecodeAreaScanlineResult {
  final LayerAreaInfo areaInfo;
  final Uint8List scanlines;

  const NativeDecodeAreaScanlineResult({
    required this.areaInfo,
    required this.scanlines,
  });
}

class NativePngEncode {
  NativePngEncode._();

  static final NativePngEncode instance = NativePngEncode._();

  ffi.DynamicLibrary? _lib;
  _DartBuildScanlines? _build;
  _DartDecodeAndBuildScanlines? _decodeAndBuild;
  _DartDecodeBuildAndArea? _decodeBuildAndArea;
  bool _initTried = false;

  bool get available {
    _ensureInit();
    return _build != null;
  }

  bool get mergedDecodeAvailable {
    _ensureInit();
    return _decodeAndBuild != null;
  }

  bool get mergedDecodeAreaAvailable {
    _ensureInit();
    return _decodeBuildAndArea != null;
  }

  Uint8List? buildRgbScanlines(
    Uint8List greyPixels,
    int srcWidth,
    int height,
    int outWidth,
  ) {
    return _buildScanlines(greyPixels, srcWidth, height, outWidth, 3);
  }

  Uint8List? buildGreyscaleScanlines(
    Uint8List greyPixels,
    int srcWidth,
    int height,
    int outWidth,
  ) {
    return _buildScanlines(greyPixels, srcWidth, height, outWidth, 1);
  }

  Uint8List? _buildScanlines(
    Uint8List greyPixels,
    int srcWidth,
    int height,
    int outWidth,
    int channels,
  ) {
    _ensureInit();
    final fn = _build;
    if (fn == null) return null;

    final bytesPerRow = outWidth * channels;
    final scanlineSize = 1 + bytesPerRow;
    final outLen = scanlineSize * height;

    final inPtr = malloc<ffi.Uint8>(greyPixels.length);
    final outPtr = malloc<ffi.Uint8>(outLen);

    try {
      inPtr.asTypedList(greyPixels.length).setAll(0, greyPixels);
      final ok = fn(
        inPtr,
        srcWidth,
        height,
        outWidth,
        channels,
        outPtr,
        outLen,
      );
      if (ok == 0) return null;
      return Uint8List.fromList(outPtr.asTypedList(outLen));
    } catch (_) {
      return null;
    } finally {
      malloc.free(inPtr);
      malloc.free(outPtr);
    }
  }

  NativeDecodeScanlineResult? decodeAndBuildScanlines(
    Uint8List rawRleData,
    int layerIndex,
    int encryptionKey,
    int srcWidth,
    int height,
    int outWidth,
    int channels,
  ) {
    _ensureInit();
    final fn = _decodeAndBuild;
    if (fn == null) return null;

    final pixelCount = srcWidth * height;
    final bytesPerRow = outWidth * channels;
    final scanlineSize = 1 + bytesPerRow;
    final outLen = scanlineSize * height;

    final dataPtr = malloc<ffi.Uint8>(rawRleData.length);
    final outPixelsPtr = malloc<ffi.Uint8>(pixelCount);
    final outScanlinesPtr = malloc<ffi.Uint8>(outLen);

    try {
      dataPtr.asTypedList(rawRleData.length).setAll(0, rawRleData);
      final ok = fn(
        dataPtr,
        rawRleData.length,
        layerIndex,
        encryptionKey,
        srcWidth,
        height,
        outWidth,
        channels,
        outPixelsPtr,
        pixelCount,
        outScanlinesPtr,
        outLen,
      );
      if (ok == 0) return null;

      return NativeDecodeScanlineResult(
        greyPixels: Uint8List.fromList(outPixelsPtr.asTypedList(pixelCount)),
        scanlines: Uint8List.fromList(outScanlinesPtr.asTypedList(outLen)),
      );
    } catch (_) {
      return null;
    } finally {
      malloc.free(dataPtr);
      malloc.free(outPixelsPtr);
      malloc.free(outScanlinesPtr);
    }
  }

  NativeDecodeAreaScanlineResult? decodeBuildScanlinesAndArea(
    Uint8List rawRleData,
    int layerIndex,
    int encryptionKey,
    int srcWidth,
    int height,
    int outWidth,
    int channels,
    double xPixelSizeMm,
    double yPixelSizeMm,
  ) {
    _ensureInit();
    final fn = _decodeBuildAndArea;
    if (fn == null) return null;

    final bytesPerRow = outWidth * channels;
    final scanlineSize = 1 + bytesPerRow;
    final outLen = scanlineSize * height;

    final dataPtr = malloc<ffi.Uint8>(rawRleData.length);
    final outAreaPtr = malloc<_NativeAreaStatsResult>();
    final outScanlinesPtr = malloc<ffi.Uint8>(outLen);

    try {
      dataPtr.asTypedList(rawRleData.length).setAll(0, rawRleData);
      final ok = fn(
        dataPtr,
        rawRleData.length,
        layerIndex,
        encryptionKey,
        srcWidth,
        height,
        outWidth,
        channels,
        xPixelSizeMm,
        yPixelSizeMm,
        outAreaPtr,
        outScanlinesPtr,
        outLen,
      );
      if (ok == 0) return null;

      final out = outAreaPtr.ref;
      return NativeDecodeAreaScanlineResult(
        areaInfo: LayerAreaInfo(
          totalSolidArea: out.totalSolidArea,
          largestArea: out.largestArea,
          smallestArea: out.smallestArea,
          minX: out.minX,
          minY: out.minY,
          maxX: out.maxX,
          maxY: out.maxY,
          areaCount: out.areaCount,
        ),
        scanlines: Uint8List.fromList(outScanlinesPtr.asTypedList(outLen)),
      );
    } catch (_) {
      return null;
    } finally {
      malloc.free(dataPtr);
      malloc.free(outAreaPtr);
      malloc.free(outScanlinesPtr);
    }
  }

  void _ensureInit() {
    if (_initTried) return;
    _initTried = true;

    try {
      _lib = _openLibrary();
      if (_lib == null) return;
      _build = _lib!
          .lookupFunction<_NativeBuildScanlines, _DartBuildScanlines>('build_png_scanlines');
      _decodeAndBuild = _lib!.lookupFunction<
          _NativeDecodeAndBuildScanlines,
          _DartDecodeAndBuildScanlines>('decode_and_build_png_scanlines');
      _decodeBuildAndArea = _lib!.lookupFunction<
          _NativeDecodeBuildAndArea,
          _DartDecodeBuildAndArea>('decode_build_scanlines_and_area');
    } catch (_) {
      _build = null;
      _decodeAndBuild = null;
      _decodeBuildAndArea = null;
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
