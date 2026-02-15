import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/models.dart';
import 'ctb_parser.dart';
import 'layer_processor.dart';
import 'native_gpu_accel.dart';
import 'native_layer_batch_process.dart';
import 'nanodlp_file_writer.dart';
import 'profile_detector.dart';
import 'thumbnail_processor.dart';
import '../network/app_settings.dart';

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

/// Benchmark cache update (keyed by device/profile/resolution).
class WorkerBenchmarkUpdate {
  final String key;
  final Map<String, dynamic> entry;
  const WorkerBenchmarkUpdate(this.key, this.entry);
}

/// Analytics report for diagnostics (per-worker timings + stage totals).
class WorkerAnalyticsUpdate {
  final Map<String, dynamic> data;
  const WorkerAnalyticsUpdate(this.data);
}

class _ThreadStat {
  int layers = 0;
  int totalNs = 0;
  int decodeNs = 0;
  int scanlineNs = 0;
  int compressNs = 0;
  int pngNs = 0;

  void add(NativeThreadStats s) {
    layers += s.layers;
    totalNs += s.totalNs;
    decodeNs += s.decodeNs;
    scanlineNs += s.scanlineNs;
    compressNs += s.compressNs;
    pngNs += s.pngNs;
  }

  Map<String, dynamic> toJson(int index) => {
        'index': index,
        'layers': layers,
        'totalNs': totalNs,
        'decodeNs': decodeNs,
        'scanlineNs': scanlineNs,
        'compressNs': compressNs,
        'pngNs': pngNs,
      };
}

class _AnalyticsCollector {
  final bool enabled;
  final Map<String, int> _stageNs = {};
  final List<_ThreadStat> _threads = [];

  _AnalyticsCollector(this.enabled);

  void addStage(String name, Duration duration) {
    if (!enabled) return;
    final ns = duration.inMicroseconds * 1000;
    _stageNs[name] = (_stageNs[name] ?? 0) + ns;
  }

  void addNativeStats(List<NativeThreadStats> stats) {
    if (!enabled || stats.isEmpty) return;
    if (_threads.length < stats.length) {
      for (int i = _threads.length; i < stats.length; i++) {
        _threads.add(_ThreadStat());
      }
    }
    for (int i = 0; i < stats.length; i++) {
      _threads[i].add(stats[i]);
    }
  }

  Map<String, dynamic> toMap({
    required int cpuCores,
    required int workers,
    required String processingEngine,
    required bool gpuActive,
    required int gpuAttempts,
    required int gpuSuccesses,
    required int gpuFallbacks,
  }) {
    final nativeTotals = <String, int>{
      'decode': 0,
      'scanline': 0,
      'compress': 0,
      'png': 0,
    };

    for (final t in _threads) {
      nativeTotals['decode'] = (nativeTotals['decode'] ?? 0) + t.decodeNs;
      nativeTotals['scanline'] = (nativeTotals['scanline'] ?? 0) + t.scanlineNs;
      nativeTotals['compress'] = (nativeTotals['compress'] ?? 0) + t.compressNs;
      nativeTotals['png'] = (nativeTotals['png'] ?? 0) + t.pngNs;
    }

    return {
      'cpuCores': cpuCores,
      'workers': workers,
      'processingEngine': processingEngine,
      'gpuActive': gpuActive,
      'gpuAttempts': gpuAttempts,
      'gpuSuccesses': gpuSuccesses,
      'gpuFallbacks': gpuFallbacks,
      'stagesNs': _stageNs,
      'nativeStagesNs': nativeTotals,
      'threadStats': [
        for (int i = 0; i < _threads.length; i++) _threads[i].toJson(i)
      ],
    };
  }
}

// ── Request object sent to the worker ───────────────────────

class ConversionWorkerRequest {
  final String ctbPath;
  final PrinterProfile? targetProfile;
  final double? maxZHeightOverride;
  final String? outputDirectory;
  final String? outputFileName;
  final Map<String, dynamic> postProcessingSettings;
  final Map<String, dynamic> benchmarkCache;
  final SendPort sendPort;

