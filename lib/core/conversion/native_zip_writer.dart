import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

class NativeZipEntry {
  final String name;
  final Uint8List data;

  const NativeZipEntry({required this.name, required this.data});
}

typedef _NativeZipOpen = ffi.Int64 Function(ffi.Pointer<Utf8> outputPath);
typedef _DartZipOpen = int Function(ffi.Pointer<Utf8> outputPath);

typedef _NativeZipAddFile = ffi.Int32 Function(
  ffi.Int64 handle,
  ffi.Pointer<Utf8> name,
  ffi.Pointer<ffi.Uint8> data,
  ffi.Int32 dataLen,
);
typedef _DartZipAddFile = int Function(
  int handle,
  ffi.Pointer<Utf8> name,
  ffi.Pointer<ffi.Uint8> data,
  int dataLen,
);

typedef _NativeZipClose = ffi.Int32 Function(ffi.Int64 handle);
typedef _DartZipClose = int Function(int handle);

typedef _NativeZipAbort = ffi.Void Function(ffi.Int64 handle);
typedef _DartZipAbort = void Function(int handle);

class NativeZipWriter {
  NativeZipWriter._();

  static final NativeZipWriter instance = NativeZipWriter._();

  ffi.DynamicLibrary? _lib;
  _DartZipOpen? _open;
  _DartZipAddFile? _addFile;
  _DartZipClose? _close;
  _DartZipAbort? _abort;
  bool _initTried = false;

  bool get available {
    _ensureInit();
    return _open != null && _addFile != null && _close != null && _abort != null;
  }

  Future<bool> writeArchive(
    String outputPath,
    List<NativeZipEntry> entries, {
    void Function(double progress)? onProgress,
  }) async {
    _ensureInit();
    final openFn = _open;
    final addFn = _addFile;
    final closeFn = _close;
    final abortFn = _abort;

    if (openFn == null || addFn == null || closeFn == null || abortFn == null) {
      return false;
    }

    final outputPathPtr = outputPath.toNativeUtf8();
    final handle = openFn(outputPathPtr);
    malloc.free(outputPathPtr);

    if (handle == 0) return false;

    try {
      DateTime lastReportTime = DateTime.now();
      const reportIntervalMs = 250;

      for (int i = 0; i < entries.length; i++) {
        final entry = entries[i];
        final namePtr = entry.name.toNativeUtf8();
        final dataPtr = malloc<ffi.Uint8>(entry.data.length);

        try {
          dataPtr.asTypedList(entry.data.length).setAll(0, entry.data);
          final ok = addFn(handle, namePtr, dataPtr, entry.data.length);
          if (ok == 0) {
            abortFn(handle);
            return false;
          }
        } finally {
          malloc.free(namePtr);
          malloc.free(dataPtr);
        }

        final now = DateTime.now();
        if (now.difference(lastReportTime).inMilliseconds >= reportIntervalMs ||
            i == entries.length - 1) {
          onProgress?.call((i + 1) / entries.length);
          lastReportTime = now;
        }

        if (i % 12 == 11 || i == entries.length - 1) {
          await Future.delayed(Duration.zero);
        }
      }

      return closeFn(handle) != 0;
    } catch (_) {
      abortFn(handle);
      return false;
    }
  }

  void _ensureInit() {
    if (_initTried) return;
    _initTried = true;

    try {
      _lib = _openLibrary();
      if (_lib == null) return;

      _open = _lib!.lookupFunction<_NativeZipOpen, _DartZipOpen>('vs_zip_open');
      _addFile =
          _lib!.lookupFunction<_NativeZipAddFile, _DartZipAddFile>('vs_zip_add_file');
      _close = _lib!.lookupFunction<_NativeZipClose, _DartZipClose>('vs_zip_close');
      _abort = _lib!.lookupFunction<_NativeZipAbort, _DartZipAbort>('vs_zip_abort');
    } catch (_) {
      _open = null;
      _addFile = null;
      _close = null;
      _abort = null;
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
