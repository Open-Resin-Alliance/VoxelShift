import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Post-processing settings that mirror environment flags.
class PostProcessingSettings {
  String gpuMode;
  String gpuBackend;
  bool autotune;
  bool fastMode;
  bool usePhased;
  String recompressMode;
  int? processPngLevel;
  int? gpuHostWorkers;
  int? cpuHostWorkers;
  int? cudaHostWorkers;

  PostProcessingSettings({
    this.gpuMode = 'auto',
    this.gpuBackend = 'auto',
    this.autotune = true,
    this.fastMode = false,
    this.usePhased = false,
    this.recompressMode = 'adaptive',
    this.processPngLevel,
    this.gpuHostWorkers,
    this.cpuHostWorkers,
    this.cudaHostWorkers,
  });

  factory PostProcessingSettings.fromJson(Map<String, dynamic> json) {
    return PostProcessingSettings(
      gpuMode: (json['gpuMode'] as String?) ?? 'auto',
      gpuBackend: (json['gpuBackend'] as String?) ?? 'auto',
      autotune: (json['autotune'] as bool?) ?? true,
      fastMode: (json['fastMode'] as bool?) ?? false,
      usePhased: (json['usePhased'] as bool?) ?? false,
      recompressMode: (json['recompressMode'] as String?) ?? 'adaptive',
      processPngLevel: json['processPngLevel'] as int?,
      gpuHostWorkers: json['gpuHostWorkers'] as int?,
      cpuHostWorkers: json['cpuHostWorkers'] as int?,
      cudaHostWorkers: json['cudaHostWorkers'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'gpuMode': gpuMode,
      'gpuBackend': gpuBackend,
      'autotune': autotune,
      'fastMode': fastMode,
      'usePhased': usePhased,
      'recompressMode': recompressMode,
      'processPngLevel': processPngLevel,
      'gpuHostWorkers': gpuHostWorkers,
      'cpuHostWorkers': cpuHostWorkers,
      'cudaHostWorkers': cudaHostWorkers,
    };
  }
}

/// Cached benchmark result for a device/profile/resolution tuple.
class BenchmarkCacheEntry {
  final int cpuMs;
  final int gpuMs;
  final int backend;
  final int updatedAtMs;
  final int sampleSize;

  const BenchmarkCacheEntry({
    required this.cpuMs,
    required this.gpuMs,
    required this.backend,
    required this.updatedAtMs,
    required this.sampleSize,
  });

  factory BenchmarkCacheEntry.fromJson(Map<String, dynamic> json) {
    return BenchmarkCacheEntry(
      cpuMs: (json['cpuMs'] as int?) ?? -1,
      gpuMs: (json['gpuMs'] as int?) ?? -1,
      backend: (json['backend'] as int?) ?? 0,
      updatedAtMs: (json['updatedAtMs'] as int?) ?? 0,
      sampleSize: (json['sampleSize'] as int?) ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'cpuMs': cpuMs,
      'gpuMs': gpuMs,
      'backend': backend,
      'updatedAtMs': updatedAtMs,
      'sampleSize': sampleSize,
    };
  }
}

/// Persists application settings/preferences.
class AppSettings {
  static const _fileName = 'app_settings.json';

  String? defaultMaterialProfileId;
  PostProcessingSettings postProcessing;
  Map<String, BenchmarkCacheEntry> benchmarkCache;

  AppSettings({
    this.defaultMaterialProfileId,
    PostProcessingSettings? postProcessing,
    Map<String, BenchmarkCacheEntry>? benchmarkCache,
  })  : postProcessing = postProcessing ?? PostProcessingSettings(),
        benchmarkCache = benchmarkCache ?? <String, BenchmarkCacheEntry>{};

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final pp = json['postProcessing'];
    final cache = json['benchmarkCache'];
    final parsedCache = <String, BenchmarkCacheEntry>{};
    if (cache is Map) {
      for (final entry in cache.entries) {
        if (entry.key is String && entry.value is Map) {
          parsedCache[entry.key as String] =
              BenchmarkCacheEntry.fromJson(Map<String, dynamic>.from(entry.value));
        }
      }
    }
    return AppSettings(
      defaultMaterialProfileId: json['defaultMaterialProfileId'] as String?,
      postProcessing: pp is Map
          ? PostProcessingSettings.fromJson(Map<String, dynamic>.from(pp))
          : PostProcessingSettings(),
      benchmarkCache: parsedCache,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'defaultMaterialProfileId': defaultMaterialProfileId,
      'postProcessing': postProcessing.toJson(),
      'benchmarkCache': benchmarkCache.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
    };
  }

  Future<File> _getFile() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// Load settings from disk.
  static Future<AppSettings> load() async {
    try {
      final instance = AppSettings();
      final file = await instance._getFile();
      if (!await file.exists()) return AppSettings();
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return AppSettings();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return AppSettings();
      return AppSettings.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return AppSettings();
    }
  }

  /// Save settings to disk.
  Future<void> save() async {
    try {
      final file = await _getFile();
      final payload = toJson();
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
    } catch (_) {
      // best-effort
    }
  }
}
