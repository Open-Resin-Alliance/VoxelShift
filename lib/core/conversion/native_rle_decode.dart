import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _NativeDecryptDecode = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8> data,
  ffi.Int32 dataLen,
  ffi.Int32 layerIndex,
  ffi.Int32 encryptionKey,
  ffi.Int32 pixelCount,
  ffi.Pointer<ffi.Uint8> outPixels,
);

typedef _DartDecryptDecode = int Function(
  ffi.Pointer<ffi.Uint8> data,
  int dataLen,
  int layerIndex,
  int encryptionKey,
  int pixelCount,
  ffi.Pointer<ffi.Uint8> outPixels,
);

class NativeRleDecode {
  NativeRleDecode._();

  static final NativeRleDecode instance = NativeRleDecode._();

  ffi.DynamicLibrary? _lib;
  _DartDecryptDecode? _decode;
  bool _initTried = false;

  bool get available {
    _ensureInit();
    return _decode != null;
  }

  Uint8List? decryptAndDecode(
    Uint8List rawRleData,
    int layerIndex,
    int encryptionKey,
    int pixelCount,
  ) {
    _ensureInit();
    final fn = _decode;
    if (fn == null) return null;

    final dataPtr = malloc<ffi.Uint8>(rawRleData.length);
    final outPtr = malloc<ffi.Uint8>(pixelCount);

    try {
      dataPtr.asTypedList(rawRleData.length).setAll(0, rawRleData);
      final ok = fn(
        dataPtr,
        rawRleData.length,
        layerIndex,
        encryptionKey,
        pixelCount,
        outPtr,
      );
      if (ok == 0) return null;
      return Uint8List.fromList(outPtr.asTypedList(pixelCount));
    } catch (_) {
      return null;
    } finally {
      malloc.free(dataPtr);
      malloc.free(outPtr);
    }
  }

  void _ensureInit() {
    if (_initTried) return;
    _initTried = true;

    try {
      _lib = _openLibrary();
      if (_lib == null) return;
      _decode = _lib!
          .lookupFunction<_NativeDecryptDecode, _DartDecryptDecode>('decrypt_and_decode_layer');
    } catch (_) {
      _decode = null;
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
