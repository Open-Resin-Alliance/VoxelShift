import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:convert' show base64Decode;
import 'package:pointycastle/export.dart';

import '../models/slice_file_info.dart';

/// Pure-Dart CTB file parser supporting multiple formats.
///
/// CTB files use a binary header followed by layer definitions.
/// Each layer image is RLE-encoded greyscale data.
///
/// Supported formats:
///   - CBDDLP (magic 0x12FD0066)
///   - CTB v2/v3 (magic 0x12FD0086)
///   - CTB v4 (magic 0x12FD0106) - encrypted layer data
///   - CTB v4 encrypted (magic 0x12FD0107) - fully encrypted including settings
///
/// For CTBv4 encrypted files, the entire settings block is decrypted using
/// AES-256-CBC with XOR-obfuscated keys derived from UVtools.
///
/// References:
///   - UVtools source (CTBv4 format)
///   - ChiTuBox slicer output format
///   - Elegoo Mars 3 (uses CTBv4 encrypted format)
///   - Reverse engineering by Paul_GD, CryptoCTB, 2021
class CtbParser {
  // ── CTB header magic & offsets ───────────────────────────────

  // CTBv2 magic
  static const int _magicCbddlp = 0x12FD0066;
  // CTBv3+ magic
  static const int _magicCtb = 0x12FD0086;
  // CTBv4 magic (encrypted)
  static const int _magicCtbV4 = 0x12FD0106;
  // CTBv4 encrypted magic (Elegoo Mars 3, etc.)
  static const int _magicCtbV4Encrypted = 0x12FD0107;

  // AES encryption keys for CTBv4E (base64-encoded, then XOR-decoded)
  // These are from UVtools and XORed with "UVtools" to obfuscate
  static const String _secret1 = 'hQ36XB6yTk+zO02ysyiowt8yC1buK+nbLWyfY40EXoU=';
  static const String _secret2 = 'Wld+ampndVJecmVjYH5cWQ==';
  static const String _xorKey = 'UVtools';

  late final RandomAccessFile _raf;
  // ignore: unused_field
  late final int _fileLength; // kept for potential future use

  // Header fields
  late final int magic;
  late final int version;
  late final double bedXMm;
  late final double bedYMm;
  late final double bedZMm;
  late final double layerHeightMm;
  late final double exposureTime;
  late final double bottomExposureTime;
  late final int resolutionX;
  late final int resolutionY;
  late final int layerCount;
  late final int previewLargeOffset;
  late final int previewSmallOffset;
  late final int layerTableOffset;
  late final int printTime;
  late final int projectorType;
  late final int bottomLayerCount;
  late final double liftHeight;
  late final double liftSpeed;
  late final double retractSpeed;
  late final double totalVolume;
  late final int antiAliasingLevel;
  late final int lightPwm;
  late final int bottomLightPwm;
  late final int encryptionKey;
  late final String? machineName;

  // Layer table
  late final List<_CtbLayerDef> _layerDefs;

  // Print parameters (extended)
  late final int _printParamsOffset;
  late final int _printParamsSize;
  late final int _slicerInfoOffset;
  // ignore: unused_field
  late final int _slicerInfoSize; // kept for potential future use

  CtbParser._();

  /// Open and parse a CTB file. Returns the parser with header info loaded.
  static Future<CtbParser> open(String path) async {
    final parser = CtbParser._();
    await parser._open(path);
    return parser;
  }

  Future<void> _open(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('CTB file not found', path);
    }

    _raf = await file.open(mode: FileMode.read);
    _fileLength = await file.length();

