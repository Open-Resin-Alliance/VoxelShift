import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/models.dart';
import '../network/app_settings.dart';
import 'conversion_worker.dart';
import 'ctb_parser.dart';
import 'thumbnail_processor.dart';

/// Progress info reported during conversion.
class ConversionProgress {
  final int current;
  final int total;
  final String phase;
  final int? workers;
  const ConversionProgress(this.current, this.total, this.phase, {this.workers});

  double get fraction => total > 0 ? current / total : 0;
}

/// Main converter: CTB → NanoDLP plate file.
///
/// Conversion runs entirely in a background isolate. The main thread
/// only receives small progress/log messages — no layer image data
/// ever crosses the isolate boundary, so the UI stays perfectly smooth.
class CtbToNanoDlpConverter {
  final List<void Function(String)> _logListeners = [];

  void addLogListener(void Function(String) listener) =>
      _logListeners.add(listener);

  void removeLogListener(void Function(String) listener) =>
      _logListeners.remove(listener);

  /// Read CTB file and return metadata without converting.
  Future<SliceFileInfo> readFileInfo(String ctbPath) async {
    final parser = await CtbParser.open(ctbPath);
    try {
      Uint8List? thumbnail;
      try {
        thumbnail = await parser.readPreviewLarge();
        thumbnail ??= await parser.readPreviewSmall();
        
        // Process thumbnail: crop black borders & generate VoxelShift branding
        thumbnail = ThumbnailProcessor.processThumbail(thumbnail);
      } catch (_) {}

      return parser.toSliceFileInfo(ctbPath, thumbnail: thumbnail);
    } finally {
      await parser.close();
    }
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
    final completer = Completer<ConversionResult>();

    receivePort.listen((message) {
      if (message is WorkerProgress) {
        onProgress?.call(
            ConversionProgress(message.current, message.total, message.phase,
                workers: message.workers));
      } else if (message is WorkerLog) {
        _log(message.text);
      } else if (message is WorkerBenchmarkUpdate) {
        settings.benchmarkCache[message.key] =
            BenchmarkCacheEntry.fromJson(Map<String, dynamic>.from(message.entry));
        settings.save();
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
}
