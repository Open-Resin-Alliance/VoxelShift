import 'dart:async';
import 'dart:io' show Platform, ZLibDecoder, ZLibEncoder;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/board_type.dart';
import '../models/layer_area_info.dart';
import 'native_area_stats.dart';
import 'native_png_encode.dart';
import 'native_png_recompress.dart';
import 'native_rle_decode.dart';
import 'native_thread_priority.dart';

/// Parameters for processing a single layer in a worker isolate.
///
/// All fields are primitives or typed data so they can be sent
/// across isolate boundaries without issues.
class LayerTaskParams {
  final int layerIndex;
  final Uint8List rawRleData;
  final int encryptionKey;
  final int resolutionX;
  final int resolutionY;
  final double xPixelSizeMm;
  final double yPixelSizeMm;
  final int boardTypeIndex; // BoardType.values index
  final int? targetWidth;
  final int pngLevel;

  const LayerTaskParams({
    required this.layerIndex,
    required this.rawRleData,
    required this.encryptionKey,
    required this.resolutionX,
    required this.resolutionY,
    required this.xPixelSizeMm,
    required this.yPixelSizeMm,
    required this.boardTypeIndex,
    required this.targetWidth,
    this.pngLevel = 1,
  });
}

/// Result from processing a single layer.
class LayerResult {
  final int layerIndex;
  final Uint8List pngBytes;
  final LayerAreaInfo areaInfo;

  const LayerResult({
    required this.layerIndex,
    required this.pngBytes,
    required this.areaInfo,
  });
}

class _RecompressChunkTask {
  final int startIndex;
  final List<Uint8List> pngs;
  final int level;

  const _RecompressChunkTask({
    required this.startIndex,
    required this.pngs,
    required this.level,
  });
}

class _RecompressChunkResult {
  final int startIndex;
  final List<Uint8List> outputs;

  const _RecompressChunkResult({
    required this.startIndex,
    required this.outputs,
  });
}

class _RecompressChunkSpawnParams {
  final _RecompressChunkTask task;
  final SendPort sendPort;

  const _RecompressChunkSpawnParams({
    required this.task,
    required this.sendPort,
  });
}

class _ProcessChunkTask {
  final int startIndex;
  final List<LayerTaskParams> tasks;

  const _ProcessChunkTask({
    required this.startIndex,
    required this.tasks,
  });
}

class _ProcessChunkResult {
  final int startIndex;
  final List<LayerResult> results;

  const _ProcessChunkResult({
    required this.startIndex,
    required this.results,
  });
}

class _ProcessChunkSpawnParams {
  final _ProcessChunkTask task;
  final SendPort sendPort;

  const _ProcessChunkSpawnParams({
    required this.task,
    required this.sendPort,
  });
}

/// Optimal worker count based on available CPU cores.
int get defaultWorkerCount {
  final cores = Platform.numberOfProcessors;
  // Use ~75% of logical cores for conversion workers and keep headroom
  // for UI, filesystem, and native zlib threads.
  return (cores * 0.75).floor().clamp(2, 12);
}

/// Human-readable summary of which native accelerators are active.
String getProcessingEngineLabel() {
  final allNative = NativeRleDecode.instance.available &&
      NativeAreaStats.instance.available &&
      NativePngEncode.instance.available;
  return allNative ? 'Native Mode' : 'Dart Mode';
}

void _processChunkEntry(_ProcessChunkSpawnParams params) {
  // Hint OS scheduler to favor UI thread responsiveness under high worker load.
  NativeThreadPriority.instance.setBackgroundPriority(true);

  final task = params.task;
  final out = <LayerResult>[];
  final len = task.tasks.length;
  final feedbackStride = len <= 8
      ? 1
      : len <= 24
          ? 2
          : len <= 48
              ? 4
              : 8;

  for (int i = 0; i < len; i++) {
    out.add(processLayerSync(task.tasks[i]));

    // Emit lightweight incremental progress for smoother UI-side feedback.
    final done = i + 1;
    if ((done % feedbackStride) == 0 || done == len) {
      params.sendPort.send(done);
    }
  }

  params.sendPort.send(
    _ProcessChunkResult(startIndex: task.startIndex, results: out),
  );
}

Future<_ProcessChunkResult> _processChunkInSubIsolate(
  _ProcessChunkTask task, {
  void Function(int processed)? onProgress,
}) async {
  final receivePort = ReceivePort();
  final completer = Completer<_ProcessChunkResult>();

  receivePort.listen((message) {
    if (message is int) {
      onProgress?.call(message);
      return;
    }

    if (message is _ProcessChunkResult) {
      if (!completer.isCompleted) completer.complete(message);
      receivePort.close();
    }
  });

  await Isolate.spawn(
    _processChunkEntry,
    _ProcessChunkSpawnParams(task: task, sendPort: receivePort.sendPort),
  );

  return completer.future;
}