  const ConversionWorkerRequest({
    required this.ctbPath,
    this.targetProfile,
    this.maxZHeightOverride,
    this.outputDirectory,
    this.outputFileName,
    this.postProcessingSettings = const {},
    this.benchmarkCache = const {},
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
  final settings = req.postProcessingSettings;
  final analyticsEnabled = _settingBool(
    settings,
    'analyticsMode',
    envKey: 'VOXELSHIFT_ANALYTICS',
    defaultValue: false,
  );
  final analytics = _AnalyticsCollector(analyticsEnabled);

  void log(String msg) => port.send(WorkerLog(msg));
  DateTime lastReport = DateTime.now();
  const reportMs = 400;

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

    final openSw = Stopwatch()..start();
    final parser = await CtbParser.open(req.ctbPath);
    openSw.stop();
    analytics.addStage('open', openSw.elapsed);

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

      // Optional native GPU backend toggle/detection (safe no-op when unavailable).
      final gpu = NativeGpuAccel.instance;
      bool gpuRequested = false;
      bool gpuAccelActive = false;
      int gpuBackendCode = 0;
        final gpuMode = (_settingString(
          settings,
          'gpuMode',
          envKey: 'VOXELSHIFT_GPU_MODE',
          ) ??
          'auto')
          .toLowerCase()
          .trim();
        final gpuBackendPrefEnv = (_settingString(
          settings,
          'gpuBackend',
          envKey: 'VOXELSHIFT_GPU_BACKEND',
          ) ??
          'auto')
          .toLowerCase()
          .trim();
      final preferredBackendCode = switch (gpuBackendPrefEnv) {
        'opencl' => 1,
        'metal' => 2,
        'cuda' || 'tensor' || 'cuda/tensor' => 3,
        _ => 0,
      };
      if (gpu.available) {
        final gpuEnv = (Platform.environment['VOXELSHIFT_USE_GPU'] ?? '').toLowerCase();
        // Selection priority:
        // 1) VOXELSHIFT_GPU_MODE = cpu|gpu|auto
        // 2) legacy VOXELSHIFT_USE_GPU (1/0)
        // 3) default auto
        if (gpuMode == 'cpu') {
          gpuRequested = false;
        } else if (gpuMode == 'gpu') {
          gpuRequested = true;
        } else {
          gpuRequested = gpuEnv.isEmpty
              ? true
              : (gpuEnv == '1' || gpuEnv == 'true' || gpuEnv == 'yes');
        }
        gpu.setPreferredBackend(preferredBackendCode);
        gpu.setEnabled(gpuRequested);
        gpuBackendCode = gpu.backendCode;
        gpuAccelActive = gpu.active && (gpuBackendCode == 1 || gpuBackendCode == 3);
        log('GPU backend: ${gpu.backendName} '
            '(mode: $gpuMode, requested: ${gpuRequested ? 'yes' : 'no'}, '
            'active: ${gpu.active ? 'yes' : 'no'})');
        log('GPU backend availability: '
            'CUDA/Tensor=${gpu.isBackendAvailable(3) ? 'yes' : 'no'}, '
            'OpenCL=${gpu.isBackendAvailable(1) ? 'yes' : 'no'} '
            '(preferred: ${gpuBackendPrefEnv.toUpperCase()})');

        // Log CUDA device info if available
        final nativeBatchInfo = NativeLayerBatchProcess.instance;
        if (nativeBatchInfo.cudaInit()) {
          log('CUDA device: ${nativeBatchInfo.cudaDeviceName}');
          log('  VRAM: ${(nativeBatchInfo.cudaVramBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB');
          log('  Compute capability: ${nativeBatchInfo.cudaComputeCapability ~/ 10}.${nativeBatchInfo.cudaComputeCapability % 10}');
          log('  SMs: ${nativeBatchInfo.cudaMultiprocessorCount}');
          log('  Tensor cores: ${nativeBatchInfo.cudaHasTensorCores ? "yes" : "no"}');
          log('  Phased pipeline: ${nativeBatchInfo.phasedAvailable ? "available" : "not available"}');
        }
      } else {
        log('GPU backend: unavailable');
      }

      final maxZ = req.maxZHeightOverride ?? targetProfile.maxZHeight;
      final printHeight = info.layerCount * info.layerHeight;
      if (printHeight > maxZ) {
        _sendFail(port, req, info, sw.elapsed,
            'Print height (${printHeight.toStringAsFixed(2)}mm) exceeds '
            'target max Z (${maxZ.toStringAsFixed(0)}mm).');
        return;
      }

      // ── 3. Read + process layers (sequential, all in this isolate) ──
      final xPix = info.displayWidth / info.resolutionX;
      final yPix = info.displayHeight / info.resolutionY;

      final layerImages = <Uint8List>[];
      final layerAreas = <LayerAreaInfo>[];

      // Preload only for small jobs; stream for large jobs to cap RAM.
      final shouldPreload = _envIsTruthy('VOXELSHIFT_PRELOAD_LAYERS') ||
          info.layerCount <= 200;

      final rawLayers = <Uint8List>[];
      final readSw = Stopwatch();
      Duration readStreamingTime = Duration.zero;
      if (shouldPreload) {
        log('Reading raw layer data (preload)...');
        progress(0, info.layerCount, 'Reading layers...', force: true);
        readSw.start();
        for (int i = 0; i < info.layerCount; i++) {
          rawLayers.add(await parser.readRawLayerData(i));
          progress(i + 1, info.layerCount, 'Reading layers...');
        }
        readSw.stop();
        analytics.addStage('read', readSw.elapsed);
      } else {
        log('Reading raw layer data on the fly (streaming)...');
        progress(0, info.layerCount, 'Reading layers...', force: true);
      }

      final nativeBatch = NativeLayerBatchProcess.instance;
      nativeBatch.setAnalyticsEnabled(analyticsEnabled);
        final outWidth = targetProfile.pngOutputWidth;
      final outChannels = targetProfile.board == BoardType.rgb8Bit ? 3 : 1;

      final fastMode = _settingBool(
        settings,
        'fastMode',
        envKey: 'VOXELSHIFT_FAST_MODE',
        defaultValue: false,
      );
      final processPngLevel = (() {
        final override = _settingInt(
          settings,
          'processPngLevel',
          envKey: 'VOXELSHIFT_PROCESS_PNG_LEVEL',
        );
        if (override != null) return override.clamp(0, 9);
        return fastMode ? 0 : 1;
      })();
      if (fastMode) {
        log('Fast mode enabled: using speed-first defaults '
            '(process PNG level: $processPngLevel).');
      }

      // Process in parallel using worker pool
      var processingEngine = _processingEngineLabel(gpuAccelActive, gpuBackendCode);
      log('Processing engine: $processingEngine');
      log('Processing ${info.layerCount} layers...');
      progress(
        0,
        info.layerCount,
        'Preparing native processing batch... [$processingEngine]',
        force: true,
      );

      var processingMaxConcurrency = _nativeWorkerTarget(
        layerCount: info.layerCount,
        gpuActive: gpuAccelActive,
        settings: settings,
      );

      int gpuWorkersForBackend(int backendCode, int layerCount) {
        final explicitGpu = _settingInt(
          settings,
          'gpuHostWorkers',
          envKey: 'VOXELSHIFT_GPU_HOST_WORKERS',
        );
        if (explicitGpu != null) {
          return explicitGpu.clamp(1, math.min(256, math.max(1, layerCount)));
        }

        if (backendCode == 3) {
          final explicitCuda = _settingInt(
            settings,
            'cudaHostWorkers',
            envKey: 'VOXELSHIFT_CUDA_HOST_WORKERS',
          );
          if (explicitCuda != null) {
            return explicitCuda.clamp(1, math.min(256, math.max(1, layerCount)));
          }

          // Auto-detect: query CUDA kernel for how many concurrent layers
          // fit in VRAM (accounts for per-thread device buffer pairs).
          int vramCap = nativeBatch.cudaMaxConcurrentLayers(
            srcWidth: info.resolutionX,
            height: info.resolutionY,
            outWidth: outWidth,
            channels: outChannels,
          );
          if (vramCap <= 0) {
            // Fallback: estimate from total VRAM if the export is missing.
            final vramBytes = nativeBatch.cudaVramBytes;
            if (vramBytes > 0) {
              const headroomBytes = 2560 * 1024 * 1024; // 2.5 GB
              final pixelsBytes = info.resolutionX * info.resolutionY;
              final scanlineSize = 1 + outWidth * outChannels;
              final scanlinesBytes = scanlineSize * info.resolutionY;
              final perLayer = pixelsBytes + scanlinesBytes;
              final budget = vramBytes - headroomBytes;
              if (perLayer > 0 && budget > 0) {
                vramCap = budget ~/ perLayer;
                if (vramCap < 1) vramCap = 1;
              }
            }
          }
          if (vramCap > 0) {
            // We don't need many concurrent GPU operations — the GPU can
            // only overlap a handful of kernel launches.  A small number
            // of CUDA workers (capped at 8) keeps VRAM usage sane while
            // still saturating the GPU pipeline.  The remaining CPU cores
            // handle decode+compress without needing VRAM.
            final cudaWorkers = math.min(vramCap, 8);
            // Total threads = CUDA workers + enough CPU cores for decode/compress
            final cores = Platform.numberOfProcessors;
            final target = math.max(cudaWorkers, cores);
            log('CUDA VRAM budget: $vramCap concurrent layers, '
                'using $cudaWorkers CUDA + ${target - cudaWorkers} CPU-only workers.');
            return math.min(target, math.max(1, layerCount));
          }

          // Fallback: conservative CUDA workers even if VRAM is unknown.
          final cores = Platform.numberOfProcessors;
          final cudaWorkers = math.min(8, math.max(1, cores ~/ 2));
          final target = math.max(cudaWorkers, cores);
          log('CUDA VRAM cap unavailable; using $cudaWorkers CUDA + '
              '${target - cudaWorkers} CPU-only workers.');
          return math.min(target, math.max(1, layerCount));
        }

        return _nativeWorkerTarget(
          layerCount: layerCount,
          gpuActive: true,
          settings: settings,
        );
      }

      if (gpuAccelActive) {
        processingMaxConcurrency = gpuWorkersForBackend(gpuBackendCode, info.layerCount);
      }

      // Hybrid GPU mode: keep several host workers active so decode/area/zlib
      // stay parallel while scanline mapping uses GPU.
      if (gpuAccelActive) {
        log('GPU mode enabled: hybrid CPU+GPU with $processingMaxConcurrency workers.');
        if (gpuBackendCode == 3) {
          int vramCap = nativeBatch.cudaMaxConcurrentLayers(
            srcWidth: info.resolutionX,
            height: info.resolutionY,
            outWidth: outWidth,
            channels: outChannels,
          );
          if (vramCap <= 0) {
            final vramBytes = nativeBatch.cudaVramBytes;
            if (vramBytes > 0) {
              const headroomBytes = 2560 * 1024 * 1024; // 2.5 GB
              final pixelsBytes = info.resolutionX * info.resolutionY;
              final scanlineSize = 1 + outWidth * outChannels;
              final scanlinesBytes = scanlineSize * info.resolutionY;
              final perLayer = pixelsBytes + scanlinesBytes;
              final budget = vramBytes - headroomBytes;
              if (perLayer > 0 && budget > 0) {
                vramCap = budget ~/ perLayer;
                if (vramCap < 1) vramCap = 1;
              }
            }
          }
          log('CUDA VRAM cap: $vramCap concurrent layers. '
              'Override with VOXELSHIFT_CUDA_HOST_WORKERS or VOXELSHIFT_GPU_HOST_WORKERS.');
        }
      } else {
        log('CPU native mode with $processingMaxConcurrency workers.');
      }

        final autoTuneEnabled = _settingBool(
          settings,
          'autotune',
          envKey: 'VOXELSHIFT_AUTOTUNE',
          defaultValue: true,
        );
        if (autoTuneEnabled &&
          gpuMode == 'auto' &&
          nativeBatch.available &&
          info.layerCount >= 8) {
        final sampleSize = math.min(info.layerCount, 64);
        final sample = shouldPreload
            ? rawLayers.sublist(0, sampleSize)
            : await _readRawLayerRange(parser, 0, sampleSize);
        final cpuWorkersFinal = _nativeWorkerTarget(
          layerCount: info.layerCount,
          gpuActive: false,
          settings: settings,
        );
        final cpuWorkersBench = math.min(cpuWorkersFinal, sampleSize);

        Duration? cpuTime;
        Duration? bestGpuTime;
        int bestGpuBackend = 0;
        bool usedCache = false;

        final cacheKey = _benchmarkCacheKey(
          info: info,
          profile: targetProfile,
          backend: gpuBackendCode,
          gpuName: nativeBatch.cudaDeviceName,
          cpuCores: Platform.numberOfProcessors,
          outWidth: outWidth,
          outChannels: outChannels,
        );
        final cacheEntry = _benchmarkCacheEntry(req.benchmarkCache, cacheKey);
        if (cacheEntry != null && !_benchmarkCacheStale(cacheEntry)) {
          final gpuAvailable = gpu.isBackendAvailable(cacheEntry.backend);
          if (gpuRequested && gpuAvailable &&
              cacheEntry.gpuMs > 0 && cacheEntry.cpuMs > 0 &&
              cacheEntry.gpuMs < cacheEntry.cpuMs) {
            gpu.setPreferredBackend(cacheEntry.backend);
            gpu.setEnabled(true);
            gpuBackendCode = gpu.backendCode;
            gpuAccelActive = gpu.active && (gpuBackendCode == 1 || gpuBackendCode == 3);
            processingMaxConcurrency = gpuWorkersForBackend(gpuBackendCode, info.layerCount);
            processingEngine = _processingEngineLabel(gpuAccelActive, gpuBackendCode);
            log('Auto-tuner cache hit: selecting GPU '
                '(${gpu.backendName}) [CPU: ${cacheEntry.cpuMs}ms, GPU: ${cacheEntry.gpuMs}ms].');
            usedCache = true;
          } else if (cacheEntry.cpuMs > 0) {
            gpu.setPreferredBackend(0);
            gpu.setEnabled(false);
            gpuBackendCode = 0;
            gpuAccelActive = false;
            processingMaxConcurrency = _nativeWorkerTarget(
              layerCount: info.layerCount,
              gpuActive: false,
              settings: settings,
            );
            processingEngine = 'CPU Native';
            log('Auto-tuner cache hit: selecting CPU '
                '[CPU: ${cacheEntry.cpuMs}ms, GPU: ${cacheEntry.gpuMs}ms].');
            usedCache = true;
          }
          if (usedCache) {
            progress(
              0,
              info.layerCount,
              'Auto-tune cache: $processingEngine',
              workers: processingMaxConcurrency,
              force: true,
            );
          }
        }

        Future<Duration?> benchmarkGpuBackend(int backendCode, String name) async {
          if (!gpu.isBackendAvailable(backendCode)) {
            log('Auto-tuner: skip $name (not available).');
            progress(
              0,
              info.layerCount,
              'Auto-tune: Skip $name (not available)',
              workers: processingMaxConcurrency,
              force: true,
            );
            return null;
          }
          progress(
            0,
            info.layerCount,
            'Auto-tune: Testing $name...',
            workers: processingMaxConcurrency,
            force: true,
          );
          gpu.setPreferredBackend(backendCode);
          gpu.setEnabled(true);
          final active = gpu.active;
          final selected = gpu.backendCode;
          if (!active || selected != backendCode) {
            log('Auto-tuner: skip $name (active=${active ? 'yes' : 'no'}, selected=$selected).');
            progress(
              0,
              info.layerCount,
              'Auto-tune: Skip $name (selection failed)',
              workers: processingMaxConcurrency,
              force: true,
            );
            return null;
          }

          final sw = Stopwatch()..start();
          final backendGpuWorkersFinal = gpuWorkersForBackend(backendCode, info.layerCount);
          final backendGpuWorkersBench = math.min(backendGpuWorkersFinal, sampleSize);
          final result = nativeBatch.processBatch(
            rawLayers: sample,
            layerIndexBase: 0,
            encryptionKey: parser.encryptionKey,
            srcWidth: info.resolutionX,
            height: info.resolutionY,
            outWidth: outWidth,
            channels: outChannels,
            xPixelSizeMm: xPix,
            yPixelSizeMm: yPix,
            pngLevel: processPngLevel,
            threadCount: backendGpuWorkersBench,
          );
          sw.stop();
          if (result == null || result.length != sampleSize) {
            log('Auto-tuner: $name run failed.');
            return null;
          }
          final attempts = nativeBatch.lastGpuAttempts;
          final successes = nativeBatch.lastGpuSuccesses;
          final fallbacks = nativeBatch.lastGpuFallbacks;
            final cudaErr = nativeBatch.lastCudaError;
          final usagePct = attempts > 0
              ? ((successes * 100.0) / attempts).toStringAsFixed(1)
              : '0.0';
          log('Auto-tuner: $name = ${sw.elapsedMilliseconds}ms '
              '[workers: $backendGpuWorkersBench] '
              '[GPU usage: $successes/$attempts (${usagePct}%, fallbacks: $fallbacks, '
              'cuda_err: $cudaErr)]');
          return sw.elapsed;
        }

        log('Auto-tuning compute path on $sampleSize sample layers...');
        progress(
          0,
          info.layerCount,
          'Auto-tune: Benchmarking CPU and GPU backends...',
          workers: processingMaxConcurrency,
          force: true,
        );

        if (!usedCache && gpu.available) {
          gpu.setEnabled(false);
          progress(
            0,
            info.layerCount,
            'Auto-tune: Testing CPU Native...',
            workers: processingMaxConcurrency,
            force: true,
          );
          final cpuSw = Stopwatch()..start();
          final cpuResult = nativeBatch.processBatch(
            rawLayers: sample,
            layerIndexBase: 0,
            encryptionKey: parser.encryptionKey,
            srcWidth: info.resolutionX,
            height: info.resolutionY,
            outWidth: outWidth,
            channels: outChannels,
            xPixelSizeMm: xPix,
            yPixelSizeMm: yPix,
            pngLevel: processPngLevel,
            threadCount: cpuWorkersBench,
          );
          cpuSw.stop();
          if (cpuResult != null && cpuResult.length == sampleSize) {
            cpuTime = cpuSw.elapsed;
          }

          if (gpuRequested) {
            final candidates = <(int, String)>[];
            if (preferredBackendCode == 3 || preferredBackendCode == 0) {
              candidates.add((3, 'GPU CUDA/Tensor'));
            }
            if (preferredBackendCode == 1 || preferredBackendCode == 0) {
              candidates.add((1, 'GPU OpenCL'));
            }

            for (final c in candidates) {
              // Skip slower backends once we already have one that beats CPU.
              // This avoids spending ~4s benchmarking OpenCL when CUDA already won.
              if (bestGpuTime != null &&
                  cpuTime != null &&
                  bestGpuTime.inMicroseconds < cpuTime.inMicroseconds) {
                log('Auto-tuner: skip ${c.$2} (already have a faster GPU backend).');
                continue;
              }
              final t = await benchmarkGpuBackend(c.$1, c.$2);
              if (t != null &&
                  (bestGpuTime == null || t.inMicroseconds < bestGpuTime.inMicroseconds)) {
                bestGpuTime = t;
                bestGpuBackend = c.$1;
              }
            }
          }
        }

        if (!usedCache && bestGpuTime != null &&
            (cpuTime == null || bestGpuTime.inMicroseconds < cpuTime.inMicroseconds)) {
          gpu.setPreferredBackend(bestGpuBackend);
          gpu.setEnabled(true);
          gpuBackendCode = gpu.backendCode;
          gpuAccelActive = gpu.active && (gpuBackendCode == 1 || gpuBackendCode == 3);
          processingMaxConcurrency = gpuWorkersForBackend(gpuBackendCode, info.layerCount);
          processingEngine = _processingEngineLabel(gpuAccelActive, gpuBackendCode);
          log('Auto-tuner selected GPU (${gpu.backendName}) '
              '[CPU: ${cpuTime?.inMilliseconds ?? -1}ms, GPU: ${bestGpuTime.inMilliseconds}ms].');
          progress(
            0,
            info.layerCount,
            'Auto-tune selected: $processingEngine',
            workers: processingMaxConcurrency,
            force: true,
          );
        } else if (!usedCache) {
          gpu.setPreferredBackend(0);
          gpu.setEnabled(false);
          gpuBackendCode = 0;
          gpuAccelActive = false;
          processingMaxConcurrency = cpuWorkersFinal;
          processingEngine = 'CPU Native';
          log('Auto-tuner selected CPU '
              '[CPU: ${cpuTime?.inMilliseconds ?? -1}ms, GPU: ${bestGpuTime?.inMilliseconds ?? -1}ms].');
          progress(
            0,
            info.layerCount,
            'Auto-tune selected: CPU Native',
            workers: processingMaxConcurrency,
            force: true,
          );
        }

        if (!usedCache && cpuTime != null && bestGpuTime != null) {
          final entry = BenchmarkCacheEntry(
            cpuMs: cpuTime.inMilliseconds,
            gpuMs: bestGpuTime.inMilliseconds,
            backend: bestGpuBackend,
            updatedAtMs: DateTime.now().millisecondsSinceEpoch,
            sampleSize: sampleSize,
          );
          port.send(WorkerBenchmarkUpdate(cacheKey, entry.toJson()));
        }
      }

      bool usedNativeBatch = false;
      final processingPhaseSw = Stopwatch()..start();
      var processingGpuAttempts = 0;
      var processingGpuSuccesses = 0;
      var processingGpuFallbacks = 0;

      // ── Try phased pipeline (opt-in, CPU+GPU hybrid) ──
      // For large layers (16K), the integrated chunked pipeline with per-layer
      // GPU is typically faster due to natural overlap between decode/scanlines/
      // compress across threads. The phased pipeline serialises phases with sync
      // barriers, eliminating that overlap. Enable with VOXELSHIFT_USE_PHASED=1.
      final usePhasedPipeline = _settingBool(
        settings,
        'usePhased',
        envKey: 'VOXELSHIFT_USE_PHASED',
        defaultValue: false,
      );
      if (usePhasedPipeline &&
          nativeBatch.available &&
          nativeBatch.phasedAvailable) {
        final useMegaBatchGpu =
            gpuRequested && gpu.available && gpu.isBackendAvailable(3);
        if (useMegaBatchGpu) {
          gpu.setPreferredBackend(3);
          gpu.setEnabled(true);
        }
        final phasedEngine =
            useMegaBatchGpu ? 'Phased GPU Mega-Batch' : 'Phased CPU';
        log('Using phased pipeline ($phasedEngine).');

        // CPU-appropriate thread count for decode + compress phases.
        // GPU mega-batch is a single bulk call, not per-thread.
        final phasedThreads = math.min(
          Platform.numberOfProcessors * 2,
          processingMaxConcurrency,
        );

        // Chunk from Dart side for progress reporting & memory control.
        final phasedChunkSize = math.min(96, info.layerCount);
        final logStep = (info.layerCount ~/ 4).clamp(1, info.layerCount);
        int done = 0;
        bool phasedFailed = false;
        int nextLog = logStep;

        progress(0, info.layerCount,
            'Processing layers (phased)... [$phasedEngine]',
            workers: phasedThreads, force: true);

        for (int start = 0;
            start < info.layerCount;
            start += phasedChunkSize) {
          final end = math.min(start + phasedChunkSize, info.layerCount);
          late final List<Uint8List> chunk;
          if (shouldPreload) {
            chunk = rawLayers.sublist(start, end);
          } else {
            final chunkReadSw = Stopwatch()..start();
            chunk = await _readRawLayerRange(parser, start, end);
            chunkReadSw.stop();
            readStreamingTime += chunkReadSw.elapsed;
          }

          nativeBatch.setBatchThreads(phasedThreads);
          final chunkResults = nativeBatch.processBatchPhased(
            rawLayers: chunk,
            layerIndexBase: start,
            encryptionKey: parser.encryptionKey,
            srcWidth: info.resolutionX,
            height: info.resolutionY,
            outWidth: outWidth,
            channels: outChannels,
            xPixelSizeMm: xPix,
            yPixelSizeMm: yPix,
            pngLevel: processPngLevel,
            threadCount: phasedThreads,
            useGpuBatch: useMegaBatchGpu,
          );

          if (chunkResults == null || chunkResults.length != chunk.length) {
            phasedFailed = true;
            break;
          }

          final gpuBatchOk = nativeBatch.lastGpuBatchOk != 0;
          processingEngine =
              gpuBatchOk ? 'Phased GPU Mega-Batch' : 'Phased CPU';

          for (final r in chunkResults) {
            layerImages.add(r.pngBytes);
            layerAreas.add(r.areaInfo);
          }

          done = end;
          progress(done, info.layerCount,
              'Processing layers (phased)... [$processingEngine]',
              workers: phasedThreads, force: true);
          while (done >= nextLog && nextLog <= info.layerCount) {
            log('  Layer $nextLog/${info.layerCount}');
            nextLog += logStep;
          }
          if (done == info.layerCount) {
            log('  Layer $done/${info.layerCount}');
          }
        }

        if (!phasedFailed && done == info.layerCount) {
          usedNativeBatch = true;
          log('Phased pipeline complete ($processingEngine).');
        } else {
          log('Phased pipeline failed at layer $done '
              '— falling back to chunked pipeline.');
          layerImages.clear();
          layerAreas.clear();
        }

        // Restore GPU state for chunked fallback
        if (useMegaBatchGpu && !gpuAccelActive) {
          gpu.setPreferredBackend(0);
          gpu.setEnabled(false);
        }
      }

      // ── Chunked pipeline fallback (original path) ──
      if (!usedNativeBatch && nativeBatch.available) {
        progress(
          0,
          info.layerCount,
          'Processing layers... [$processingEngine]',
          workers: processingMaxConcurrency,
          force: true,
        );

        // Process in medium native batches for smoother progress feedback
        // while keeping threading entirely in C.
        final nativeChunkSize = info.layerCount < 120
          ? 24
          : info.layerCount < 500
            ? 48
            : info.layerCount < 1500
              ? 64
              : 96;

        int done = 0;
        final chunkLogStep = (info.layerCount ~/ 4).clamp(1, info.layerCount);
        int nextChunkLog = chunkLogStep;
        for (int start = 0; start < info.layerCount; start += nativeChunkSize) {
          final end = math.min(start + nativeChunkSize, info.layerCount);
          late final List<Uint8List> chunk;
          if (shouldPreload) {
            chunk = rawLayers.sublist(start, end);
          } else {
            final chunkReadSw = Stopwatch()..start();
            chunk = await _readRawLayerRange(parser, start, end);
            chunkReadSw.stop();
            readStreamingTime += chunkReadSw.elapsed;
          }

          nativeBatch.setBatchThreads(processingMaxConcurrency);
          final chunkResults = nativeBatch.processBatch(
            rawLayers: chunk,
            layerIndexBase: start,
            encryptionKey: parser.encryptionKey,
            srcWidth: info.resolutionX,
            height: info.resolutionY,
            outWidth: outWidth,
            channels: outChannels,
            xPixelSizeMm: xPix,
            yPixelSizeMm: yPix,
            pngLevel: processPngLevel,
            threadCount: processingMaxConcurrency,
          );

          if (chunkResults == null || chunkResults.length != chunk.length) {
            usedNativeBatch = false;
            break;
          }

          processingEngine = nativeBatch.lastBackendName;
          processingGpuAttempts += nativeBatch.lastGpuAttempts;
          processingGpuSuccesses += nativeBatch.lastGpuSuccesses;
          processingGpuFallbacks += nativeBatch.lastGpuFallbacks;
          if (analyticsEnabled) {
            analytics.addNativeStats(nativeBatch.getLastThreadStats());
          }

          usedNativeBatch = true;
          for (final r in chunkResults) {
            layerImages.add(r.pngBytes);
            layerAreas.add(r.areaInfo);
          }

          done = end;
          progress(done, info.layerCount, 'Processing layers... [$processingEngine]',
              workers: processingMaxConcurrency, force: true);
          while (done >= nextChunkLog && nextChunkLog <= info.layerCount) {
            log('  Layer $nextChunkLog/${info.layerCount}');
            nextChunkLog += chunkLogStep;
          }
          if (done == info.layerCount) {
            log('  Layer $done/${info.layerCount}');
          }
        }
      }

      if (!usedNativeBatch) {
        layerImages.clear();
        layerAreas.clear();
        processingEngine = 'CPU Dart';
        log('Processing engine fallback: $processingEngine');

        late final List<Uint8List> rawLayersForFallback;
        if (shouldPreload) {
          rawLayersForFallback = rawLayers;
        } else {
          final chunkReadSw = Stopwatch()..start();
          rawLayersForFallback =
              await _readRawLayerRange(parser, 0, info.layerCount);
          chunkReadSw.stop();
          readStreamingTime += chunkReadSw.elapsed;
        }

        final tasks = <LayerTaskParams>[];
        for (int i = 0; i < info.layerCount; i++) {
          tasks.add(LayerTaskParams(
            layerIndex: i,
            rawRleData: rawLayersForFallback[i],
            encryptionKey: parser.encryptionKey,
            resolutionX: info.resolutionX,
            resolutionY: info.resolutionY,
            xPixelSizeMm: xPix,
            yPixelSizeMm: yPix,
            boardTypeIndex: targetProfile.board.index,
            targetWidth: targetProfile.pngOutputWidth,
            pngLevel: processPngLevel,
          ));
        }

        int? processingWorkers;
        final results = await processLayersParallel(
          tasks: tasks,
          maxConcurrency: processingMaxConcurrency,
          onWorkersReady: (workers) {
            processingWorkers = workers;
            progress(
              0,
              info.layerCount,
              'Processing layers... [$processingEngine]',
              workers: processingWorkers,
              force: true,
            );
          },
          onLayerComplete: (done, total) {
            progress(done, total, 'Processing layers... [$processingEngine]',
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
      }

      processingPhaseSw.stop();
      analytics.addStage('process', processingPhaseSw.elapsed);
      if (!shouldPreload && readStreamingTime.inMicroseconds > 0) {
        analytics.addStage('read', readStreamingTime);
      }
      log('Processing phase finished in '
          '${(processingPhaseSw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s '
          '[$processingEngine].');
        if (processingGpuAttempts > 0) {
        final usagePct =
          ((processingGpuSuccesses * 100.0) / processingGpuAttempts).toStringAsFixed(1);
          final cudaErr = nativeBatch.lastCudaError;
        log('Processing GPU usage: $processingGpuSuccesses/$processingGpuAttempts '
            '(${usagePct}%, fallbacks: $processingGpuFallbacks, cuda_err: $cudaErr).');
        }

      if (shouldPreload) {
        rawLayers.clear(); // free memory
      }

      // ── 3b. Recompress PNGs adaptively (expensive pass) ───
      progress(0, info.layerCount, 'Preparing compression pass...', force: true);
        final recompressModeRaw = _settingString(
          settings,
          'recompressMode',
          envKey: 'VOXELSHIFT_RECOMPRESS_MODE',
        );
        final recompressMode =
          ((recompressModeRaw == null || recompressModeRaw.trim().isEmpty) && fastMode
              ? 'off'
              : (recompressModeRaw ?? 'adaptive'))
              .toLowerCase()
              .trim();
      final shouldRecompress = switch (recompressMode) {
        'off' || 'false' || '0' => false,
        'on' || 'true' || '1' || 'force' => true,
        _ => _shouldRecompressLayers(layerImages, log),
      };

      if (!shouldRecompress && recompressMode != 'adaptive') {
        log('Skipping PNG recompression (mode: $recompressMode).');
      }

      if (shouldRecompress) {
        final recompressSw = Stopwatch()..start();
        log('Recompressing ${layerImages.length} PNGs (adaptive pass)...');
        final recompressWorkers = _positiveEnvInt('VOXELSHIFT_RECOMPRESS_WORKERS') ??
            _nativeWorkerTarget(
              layerCount: layerImages.length,
              gpuActive: false,
              settings: settings,
            );
        int? compressWorkers;
        final compressStep = (info.layerCount ~/ 4).clamp(1, info.layerCount);
        int nextCompressLog = compressStep;
        progress(0, info.layerCount, 'Compressing PNGs...', force: true);
        final recompressed = await recompressPngsParallel(
          pngs: layerImages,
          maxConcurrency: recompressWorkers,
          onWorkersReady: (workers) {
            compressWorkers = workers;
            progress(
              0,
              info.layerCount,
              'Compressing PNGs...',
              workers: compressWorkers,
              force: true,
            );
          },
          onProgress: (done, total) {
            progress(done, total, 'Compressing PNGs...',
                workers: compressWorkers);
            while (done >= nextCompressLog && nextCompressLog <= total) {
              log('  Compressed $nextCompressLog/$total');
              nextCompressLog += compressStep;
            }
            if (done == total) {
              log('  Compressed $done/$total');
            }
          },
        );
        for (int i = 0; i < recompressed.length; i++) {
          layerImages[i] = recompressed[i];
        }
        recompressSw.stop();
        analytics.addStage('recompress', recompressSw.elapsed);
        log('Recompression phase finished in '
            '${(recompressSw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s.');
      } else {
        log('Skipping PNG recompression (expected gain too small).');
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
      final writeSw = Stopwatch()..start();
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
      writeSw.stop();
      analytics.addStage('write', writeSw.elapsed);

      sw.stop();
      final fileSize = await File(outputPath).length();

      log('Conversion complete: $outputPath '
          '(${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB) '
          'in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');

      if (analyticsEnabled) {
        port.send(WorkerAnalyticsUpdate(analytics.toMap(
          cpuCores: Platform.numberOfProcessors,
          workers: processingMaxConcurrency,
          processingEngine: processingEngine,
          gpuActive: gpuAccelActive,
          gpuAttempts: processingGpuAttempts,
          gpuSuccesses: processingGpuSuccesses,
          gpuFallbacks: processingGpuFallbacks,
        )));
      }

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

String? _settingString(
  Map<String, dynamic> settings,
  String key, {
  String? envKey,
}) {
  final v = settings[key];
  if (v is String && v.trim().isNotEmpty) return v;
  if (envKey == null) return null;
  final env = Platform.environment[envKey];
  if (env == null || env.trim().isEmpty) return null;
  return env;
}

bool _settingBool(
  Map<String, dynamic> settings,
  String key, {
  String? envKey,
  bool defaultValue = false,
}) {
  final v = settings[key];
  if (v is bool) return v;
  if (envKey == null) return false;
  final env = Platform.environment[envKey];
  if (env == null || env.trim().isEmpty) return defaultValue;
  return _envIsTruthy(envKey);
}

int? _settingInt(
  Map<String, dynamic> settings,
  String key, {
  String? envKey,
}) {
  final v = settings[key];
  if (v is int && v > 0) return v;
  if (envKey == null) return null;
  return _positiveEnvInt(envKey);
}

BenchmarkCacheEntry? _benchmarkCacheEntry(
  Map<String, dynamic> cache,
  String key,
) {
  final raw = cache[key];
  if (raw is Map) {
    return BenchmarkCacheEntry.fromJson(Map<String, dynamic>.from(raw));
  }
  return null;
}

bool _benchmarkCacheStale(BenchmarkCacheEntry entry) {
  const ttlDays = 30;
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final ageMs = nowMs - entry.updatedAtMs;
  return ageMs < 0 || ageMs > ttlDays * 24 * 60 * 60 * 1000;
}

String _benchmarkCacheKey({
  required SliceFileInfo info,
  required PrinterProfile profile,
  required int backend,
  required String gpuName,
  required int cpuCores,
  required int outWidth,
  required int outChannels,
}) {
  final gpu = gpuName.trim().isEmpty ? 'unknown' : gpuName.trim();
  return 'b=$backend;gpu=$gpu;cpu=$cpuCores;'
      'res=${info.resolutionX}x${info.resolutionY};'
      'out=${outWidth}x${info.resolutionY};'
      'ch=$outChannels;profile=${profile.name}';
}

Future<List<Uint8List>> _readRawLayerRange(
  CtbParser parser,
  int start,
  int end,
) async {
  final out = <Uint8List>[];
  if (end <= start) return out;
  for (int i = start; i < end; i++) {
    out.add(await parser.readRawLayerData(i));
  }
  return out;
}

bool _envIsTruthy(String key) {
  final v = (Platform.environment[key] ?? '').toLowerCase();
  return v == '1' || v == 'true' || v == 'yes' || v == 'on';
}

int? _positiveEnvInt(String key) {
  final raw = Platform.environment[key];
  if (raw == null) return null;
  final parsed = int.tryParse(raw.trim());
  if (parsed == null || parsed <= 0) return null;
  return parsed;
}

double? _positiveEnvDouble(String key) {
  final raw = Platform.environment[key];
  if (raw == null) return null;
  final parsed = double.tryParse(raw.trim());
  if (parsed == null || parsed <= 0) return null;
  return parsed;
}

int _nativeWorkerTarget({
  required int layerCount,
  required bool gpuActive,
  Map<String, dynamic>? settings,
}) {
  final directOverride = _settingInt(
    settings ?? const {},
    gpuActive ? 'gpuHostWorkers' : 'cpuHostWorkers',
    envKey: gpuActive ? 'VOXELSHIFT_GPU_HOST_WORKERS' : 'VOXELSHIFT_CPU_HOST_WORKERS',
  );
  if (directOverride != null) {
    return directOverride.clamp(1, math.max(1, layerCount));
  }

  final cores = math.max(1, Platform.numberOfProcessors);
  final defaultMultiplier = gpuActive ? 1.0 : 2.0;
  final multiplier = _positiveEnvDouble(
        gpuActive ? 'VOXELSHIFT_GPU_WORKER_MULTIPLIER' : 'VOXELSHIFT_CPU_WORKER_MULTIPLIER',
      ) ??
      defaultMultiplier;

  final minThreads = gpuActive ? 2 : 4;
  final computed = (cores * multiplier).round();
  return computed.clamp(minThreads, math.max(minThreads, layerCount));
}

String _processingEngineLabel(bool gpuActive, int backendCode) {
  if (!gpuActive) return 'CPU Native';
  switch (backendCode) {
    case 3:
      return 'GPU CUDA/Tensor';
    case 1:
      return 'GPU OpenCL';
    case 2:
      return 'GPU Metal';
    default:
      return 'CPU Native';
  }
}

bool _shouldRecompressLayers(
  List<Uint8List> pngs,
  void Function(String) log,
) {
  if (pngs.isEmpty) return false;

  // Tiny files are usually the 1x1 blank PNG fast-path; no need to recompress.
  int candidateCount = 0;
  int sampleOriginalTotal = 0;
  int sampleRecompressedTotal = 0;

  const int maxSamples = 8;
  final sampleCount = math.min(maxSamples, pngs.length);
  final step = math.max(1, (pngs.length / sampleCount).floor());

  for (int i = 0; i < pngs.length && candidateCount < sampleCount; i += step) {
    final original = pngs[i];
    if (original.length < 256) {
      continue;
    }

    final recompressed = recompressPng(original);
    sampleOriginalTotal += original.length;
    sampleRecompressedTotal += recompressed.length;
    candidateCount++;
  }

  if (candidateCount == 0 || sampleOriginalTotal == 0) {
    return false;
  }

  final savingsRatio =
      (sampleOriginalTotal - sampleRecompressedTotal) / sampleOriginalTotal;
  final projectedSavingsMb =
      (pngs.length * (sampleOriginalTotal - sampleRecompressedTotal) / candidateCount) /
          (1024 * 1024);

  log('Recompression sample: ${(savingsRatio * 100).toStringAsFixed(1)}% '
      'estimated savings (~${projectedSavingsMb.toStringAsFixed(1)} MB).');

  // Run expensive pass only if savings are meaningful.
  // For very large jobs, require stronger benefit to protect throughput.
  if (pngs.length >= 2000) {
    return savingsRatio >= 0.08 || projectedSavingsMb >= 150;
  }

  return savingsRatio >= 0.04 || projectedSavingsMb >= 25;
}
