import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/models.dart';
import 'ctb_parser.dart';
import 'layer_processor.dart';
import 'nanodlp_file_writer.dart';
import 'profile_detector.dart';
import 'thumbnail_processor.dart';

// ── Messages sent from worker isolate → main thread ─────────
//
// Only tiny objects cross the boundary: strings, ints, booleans.
// No Uint8List layer data ever touches the main thread.

/// Progress update (current, total, phase name).
class WorkerProgress {
  final int current;
  final int total;
  final String phase;
  final int? workers;
  const WorkerProgress(this.current, this.total, this.phase, {this.workers});
}

/// Log line.
class WorkerLog {
  final String text;
  const WorkerLog(this.text);
}

/// Conversion finished (success or failure).
class WorkerDone {
  final ConversionResult result;
  const WorkerDone(this.result);
}

// ── Request object sent to the worker ───────────────────────

class ConversionWorkerRequest {
  final String ctbPath;
  final PrinterProfile? targetProfile;
  final double? maxZHeightOverride;
  final String? outputDirectory;
  final String? outputFileName;
  final SendPort sendPort;

  const ConversionWorkerRequest({
    required this.ctbPath,
    this.targetProfile,
    this.maxZHeightOverride,
    this.outputDirectory,
    this.outputFileName,
    required this.sendPort,
  });
}

// ── Worker entry point (top-level, runs in background isolate) ──
//
// The ENTIRE conversion pipeline runs here:
//   1. Open & parse CTB file
//   2. Read raw layer data (sequential I/O)
//   3. Process each layer: decrypt → RLE decode → area stats → PNG encode
//   4. Build metadata
//   5. Write .nanodlp ZIP file
//
// The main thread receives only small WorkerProgress / WorkerLog
// messages. No layer image data ever crosses the isolate boundary.