void _recompressChunkEntry(_RecompressChunkSpawnParams params) {
  // Hint OS scheduler to favor UI thread responsiveness under high worker load.
  NativeThreadPriority.instance.setBackgroundPriority(true);

  final task = params.task;
  final len = task.pngs.length;
  final feedbackStride = len <= 8
      ? 1
      : len <= 24
          ? 2
          : len <= 48
              ? 4
              : 8;

  final batch = NativePngRecompress.instance.recompressBatch(
    task.pngs,
    level: task.level,
  );

  if (batch != null && batch.length == len) {
    for (int i = 0; i < len; i++) {
      final done = i + 1;
      if ((done % feedbackStride) == 0 || done == len) {
        params.sendPort.send(done);
      }
    }
    params.sendPort.send(
      _RecompressChunkResult(startIndex: task.startIndex, outputs: batch),
    );
    return;
  }

  final out = <Uint8List>[];
  for (int i = 0; i < len; i++) {
    out.add(recompressPng(task.pngs[i]));
    final done = i + 1;
    if ((done % feedbackStride) == 0 || done == len) {
      params.sendPort.send(done);
    }
  }

  params.sendPort.send(
    _RecompressChunkResult(startIndex: task.startIndex, outputs: out),
  );
}

Future<_RecompressChunkResult> _recompressChunkInSubIsolate(
  _RecompressChunkTask task, {
  void Function(int processed)? onProgress,
}) async {
  final receivePort = ReceivePort();
  final completer = Completer<_RecompressChunkResult>();

  receivePort.listen((message) {
    if (message is int) {
      onProgress?.call(message);
      return;
    }

    if (message is _RecompressChunkResult) {
      if (!completer.isCompleted) completer.complete(message);
      receivePort.close();
    }
  });

  await Isolate.spawn(
    _recompressChunkEntry,
    _RecompressChunkSpawnParams(task: task, sendPort: receivePort.sendPort),
  );

  return completer.future;
}

/// Process layers in parallel with true N-way concurrency.
///
/// Maintains exactly `concurrencyLimit` in-flight compute() calls at all
/// times.  As each isolate finishes, the next task is dispatched immediately
/// — no serial await bottleneck.
///
/// Concurrency is scaled based on layer count:
///   • Small files (< 100 layers):     3 concurrent compute() calls
///   • Medium files (100-500 layers):  8 concurrent
///   • Large files (> 500 layers):    12 concurrent
///
/// Progress callbacks are debounced to 250ms intervals.
Future<List<LayerResult>> processLayersParallel({
  required List<LayerTaskParams> tasks,
  required int maxConcurrency,
  void Function(int completedCount, int totalCount)? onLayerComplete,
  void Function(int workers)? onWorkersReady,
}) async {
  if (tasks.isEmpty) return [];

  // Adaptive concurrency: scale based on layer count
    final baseConcurrency = tasks.length < 100
      ? 3
      : tasks.length < 500
        ? 8
        : 12;

  final concurrencyLimit =
      math.min(baseConcurrency, math.max(1, maxConcurrency));

  onWorkersReady?.call(concurrencyLimit);
    onLayerComplete?.call(0, tasks.length);

      // Strong chunking to reduce isolate spawn churn during processing.
      // This keeps throughput high while leaving more scheduler headroom for UI.
      final targetWavesPerWorker = tasks.length < 300
        ? 3
        : tasks.length < 1200
          ? 2
          : 2;
    final computedChunkSize =
      (tasks.length / (concurrencyLimit * targetWavesPerWorker)).ceil();
      final chunkSize = math.max(12, math.min(64, computedChunkSize));

  final chunks = <_ProcessChunkTask>[];
  for (int start = 0; start < tasks.length; start += chunkSize) {
    final end = math.min(start + chunkSize, tasks.length);
    chunks.add(_ProcessChunkTask(startIndex: start, tasks: tasks.sublist(start, end)));
  }

  final results = List<LayerResult?>.filled(tasks.length, null);
  int completedCount = 0;
  int nextChunk = 0;
  DateTime lastReportTime = DateTime.now();
  const reportIntervalMs = 250;

  final completer = Completer<void>();

  /// Launch exactly one compute() call. When it finishes, it backfills
  /// the slot by calling launchOne() again.
  void launchOne() {
    if (nextChunk >= chunks.length || completer.isCompleted) return;

    final chunk = chunks[nextChunk++];
    int chunkProgressCount = 0;

    _processChunkInSubIsolate(
      chunk,
      onProgress: (processed) {
        final delta = processed - chunkProgressCount;
        if (delta <= 0) return;

        chunkProgressCount = processed;
        completedCount += delta;

        final now = DateTime.now();
        if (now.difference(lastReportTime).inMilliseconds >= reportIntervalMs ||
            completedCount == tasks.length) {
          onLayerComplete?.call(completedCount, tasks.length);
          lastReportTime = now;
        }
      },
    ).then((chunkResult) {
      for (final result in chunkResult.results) {
        results[result.layerIndex] = result;
      }

      // Guard against missed final progress messages.
      final missing = chunkResult.results.length - chunkProgressCount;
      if (missing > 0) {
        completedCount += missing;
      }

      // Debounced progress reporting
      final now = DateTime.now();
      if (now.difference(lastReportTime).inMilliseconds >= reportIntervalMs ||
          completedCount == tasks.length) {
        onLayerComplete?.call(completedCount, tasks.length);
        lastReportTime = now;
      }

      if (completedCount == tasks.length) {
        if (!completer.isCompleted) completer.complete();
      } else {
        launchOne(); // backfill this slot with the next task
      }
    }).catchError((Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    });
  }

  // Kick off the initial batch — up to concurrencyLimit parallel workers
  final initialBatch = math.min(concurrencyLimit, tasks.length);
  for (int i = 0; i < initialBatch; i++) {
    launchOne();
  }

  await completer.future;
  return results.cast<LayerResult>();
}

