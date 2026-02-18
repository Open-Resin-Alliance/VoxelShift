import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:io';

import '../models/models.dart';
import '../network/app_settings.dart';
import 'conversion_worker.dart';
import 'conversion_analytics.dart';
import 'ctb_parser.dart';
import 'thumbnail_processor.dart';

/// Progress info reported during conversion.
class ConversionProgress {
  final int current;
  final int total;
  final String phase;
  final int? workers;
  const ConversionProgress(
    this.current,
    this.total,
    this.phase, {
    this.workers,
  });

  double get fraction => total > 0 ? current / total : 0;
}

/// Main converter: CTB → NanoDLP plate file.
///
/// Conversion runs entirely in a background isolate. The main thread
/// only receives small progress/log messages — no layer image data
/// ever crosses the isolate boundary, so the UI stays perfectly smooth.
class CtbToNanoDlpConverter {
  final List<void Function(String)> _logListeners = [];
  static Future<String?>? _cpuNameFuture;

  void addLogListener(void Function(String) listener) =>
      _logListeners.add(listener);

  void removeLogListener(void Function(String) listener) =>
      _logListeners.remove(listener);

  /// Read CTB file and return metadata without converting.
  ///
  /// Optional [onProgress] callback receives updates:
  /// - "Opening file..." → "Reading preview..." → "Processing metadata..."
  Future<SliceFileInfo> readFileInfo(
    String ctbPath, {
    void Function(String)? onProgress,
  }) async {
    onProgress?.call('Opening file...');
    final parser = await CtbParser.open(ctbPath);
    try {
      var thumbnailPair = ThumbnailPair(
        guiThumbnail: null,
        nanodlpThumbnail: null,
      );
      try {
        onProgress?.call('Reading preview...');
        var rawThumbnail = await parser.readPreviewLarge();
        rawThumbnail ??= await parser.readPreviewSmall();

        // Process thumbnail: crop black borders & generate VoxelShift branding
        if (rawThumbnail != null) {
          onProgress?.call('Processing metadata...');
          thumbnailPair = ThumbnailProcessor.processThumbail(rawThumbnail);
        }
      } catch (_) {}

      onProgress?.call('Validating file...');
      return parser.toSliceFileInfo(
        ctbPath,
        thumbnail: thumbnailPair.guiThumbnail,
      );
    } finally {
      await parser.close();
    }
  }

  /// Check for corrupt layers (fully black or fully white).
  /// Samples up to 10 layers throughout the file.
  /// Returns list of corrupt layer indices, or empty if file is OK.
  ///
  /// Optional [onProgress] callback receives updates like "Checking layer 3 of 8..."
  Future<List<int>> checkForCorruptLayers(
    String ctbPath, {
    void Function(String)? onProgress,
  }) async {
    final parser = await CtbParser.open(ctbPath);
    final corruptLayers = <int>[];

    try {
      final totalLayers = parser.layerCount;
      if (totalLayers == 0) return corruptLayers;

      // Sample layers: first, middle, and evenly spaced
      // Skip last layer - some slicers add empty padding layers at the end which is okay
      final samplesToCheck = <int>{};
      samplesToCheck.add(0); // First layer
      if (totalLayers > 2) samplesToCheck.add(totalLayers ~/ 2); // Middle

      // Add evenly spaced samples (up to 10 total), but don't include last
      final step = (totalLayers / 10).ceil();
      final maxLayer = totalLayers - 2; // Exclude last layer
      for (var i = 0; i <= maxLayer && samplesToCheck.length < 10; i += step) {
        samplesToCheck.add(i);
      }

      final sortedSamples = samplesToCheck.toList()..sort();
      for (int idx = 0; idx < sortedSamples.length; idx++) {
        final layerIdx = sortedSamples[idx];
        onProgress?.call(
          'Checking layer ${idx + 1} of ${sortedSamples.length}...',
        );

        try {
          final layerData = await parser.readLayerImage(layerIdx);
          if (layerData.isEmpty) continue;

          // Check if all pixels are same value (0 = fully black, 255 = fully white)
          final firstPixel = layerData[0];
          if (firstPixel == 0 || firstPixel == 255) {
            final allSame = layerData.every((pixel) => pixel == firstPixel);
            if (allSame) {
              corruptLayers.add(layerIdx);
            }
          }
        } catch (_) {
          // If we can't read a layer, consider it potentially corrupt
          corruptLayers.add(layerIdx);
        }
      }
    } finally {
      await parser.close();
    }

    return corruptLayers;
  }