Future<void> conversionWorkerEntry(ConversionWorkerRequest req) async {
  final port = req.sendPort;
  final sw = Stopwatch()..start();

  void log(String msg) => port.send(WorkerLog(msg));
  DateTime lastReport = DateTime.now();
  const reportMs = 250;

  void progress(
    int cur,
    int total,
    String phase, {
    bool force = false,
    int? workers,
  }) {
    final now = DateTime.now();
    if (force ||
        now.difference(lastReport).inMilliseconds >= reportMs ||
        cur == total) {
      port.send(WorkerProgress(cur, total, phase, workers: workers));
      lastReport = now;
    }
  }

  try {
    // ── 1. Open CTB ─────────────────────────────────────────
    log('Opening ${_fileName(req.ctbPath)}...');
    progress(0, 1, 'Opening CTB file...', force: true);

    final parser = await CtbParser.open(req.ctbPath);

    try {
      Uint8List? thumbnail;
      try {
        thumbnail = await parser.readPreviewLarge();
        thumbnail ??= await parser.readPreviewSmall();
        
        // Process thumbnail: crop black borders & generate VoxelShift branding
        thumbnail = ThumbnailProcessor.processThumbail(thumbnail);
      } catch (_) {}

      final info = parser.toSliceFileInfo(req.ctbPath, thumbnail: thumbnail);
      log('Detected: ${info.resolutionX}x${info.resolutionY} '
          '(${info.detectedResolutionLabel}), '
          '${info.layerCount} layers, ${info.layerHeight}mm layer height');

      // ── 2. Validate & profile ─────────────────────────────
      final (valid, validationError) =
          PrinterProfileDetector.validateResolution(
              info.resolutionX, info.resolutionY);
      if (!valid) {
        _sendFail(port, req, info, sw.elapsed, validationError!);
        return;
      }

      final targetProfile = req.targetProfile ??
          PrinterProfileDetector.detectTargetProfile(
              info.resolutionX, info.resolutionY);
      if (targetProfile == null) {
        _sendFail(port, req, info, sw.elapsed,
            'Could not determine target printer for resolution '
            '${info.resolutionX}x${info.resolutionY}.');
        return;
      }

      log('Target profile: ${targetProfile.name} '
          '(board: ${targetProfile.board.name}, '
          'max Z: ${targetProfile.maxZHeight}mm)');

      final maxZ = req.maxZHeightOverride ?? targetProfile.maxZHeight;
      final printHeight = info.layerCount * info.layerHeight;
      if (printHeight > maxZ) {
        _sendFail(port, req, info, sw.elapsed,
            'Print height (${printHeight.toStringAsFixed(2)}mm) exceeds '
            'target max Z (${maxZ.toStringAsFixed(0)}mm).');
        return;
      }

      // ── 3. Read + process layers (sequential, all in this isolate) ──
      log('Reading raw layer data...');
      progress(0, info.layerCount, 'Reading layers...', force: true);

      final xPix = info.displayWidth / info.resolutionX;
      final yPix = info.displayHeight / info.resolutionY;

      final layerImages = <Uint8List>[];
      final layerAreas = <LayerAreaInfo>[];

      // Pre-read all raw layer data (sequential I/O, fast)
      final rawLayers = <Uint8List>[];
      for (int i = 0; i < info.layerCount; i++) {
        rawLayers.add(await parser.readRawLayerData(i));
        progress(i + 1, info.layerCount, 'Reading layers...');
      }

      // Process in parallel using worker pool
      log('Processing ${info.layerCount} layers...');
      final tasks = <LayerTaskParams>[];
      for (int i = 0; i < info.layerCount; i++) {
        tasks.add(LayerTaskParams(
          layerIndex: i,
          rawRleData: rawLayers[i],
          encryptionKey: parser.encryptionKey,
          resolutionX: info.resolutionX,
          resolutionY: info.resolutionY,
          xPixelSizeMm: xPix,
          yPixelSizeMm: yPix,
          boardTypeIndex: targetProfile.board.index,
          targetWidth: targetProfile.pngOutputWidth,
          pngLevel: 1,
        ));
      }
      rawLayers.clear(); // free memory

      int? processingWorkers;
      final results = await processLayersParallel(
        tasks: tasks,
        maxConcurrency: defaultWorkerCount,
        onWorkersReady: (workers) => processingWorkers = workers,
        onLayerComplete: (done, total) {
          progress(done, total, 'Processing layers...',
              workers: processingWorkers);
          if (done % (total ~/ 4).clamp(1, total) == 0 || done == total) {
            log('  Layer $done/$total');
          }
        },
      );

      results.sort((a, b) => a.layerIndex.compareTo(b.layerIndex));
      for (final r in results) {
        layerImages.add(r.pngBytes);
        layerAreas.add(r.areaInfo);
      }

      // ── 3b. Recompress PNGs (level 1 → 9) ────────────────
      log('Recompressing ${layerImages.length} PNGs (level 9)...');
      int? compressWorkers;
      final recompressed = await recompressPngsParallel(
        pngs: layerImages,
        maxConcurrency: defaultWorkerCount,
        onWorkersReady: (workers) => compressWorkers = workers,
        onProgress: (done, total) {
          progress(done, total, 'Compressing PNGs...',
              workers: compressWorkers);
          if (done % (total ~/ 4).clamp(1, total) == 0 || done == total) {
            log('  Compressed $done/$total');
          }
        },
      );
      for (int i = 0; i < recompressed.length; i++) {
        layerImages[i] = recompressed[i];
      }

      // ── 4. Metadata ───────────────────────────────────────
      final sourceProfile = PrinterProfileDetector.detectSourceProfile(
          info.resolutionX, info.resolutionY);

      final metadata = NanoDlpPlateMetadata(
        sourceFile: _fileName(req.ctbPath),
        sourcePrinterProfile:
            sourceProfile?.name ?? info.machineName ?? 'Unknown',
        targetPrinterProfile: targetProfile.name,
        resolutionX: info.resolutionX,
        resolutionY: info.resolutionY,
        displayWidthMm: info.displayWidth,
        displayHeightMm: info.displayHeight,
        maxZHeightMm: maxZ,
        layerHeightMm: info.layerHeight,
        layerCount: layerImages.length,
        bottomExposureTimeSec: info.bottomExposureTime,
        normalExposureTimeSec: info.exposureTime,
        bottomLayerCount: info.bottomLayerCount,
        liftHeightMm: info.liftHeight,
        liftSpeedMmPerMin: info.liftSpeed,
        retractSpeedMmPerMin: info.retractSpeed,
        xPixelSizeMm: xPix,
        yPixelSizeMm: yPix,
        thumbnailPng: thumbnail,
      );

      // ── 5. Write .nanodlp ZIP ─────────────────────────────
      final outputDir =
          req.outputDirectory ?? File(req.ctbPath).parent.path;
      final outputName =
          req.outputFileName ?? _fileNameWithoutExt(req.ctbPath);
      final outputPath =
          '$outputDir${Platform.pathSeparator}$outputName.nanodlp';

      log('Writing ${_fileName(outputPath)}...');

      final writer = NanoDlpFileWriter();
      await writer.writeAsync(
        outputPath,
        layerImages,
        metadata,
        layerAreaInfos: layerAreas,
        onProgress: (p) {
          progress(
            (p * layerImages.length).round(),
            layerImages.length,
            'Writing NanoDLP file...',
          );
        },
      );

      sw.stop();
      final fileSize = await File(outputPath).length();

      log('Conversion complete: $outputPath '
          '(${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB) '
          'in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');

      port.send(WorkerDone(ConversionResult(
        success: true,
        outputPath: outputPath,
        sourceInfo: info,
        targetProfile: targetProfile,
        layerCount: layerImages.length,
        outputFileSizeBytes: fileSize,
        duration: sw.elapsed,
      )));
    } finally {
      await parser.close();
    }
  } catch (e) {
    log('ERROR: $e');
    port.send(WorkerDone(ConversionResult(
      success: false,
      errorMessage: 'Conversion failed: $e',
      outputPath: '',
      sourceInfo: SliceFileInfo(
        sourcePath: req.ctbPath,
        resolutionX: 0,
        resolutionY: 0,
        displayWidth: 0,
        displayHeight: 0,
        machineZ: 0,
        layerHeight: 0,
        layerCount: 0,
        bottomExposureTime: 0,
        exposureTime: 0,
        bottomLayerCount: 0,
        liftHeight: 0,
        liftSpeed: 0,
        retractSpeed: 0,
      ),
      targetProfile: req.targetProfile ?? PrinterProfile.athena2_16K,
      layerCount: 0,
      outputFileSizeBytes: 0,
      duration: sw.elapsed,
    )));
  }
}

// ── Helpers ─────────────────────────────────────────────────

void _sendFail(SendPort port, ConversionWorkerRequest req,
    SliceFileInfo info, Duration elapsed, String error) {
  port.send(WorkerLog('ERROR: $error'));
  port.send(WorkerDone(ConversionResult(
    success: false,
    errorMessage: error,
    outputPath: '',
    sourceInfo: info,
    targetProfile: req.targetProfile ?? PrinterProfile.athena2_16K,
    layerCount: 0,
    outputFileSizeBytes: 0,
    duration: elapsed,
  )));
}

String _fileName(String path) {
  final sep = path.contains('\\') ? '\\' : '/';
  return path.split(sep).last;
}

String _fileNameWithoutExt(String path) {
  final name = _fileName(path);
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}
