import 'package:flutter/material.dart';

import '../../core/conversion/conversion_analytics.dart';

class AnalyticsOverlay extends StatefulWidget {
  final ConversionAnalytics analytics;
  final VoidCallback onClose;

  const AnalyticsOverlay({
    super.key,
    required this.analytics,
    required this.onClose,
  });

  @override
  State<AnalyticsOverlay> createState() => _AnalyticsOverlayState();
}

class _AnalyticsOverlayState extends State<AnalyticsOverlay> {
  bool _compact = true;

  String _fmtDuration(Duration d) {
    if (d.inMilliseconds >= 1000) {
      return '${(d.inMilliseconds / 1000).toStringAsFixed(2)}s';
    }
    return '${d.inMilliseconds}ms';
  }

  @override
  Widget build(BuildContext context) {
    final stagePercent = widget.analytics.stagePercentages;
    final workerTimings = widget.analytics.workerTimings
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    // Only consider active workers for color gradient normalization
    final activeWorkers = workerTimings.where((w) => w.layers > 0).toList();
    final minWorkerLayers = activeWorkers.isEmpty
        ? 0
        : activeWorkers
            .map((w) => w.layers)
            .reduce((a, b) => a < b ? a : b);
    final maxWorkerLayers = activeWorkers.isEmpty
        ? 0
        : activeWorkers
            .map((w) => w.layers)
            .reduce((a, b) => a > b ? a : b);

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 700),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF141D2E).withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.query_stats, size: 18, color: Colors.cyan),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Analytics',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _compact ? Icons.unfold_more : Icons.unfold_less,
                      size: 18,
                    ),
                    color: Colors.white.withValues(alpha: 0.7),
                    onPressed: () => setState(() => _compact = !_compact),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: Colors.white.withValues(alpha: 0.7),
                    onPressed: widget.onClose,
                  )
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _kv('Engine', widget.analytics.processingEngine),
                      _kv(
                        'Workers',
                        '${widget.analytics.workers} '
                        '(cores ${widget.analytics.cpuCores})',
                      ),
                      if ((widget.analytics.cpuName ?? '').isNotEmpty)
                        _kv('CPU', widget.analytics.cpuName!),
                      if (widget.analytics.gpuAttempts > 0)
                        _kv(
                          'GPU usage',
                          '${widget.analytics.gpuSuccesses}/'
                          '${widget.analytics.gpuAttempts} '
                          '(${(widget.analytics.gpuSuccesses * 100 / widget.analytics.gpuAttempts).toStringAsFixed(1)}%) '
                          'fallbacks ${widget.analytics.gpuFallbacks}',
                        ),
                      const SizedBox(height: 8),
                      _sectionTitle('Stages'),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final columnWidth =
                              (constraints.maxWidth - 12) / 2;
                          const stageOrder = [
                            'open',
                            'read',
                            'process',
                            'recompress',
                            'write',
                          ];
                          final stageMap = widget.analytics.stages;
                          final stageEntries = <MapEntry<String, Duration>>[
                            for (final key in stageOrder)
                              if (stageMap.containsKey(key))
                                MapEntry(key, stageMap[key]!),
                            ...stageMap.entries
                                .where((e) => !stageOrder.contains(e.key)),
                          ];
                          final recompressIndex = stageEntries
                              .indexWhere((e) => e.key == 'recompress');
                          final insertIndex = recompressIndex >= 0
                              ? recompressIndex + 1
                              : stageEntries.length;
                          stageEntries.insert(
                            insertIndex,
                            MapEntry(
                              'total',
                              widget.analytics.totalStageTime,
                            ),
                          );
                          return Wrap(
                            spacing: 12,
                            runSpacing: 6,
                            children: stageEntries
                                .map(
                                  (e) => SizedBox(
                                    width: columnWidth,
                                    child: _kv(
                                      e.key,
                                      '${_fmtDuration(e.value)} • '
                                      '${(stagePercent[e.key] ?? 0).toStringAsFixed(1)}%',
                                      labelWidth: 78,
                                      fontSize: 12,
                                      dense: true,
                                    ),
                                  ),
                                )
                                .toList(),
                          );
                        },
                      ),
                      const SizedBox(height: 10),
                      Divider(
                        height: 16,
                        thickness: 1,
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                      const SizedBox(height: 2),
                      _sectionTitle('Worker timings'),
                      if (workerTimings.isEmpty)
                        Text(
                          'Per-worker timings unavailable for this run.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.6),
                          ),
                        )
                      else
                        _compact
                            ? _workerBars(
                                workerTimings,
                                minWorkerLayers,
                                maxWorkerLayers,
                              )
                            : LayoutBuilder(
                                builder: (context, constraints) {
                                  const columnGap = 12.0;
                                  final left = <WorkerTiming>[];
                                  final right = <WorkerTiming>[];
                                  for (var i = 0;
                                      i < workerTimings.length;
                                      i++) {
                                    if (i.isEven) {
                                      left.add(workerTimings[i]);
                                    } else {
                                      right.add(workerTimings[i]);
                                    }
                                  }
                                  return Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          children: _buildWorkerColumn(
                                            left,
                                            minWorkerLayers,
                                            maxWorkerLayers,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: columnGap),
                                      Expanded(
                                        child: Column(
                                          children: _buildWorkerColumn(
                                            right,
                                            minWorkerLayers,
                                            maxWorkerLayers,
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                      const SizedBox(height: 8),
                      Divider(
                        height: 16,
                        thickness: 1,
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                      const SizedBox(height: 2),
                      _sectionTitle('Auto-diagnosis'),
                      if (widget.analytics.diagnosis.isEmpty)
                        Text(
                          'No issues detected.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.6),
                          ),
                        )
                      else
                        ...widget.analytics.diagnosis.map(
                          (d) => Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${d.title} (${d.score.toStringAsFixed(0)}%)',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  d.detail,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white.withValues(alpha: 0.65),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _kv(
    String k,
    String v, {
    double labelWidth = 150,
    double fontSize = 13,
    double? valueFontSize,
    bool dense = false,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 1 : 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              k,
              style: TextStyle(
                fontSize: fontSize,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: TextStyle(fontSize: valueFontSize ?? fontSize),
            ),
          ),
        ],
      ),
    );
  }

  Widget _workerRow(
    WorkerTiming w,
    int minLayers,
    int maxLayers,
  ) {
    // Scale gradient so only >25% deviation shows as red
    final deviation = (maxLayers - minLayers) <= 0
        ? 0.0
        : ((maxLayers - w.layers) / maxLayers);
    final t = (deviation / 0.25).clamp(0.0, 1.0);
    final hasLayers = w.layers > 0;
    final color = hasLayers
      ? (Color.lerp(Colors.greenAccent, Colors.redAccent, t) ??
        Colors.greenAccent)
      : Colors.white.withValues(alpha: 0.35);

    const labelWidth = 92.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: labelWidth,
                child: Text(
                  'Worker #${w.index + 1}',
                  style: TextStyle(
                    fontSize: 12,
                    color: hasLayers
                        ? color.withValues(alpha: 0.95)
                        : Colors.white.withValues(alpha: 0.5),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  '${_fmtDuration(w.total)} • ${w.layers} layers',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: labelWidth),
            child: Text(
              '${w.avgMsPerLayer.toStringAsFixed(2)} ms/layer',
              style: TextStyle(
                fontSize: 11,
                color: hasLayers
                    ? color.withValues(alpha: 0.85)
                    : Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _workerBars(
    List<WorkerTiming> items,
    int minLayers,
    int maxLayers,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const columnGap = 12.0;
        final left = <WorkerTiming>[];
        final right = <WorkerTiming>[];
        for (var i = 0; i < items.length; i++) {
          if (i.isEven) {
            left.add(items[i]);
          } else {
            right.add(items[i]);
          }
        }

        Widget buildBars(List<WorkerTiming> list) {
          final bars = <Widget>[];
          for (var i = 0; i < list.length; i++) {
            final w = list[i];
            // Scale gradient so only >25% deviation shows as red
            final deviation = (maxLayers - minLayers) <= 0
                ? 0.0
                : ((maxLayers - w.layers) / maxLayers);
            final t = (deviation / 0.25).clamp(0.0, 1.0);
            final hasLayers = w.layers > 0;
            final color = hasLayers
              ? (Color.lerp(Colors.greenAccent, Colors.redAccent, t) ??
                Colors.greenAccent)
              : Colors.white.withValues(alpha: 0.35);
            final labelColor = color.computeLuminance() > 0.6
              ? const Color(0xFF0B0F1A)
              : Colors.white;
            final widthFactor = maxLayers == 0
              ? 0.0
              : (w.layers / maxLayers).clamp(0.04, 1.0);
            bars.add(
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    height: 16,
                    color: Colors.white.withValues(alpha: 0.08),
                    child: Stack(
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: widthFactor,
                            child: Container(
                              color: color.withValues(alpha: 0.9),
                            ),
                          ),
                        ),
                        Center(
                          child: Text(
                            '${w.index + 1}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: hasLayers
                                  ? labelColor.withValues(alpha: 0.9)
                                  : Colors.white.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }
          return Column(children: bars);
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: buildBars(left)),
            const SizedBox(width: columnGap),
            Expanded(child: buildBars(right)),
          ],
        );
      },
    );
  }

  List<Widget> _buildWorkerColumn(
    List<WorkerTiming> items,
    int minLayers,
    int maxLayers,
  ) {
    const itemGap = 8.0;
    final widgets = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      widgets.add(
        _workerRow(
          items[i],
          minLayers,
          maxLayers,
        ),
      );
      if (i != items.length - 1) {
        widgets.add(const SizedBox(height: itemGap));
      }
    }
    return widgets;
  }
}