// ══════════════════════════════════════════════════════════════
// All code below runs inside worker isolates (top-level functions).
// No Flutter bindings, no UI — pure computation.
//
// Key performance decisions
// ─────────────────────────
//   • Custom PNG encoder — bypasses the `image` package entirely.
//     No 125 MB img.Image allocation, no 31 M setPixelRgb() calls.
//   • Native zlib via dart:io ZLibEncoder (C library, not pure Dart).
//   • PNG Up filter for ~5–10× better compression of layer data
//     (adjacent rows are often identical → differences are all zeros).
//   • Fast-path for the common no-padding RGB case: a single
//     Uint8List.setRange() per row instead of per-pixel loops.
// ══════════════════════════════════════════════════════════════

/// Process a single layer: decrypt → RLE decode → area stats → PNG encode.
///
/// This is a pure function with no Flutter dependencies. It can run
/// directly in any isolate (background worker, compute(), etc.).
LayerResult processLayerSync(LayerTaskParams p) {
  final pixelCount = p.resolutionX * p.resolutionY;
  final boardType = BoardType.values[p.boardTypeIndex];

  // 1. Early detection: if RLE data is < 100 bytes, layer is almost certainly blank
  //    (A full-resolution real layer is typically >100KB even with aggressive compression)
  if (p.rawRleData.length < 100) {
    return LayerResult(
      layerIndex: p.layerIndex,
      pngBytes: _buildMinimalBlackPng(),
      areaInfo: LayerAreaInfo.empty,
    );
  }

  // 2+3+5. Merged native path: decrypt + decode + build scanlines in one call.
  final outWidth = p.targetWidth ??
      (boardType == BoardType.rgb8Bit ? (p.resolutionX ~/ 3) : (p.resolutionX ~/ 2));
  final channels = boardType == BoardType.rgb8Bit ? 3 : 1;
  final fused = NativePngEncode.instance.decodeBuildScanlinesAndArea(
    p.rawRleData,
    p.layerIndex,
    p.encryptionKey,
    p.resolutionX,
    p.resolutionY,
    outWidth,
    channels,
    p.xPixelSizeMm,
    p.yPixelSizeMm,
  );

  late final Uint8List greyPixels;
  late final Uint8List pngBytes;
  late final LayerAreaInfo areaInfo;

  if (fused != null) {
    areaInfo = fused.areaInfo;
    pngBytes = _encodeScanlinesToPng(
      fused.scanlines,
      outWidth,
      p.resolutionY,
      boardType == BoardType.rgb8Bit ? 2 : 0,
      p.pngLevel,
    );
    greyPixels = Uint8List(0); // Not used in fused path.
  } else {
    final merged = NativePngEncode.instance.decodeAndBuildScanlines(
      p.rawRleData,
      p.layerIndex,
      p.encryptionKey,
      p.resolutionX,
      p.resolutionY,
      outWidth,
      channels,
    );

    if (merged != null) {
    greyPixels = merged.greyPixels;
    pngBytes = _encodeScanlinesToPng(
      merged.scanlines,
      outWidth,
      p.resolutionY,
      boardType == BoardType.rgb8Bit ? 2 : 0,
      p.pngLevel,
    );
    areaInfo = _computeLayerArea(
      greyPixels,
      p.resolutionX,
      p.resolutionY,
      p.xPixelSizeMm,
      p.yPixelSizeMm,
    );
    } else {
    // 2+3. Decrypt + RLE decode (native fast path with Dart fallback)
    greyPixels = NativeRleDecode.instance.decryptAndDecode(
          p.rawRleData,
          p.layerIndex,
          p.encryptionKey,
          pixelCount,
        ) ??
        _decodeRle(
          _decryptLayerData(p.rawRleData, p.layerIndex, p.encryptionKey),
          pixelCount,
        );

    // 5. PNG encode (custom fast encoder — no image package)
    pngBytes = _encodeToPng(
      greyPixels,
      p.resolutionX,
      p.resolutionY,
      boardType,
      p.targetWidth,
      p.pngLevel,
    );
    areaInfo = _computeLayerArea(
      greyPixels,
      p.resolutionX,
      p.resolutionY,
      p.xPixelSizeMm,
      p.yPixelSizeMm,
    );
    }
  }

  return LayerResult(
    layerIndex: p.layerIndex,
    pngBytes: pngBytes,
    areaInfo: areaInfo,
  );
}

