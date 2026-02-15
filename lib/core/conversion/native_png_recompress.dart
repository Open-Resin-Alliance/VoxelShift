import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _NativeRecompressPngIdat = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8> pngData,
  ffi.Int32 pngLen,
  ffi.Int32 level,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>> outData,
  ffi.Pointer<ffi.Int32> outLen,
);

typedef _DartRecompressPngIdat = int Function(
  ffi.Pointer<ffi.Uint8> pngData,
  int pngLen,
  int level,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>> outData,
  ffi.Pointer<ffi.Int32> outLen,
);

typedef _NativeFreeBuffer = ffi.Void Function(ffi.Pointer<ffi.Uint8> buffer);
typedef _DartFreeBuffer = void Function(ffi.Pointer<ffi.Uint8> buffer);

typedef _NativeRecompressPngBatch = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8> inputBlob,
  ffi.Int32 inputBlobLen,
  ffi.Pointer<ffi.Int32> inputOffsets,
  ffi.Pointer<ffi.Int32> inputLengths,
  ffi.Int32 count,
  ffi.Int32 level,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>> outBlob,
  ffi.Pointer<ffi.Int32> outBlobLen,
  ffi.Pointer<ffi.Pointer<ffi.Int32>> outOffsets,
  ffi.Pointer<ffi.Pointer<ffi.Int32>> outLengths,
);

typedef _DartRecompressPngBatch = int Function(
  ffi.Pointer<ffi.Uint8> inputBlob,
  int inputBlobLen,
  ffi.Pointer<ffi.Int32> inputOffsets,
  ffi.Pointer<ffi.Int32> inputLengths,
  int count,
  int level,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>> outBlob,
  ffi.Pointer<ffi.Int32> outBlobLen,
  ffi.Pointer<ffi.Pointer<ffi.Int32>> outOffsets,
  ffi.Pointer<ffi.Pointer<ffi.Int32>> outLengths,
);

typedef _NativeFreeIntBuffer = ffi.Void Function(ffi.Pointer<ffi.Int32> buffer);
typedef _DartFreeIntBuffer = void Function(ffi.Pointer<ffi.Int32> buffer);

typedef _NativeSetBatchThreads = ffi.Void Function(ffi.Int32 threads);
typedef _DartSetBatchThreads = void Function(int threads);

class NativePngRecompress {
  NativePngRecompress._();

  static final NativePngRecompress instance = NativePngRecompress._();

  ffi.DynamicLibrary? _lib;
  _DartRecompressPngIdat? _recompress;
  _DartRecompressPngBatch? _recompressBatch;
  _DartFreeBuffer? _freeBuffer;
  _DartFreeIntBuffer? _freeIntBuffer;
  _DartSetBatchThreads? _setBatchThreads;
  bool _initTried = false;

  bool get available {
    _ensureInit();
    return _recompress != null && _freeBuffer != null;
  }

  bool get batchAvailable {
    _ensureInit();
    return _recompressBatch != null && _freeBuffer != null && _freeIntBuffer != null;
  }

  void setBatchThreads(int threads) {
    _ensureInit();
    final fn = _setBatchThreads;
    if (fn == null) return;
    try {
      fn(threads);
    } catch (_) {}
  }

  Uint8List? recompress(Uint8List pngBytes, {int level = 7}) {
    _ensureInit();
    final fn = _recompress;
    final freeFn = _freeBuffer;
    if (fn == null || freeFn == null) return null;

    final inPtr = malloc<ffi.Uint8>(pngBytes.length);
    final outDataPtr = malloc<ffi.Pointer<ffi.Uint8>>();
    final outLenPtr = malloc<ffi.Int32>();

    try {
      inPtr.asTypedList(pngBytes.length).setAll(0, pngBytes);
      outDataPtr.value = ffi.nullptr;
      outLenPtr.value = 0;

      final ok = fn(
        inPtr,
        pngBytes.length,
        level,
        outDataPtr,
        outLenPtr,
      );
      if (ok == 0) return null;

      final outPtr = outDataPtr.value;
      final outLen = outLenPtr.value;
      if (outPtr == ffi.nullptr || outLen <= 0) return null;

      final out = Uint8List.fromList(outPtr.asTypedList(outLen));
      freeFn(outPtr);
      return out;
    } catch (_) {
      final outPtr = outDataPtr.value;
      if (outPtr != ffi.nullptr) {
        freeFn(outPtr);
      }
      return null;
    } finally {
      malloc.free(inPtr);
      malloc.free(outDataPtr);
      malloc.free(outLenPtr);
    }
  }

