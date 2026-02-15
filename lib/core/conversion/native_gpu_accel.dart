import 'dart:ffi' as ffi;
import 'dart:io';

typedef _NativeSetGpuEnabled = ffi.Void Function(ffi.Int32 enabled);
typedef _DartSetGpuEnabled = void Function(int enabled);

typedef _NativeGpuActive = ffi.Int32 Function();
typedef _DartGpuActive = int Function();

typedef _NativeGpuBackend = ffi.Int32 Function();
typedef _DartGpuBackend = int Function();

typedef _NativeSetGpuBackendPreference = ffi.Void Function(ffi.Int32 backendCode);
typedef _DartSetGpuBackendPreference = void Function(int backendCode);

typedef _NativeGpuBackendAvailable = ffi.Int32 Function(ffi.Int32 backendCode);
typedef _DartGpuBackendAvailable = int Function(int backendCode);

class NativeGpuAccel {
  NativeGpuAccel._();

  static final NativeGpuAccel instance = NativeGpuAccel._();

  ffi.DynamicLibrary? _lib;
  _DartSetGpuEnabled? _setEnabled;
  _DartGpuActive? _isActive;
  _DartGpuBackend? _backend;
  _DartSetGpuBackendPreference? _setBackendPreference;
  _DartGpuBackendAvailable? _backendAvailable;
  bool _initTried = false;

  bool get available {
    _ensureInit();
    return _setEnabled != null && _isActive != null && _backend != null;
  }

  void setEnabled(bool enabled) {
    _ensureInit();
    final fn = _setEnabled;
    if (fn == null) return;
    try {
      fn(enabled ? 1 : 0);
    } catch (_) {}
  }

  void setPreferredBackend(int backendCode) {
    _ensureInit();
    final fn = _setBackendPreference;
    if (fn == null) return;
    try {
      fn(backendCode);
    } catch (_) {}
  }

  bool isBackendAvailable(int backendCode) {
    _ensureInit();
    final fn = _backendAvailable;
    if (fn == null) return false;
    try {
      return fn(backendCode) != 0;
    } catch (_) {
      return false;
    }
  }

  bool get active {
    _ensureInit();
    final fn = _isActive;
    if (fn == null) return false;
    try {
      return fn() != 0;
    } catch (_) {
      return false;
    }
  }

  int get backendCode {
    _ensureInit();
    final fn = _backend;
    if (fn == null) return 0;
    try {
      return fn();
    } catch (_) {
      return 0;
    }
  }

  String get backendName {
    switch (backendCode) {
      case 1:
        return 'OpenCL';
      case 2:
        return 'Metal';
      case 3:
        return 'CUDA/Tensor';
      default:
        return 'None';
    }
  }

  void _ensureInit() {
    if (_initTried) return;
    _initTried = true;

    try {
      _lib = _openLibrary();
      if (_lib == null) return;
      _setEnabled = _lib!
          .lookupFunction<_NativeSetGpuEnabled, _DartSetGpuEnabled>('set_gpu_acceleration_enabled');
        _setBackendPreference = _lib!.lookupFunction<
          _NativeSetGpuBackendPreference,
          _DartSetGpuBackendPreference>('set_gpu_backend_preference');
      _isActive =
          _lib!.lookupFunction<_NativeGpuActive, _DartGpuActive>('gpu_acceleration_active');
      _backend =
          _lib!.lookupFunction<_NativeGpuBackend, _DartGpuBackend>('gpu_acceleration_backend');
        _backendAvailable = _lib!.lookupFunction<
          _NativeGpuBackendAvailable,
          _DartGpuBackendAvailable>('gpu_backend_available');
    } catch (_) {
      _setEnabled = null;
        _setBackendPreference = null;
      _isActive = null;
      _backend = null;
        _backendAvailable = null;
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
