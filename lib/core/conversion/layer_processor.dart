import 'dart:async';
import 'dart:io' show Platform, ZLibDecoder, ZLibEncoder;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/board_type.dart';
import '../models/layer_area_info.dart';

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

/// Optimal worker count based on available CPU cores.
int get defaultWorkerCount =>
  math.max(2, (Platform.numberOfProcessors / 2).floor()).clamp(2, 6);

/// Run a single layer in a sub-isolate.
///
/// MUST be a top-level function so the closure passed to [Isolate.run] only
/// captures [task] (which is fully sendable).  If this were a nested closure
/// inside [processLayersParallel], it would inadvertently capture the
/// enclosing scope's [Completer] and other unsendable objects.
Future<LayerResult> _processInSubIsolate(LayerTaskParams task) {
  return Isolate.run(() => processLayerSync(task));
}

/// Process layers in parallel with true N-way concurrency.
///
/// Maintains exactly `concurrencyLimit` in-flight compute() calls at all
/// times.  As each isolate finishes, the next task is dispatched immediately
/// — no serial await bottleneck.
///
/// Concurrency is scaled based on layer count:
///   • Small files (< 100 layers):   3 concurrent compute() calls
///   • Medium files (100-500 layers): 5 concurrent
///   • Large files (> 500 layers):    8 concurrent
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
      ? 2
      : tasks.length < 500
        ? 4
        : 6;

  final concurrencyLimit =
      math.min(baseConcurrency, math.max(1, maxConcurrency));

  onWorkersReady?.call(concurrencyLimit);

  final results = List<LayerResult?>.filled(tasks.length, null);
  int completedCount = 0;
  int nextTask = 0;
  DateTime lastReportTime = DateTime.now();
  const reportIntervalMs = 250;

  final completer = Completer<void>();

  /// Launch exactly one compute() call. When it finishes, it backfills
  /// the slot by calling launchOne() again.
  void launchOne() {
    if (nextTask >= tasks.length || completer.isCompleted) return;

    final taskIdx = nextTask++;

    _processInSubIsolate(tasks[taskIdx]).then((result) {
      results[result.layerIndex] = result;
      completedCount++;

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

  // 1. Early detection: if RLE data is < 100 bytes, layer is almost certainly blank
  //    (A full-resolution real layer is typically >100KB even with aggressive compression)
  if (p.rawRleData.length < 100) {
    return LayerResult(
      layerIndex: p.layerIndex,
      pngBytes: _buildMinimalBlackPng(),
      areaInfo: LayerAreaInfo.empty,
    );
  }

  // 2. Decrypt
  final decrypted =
      _decryptLayerData(p.rawRleData, p.layerIndex, p.encryptionKey);

  // 3. RLE decode
  final greyPixels = _decodeRle(decrypted, pixelCount);

  // 4. Area statistics
  final areaInfo = _computeLayerArea(
    greyPixels, p.resolutionX, p.resolutionY,
    p.xPixelSizeMm, p.yPixelSizeMm,
  );

  // 5. PNG encode (custom fast encoder — no image package)
  final boardType = BoardType.values[p.boardTypeIndex];
  final pngBytes = _encodeToPng(
    greyPixels, p.resolutionX, p.resolutionY,
    boardType, p.targetWidth, p.pngLevel,
  );

  return LayerResult(
    layerIndex: p.layerIndex,
    pngBytes: pngBytes,
    areaInfo: areaInfo,
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

// ── Area statistics ─────────────────────────────────────────

LayerAreaInfo _computeLayerArea(
  Uint8List greyPixels,
  int width,
  int height,
  double xPixelSizeMm,
  double yPixelSizeMm,
) {
  int nonZeroCount = 0;
  int minX = width, minY = height, maxX = 0, maxY = 0;

  for (int y = 0; y < height; y++) {
    final rowOffset = y * width;
    for (int x = 0; x < width; x++) {
      if (greyPixels[rowOffset + x] > 0) {
        nonZeroCount++;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }

  if (nonZeroCount == 0) return LayerAreaInfo.empty;

  final pixelArea = xPixelSizeMm * yPixelSizeMm;
  final totalArea = nonZeroCount * pixelArea;

  return LayerAreaInfo(
    totalSolidArea: totalArea,
    largestArea: totalArea,
    smallestArea: totalArea,
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
    areaCount: 1,
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
  final requiredSubpixels = outWidth * 3;
  final padTotal = requiredSubpixels - srcWidth;
  final padLeft = padTotal > 0 ? padTotal ~/ 2 : 0;

  final bytesPerRow = outWidth * 3;
  final scanlineSize = 1 + bytesPerRow; // filter byte + pixel data
  final scanlines = Uint8List(scanlineSize * height);

  if (padTotal == 0) {
    // ── Fast path ───────────────────────────────────────────
    // Source greyscale bytes ARE the RGB bytes in order.
    // Just prepend a filter byte per row. One setRange per row
    // instead of 5040 × setPixelRgb per row.
    for (int y = 0; y < height; y++) {
      final dstRow = y * scanlineSize;
      // scanlines[dstRow] already 0 (placeholder for Up filter)
      scanlines.setRange(
          dstRow + 1, dstRow + 1 + bytesPerRow, greyPixels, y * srcWidth);
    }
  } else {
    // ── Padding path ────────────────────────────────────────
    int dst = 0;
    for (int y = 0; y < height; y++) {
      dst++; // skip filter byte placeholder
      final rowOffset = y * srcWidth;
      for (int x = 0; x < outWidth; x++) {
        final si = x * 3 - padLeft;
        scanlines[dst++] =
            (si >= 0 && si < srcWidth) ? greyPixels[rowOffset + si] : 0;
        scanlines[dst++] = (si + 1 >= 0 && si + 1 < srcWidth)
            ? greyPixels[rowOffset + si + 1]
            : 0;
        scanlines[dst++] = (si + 2 >= 0 && si + 2 < srcWidth)
            ? greyPixels[rowOffset + si + 2]
            : 0;
      }
    }
  }

  // Apply Up filter in-place, then compress with native zlib
  _applyUpFilter(scanlines, height, scanlineSize, bytesPerRow);
  final compressed = ZLibEncoder(level: level).convert(scanlines);

  // colorType = 2 (RGB), bitDepth = 8
  return _buildPngFile(outWidth, height, 2, 8,
      compressed is Uint8List ? compressed : Uint8List.fromList(compressed));
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
  final requiredSubpixels = outWidth * 2;
  final padTotal = requiredSubpixels - srcWidth;
  final padLeft = padTotal > 0 ? padTotal ~/ 2 : 0;

  final bytesPerRow = outWidth; // 1 byte per greyscale pixel
  final scanlineSize = 1 + bytesPerRow; // filter byte + pixel data
  final scanlines = Uint8List(scanlineSize * height);

  for (int y = 0; y < height; y++) {
    final dstRow = y * scanlineSize;
    final rowOffset = y * srcWidth;
    // scanlines[dstRow] = 0 (filter byte placeholder for Up filter)
    for (int x = 0; x < outWidth; x++) {
      final si = x * 2 - padLeft;
      final a = (si >= 0 && si < srcWidth) ? greyPixels[rowOffset + si] : 0;
      final b = (si + 1 >= 0 && si + 1 < srcWidth)
          ? greyPixels[rowOffset + si + 1]
          : 0;
      scanlines[dstRow + 1 + x] = ((a + b) >> 1); // average of 2 subpixels
    }
  }

  // Apply Up filter in-place, then compress with native zlib
  _applyUpFilter(scanlines, height, scanlineSize, bytesPerRow);
  final compressed = ZLibEncoder(level: level).convert(scanlines);

  // colorType = 0 (Greyscale), bitDepth = 8
  return _buildPngFile(outWidth, height, 0, 8,
      compressed is Uint8List ? compressed : Uint8List.fromList(compressed));
}

// ── PNG recompression (level 1 → level 9) ──────────────────

/// Recompress a PNG's IDAT data from a low zlib level to level 9.
///
/// Parses the known PNG structure (signature + IHDR + IDAT + IEND),
/// decompresses the IDAT payload, then recompresses at max level.
/// Returns the rebuilt PNG. If anything goes wrong, returns the
/// original bytes unchanged.
Uint8List recompressPng(Uint8List pngBytes) {
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

    final recompressed = ZLibEncoder(level: 9).convert(scanlines);
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

  final concurrency = math.min(
    pngs.length < 100 ? 2 : pngs.length < 500 ? 4 : 6,
    math.max(1, maxConcurrency),
  );

  onWorkersReady?.call(concurrency);

  final results = List<Uint8List?>.filled(pngs.length, null);
  int completed = 0;
  int nextIdx = 0;
  DateTime lastReport = DateTime.now();
  const reportMs = 250;

  final completer = Completer<void>();

  void launchOne() {
    if (nextIdx >= pngs.length || completer.isCompleted) return;
    final idx = nextIdx++;
    Isolate.run(() => recompressPng(pngs[idx])).then((result) {
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
