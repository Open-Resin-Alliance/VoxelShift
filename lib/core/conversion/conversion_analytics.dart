import 'package:flutter/foundation.dart';

class AnalyticsBus {
  static final ValueNotifier<bool> enabled = ValueNotifier(false);
  static final ValueNotifier<ConversionAnalytics?> latest =
      ValueNotifier<ConversionAnalytics?>(null);

  static void toggle() => enabled.value = !enabled.value;

  static void update(ConversionAnalytics? report) {
    latest.value = report;
  }
}

class WorkerTiming {
  final int index;
  final int layers;
  final Duration total;
  final Duration decode;
  final Duration scanline;
  final Duration compress;
  final Duration png;

  const WorkerTiming({
    required this.index,
    required this.layers,
    required this.total,
    required this.decode,
    required this.scanline,
    required this.compress,
    required this.png,
  });

  double get avgMsPerLayer =>
      layers <= 0 ? 0 : total.inMicroseconds / 1000.0 / layers;
}

class DiagnosisItem {
  final String title;
  final String detail;
  final double score;

  const DiagnosisItem({
    required this.title,
    required this.detail,
    required this.score,
  });
}

class ConversionAnalytics {
  final DateTime capturedAt;
  final String? cpuName;
  final int cpuCores;
  final int workers;
  final String processingEngine;
  final bool gpuActive;
  final int gpuAttempts;
  final int gpuSuccesses;
  final int gpuFallbacks;
  final Map<String, Duration> stages;
  final Map<String, Duration> nativeStages;
  final List<WorkerTiming> workerTimings;
  final List<DiagnosisItem> diagnosis;

  const ConversionAnalytics({
    required this.capturedAt,
    required this.cpuName,
    required this.cpuCores,
    required this.workers,
    required this.processingEngine,
    required this.gpuActive,
    required this.gpuAttempts,
    required this.gpuSuccesses,
    required this.gpuFallbacks,
    required this.stages,
    required this.nativeStages,
    required this.workerTimings,
    required this.diagnosis,
  });

  Duration get totalStageTime =>
      stages.values.fold(Duration.zero, (acc, d) => acc + d);

  Map<String, double> get stagePercentages {
    final totalMs = totalStageTime.inMilliseconds.toDouble();
    if (totalMs <= 0) return {};
    return stages.map(
      (k, v) => MapEntry(k, (v.inMilliseconds.toDouble() / totalMs) * 100.0),
    );
  }

  static ConversionAnalytics fromWorkerMap(Map<String, dynamic> data) {
    final stageNs = Map<String, dynamic>.from(data['stagesNs'] as Map? ?? {});
    final nativeStageNs = Map<String, dynamic>.from(
      data['nativeStagesNs'] as Map? ?? {},
    );
    Duration _durFromNs(dynamic v) {
      final ns = (v is int) ? v : int.tryParse('$v') ?? 0;
      return Duration(microseconds: (ns / 1000).round());
    }

    final stages = stageNs.map((k, v) => MapEntry(k, _durFromNs(v)));
    final nativeStages = nativeStageNs.map(
      (k, v) => MapEntry(k, _durFromNs(v)),
    );

    final workersRaw = data['threadStats'] as List? ?? const [];
    final workerTimings = <WorkerTiming>[];
    for (int i = 0; i < workersRaw.length; i++) {
      final entry = Map<String, dynamic>.from(workersRaw[i] as Map);
      workerTimings.add(
        WorkerTiming(
          index: entry['index'] as int? ?? i,
          layers: entry['layers'] as int? ?? 0,
          total: _durFromNs(entry['totalNs']),
          decode: _durFromNs(entry['decodeNs']),
          scanline: _durFromNs(entry['scanlineNs']),
          compress: _durFromNs(entry['compressNs']),
          png: _durFromNs(entry['pngNs']),
        ),
      );
    }

    final analytics = ConversionAnalytics(
      capturedAt: DateTime.now(),
      cpuName: data['cpuName'] as String?,
      cpuCores: data['cpuCores'] as int? ?? 0,
      workers: data['workers'] as int? ?? 0,
      processingEngine: data['processingEngine'] as String? ?? 'Unknown',
      gpuActive: data['gpuActive'] as bool? ?? false,
      gpuAttempts: data['gpuAttempts'] as int? ?? 0,
      gpuSuccesses: data['gpuSuccesses'] as int? ?? 0,
      gpuFallbacks: data['gpuFallbacks'] as int? ?? 0,
      stages: stages,
      nativeStages: nativeStages,
      workerTimings: workerTimings,
      diagnosis: const [],
    );

    final diagnosis = _analyze(analytics);
    return ConversionAnalytics(
      capturedAt: analytics.capturedAt,
      cpuName: analytics.cpuName,
      cpuCores: analytics.cpuCores,
      workers: analytics.workers,
      processingEngine: analytics.processingEngine,
      gpuActive: analytics.gpuActive,
      gpuAttempts: analytics.gpuAttempts,
      gpuSuccesses: analytics.gpuSuccesses,
      gpuFallbacks: analytics.gpuFallbacks,
      stages: analytics.stages,
      nativeStages: analytics.nativeStages,
      workerTimings: analytics.workerTimings,
      diagnosis: diagnosis,
    );
  }