Uint8List _encodeScanlinesToPng(
  Uint8List scanlines,
  int width,
  int height,
  int colorType,
  int level,
) {
  final compressed = ZLibEncoder(level: level).convert(scanlines);
  return _buildPngFile(
    width,
    height,
    colorType,
    8,
    compressed is Uint8List ? compressed : Uint8List.fromList(compressed),
  );
}

// ── Decrypt (UVtools LFSR XOR) ──────────────────────────────

Uint8List _decryptLayerData(
    Uint8List data, int layerIndex, int encryptionKey) {
  if (encryptionKey == 0) return data;

  final result = Uint8List.fromList(data);
  final int init = (encryptionKey * 0x2d83cdac + 0xd8a83423) & 0xFFFFFFFF;
  int key = ((layerIndex * 0x1e1530cd + 0xec3d47cd) & 0xFFFFFFFF);
  key = (key * init) & 0xFFFFFFFF;

  int index = 0;
  for (int i = 0; i < result.length; i++) {
    final k = (key >> (8 * index)) & 0xFF;
    result[i] ^= k;
    index++;
    if ((index & 3) == 0) {
      key = (key + init) & 0xFFFFFFFF;
      index = 0;
    }
  }

  return result;
}

// ── RLE decode (UVtools prefix-based) ───────────────────────

Uint8List _decodeRle(Uint8List data, int pixelCount) {
  final output = Uint8List(pixelCount);
  int pixel = 0;
  int n = 0;

  while (n < data.length && pixel < pixelCount) {
    int code = data[n++];
    int stride = 1;

    if (code & 0x80 != 0) {
      code &= 0x7F;
      if (n >= data.length) break;

      final slen = data[n++];

      if ((slen & 0x80) == 0) {
        stride = slen;
      } else if ((slen & 0xC0) == 0x80) {
        if (n >= data.length) break;
        stride = ((slen & 0x3F) << 8) + data[n++];
      } else if ((slen & 0xE0) == 0xC0) {
        if (n + 1 >= data.length) break;
        stride = ((slen & 0x1F) << 16) + (data[n] << 8) + data[n + 1];
        n += 2;
      } else if ((slen & 0xF0) == 0xE0) {
        if (n + 2 >= data.length) break;
        stride = ((slen & 0x0F) << 24) +
            (data[n] << 16) + (data[n + 1] << 8) + data[n + 2];
        n += 3;
      } else {
        stride = 1;
      }
    }

    final pixelValue = code == 0 ? 0 : ((code << 1) | 1);

    final end = math.min(pixel + stride, pixelCount);
    if (pixelValue == 0) {
      pixel = end; // Output already zero-initialised
    } else {
      output.fillRange(pixel, end, pixelValue);
      pixel = end;
    }
  }

  return output;
}

// ── Area statistics (with 8-connected island detection) ───────