  List<Uint8List>? recompressBatch(List<Uint8List> pngs, {int level = 7}) {
    _ensureInit();
    final fn = _recompressBatch;
    final freeBytesFn = _freeBuffer;
    final freeIntsFn = _freeIntBuffer;
    if (fn == null || freeBytesFn == null || freeIntsFn == null) return null;
    if (pngs.isEmpty) return const <Uint8List>[];

    final count = pngs.length;
    int inputBlobLen = 0;
    for (final p in pngs) {
      inputBlobLen += p.length;
    }

    final inBlobPtr = malloc<ffi.Uint8>(inputBlobLen);
    final inOffsetsPtr = malloc<ffi.Int32>(count);
    final inLengthsPtr = malloc<ffi.Int32>(count);

    final outBlobPtr = malloc<ffi.Pointer<ffi.Uint8>>();
    final outBlobLenPtr = malloc<ffi.Int32>();
    final outOffsetsPtr = malloc<ffi.Pointer<ffi.Int32>>();
    final outLengthsPtr = malloc<ffi.Pointer<ffi.Int32>>();

    try {
      int cursor = 0;
      for (int i = 0; i < count; i++) {
        final p = pngs[i];
        inOffsetsPtr[i] = cursor;
        inLengthsPtr[i] = p.length;
        inBlobPtr.asTypedList(inputBlobLen).setAll(cursor, p);
        cursor += p.length;
      }

      outBlobPtr.value = ffi.nullptr;
      outBlobLenPtr.value = 0;
      outOffsetsPtr.value = ffi.nullptr;
      outLengthsPtr.value = ffi.nullptr;

      final ok = fn(
        inBlobPtr,
        inputBlobLen,
        inOffsetsPtr,
        inLengthsPtr,
        count,
        level,
        outBlobPtr,
        outBlobLenPtr,
        outOffsetsPtr,
        outLengthsPtr,
      );
      if (ok == 0) return null;

      final outBlob = outBlobPtr.value;
      final outBlobLen = outBlobLenPtr.value;
      final outOffsets = outOffsetsPtr.value;
      final outLengths = outLengthsPtr.value;

      if (outBlob == ffi.nullptr || outOffsets == ffi.nullptr || outLengths == ffi.nullptr || outBlobLen <= 0) {
        return null;
      }

      final blob = outBlob.asTypedList(outBlobLen);
      final result = <Uint8List>[];
      for (int i = 0; i < count; i++) {
        final off = outOffsets[i];
        final len = outLengths[i];
        if (off < 0 || len <= 0 || off + len > outBlobLen) {
          freeBytesFn(outBlob);
          freeIntsFn(outOffsets);
          freeIntsFn(outLengths);
          return null;
        }
        result.add(Uint8List.fromList(blob.sublist(off, off + len)));
      }

      freeBytesFn(outBlob);
      freeIntsFn(outOffsets);
      freeIntsFn(outLengths);

      return result;
    } catch (_) {
      final outBlob = outBlobPtr.value;
      final outOffsets = outOffsetsPtr.value;
      final outLengths = outLengthsPtr.value;
      if (outBlob != ffi.nullptr) freeBytesFn(outBlob);
      if (outOffsets != ffi.nullptr) freeIntsFn(outOffsets);
      if (outLengths != ffi.nullptr) freeIntsFn(outLengths);
      return null;
    } finally {
      malloc.free(inBlobPtr);
      malloc.free(inOffsetsPtr);
      malloc.free(inLengthsPtr);
      malloc.free(outBlobPtr);
      malloc.free(outBlobLenPtr);
      malloc.free(outOffsetsPtr);
      malloc.free(outLengthsPtr);
    }
  }

  void _ensureInit() {
    if (_initTried) return;
    _initTried = true;

    try {
      _lib = _openLibrary();
      if (_lib == null) return;
      _recompress = _lib!.lookupFunction<
          _NativeRecompressPngIdat,
          _DartRecompressPngIdat>('recompress_png_idat');
        _recompressBatch = _lib!.lookupFunction<
          _NativeRecompressPngBatch,
          _DartRecompressPngBatch>('recompress_png_batch');
      _setBatchThreads = _lib!
          .lookupFunction<_NativeSetBatchThreads, _DartSetBatchThreads>('set_recompress_batch_threads');
      _freeBuffer =
          _lib!.lookupFunction<_NativeFreeBuffer, _DartFreeBuffer>('free_native_buffer');
        _freeIntBuffer = _lib!
          .lookupFunction<_NativeFreeIntBuffer, _DartFreeIntBuffer>('free_native_int_buffer');
    } catch (_) {
      _recompress = null;
        _recompressBatch = null;
      _setBatchThreads = null;
      _freeBuffer = null;
        _freeIntBuffer = null;
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