  ConversionAnalytics withCpuName(String? name) {
    return ConversionAnalytics(
      capturedAt: capturedAt,
      cpuName: name,
      cpuCores: cpuCores,
      workers: workers,
      processingEngine: processingEngine,
      gpuActive: gpuActive,
      gpuAttempts: gpuAttempts,
      gpuSuccesses: gpuSuccesses,
      gpuFallbacks: gpuFallbacks,
      stages: stages,
      nativeStages: nativeStages,
      workerTimings: workerTimings,
      diagnosis: diagnosis,
    );
  }

  /// Calculate optimal worker count based on actual performance.
  /// Returns the number of workers that processed meaningful work.
  int calculateOptimalWorkerCount({double maxMultiplier = 2.0}) {
    if (workerTimings.isEmpty) return cpuCores;

    final activeWorkers = workerTimings.where((w) => w.layers > 0).toList();
    if (activeWorkers.isEmpty) return cpuCores;

    final layerCounts = activeWorkers.map((w) => w.layers).toList();
    final maxLayers = layerCounts.reduce((a, b) => a > b ? a : b);

    // Count workers that processed at least 80% of max layers
    final efficientWorkers = activeWorkers
        .where((w) => w.layers >= maxLayers * 0.8)
        .length;

    // Return efficient count, but clamp to reasonable range
    return efficientWorkers.clamp(
      (cpuCores * 0.5).ceil(), // At least 50% of cores
      (cpuCores * maxMultiplier).ceil(), // User-configurable cap
    );
  }
}