LayerAreaInfo _computeLayerArea(
  Uint8List greyPixels,
  int width,
  int height,
  double xPixelSizeMm,
  double yPixelSizeMm,
) {
  final nativeResult = NativeAreaStats.instance.compute(
    greyPixels,
    width,
    height,
    xPixelSizeMm,
    yPixelSizeMm,
  );
  if (nativeResult != null) {
    return nativeResult;
  }

  final pixelCount = width * height;
  final visited = Uint32List((pixelCount + 31) >> 5);
  
  // Inline bit helpers
  bool isVisited(int idx) => (visited[idx >> 5] & (1 << (idx & 31))) != 0;
  void markVisited(int idx) => visited[idx >> 5] |= (1 << (idx & 31));

  int minX = width, minY = height, maxX = 0, maxY = 0;
  final islandSizes = <int>[]; // Pixel count per island

  // Helper stack for iterative DFS (Flood Fill)
  // Stores packed coordinates: (y << 16) | x
  final stack = <int>[];

  // Directions for 8-connected neighbors: (dx, dy)
  const dxOffsets = [-1, 0, 1, -1, 1, -1, 0, 1];
  const dyOffsets = [-1, -1, -1, 0, 0, 1, 1, 1];

  for (int y = 0; y < height; y++) {
    final rowOffset = y * width;
    for (int x = 0; x < width; x++) {
      final rootIdx = rowOffset + x;
      
      if (greyPixels[rootIdx] > 0 && !isVisited(rootIdx)) {
        // Start new island
        int currentIslandPixelCount = 0;
        
        stack.add((y << 16) | x);
        markVisited(rootIdx);
        currentIslandPixelCount++;
        
        // Update bounding box for the start point
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;

        while (stack.isNotEmpty) {
          final packed = stack.removeLast();
          final cy = packed >> 16;
          final cx = packed & 0xFFFF;
          
          // Check 8 neighbors
          for (int i = 0; i < 8; i++) {
            final nx = cx + dxOffsets[i];
            final ny = cy + dyOffsets[i];

            if (nx >= 0 && nx < width && ny >= 0 && ny < height) {
              final nIdx = ny * width + nx;
              if (greyPixels[nIdx] > 0 && !isVisited(nIdx)) {
                markVisited(nIdx);
                stack.add((ny << 16) | nx);
                currentIslandPixelCount++;

                // Bounding box updates
                if (nx < minX) minX = nx;
                if (nx > maxX) maxX = nx;
                if (ny < minY) minY = ny;
                if (ny > maxY) maxY = ny;
              }
            }
          }
        }
        islandSizes.add(currentIslandPixelCount);
      }
    }
  }

  if (islandSizes.isEmpty) return LayerAreaInfo.empty;

  final pixelArea = xPixelSizeMm * yPixelSizeMm;
  
  double totalArea = 0;
  double largest = 0;
  double smallest = double.infinity;

  for (final count in islandSizes) {
    final areaBytes = count * pixelArea;
    totalArea += areaBytes;
    if (areaBytes > largest) largest = areaBytes;
    if (areaBytes < smallest) smallest = areaBytes;
  }

  return LayerAreaInfo(
    totalSolidArea: totalArea,
    largestArea: largest,
    smallestArea: smallest,
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
    areaCount: islandSizes.length,
  );
}

// ── Minimal blank layer PNG ─────────────────────────────

/// Build a tiny 1×1 black PNG for empty layers.
/// Much faster than encoding a full-resolution layer when there's no content.
/// Saves ~150ms per blank layer (skips area computation + PNG encoding).
Uint8List _buildMinimalBlackPng() {
  // Pre-built 1×1 black PNG (greyscale, value 0).
  // Total size: ~67 bytes (vs 400KB for full layer).
  // PNG signature + IHDR + minimal IDAT + IEND
  
  const bytes = <int>[
    // PNG signature
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    // IHDR chunk (1×1, 8-bit greyscale)
    0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x00, 0x00, 0x00, 0x00,
    0x5B, 0x1D, 0x4B, 0x93,
    // IDAT chunk (compressed: 1 scanline with 1 black pixel)
    0x00, 0x00, 0x00, 0x0A,
    0x49, 0x44, 0x41, 0x54,
    0x78, 0x9C, 0x62, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01,
    0xE5, 0x27, 0xDE, 0xFC,
    // IEND chunk
    0x00, 0x00, 0x00, 0x00,
    0x49, 0x45, 0x4E, 0x44,
    0xAE, 0x42, 0x60, 0x82,
  ];
  
  return Uint8List.fromList(bytes);
}

// ══════════════════════════════════════════════════════════════
// Fast PNG encoder — replaces the `image` package entirely.
//
// Previous pipeline per layer:
//   img.Image(5040×6230)          → 125 MB RGBA allocation
//   31 M × setPixelRgb()          → per-pixel method calls
//   img.encodePng(level: 9)       → pure-Dart zlib, max compression
//   Total: ~1.5 s / layer
//
// New pipeline per layer:
//   Uint8List scanlines            → direct byte packing
//   Up filter (in-place)           → 1 subtraction per byte
//   dart:io ZLibEncoder(level: 1)  → native C zlib
//   PNG chunk assembly             → BytesBuilder, no copies
//   Total: ~50–100 ms / layer
// ══════════════════════════════════════════════════════════════

Uint8List _encodeToPng(
  Uint8List greyPixels,
  int width,
  int height,
  BoardType boardType,
  int? targetWidth,
  int pngLevel,
) {
  switch (boardType) {
    case BoardType.rgb8Bit:
      return _encodePngRgb(greyPixels, width, height, targetWidth, pngLevel);
    case BoardType.twoBit3Subpixel:
      return _encodePngGreyscale(
          greyPixels, width, height, targetWidth, pngLevel);
  }
}