    await _readHeader();
    await _readLayerTable();
  }

  /// Extract metadata as [SliceFileInfo].
  SliceFileInfo toSliceFileInfo(String sourcePath, {Uint8List? thumbnail}) {
    return SliceFileInfo(
      sourcePath: sourcePath,
      resolutionX: resolutionX,
      resolutionY: resolutionY,
      displayWidth: bedXMm,
      displayHeight: bedYMm,
      machineZ: bedZMm,
      layerHeight: layerHeightMm,
      layerCount: layerCount,
      bottomExposureTime: bottomExposureTime,
      exposureTime: exposureTime,
      bottomLayerCount: bottomLayerCount,
      liftHeight: liftHeight,
      liftSpeed: liftSpeed,
      retractSpeed: retractSpeed,
      machineName: machineName,
      thumbnailPng: thumbnail,
    );
  }

  /// Read and decode a single layer image as greyscale pixel data.
  /// Returns a flat [Uint8List] of width * height greyscale pixels.
  Future<Uint8List> readLayerImage(int layerIndex) async {
    if (layerIndex < 0 || layerIndex >= layerCount) {
      throw RangeError('Layer index $layerIndex out of range [0, $layerCount)');
    }

    final layerDef = _layerDefs[layerIndex];
    await _raf.setPosition(layerDef.dataOffset);
    final rleData = await _readBytes(layerDef.dataLength);

    // Decrypt if needed (CTBv3+ with encryption key)
    final decoded = _decryptLayerData(rleData, layerIndex);

    // Decode RLE to greyscale image
    return _decodeRle(decoded, resolutionX * resolutionY);
  }

  /// Read raw (still-encrypted) RLE data for a layer.
  ///
  /// Used by the parallel converter to pre-read all layer bytes from the
  /// file, then ship them to worker isolates for decrypt + decode + encode.
  Future<Uint8List> readRawLayerData(int layerIndex) async {
    if (layerIndex < 0 || layerIndex >= layerCount) {
      throw RangeError('Layer index $layerIndex out of range [0, $layerCount)');
    }
    final layerDef = _layerDefs[layerIndex];
    await _raf.setPosition(layerDef.dataOffset);
    return _readBytes(layerDef.dataLength);
  }

  /// Read the large preview image as PNG bytes, if present.
  Future<Uint8List?> readPreviewLarge() async {
    if (previewLargeOffset == 0) return null;
    return _readPreview(previewLargeOffset);
  }

  /// Read the small preview image as PNG bytes, if present.
  Future<Uint8List?> readPreviewSmall() async {
    if (previewSmallOffset == 0) return null;
    return _readPreview(previewSmallOffset);
  }

  Future<void> close() async {
    await _raf.close();
  }

  // ── Header parsing ──────────────────────────────────────────

  Future<void> _readHeader() async {
    await _raf.setPosition(0);
    final initialHeader = await _readBytes(48); // FileHeader for all formats
    final bd = ByteData.sublistView(initialHeader);

    magic = bd.getUint32(0, Endian.little);
    if (magic != _magicCbddlp && magic != _magicCtb && magic != _magicCtbV4 && magic != _magicCtbV4Encrypted) {
      throw FormatException(
        'Not a CTB file (magic: 0x${magic.toRadixString(16)}). '
        'Supported: CBDDLP (0x12fd0066), CTB v2/v3 (0x12fd0086), CTB v4 (0x12fd0106), CTB v4 encrypted (0x12fd0107)',
      );
    }

    // Handle CTBv4E (0x12FD0107) with encrypted settings
    if (magic == _magicCtbV4Encrypted) {
      await _readHeaderEncrypted(bd);
      return;
    }

    // Regular CTB format (v2, v3, v4) - read full extended header
    await _readHeaderRegular(bd);
  }

  Future<void> _readHeaderEncrypted(ByteData headerData) async {
    final settingsSize = headerData.getUint32(4, Endian.little);
    final settingsOffset = headerData.getUint32(8, Endian.little);
    version = headerData.getUint32(16, Endian.little);

    // Read and decrypt settings block
    await _raf.setPosition(settingsOffset);
    final encryptedSettings = await _readBytes(settingsSize);
    final decryptedSettings = _decryptSettings(encryptedSettings);
    final sd = ByteData.sublistView(decryptedSettings);

    // Parse from decrypted CTBv4E settings block (288 bytes).
    // Field layout verified via hex dump analysis of test files.
    //
    // Offsets (all little-endian):
    //   [ 0] uint32 HeaderOffset (unused, = 0)
    //   [ 4] uint32 Reserved (= 0)
    //   [ 8] uint32 LayerPointersOffset
    //   [12] float  DisplayWidth mm
    //   [16] float  DisplayHeight mm
    //   [20] float  MachineZ mm
    //   [24-32] Reserved
    //   [36] float  LayerHeight mm
    //   [40] float  ExposureTime sec
    //   [44] float  BottomExposureTime sec
    //   [48] Reserved
    //   [52] uint32 BottomLayerCount
    //   [56] uint32 ResolutionX
    //   [60] uint32 ResolutionY
    //   [64] uint32 LayerCount
    //   [68] uint32 PreviewLargeOffset
    //   [72] uint32 PreviewSmallOffset
    //   [76] uint32 PrintTime sec
    //   [80] uint32 ProjectorType
    //   [84] float  BottomLiftHeight1 (often default/garbage in CTBv4E)
    //   [88] float  BottomLiftSpeed1
    //   [92] float  LiftHeight1
    //   [96] float  LiftSpeed1
    //  [100] float  RetractSpeed1
    //  [128] uint32 EncryptionKey

    layerTableOffset = sd.getUint32(8, Endian.little);
    bedXMm = sd.getFloat32(12, Endian.little);
    bedYMm = sd.getFloat32(16, Endian.little);
    bedZMm = sd.getFloat32(20, Endian.little);

    layerHeightMm = sd.getFloat32(36, Endian.little);
    exposureTime = sd.getFloat32(40, Endian.little);
    bottomExposureTime = sd.getFloat32(44, Endian.little);

    bottomLayerCount = sd.getUint32(52, Endian.little);
    resolutionX = sd.getUint32(56, Endian.little);
    resolutionY = sd.getUint32(60, Endian.little);

    layerCount = sd.getUint32(64, Endian.little);
    previewLargeOffset = sd.getUint32(68, Endian.little);
    previewSmallOffset = sd.getUint32(72, Endian.little);
    printTime = sd.getUint32(76, Endian.little);
    projectorType = sd.getUint32(80, Endian.little);

    if (layerCount > 100000) {
      throw FormatException(
        'Invalid layer count ($layerCount) — file header appears corrupted. '
        'Layer table offset: 0x${layerTableOffset.toRadixString(16)}, '
        'This file may not be a valid CTB format.'
      );
    }

    encryptionKey = sd.getUint32(128, Endian.little);
    antiAliasingLevel = 1;
    lightPwm = 255;
    bottomLightPwm = 255;

    // Lift parameters from CTBv4E are often populated with the layer height
    // value (e.g. 0.05) instead of actual motion parameters. Use sensible
    // defaults when the parsed values are clearly wrong.
    final rawLiftHeight = sd.getFloat32(92, Endian.little);
    final rawLiftSpeed = sd.getFloat32(96, Endian.little);
    final rawRetractSpeed = sd.getFloat32(100, Endian.little);

    liftHeight = (rawLiftHeight > 0.5 && rawLiftHeight < 100) ? rawLiftHeight : 6.0;
    liftSpeed = (rawLiftSpeed > 1.0 && rawLiftSpeed < 10000) ? rawLiftSpeed : 540.0;
    retractSpeed = (rawRetractSpeed > 1.0 && rawRetractSpeed < 10000) ? rawRetractSpeed : 540.0;
    totalVolume = 0;

    // Extract machine name from settings block if available
    machineName = _readMachineNameFromSettings(sd);
  }

  /// Try to read the machine name from the decrypted CTBv4E settings block.
  /// The name pointer and size are stored at offsets 276 and 268 respectively,
  /// pointing to a location in the file (not within the settings block).
  String? _readMachineNameFromSettings(ByteData sd) {
    try {
      if (sd.lengthInBytes < 280) return null;
      // Machine name metadata: offset 264 = start, 268 = size, 276 = file offset
      final nameSize = sd.getUint32(268, Endian.little);
      if (nameSize == 0 || nameSize > 256) return null;
      // The name is typically near the print parameters area, but extracting
      // it requires seeking in the file which we defer to avoid complexity.
      // For now, return null; the profile detector handles missing names.
    } catch (_) {}
    return null;
  }

  Future<void> _readHeaderRegular(ByteData initialData) async {
    // For regular CTB, read the full extended header
    await _raf.setPosition(0);
    final fullHeader = await _readBytes(96);
    final bd = ByteData.sublistView(fullHeader);

    version = bd.getUint32(4, Endian.little);
    bedXMm = bd.getFloat32(8, Endian.little);
    bedYMm = bd.getFloat32(12, Endian.little);
    bedZMm = bd.getFloat32(16, Endian.little);

    layerHeightMm = bd.getFloat32(32, Endian.little);
    exposureTime = bd.getFloat32(36, Endian.little);
    bottomExposureTime = bd.getFloat32(40, Endian.little);

    previewLargeOffset = bd.getUint32(48, Endian.little);
    layerTableOffset = bd.getUint32(52, Endian.little);
    layerCount = bd.getUint32(56, Endian.little);

    if (layerCount > 100000) {
      throw FormatException(
        'Invalid layer count ($layerCount) — file header appears corrupted. '
        'Layer table offset: 0x${layerTableOffset.toRadixString(16)}, '
        'This file may not be a valid CTB format.'
      );
    }

    resolutionX = bd.getUint32(60, Endian.little);
    resolutionY = bd.getUint32(64, Endian.little);
    previewSmallOffset = bd.getUint32(68, Endian.little);
    _printParamsOffset = bd.getUint32(72, Endian.little);
    _printParamsSize = bd.getUint32(76, Endian.little);
    antiAliasingLevel = bd.getUint32(80, Endian.little);
    lightPwm = bd.getUint16(84, Endian.little);
    bottomLightPwm = bd.getUint16(86, Endian.little);
    encryptionKey = bd.getUint32(88, Endian.little);
    _slicerInfoOffset = bd.getUint32(92, Endian.little);

    // Read print parameters if available
    if (_printParamsOffset > 0 && _printParamsSize >= 32) {
      await _raf.setPosition(_printParamsOffset);
      final params = await _readBytes(math.min(_printParamsSize, 80));
      final ppd = ByteData.sublistView(params);

      bottomLayerCount = ppd.getUint32(8, Endian.little);
      liftHeight = ppd.getFloat32(16, Endian.little);
      liftSpeed = ppd.getFloat32(20, Endian.little);
      retractSpeed = ppd.getFloat32(24, Endian.little);
      totalVolume = ppd.getFloat32(28, Endian.little);
    } else {
      bottomLayerCount = 0;
      liftHeight = 5.0;
      liftSpeed = 65.0;
      retractSpeed = 150.0;
      totalVolume = 0;
    }

    machineName = await _readMachineName();
    projectorType = 0;
    printTime = 0;
  }

  Future<String?> _readMachineName() async {
    if (_slicerInfoOffset == 0) return null;
    try {
      await _raf.setPosition(_slicerInfoOffset);
      final slicerHeader = await _readBytes(80);
      final sd = ByteData.sublistView(slicerHeader);

      // Machine name offset and size are at positions within slicer info
      // Layout varies by version, common: offset 16, size at 20
      final machineNameOffset = sd.getUint32(16, Endian.little);
      final machineNameSize = sd.getUint32(20, Endian.little);

      if (machineNameOffset > 0 && machineNameSize > 0 && machineNameSize < 256) {
        await _raf.setPosition(machineNameOffset);
        final nameBytes = await _readBytes(machineNameSize);
        // Trim null terminator
        int end = nameBytes.indexOf(0);
        if (end < 0) end = nameBytes.length;
        return String.fromCharCodes(nameBytes.sublist(0, end));
      }
    } catch (_) {}
    return null;
  }

  // ── Layer table ─────────────────────────────────────────────

  Future<void> _readLayerTable() async {
    _layerDefs = [];

    // Safety checks for corrupted headers
    if (layerTableOffset <= 0) {
      throw FormatException('Invalid layer table offset: $layerTableOffset');
    }
    if (layerCount == 0) {
      return; // Empty file is valid
    }
    if (layerCount > 100000) {
      throw FormatException(
        'Suspiciously large layer count ($layerCount) — likely corrupted header. '
        'Try reopening the file or check if it\'s a valid CTB format.'
      );
    }

    if (magic == _magicCtbV4 || magic == _magicCtbV4Encrypted) {
      await _readLayerTableV4();
    } else {
      await _readLayerTableLegacy();
    }
  }

  /// Read CTBv4/CTBv4E layer table.
  ///
  /// CTBv4 uses an indirect pointer table: each entry is 16 bytes
  /// (uint32 offset, uint32 pad, uint32 tableSize, uint32 pad).
  /// Each pointer leads to an 88-byte LayerDef structure.
  Future<void> _readLayerTableV4() async {
    await _raf.setPosition(layerTableOffset);

    // Read pointer table (16 bytes per entry)
    final pointerData = await _readBytes(layerCount * 16);
    final pd = ByteData.sublistView(pointerData);

    for (int i = 0; i < layerCount; i++) {
      final layerDefOffset = pd.getUint32(i * 16, Endian.little);
      final tableSize = pd.getUint32(i * 16 + 8, Endian.little);

      if (layerDefOffset == 0 || tableSize == 0) {
        throw FormatException(
          'Invalid layer pointer at index $i: offset=$layerDefOffset, tableSize=$tableSize'
        );
      }

      // Read the 88-byte LayerDef at the pointer target
      await _raf.setPosition(layerDefOffset);
      final entry = await _readBytes(tableSize);
      final ld = ByteData.sublistView(entry);

      // CTBv4 LayerDef layout (88 bytes):
      //   [ 0] uint32 TableSize
      //   [ 4] float  PositionZ
      //   [ 8] float  ExposureTime
      //   [12] float  LightOffDelay
      //   [16] uint32 DataOffset
      //   [20] uint32 Unknown
      //   [24] uint32 DataLength
      //   [28] uint32 Unknown
      //   [32] uint32 EncryptionSeed (0 for CTBv4E)
      //   [76] float  RestTimeAfterRetract
      //   [80] float  LightPWM
      _layerDefs.add(_CtbLayerDef(
        positionZ: ld.getFloat32(4, Endian.little),
        dataOffset: ld.getUint32(16, Endian.little),
        dataLength: ld.getUint32(24, Endian.little),
        exposureTime: ld.getFloat32(8, Endian.little),
        layerOffTimeS: ld.getFloat32(12, Endian.little),
      ));
    }
  }

  /// Read legacy (CBDDLP/CTBv2/v3) layer table with 36-byte direct entries.
  Future<void> _readLayerTableLegacy() async {
    await _raf.setPosition(layerTableOffset);

    for (int i = 0; i < layerCount; i++) {
      final entry = await _readBytes(36);
      if (entry.length < 36) {
        throw FormatException(
          'Truncated layer definition at index $i: '
          'expected 36 bytes, got ${entry.length}'
        );
      }

      final ld = ByteData.sublistView(entry);

      _layerDefs.add(_CtbLayerDef(
        positionZ: ld.getFloat32(0, Endian.little),
        dataOffset: ld.getUint32(4, Endian.little),
        dataLength: ld.getUint32(8, Endian.little),
        exposureTime: ld.getFloat32(16, Endian.little),
        layerOffTimeS: ld.getFloat32(20, Endian.little),
      ));
    }
  }

  // ── RLE decoding ────────────────────────────────────────────

  /// CTB RLE encoding (from UVtools ChituboxFile.cs DecodeCtbImage):
  ///
  /// Each entry starts with a code byte:
  ///   - Low 7 bits = greyscale value (0-127)
  ///   - Bit 7 (0x80) = run flag
  ///
  /// If run flag is set, the next byte determines run-length encoding format:
  ///   - 0xxxxxxx           → 7-bit run (1 byte, max 127)
  ///   - 10xxxxxx + 1 byte  → 14-bit run (2 bytes, max 16383)
  ///   - 110xxxxx + 2 bytes → 21-bit run (3 bytes, max 2097151)
  ///   - 1110xxxx + 3 bytes → 28-bit run (4 bytes, max 268435455)
  ///
  /// Non-zero greyscale values are expanded from 7-bit to 8-bit:
  ///   pixel = (value << 1) | 1
  Uint8List _decodeRle(Uint8List data, int pixelCount) {
    final output = Uint8List(pixelCount);
    int pixel = 0;
    int n = 0;

    while (n < data.length && pixel < pixelCount) {
      int code = data[n++];
      int stride = 1;

      if (code & 0x80 != 0) {
        // Run flag set — extract 7-bit greyscale value and read run length
        code &= 0x7F;
        if (n >= data.length) break;

        final slen = data[n++];

        if ((slen & 0x80) == 0) {
          // 0xxxxxxx: 7-bit run length
          stride = slen;
        } else if ((slen & 0xC0) == 0x80) {
          // 10xxxxxx: 14-bit run length
          if (n >= data.length) break;
          stride = ((slen & 0x3F) << 8) + data[n++];
        } else if ((slen & 0xE0) == 0xC0) {
          // 110xxxxx: 21-bit run length
          if (n + 1 >= data.length) break;
          stride = ((slen & 0x1F) << 16) + (data[n] << 8) + data[n + 1];
          n += 2;
        } else if ((slen & 0xF0) == 0xE0) {
          // 1110xxxx: 28-bit run length
          if (n + 2 >= data.length) break;
          stride = ((slen & 0x0F) << 24) +
              (data[n] << 16) + (data[n + 1] << 8) + data[n + 2];
          n += 3;
        } else {
          // Unknown prefix (0xF0+). UVtools silently treats this as stride=1.
          // This should not occur in valid data, but be tolerant like UVtools.
          stride = 1;
        }
      }

      // 7-bit to 8-bit expansion (0 stays 0, non-zero: (v << 1) | 1)
      final pixelValue = code == 0 ? 0 : ((code << 1) | 1);

      final end = math.min(pixel + stride, pixelCount);
      for (int j = pixel; j < end; j++) {
        output[j] = pixelValue;
      }
      pixel = end;
    }

    return output;
  }

  /// Decrypt layer data using UVtools' LFSR-based XOR cipher.
  ///
  /// The key stream is derived from both the file-level encryption key and
  /// the layer index, providing per-layer XOR variation.
  ///
  /// Algorithm (from UVtools ChituboxFile.cs LayerRleCryptBuffer):
  ///   init = seed * 0x2d83cdac + 0xd8a83423
  ///   key  = (layerIndex * 0x1e1530cd + 0xec3d47cd) * init
  ///   For each byte: XOR with (key >> (8 * (i % 4))) & 0xFF
  ///   Every 4 bytes: key += init
  Uint8List _decryptLayerData(Uint8List data, int layerIndex) {
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

  // ── Preview images ──────────────────────────────────────────

  Future<Uint8List?> _readPreview(int offset) async {
    try {
      await _raf.setPosition(offset);
      final header = await _readBytes(32);
      final hd = ByteData.sublistView(header);

      final width = hd.getUint32(0, Endian.little);
      final height = hd.getUint32(4, Endian.little);
      final dataOffset = hd.getUint32(8, Endian.little);
      final dataLength = hd.getUint32(12, Endian.little);

      if (width == 0 || height == 0 || dataLength == 0) return null;
      if (width > 4096 || height > 4096) return null; // sanity check

      await _raf.setPosition(dataOffset);
      final rleData = await _readBytes(dataLength);

      // CTB preview uses RLE-compressed RGB15 encoding (not raw RGB565).
      //
      // Each 16-bit word (little-endian) has this bit layout:
      //   Bits 15-11: Red   (5 bits)
      //   Bits 10-6:  Green (5 bits)
      //   Bit  5:     RLE repeat flag (REPEATRGB15MASK = 0x20)
      //   Bits 4-0:   Blue  (5 bits)
      //
      // If bit 5 is set, the next 2 bytes encode a repeat count:
      //   repeat = (rleData[i] & 0xFF) | ((rleData[i+1] & 0x0F) << 8) + 1
      //
      // If bit 5 is clear, the pixel appears exactly once.

      final totalPixels = width * height;
      final rgbPixels = Uint8List(totalPixels * 3);
      int pixelIdx = 0;
      int i = 0;

      while (i < rleData.length - 1 && pixelIdx < totalPixels) {
        final lo = rleData[i++];
        final hi = rleData[i++];
        final dot = (hi << 8) | lo;

        // Extract RGB555 channels (bit 5 is RLE flag, not color data)
        final r = ((dot >> 11) & 0x1F) << 3;
        final g = ((dot >> 6) & 0x1F) << 3;
        final b = (dot & 0x1F) << 3;

        int repeat = 1;
        if ((dot & 0x20) != 0) {
          // RLE flag set — next 2 bytes encode repeat count
          if (i + 1 < rleData.length) {
            repeat += (rleData[i] & 0xFF) | ((rleData[i + 1] & 0x0F) << 8);
            i += 2;
          }
        }

        // Write pixel `repeat` times
        for (int r2 = 0; r2 < repeat && pixelIdx < totalPixels; r2++) {
          final dst = pixelIdx * 3;
          rgbPixels[dst] = r;
          rgbPixels[dst + 1] = g;
          rgbPixels[dst + 2] = b;
          pixelIdx++;
        }
      }

      return _buildRgbPng(width.toInt(), height.toInt(), rgbPixels);
    } catch (_) {
      return null;
    }
  }

  /// Build an uncompressed PNG from RGB pixel data.
  /// Used for thumbnails where compression overhead isn't worth it.
  Uint8List _buildRgbPng(int width, int height, Uint8List rgbPixels) {
    // Build scanlines: 1 filter byte + 3 bytes per pixel
    final bytesPerRow = width * 3;
    final scanlineSize = 1 + bytesPerRow;
    final scanlines = Uint8List(scanlineSize * height);

    // Copy RGB pixels with filter type 0 (None) at start of each row
    int srcIdx = 0;
    for (int y = 0; y < height; y++) {
      final dstStart = y * scanlineSize;
      scanlines[dstStart] = 0; // filter type: None
      scanlines.setRange(dstStart + 1, dstStart + 1 + bytesPerRow, rgbPixels, srcIdx);
      srcIdx += bytesPerRow;
    }

    // Compress scanlines using ZLibEncoder from dart:io
    final compressed = ZLibEncoder(level: 6).convert(scanlines);
    final compressedBytes = compressed is Uint8List ? compressed : Uint8List.fromList(compressed);

    // Build PNG file chunks
    final parts = <Uint8List>[];

    // PNG signature
    parts.add(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]));

    // IHDR chunk
    final ihdr = Uint8List(13);
    final ihdrView = ByteData.sublistView(ihdr);
    ihdrView.setUint32(0, width, Endian.big);
    ihdrView.setUint32(4, height, Endian.big);
    ihdr[8] = 8; // bitDepth
    ihdr[9] = 2; // colorType = RGB
    parts.add(_buildPngChunk(0x49484452, ihdr)); // IHDR

    // IDAT chunk
    parts.add(_buildPngChunk(0x49444154, compressedBytes)); // IDAT

    // IEND chunk
    parts.add(_buildPngChunk(0x49454E44, Uint8List(0))); // IEND

    // Concatenate all parts
    int totalSize = 0;
    for (final p in parts) {
      totalSize += p.length;
    }
    final result = Uint8List(totalSize);
    int offset = 0;
    for (final p in parts) {
      result.setRange(offset, offset + p.length, p);
      offset += p.length;
    }
    return result;
  }

  /// Build a single PNG chunk: [length][type][data][crc].
  Uint8List _buildPngChunk(int type, Uint8List data) {
    final chunk = Uint8List(12 + data.length);
    final view = ByteData.sublistView(chunk);

    // Length (4 bytes)
    view.setUint32(0, data.length, Endian.big);

    // Type (4 bytes)
    view.setUint32(4, type, Endian.big);

    // Data
    chunk.setRange(8, 8 + data.length, data);

    // CRC-32 calculation (over type + data)
    int crc = 0xFFFFFFFF;
    crc = _crc32Lookup[(crc ^ ((type >> 24) & 0xFF)) & 0xFF] ^ (crc >>> 8);
    crc = _crc32Lookup[(crc ^ ((type >> 16) & 0xFF)) & 0xFF] ^ (crc >>> 8);
    crc = _crc32Lookup[(crc ^ ((type >> 8) & 0xFF)) & 0xFF] ^ (crc >>> 8);
    crc = _crc32Lookup[(crc ^ (type & 0xFF)) & 0xFF] ^ (crc >>> 8);
    for (int i = 0; i < data.length; i++) {
      crc = _crc32Lookup[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
    }
    crc ^= 0xFFFFFFFF;

    // CRC (4 bytes)
    ByteData.sublistView(chunk).setUint32(8 + data.length, crc, Endian.big);

    return chunk;
  }

  // ── I/O helpers ─────────────────────────────────────────────

  Future<Uint8List> _readBytes(int count) async {
    final bytes = Uint8List(count);
    int offset = 0;
    while (offset < count) {
      final read = await _raf.readInto(bytes, offset, count);
      if (read == 0) break;
      offset += read;
    }
    return bytes;
  }

  /// Derive encryption keys for CTBv4E by XOR-decoding base64 strings
  static List<int> _deriveKey(String base64Str) {
    try {
      final decoded = base64Decode(base64Str);
      final xorKeyBytes = _xorKey.codeUnits;
      final result = Uint8List(decoded.length);
      for (int i = 0; i < decoded.length; i++) {
        result[i] = decoded[i] ^ xorKeyBytes[i % xorKeyBytes.length];
      }
      return result;
    } catch (e) {
      throw Exception('Failed to derive encryption key: $e');
    }
  }

  /// Decrypt settings block for CTBv4E using AES-256-CBC with XOR-derived keys
  Uint8List _decryptSettings(Uint8List encryptedData) {
    try {
      // Derive AES key and IV from XOR-obfuscated base64 strings
      final keyBytes = Uint8List.fromList(_deriveKey(_secret1)); // 32 bytes for AES-256
      final ivBytes = Uint8List.fromList(_deriveKey(_secret2));   // 16 bytes for CBC IV

      // Create AES cipher in CBC mode using PointyCastle
      final keyParam = KeyParameter(keyBytes);
      final params = ParametersWithIV(keyParam, ivBytes);
      
      final cipher = CBCBlockCipher(AESEngine());
      cipher.init(false, params); // false = decrypt

      // Decrypt the data (no padding handling - data should be properly aligned)
      final decrypted = Uint8List(encryptedData.length);
      int offset = 0;
      
      while (offset < encryptedData.length) {
        offset += cipher.processBlock(encryptedData, offset, decrypted, offset);
      }

      return decrypted;
    } catch (e) {
      throw FormatException(
        'Failed to decrypt CTBv4E settings block: $e. '
        'File may be corrupted or use different encryption keys.',
      );
    }
  }
}

class _CtbLayerDef {
  final double positionZ;
  final int dataOffset;
  final int dataLength;
  final double exposureTime;
  final double layerOffTimeS;

  const _CtbLayerDef({
    required this.positionZ,
    required this.dataOffset,
    required this.dataLength,
    required this.exposureTime,
    required this.layerOffTimeS,
  });
}

/// CRC-32 lookup table for PNG chunk verification (standard polynomial 0xEDB88320).
final List<int> _crc32Lookup = (() {
  final table = List<int>.filled(256, 0);
  for (int i = 0; i < 256; i++) {
    int c = i;
    for (int k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[i] = c;
  }
  return table;
})();
