import 'dart:ffi' as ffi;
import 'dart:io';

typedef _NativeSetThreadPriority = ffi.Int32 Function(ffi.Int32 background);
typedef _DartSetThreadPriority = int Function(int background);

class NativeThreadPriority {
  NativeThreadPriority._();

  static final NativeThreadPriority instance = NativeThreadPriority._();

  ffi.DynamicLibrary? _lib;
  _DartSetThreadPriority? _setBackground;
  bool _initTried = false;

  bool get available {
    _ensureInit();
    return _setBackground != null;
  }

  bool setBackgroundPriority(bool enabled) {
    _ensureInit();
    final fn = _setBackground;
    if (fn == null) return false;
    try {
      return fn(enabled ? 1 : 0) != 0;
    } catch (_) {
      return false;
    }
  }

  void _ensureInit() {
    if (_initTried) return;
    _initTried = true;

    try {
      _lib = _openLibrary();
      if (_lib == null) return;
      _setBackground = _lib!.lookupFunction<
          _NativeSetThreadPriority,
          _DartSetThreadPriority>('set_current_thread_background_priority');
    } catch (_) {
      _setBackground = null;
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