/// Encode greyscale subpixels as an 8-bit RGB PNG.
///
/// 3 consecutive greyscale values → 1 RGB pixel (R, G, B).
/// Fast path when no padding is needed: the source bytes are the RGB
/// bytes, so a single [Uint8List.setRange] per row replaces 31 M
/// setPixelRgb() calls.
Uint8List _encodePngRgb(
  Uint8List greyPixels,
  int srcWidth,
  int height,
  int? targetWidth,
  int level,
) {
  final outWidth = targetWidth ?? (srcWidth ~/ 3);
  final bytesPerRow = outWidth * 3;
  final scanlineSize = 1 + bytesPerRow; // filter byte + pixel data
  final scanlines = NativePngEncode.instance
          .buildRgbScanlines(greyPixels, srcWidth, height, outWidth) ??
      (() {
        final requiredSubpixels = outWidth * 3;
        final padTotal = requiredSubpixels - srcWidth;
        final padLeft = padTotal > 0 ? padTotal ~/ 2 : 0;
        final fallback = Uint8List(scanlineSize * height);

        if (padTotal == 0) {
          // ── Fast path ─────────────────────────────────────
          for (int y = 0; y < height; y++) {
            final dstRow = y * scanlineSize;
            fallback.setRange(
                dstRow + 1, dstRow + 1 + bytesPerRow, greyPixels, y * srcWidth);
          }
        } else {
          // ── Padding path ──────────────────────────────────
          int dst = 0;
          for (int y = 0; y < height; y++) {
            dst++;
            final rowOffset = y * srcWidth;
            for (int x = 0; x < outWidth; x++) {
              final si = x * 3 - padLeft;
              fallback[dst++] =
                  (si >= 0 && si < srcWidth) ? greyPixels[rowOffset + si] : 0;
              fallback[dst++] = (si + 1 >= 0 && si + 1 < srcWidth)
                  ? greyPixels[rowOffset + si + 1]
                  : 0;
              fallback[dst++] = (si + 2 >= 0 && si + 2 < srcWidth)
                  ? greyPixels[rowOffset + si + 2]
                  : 0;
            }
          }
        }

        _applyUpFilter(fallback, height, scanlineSize, bytesPerRow);
        return fallback;
      })();

  // colorType = 2 (RGB), bitDepth = 8
  return _encodeScanlinesToPng(scanlines, outWidth, height, 2, level);
}

/// Encode greyscale subpixels as an 8-bit greyscale PNG (3-bit driver).
///
/// 2 consecutive greyscale values → 1 greyscale pixel (average).
/// Output is a greyscale PNG (colorType=0) with width = sourceWidth / 2.
Uint8List _encodePngGreyscale(
  Uint8List greyPixels,
  int srcWidth,
  int height,
  int? targetWidth,
  int level,
) {
  final outWidth = targetWidth ?? (srcWidth ~/ 2);
  final bytesPerRow = outWidth; // 1 byte per greyscale pixel
  final scanlineSize = 1 + bytesPerRow; // filter byte + pixel data
  final scanlines = NativePngEncode.instance
          .buildGreyscaleScanlines(greyPixels, srcWidth, height, outWidth) ??
      (() {
        final requiredSubpixels = outWidth * 2;
        final padTotal = requiredSubpixels - srcWidth;
        final padLeft = padTotal > 0 ? padTotal ~/ 2 : 0;
        final fallback = Uint8List(scanlineSize * height);

        for (int y = 0; y < height; y++) {
          final dstRow = y * scanlineSize;
          final rowOffset = y * srcWidth;
          for (int x = 0; x < outWidth; x++) {
            final si = x * 2 - padLeft;
            final a = (si >= 0 && si < srcWidth) ? greyPixels[rowOffset + si] : 0;
            final b = (si + 1 >= 0 && si + 1 < srcWidth)
                ? greyPixels[rowOffset + si + 1]
                : 0;
            fallback[dstRow + 1 + x] = ((a + b) >> 1);
          }
        }

        _applyUpFilter(fallback, height, scanlineSize, bytesPerRow);
        return fallback;
      })();

  // colorType = 0 (Greyscale), bitDepth = 8
  return _encodeScanlinesToPng(scanlines, outWidth, height, 0, level);
}

// ── PNG recompression (level 1 → level 9) ──────────────────