  /// Convert a CTB file to a NanoDLP plate file.
  ///
  /// The entire conversion runs in a background isolate. Only small
  /// progress / log messages are sent back to the UI thread.
  Future<ConversionResult> convert(
    String ctbPath, {
    ConversionOptions? options,
    void Function(ConversionProgress)? onProgress,
  }) async {
    options ??= ConversionOptions();
    final receivePort = ReceivePort();
    final settings = await AppSettings.load();
    AnalyticsBus.enabled.value = settings.postProcessing.analyticsMode;
    final completer = Completer<ConversionResult>();

    receivePort.listen((message) {
      if (message is WorkerProgress) {
        onProgress?.call(
          ConversionProgress(
            message.current,
            message.total,
            message.phase,
            workers: message.workers,
          ),
        );
      } else if (message is WorkerLog) {
        _log(message.text);
      } else if (message is WorkerBenchmarkUpdate) {
        settings.benchmarkCache[message.key] = BenchmarkCacheEntry.fromJson(
          Map<String, dynamic>.from(message.entry),
        );
        settings.save();
      } else if (message is WorkerAnalyticsUpdate) {
        final report = ConversionAnalytics.fromWorkerMap(
          Map<String, dynamic>.from(message.data),
        );
        AnalyticsBus.update(report);

        // Auto-optimize worker count after first run (ONE-TIME only)
        // Once cpuHostWorkers is set, this won't run again - prevents
        // continuously optimizing down to fewer workers
        if (settings.postProcessing.cpuHostWorkers == null) {
          // Windows: 1.0x multiplier cap (SMT well-handled by scheduler)
          // macOS: 2.0x multiplier cap (leverage efficiency cores)
          final platformDefault = Platform.isWindows ? 1.0 : 2.0;
          final maxMultiplier =
              settings.postProcessing.workerMultiplierCap ?? platformDefault;
          final optimal = report.calculateOptimalWorkerCount(
            maxMultiplier: maxMultiplier,
          );
          if (optimal != report.workers && optimal > 0) {
            settings.postProcessing.cpuHostWorkers = optimal;
            settings.save();
            _log(
              'Auto-optimized worker count: ${report.workers} → $optimal (future runs will use $optimal)',
            );
          }
        }

        _cpuNameFuture ??= _readCpuName();
        _cpuNameFuture?.then((name) {
          if (name == null || name.isEmpty) return;
          final current = AnalyticsBus.latest.value;
          if (current == null) return;
          if (current.capturedAt != report.capturedAt) return;
          AnalyticsBus.update(current.withCpuName(name));
        });
      } else if (message is WorkerDone) {
        completer.complete(message.result);
        receivePort.close();
      }
    });

    await Isolate.spawn(
      conversionWorkerEntry,
      ConversionWorkerRequest(
        ctbPath: ctbPath,
        targetProfile: options.targetProfile,
        maxZHeightOverride: options.maxZHeightOverride,
        outputDirectory: options.outputDirectory,
        outputFileName: options.outputFileName,
        postProcessingSettings: settings.postProcessing.toJson(),
        benchmarkCache: settings.benchmarkCache.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
        sendPort: receivePort.sendPort,
      ),
    );

    return completer.future;
  }

  void _log(String message) {
    for (final listener in _logListeners) {
      listener(message);
    }
  }

  static Future<String?> _readCpuName() async {
    try {
      if (Platform.isMacOS) {
        final result = await Process.run('sysctl', [
          '-n',
          'machdep.cpu.brand_string',
        ]);
        if (result.exitCode == 0) {
          final name = (result.stdout as String).trim();
          if (name.isNotEmpty) return name;
        }
      } else if (Platform.isWindows) {
        final result = await Process.run('wmic', ['cpu', 'get', 'name']);
        if (result.exitCode == 0) {
          final lines = (result.stdout as String)
              .split(RegExp(r'\r?\n'))
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .toList();
          if (lines.length >= 2) return lines[1];
        }
      } else if (Platform.isLinux) {
        final cpuInfo = await File('/proc/cpuinfo').readAsString();
        for (final line in cpuInfo.split('\n')) {
          if (line.toLowerCase().startsWith('model name')) {
            final parts = line.split(':');
            if (parts.length > 1) return parts[1].trim();
          }
        }
      }
    } catch (_) {
      // Ignore and fall through.
    }
    return null;
  }
}