List<DiagnosisItem> _analyze(ConversionAnalytics a) {
  final items = <DiagnosisItem>[];
  final cores = a.cpuCores <= 0 ? 1 : a.cpuCores;
  final workers = a.workers;
  final suggestedWorkers = cores;
  final workerDelta = (workers - suggestedWorkers).abs();
  final workerDeltaPct = suggestedWorkers <= 0
      ? 0.0
      : (workerDelta / suggestedWorkers) * 100.0;
  final suggestion = DiagnosisItem(
    title: 'Suggested worker count',
    detail: workers == suggestedWorkers
        ? 'Workers ($workers) match logical cores ($cores).'
        : 'For $cores logical cores, try ~$suggestedWorkers workers '
              '(current: $workers).',
    score: workerDeltaPct.clamp(0, 100).toDouble(),
  );

  if (workers > cores) {
    final ratio = workers / cores;
    final score = ((ratio - 1.0) * 65).clamp(0, 100).toDouble();
    if (score >= 10) {
      items.add(
        DiagnosisItem(
          title: 'Worker oversubscription',
          detail:
              'Workers ($workers) exceed logical cores ($cores). '
              'High context switching can reduce throughput.',
          score: score,
        ),
      );
    }
  }

  if (a.workerTimings.isNotEmpty) {
    final activeWorkers = a.workerTimings.where((w) => w.layers > 0).toList();
    final totals = activeWorkers.map((w) => w.total.inMilliseconds.toDouble());
    if (totals.isNotEmpty) {
      final max = totals.reduce((v, e) => v > e ? v : e);
      final min = totals.reduce((v, e) => v < e ? v : e);
      if (min > 0) {
        final imbalance = max / min;
        final score = ((imbalance - 1.0) * 60).clamp(0, 100).toDouble();
        if (score >= 12) {
          items.add(
            DiagnosisItem(
              title: 'Load imbalance',
              detail:
                  'Worker time spread suggests uneven chunking or contention.',
              score: score,
            ),
          );
        }
      }
    }

    // Layer count distribution analysis to detect drop-off point
    if (activeWorkers.length >= 3) {
      final layerCounts = activeWorkers.map((w) => w.layers).toList();
      final maxLayers = layerCounts.reduce((a, b) => a > b ? a : b);
      final minLayers = layerCounts.reduce((a, b) => a < b ? a : b);
      final avgLayers =
          layerCounts.reduce((a, b) => a + b) / layerCounts.length;
      final layerRange = maxLayers - minLayers;
      final deviationPct = maxLayers > 0 ? (layerRange / maxLayers) * 100 : 0.0;

      if (deviationPct > 5) {
        // Count workers significantly below peak (less than 80% of max)
        final slowWorkers = activeWorkers
            .where((w) => w.layers < maxLayers * 0.8)
            .toList();

        // Only recommend reducing if 3+ workers are significantly underutilized
        if (slowWorkers.length >= 3) {
          final efficientCount = activeWorkers.length - slowWorkers.length;
          items.add(
            DiagnosisItem(
              title: 'Worker efficiency drop-off',
              detail:
                  'Layer distribution: ${minLayers}-${maxLayers} (${deviationPct.toStringAsFixed(1)}% spread). '
                  '${slowWorkers.length} of ${activeWorkers.length} workers processed <80% of max. '
                  'Consider reducing to ~$efficientCount workers for better balance.',
              score: (deviationPct * 3).clamp(0, 100).toDouble(),
            ),
          );
        } else if (deviationPct > 15) {
          // High deviation but few slow workers - just show info
          items.add(
            DiagnosisItem(
              title: 'Worker load variation',
              detail:
                  'Layer distribution: ${minLayers}-${maxLayers} (${deviationPct.toStringAsFixed(1)}% spread). '
                  'Distribution is uneven but most workers are productive.',
              score: (deviationPct * 2).clamp(0, 100).toDouble(),
            ),
          );
        }
      }
    }
  }

  double _stagePct(String key) {
    final totalMs = a.totalStageTime.inMilliseconds.toDouble();
    if (totalMs <= 0) return 0;
    return (a.stages[key]?.inMilliseconds.toDouble() ?? 0) / totalMs;
  }

  final processPct = _stagePct('process');
  final readPct = _stagePct('read');
  final writePct = _stagePct('write');
  final recompressPct = _stagePct('recompress');

  if (readPct > 0.35) {
    items.add(
      DiagnosisItem(
        title: 'I/O bound (read)',
        detail:
            'Reading layers dominates runtime. Consider preload, faster disk, '
            'or smaller chunk sizes for streaming.',
        score: (readPct * 100).clamp(0, 100).toDouble(),
      ),
    );
  }

  if (writePct > 0.30) {
    items.add(
      DiagnosisItem(
        title: 'I/O bound (write)',
        detail:
            'Writing the NanoDLP ZIP dominates runtime. Fast storage or '
            'lower PNG compression can help.',
        score: (writePct * 100).clamp(0, 100).toDouble(),
      ),
    );
  }

  if (recompressPct > 0.25) {
    items.add(
      DiagnosisItem(
        title: 'Recompression overhead',
        detail:
            'Recompress pass is expensive. Try recompress mode “adaptive/off”.',
        score: (recompressPct * 100).clamp(0, 100).toDouble(),
      ),
    );
  }

  final nativeTotalMs = a.nativeStages.values.fold(
    0.0,
    (acc, d) => acc + d.inMilliseconds.toDouble(),
  );
  if (nativeTotalMs > 0) {
    double nativePct(String key) {
      final v = a.nativeStages[key]?.inMilliseconds.toDouble() ?? 0;
      return v / nativeTotalMs;
    }

    final compressPct = nativePct('compress');
    final scanPct = nativePct('scanline');

    if (compressPct > 0.45) {
      items.add(
        DiagnosisItem(
          title: 'Compression bottleneck',
          detail:
              'Zlib compression dominates native time. Reduce PNG level '
              'or enable fast mode.',
          score: (compressPct * 100).clamp(0, 100).toDouble(),
        ),
      );
    }

    if (scanPct > 0.45) {
      items.add(
        DiagnosisItem(
          title: 'Scanline mapping bottleneck',
          detail: a.gpuActive
              ? 'GPU scanline path dominates. Check GPU usage/fallbacks.'
              : 'CPU scanline path dominates. Consider GPU backend if available.',
          score: (scanPct * 100).clamp(0, 100).toDouble(),
        ),
      );
    }
  }

  if (a.gpuAttempts > 0) {
    final failPct = (a.gpuAttempts - a.gpuSuccesses) / a.gpuAttempts.toDouble();
    if (failPct > 0.15) {
      items.add(
        DiagnosisItem(
          title: 'GPU fallbacks',
          detail:
              'GPU attempts frequently fall back to CPU. Verify drivers or '
              'use CPU native mode.',
          score: (failPct * 100).clamp(0, 100).toDouble(),
        ),
      );
    }
  }

  items.sort((a, b) => b.score.compareTo(a.score));
  final top = items.take(8).toList();
  if (!top.any((item) => item.title == suggestion.title)) {
    top.add(suggestion);
  }
  return top;
}