/// Recompress a PNG's IDAT data from a low zlib level to level 9.
///
/// Parses the known PNG structure (signature + IHDR + IDAT + IEND),
/// decompresses the IDAT payload, then recompresses at max level.
/// Returns the rebuilt PNG. If anything goes wrong, returns the
/// original bytes unchanged.
Uint8List recompressPng(Uint8List pngBytes, {int level = 7}) {
  final safeLevel = level.clamp(0, 9);
  final native = NativePngRecompress.instance.recompress(pngBytes, level: safeLevel);
  if (native != null) {
    return native;
  }

  try {
    if (pngBytes.length < 45) return pngBytes;

    final view = ByteData.sublistView(pngBytes);
    const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    for (int i = 0; i < signature.length; i++) {
      if (pngBytes[i] != signature[i]) return pngBytes;
    }

    int offset = 8;
    int? width;
    int? height;
    int? bitDepth;
    int? colorType;
    final idatBytes = BytesBuilder(copy: false);

    while (offset + 8 <= pngBytes.length) {
      final len = view.getUint32(offset, Endian.big);
      final type = view.getUint32(offset + 4, Endian.big);
      final dataStart = offset + 8;
      final dataEnd = dataStart + len;
      final crcEnd = dataEnd + 4;
      if (crcEnd > pngBytes.length) break;

      if (type == 0x49484452 && len >= 13) {
        width = view.getUint32(dataStart, Endian.big);
        height = view.getUint32(dataStart + 4, Endian.big);
        bitDepth = pngBytes[dataStart + 8];
        colorType = pngBytes[dataStart + 9];
      } else if (type == 0x49444154) {
        idatBytes.add(Uint8List.sublistView(pngBytes, dataStart, dataEnd));
      } else if (type == 0x49454E44) {
        break;
      }

      offset = crcEnd;
    }

    if (idatBytes.isEmpty || width == null || height == null) return pngBytes;
    final compressedData = idatBytes.takeBytes();
    final scanlines = ZLibDecoder().convert(compressedData);

    final recompressed = ZLibEncoder(level: safeLevel).convert(scanlines);
    final newIdat = recompressed is Uint8List
        ? recompressed
        : Uint8List.fromList(recompressed);

    return _buildPngFile(
      width,
      height,
      colorType ?? 0,
      bitDepth ?? 8,
      newIdat,
    );
  } catch (_) {
    return pngBytes;
  }
}

/// Recompress a list of PNGs in parallel using isolates.
Future<List<Uint8List>> recompressPngsParallel({
  required List<Uint8List> pngs,
  required int maxConcurrency,
  void Function(int completed, int total)? onProgress,
  void Function(int workers)? onWorkersReady,
}) async {
  if (pngs.isEmpty) return [];

  final nativeBatch = NativePngRecompress.instance.batchAvailable;
  if (nativeBatch) {
    final nativeThreads = math.min(
      pngs.length,
      math.max(1, maxConcurrency),
    );

    final recompressLevelEnv = int.tryParse(
      (Platform.environment['VOXELSHIFT_RECOMPRESS_LEVEL'] ?? '').trim(),
    );
    final defaultLevel = pngs.length >= 1200
      ? 4
      : pngs.length >= 500
        ? 5
        : 7;
    final recompressLevel =
      (recompressLevelEnv == null ? defaultLevel : recompressLevelEnv.clamp(0, 9));

    // Native recompress now owns multithreading internally.
    NativePngRecompress.instance.setBatchThreads(nativeThreads);

    onWorkersReady?.call(nativeThreads);
    onProgress?.call(0, pngs.length);

    final chunkOverride = int.tryParse(
      (Platform.environment['VOXELSHIFT_RECOMPRESS_CHUNKS'] ?? '').trim(),
    );
    final targetChunks = (chunkOverride == null || chunkOverride <= 0)
        ? (pngs.length < 256
            ? 2
            : pngs.length < 800
                ? 4
                : 8)
        : chunkOverride;
    final chunkCount = targetChunks.clamp(1, pngs.length);
    final chunkSize = (pngs.length / chunkCount).ceil();

    final out = List<Uint8List>.filled(pngs.length, Uint8List(0), growable: false);
    int completed = 0;

    for (int start = 0; start < pngs.length; start += chunkSize) {
      final end = math.min(start + chunkSize, pngs.length);
      final chunk = pngs.sublist(start, end);

      final result = NativePngRecompress.instance.recompressBatch(
        chunk,
        level: recompressLevel,
      );

      if (result == null || result.length != chunk.length) {
        // If native chunk fails, preserve correctness by copying originals.
        for (int i = 0; i < chunk.length; i++) {
          out[start + i] = chunk[i];
        }
      } else {
        for (int i = 0; i < result.length; i++) {
          out[start + i] = result[i];
        }
      }

      completed = end;
      onProgress?.call(completed, pngs.length);
    }

    return out;
  }

  final concurrency = math.min(
    pngs.length < 100 ? 3 : pngs.length < 500 ? 6 : 12,
    math.max(1, maxConcurrency),
  );

  final recompressLevelEnv = int.tryParse(
    (Platform.environment['VOXELSHIFT_RECOMPRESS_LEVEL'] ?? '').trim(),
  );
  final defaultLevel = pngs.length >= 1200
      ? 4
      : pngs.length >= 500
          ? 5
          : 7;
  final recompressLevel =
      (recompressLevelEnv == null ? defaultLevel : recompressLevelEnv.clamp(0, 9));

  onWorkersReady?.call(concurrency);
  onProgress?.call(0, pngs.length);

  final results = List<Uint8List?>.filled(pngs.length, null);
  int completed = 0;
  int nextIdx = 0;
  DateTime lastReport = DateTime.now();
  const reportMs = 250;

  final completer = Completer<void>();

  void launchOne() {
    if (nextIdx >= pngs.length || completer.isCompleted) return;
    final idx = nextIdx++;
    Isolate.run(() => recompressPng(pngs[idx], level: recompressLevel)).then((result) {
      results[idx] = result;
      completed++;
      final now = DateTime.now();
      if (now.difference(lastReport).inMilliseconds >= reportMs ||
          completed == pngs.length) {
        onProgress?.call(completed, pngs.length);
        lastReport = now;
      }
      if (completed == pngs.length) {
        if (!completer.isCompleted) completer.complete();
      } else {
        launchOne();
      }
    }).catchError((Object e) {
      results[idx] = pngs[idx];
      completed++;
      if (completed == pngs.length) {
        if (!completer.isCompleted) completer.complete();
      } else {
        launchOne();
      }
    });
  }

  for (int i = 0; i < math.min(concurrency, pngs.length); i++) {
    launchOne();
  }

  await completer.future;
  return results.cast<Uint8List>();
}

// ── PNG Up filter ───────────────────────────────────────────

/// Apply PNG Up filter (type 2) in-place, processing rows bottom-to-top
/// so that each row reads the still-unmodified row above it.
///
/// Up filter: Filtered[i] = Raw[i] − Prior[i]  (mod 256)
///
/// For layer slices, adjacent rows are often identical, so the filtered
/// bytes are mostly zeros → zlib compresses them dramatically better.
void _applyUpFilter(
    Uint8List scanlines, int height, int scanlineSize, int bytesPerRow) {
  for (int y = height - 1; y >= 1; y--) {
    final curStart = y * scanlineSize;
    final prevStart = (y - 1) * scanlineSize;
    scanlines[curStart] = 2; // filter type = Up
    for (int i = 1; i <= bytesPerRow; i++) {
      scanlines[curStart + i] =
          (scanlines[curStart + i] - scanlines[prevStart + i]) & 0xFF;
    }
  }
  // First row: Up with zero "above" → byte values stay the same
  scanlines[0] = 2;
}

// ── PNG file structure ──────────────────────────────────────

/// Build a complete PNG file from pre-compressed IDAT data.
Uint8List _buildPngFile(
    int width, int height, int colorType, int bitDepth, Uint8List idat) {
  final buf = BytesBuilder(copy: false);

  // PNG signature
  buf.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  // IHDR chunk (13 bytes)
  final ihdr = Uint8List(13);
  final hv = ByteData.sublistView(ihdr);
  hv.setUint32(0, width, Endian.big);
  hv.setUint32(4, height, Endian.big);
  ihdr[8] = bitDepth;
  ihdr[9] = colorType;
  // compression = 0, filter = 0, interlace = 0 — already zeroed
  _writePngChunk(buf, 0x49484452, ihdr); // 'IHDR'

  // IDAT chunk
  _writePngChunk(buf, 0x49444154, idat); // 'IDAT'

  // IEND chunk
  _writePngChunk(buf, 0x49454E44, _emptyBytes); // 'IEND'

  return buf.toBytes();
}

final Uint8List _emptyBytes = Uint8List(0);

/// Write one PNG chunk: [4-byte length][4-byte type][data][4-byte CRC32].
void _writePngChunk(BytesBuilder buf, int type, Uint8List data) {
  // Length + type header (8 bytes)
  final header = Uint8List(8);
  final headerView = ByteData.sublistView(header);
  headerView.setUint32(0, data.length, Endian.big);
  headerView.setUint32(4, type, Endian.big);
  buf.add(header);

  // Data
  if (data.isNotEmpty) buf.add(data);

  // CRC-32 over type bytes + data bytes
  int crc = 0xFFFFFFFF;
  // Type (4 bytes, big-endian from the int)
  crc = _crc32Table[(crc ^ ((type >> 24) & 0xFF)) & 0xFF] ^ (crc >>> 8);
  crc = _crc32Table[(crc ^ ((type >> 16) & 0xFF)) & 0xFF] ^ (crc >>> 8);
  crc = _crc32Table[(crc ^ ((type >> 8) & 0xFF)) & 0xFF] ^ (crc >>> 8);
  crc = _crc32Table[(crc ^ (type & 0xFF)) & 0xFF] ^ (crc >>> 8);
  // Data
  for (int i = 0; i < data.length; i++) {
    crc = _crc32Table[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
  }
  crc ^= 0xFFFFFFFF;

  final crcBytes = Uint8List(4);
  ByteData.sublistView(crcBytes).setUint32(0, crc, Endian.big);
  buf.add(crcBytes);
}

// ── CRC-32 lookup table (standard polynomial 0xEDB88320) ────

final List<int> _crc32Table = _buildCrc32Table();

List<int> _buildCrc32Table() {
  final table = List<int>.filled(256, 0);
  for (int i = 0; i < 256; i++) {
    int c = i;
    for (int k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[i] = c;
  }
  return table;
}
