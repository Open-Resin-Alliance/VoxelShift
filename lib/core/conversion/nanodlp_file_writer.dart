import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';

import '../models/layer_area_info.dart';
import '../models/nanodlp_metadata.dart';
import 'native_zip_writer.dart';

/// Writes a NanoDLP-compatible plate file (ZIP with PNG layers + JSON metadata).
///
/// PNGs are stored with ZIP DEFLATE to minimize .nanodlp size.
/// JSON metadata files are small and use DEFLATE as well.
/// This trades a bit of write time for much smaller output archives.
class NanoDlpFileWriter {
  /// Create a .nanodlp (ZIP) plate file from layer images + metadata.
  Future<void> writeAsync(
    String outputPath,
    List<Uint8List> layers,
    NanoDlpPlateMetadata metadata, {
    List<LayerAreaInfo>? layerAreaInfos,
    void Function(double progress)? onProgress,
  }) async {
    final dir = File(outputPath).parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Compute area stats
    double totalSolidArea = 0;
    if (layerAreaInfos != null && layerAreaInfos.isNotEmpty) {
      double avgArea = 0;
      for (final info in layerAreaInfos) {
        avgArea += info.totalSolidArea;
      }
      avgArea /= layerAreaInfos.length;
      totalSolidArea = (avgArea * metadata.layerHeightMm * metadata.layerCount) / 1000;
    }

    // Compute bounding box
    double xMin = 0, xMax = 0, yMin = 0, yMax = 0;
    if (layerAreaInfos != null && layerAreaInfos.isNotEmpty) {
      final halfW = metadata.displayWidthMm / 2;
      final halfH = metadata.displayHeightMm / 2;
      int pixMinX = 0x7FFFFFFF, pixMinY = 0x7FFFFFFF;
      int pixMaxX = 0, pixMaxY = 0;
      for (final info in layerAreaInfos) {
        if (info.areaCount == 0) continue;
        if (info.minX < pixMinX) pixMinX = info.minX;
        if (info.minY < pixMinY) pixMinY = info.minY;
        if (info.maxX > pixMaxX) pixMaxX = info.maxX;
        if (info.maxY > pixMaxY) pixMaxY = info.maxY;
      }
      xMin = pixMinX * metadata.xPixelSizeMm - halfW;
      xMax = (pixMaxX + 1) * metadata.xPixelSizeMm - halfW;
      yMin = pixMinY * metadata.yPixelSizeMm - halfH;
      yMax = (pixMaxY + 1) * metadata.yPixelSizeMm - halfH;
    }

    final zMax = double.parse(
      (metadata.layerCount * metadata.layerHeightMm).toStringAsFixed(4)
    );

    // ── Build JSON blobs once (shared by native and fallback paths) ──
    final plateJson = _encodeJson(_buildPlateJson(
      totalSolidArea: totalSolidArea,
      layersCount: layers.length,
      xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax, zMax: zMax,
    ));

    final profileJson = _encodeJson(_buildProfileJson(metadata));

    Uint8List? infoJson;
    if (layerAreaInfos != null && layerAreaInfos.isNotEmpty) {
      infoJson = _encodeJson(layerAreaInfos.map((a) => a.toJson()).toList());
    }

    final optionsJson = _encodeJson(_buildOptionsJson(metadata));

    final nativeEntries = <NativeZipEntry>[
      NativeZipEntry(name: 'plate.json', data: plateJson),
      NativeZipEntry(name: 'profile.json', data: profileJson),
      if (infoJson != null) NativeZipEntry(name: 'info.json', data: infoJson),
      NativeZipEntry(name: 'options.json', data: optionsJson),
      if (metadata.thumbnailPng != null && metadata.thumbnailPng!.isNotEmpty)
        NativeZipEntry(name: '3d.png', data: metadata.thumbnailPng!),
    ];

    for (int i = 0; i < layers.length; i++) {
      nativeEntries.add(NativeZipEntry(name: '${i + 1}.png', data: layers[i]));
    }

    final usedNative = await NativeZipWriter.instance.writeArchive(
      outputPath,
      nativeEntries,
      onProgress: onProgress,
    );

    if (usedNative) {
      return;
    }

    final archive = Archive();
    archive.addFile(ArchiveFile('plate.json', plateJson.length, plateJson));
    archive.addFile(ArchiveFile('profile.json', profileJson.length, profileJson));
    if (infoJson != null) {
      archive.addFile(ArchiveFile('info.json', infoJson.length, infoJson));
    }
    archive.addFile(ArchiveFile('options.json', optionsJson.length, optionsJson));

    // ── 3d.png (thumbnail) ──────────────────────────────
    if (metadata.thumbnailPng != null && metadata.thumbnailPng!.isNotEmpty) {
      final thumbFile = ArchiveFile(
        '3d.png',
        metadata.thumbnailPng!.length,
        metadata.thumbnailPng!,
      );
      archive.addFile(thumbFile);
    }

    // ── Layer PNGs: 1.png, 2.png, ... ───────────────────
    // Use ZIP DEFLATE for maximum size reduction.
    DateTime lastReportTime = DateTime.now();
    const reportIntervalMs = 250;
    
    for (int i = 0; i < layers.length; i++) {
      final layerFile = ArchiveFile(
        '${i + 1}.png',
        layers[i].length,
        layers[i],
      );
      archive.addFile(layerFile);
      
      // Debounce progress callbacks: only report every 250ms or at the end
      final now = DateTime.now();
      if (now.difference(lastReportTime).inMilliseconds >= reportIntervalMs ||
          i == layers.length - 1) {
        onProgress?.call((i + 1) / layers.length);
        lastReportTime = now;
      }
      
      // Yield every 10 layers to keep UI responsive
      if (i % 10 == 9 || i == layers.length - 1) {
        await Future.delayed(Duration.zero);
      }
    }

    // Write ZIP to temp file, then atomically rename.
    // PNG layers are already DEFLATE-compressed, so re-compressing the whole
    // archive at level 9 adds a lot of CPU time for limited gains.
    // Use low compression for much faster packaging on large jobs.
    final tempPath = '$outputPath.tmp';
    
    // Yield before expensive ZIP encoding
    await Future.delayed(Duration.zero);
    
    final zipData = ZipEncoder().encode(archive, level: 1);

    final tempFile = File(tempPath);
    await tempFile.writeAsBytes(zipData);

    // Atomic move
    final outFile = File(outputPath);
    if (await outFile.exists()) await outFile.delete();
    await tempFile.rename(outputPath);
  }

  Uint8List _encodeJson(Object data) {
    final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
    return Uint8List.fromList(utf8.encode(jsonStr));
  }

  Map<String, dynamic> _buildPlateJson({
    required double totalSolidArea,
    required int layersCount,
    required double xMin,
    required double xMax,
    required double yMin,
    required double yMax,
    required double zMax,
  }) {
    return {
      'PlateID': 0,
      'ProfileID': 0,
      'Profile': null,
      'CreatedDate': 0,
      'StopLayers': '',
      'Path': '',
      'LowQualityLayerNumber': 0,
      'AutoCenter': 0,
      'Updated': 0,
      'LastPrint': 0,
      'PrintTime': 0,
      'PrintEst': 0,
      'ImageRotate': 0,
      'MaskEffect': 0,
      'XRes': 0,
      'YRes': 0,
      'ZRes': 0,
      'MultiCure': '',
      'MultiThickness': '',
      'CureTimes': null,
      'DynamicThickness': null,
      'Offset': 0,
      'OverHangs': null,
      'Risky': false,
      'IsFaulty': false,
      'IsOverhang': false,
      'HasCup': false,
      'HasResinTrap': false,
      'Repaired': false,
      'Deleted': false,
      'Corrupted': false,
      'FaultyLayers': null,
      'TotalSolidArea': totalSolidArea,
      'BlackoutData': '',
      'LayersCount': layersCount,
      'Processed': true,
      'Feedback': false,
      'ReSliceNeeded': false,
      'MultiMaterial': false,
      'PrintID': 0,
      'MC': {
        'StartX': 0, 'StartY': 0, 'Width': 0, 'Height': 0,
        'X': null, 'Y': null, 'MultiCureGap': 0, 'Count': 0,
      },
      'XMin': xMin,
      'XMax': xMax,
      'YMin': yMin,
      'YMax': yMax,
      'ZMin': 0.0,
      'ZMax': zMax,
    };
  }

  Map<String, dynamic> _buildProfileJson(NanoDlpPlateMetadata m) {
    return {
      'ResinID': 0,
      'ProfileID': 0,
      'Title': 'VoxelShift — ${m.targetPrinterProfile ?? "Imported"}',
      'Desc': 'Imported from ${m.sourceFile ?? "CTB"} via VoxelShift',
      'Color': '',
      'ResinPrice': 0,
      'OptimumTemperature': 0,
      'Depth': _roundDepth(m.layerHeightMm * 1000),
      'SupportTopWait': 0.0,
      'SupportWaitHeight': m.liftHeightMm,
      'SupportDepth': _roundDepth(m.layerHeightMm * 1000),
      'SupportWaitBeforePrint': 0.0,
      'SupportWaitAfterPrint': 1.0,
      'TransitionalLayer': 0,
      'Updated': 0,
      'ManufacturerLock': false,
      'CustomValues': <String, dynamic>{},
      'Type': 0,
      'ZStepWait': 0,
      'LiftSpeed': m.liftSpeedMmPerMin,
      'RetractSpeed': m.retractSpeedMmPerMin,
      'TopWait': 0.0,
      'WaitHeight': m.liftHeightMm,
      'CureTime': m.normalExposureTimeSec,
      'WaitBeforePrint': 0.0,
      'WaitAfterPrint': 0.4,
      'SupportCureTime': m.bottomExposureTimeSec,
      'SupportLayerNumber': m.bottomLayerCount,
      'AdaptSlicing': 0,
      'AdaptSlicingMin': 0,
      'AdaptSlicingMax': 0,
      'SupportOffset': 0,
      'Offset': 0,
      'ErodeStartMode': 0,
      'ErodeStartLayer': 0,
      'ErodeStartHeight': 0,
      'FillColor': '#ffffff',
      'BlankColor': '#000000',
      'DimAmount': 0,
      'DimWall': 0,
      'DimBorder': 0,
      'DimSkip': 0,
      'PixelDiming': 0,
      'HatchingType': 0,
      'ElephantMidExposure': 0,
      'EFMEMode': 0,
      'EFMEMaxLayer': 0,
      'EFMEContinuous': 0,
      'EFMEGuardBand': 0,
      'ElephantType': 0,
      'ElephantAmount': 0,
      'ElephantWall': 0,
      'ElephantBorder': 0,
      'ElephantThickness': 0,
      'ElephantLayers': 0,
      'HatchingWall': 0,
      'HatchingGap': 0,
      'HatchingOuterWall': 0,
      'HatchingTopCap': 0,
      'HatchingBottomCap': 0,
      'HatchingBorder': 0,
      'HatchingSpace': 0,
      'HatchingOuter': 0,
      'HatchingTop': 0,
      'HatchingBottom': 0,
      'MultiCureGap': 0,
      'AntiAliasThreshold': 0,
      'AntiAlias': 0,
      'AntiAlias3D': 0,
      'ImageRotate': 0,
      'IgnoreMask': 0,
      'XYRes': 0.0,
      'YRes': 0.0,
      'ZResPerc': 0.0,
      'XScale': 100,
      'YScale': 100,
      'ZScale': 100,
      'AdvancedBaseLayer': 0,
      'BaseLayerSeedSize': 0,
      'BaseLayerSeedSpacing': 0,
      'BaseLayerSeedExposure': 0,
      'BaseLayerLatticeExposure': 0,
      'BaseLayerFinalExposure': 0,
      'BaseLayerMaxLayers': 0,
      'RingExposureEnabled': 0,
      'RingThickness': 1.5,
      'RingExposureReduction': 30,
      'RingGradientFalloff': 0,
      'RingExposureMode': 0,
      'RingMaxLayer': 20,
      'DynamicCureTime': '',
      'DynamicSpeed': '',
      'DynamicRetractSpeed': '',
      'ShieldBeforeLayer': '',
      'ShieldAfterLayer': '',
      'ShieldDuringCure': '',
      'ShieldStart': '',
      'ShieldResume': '',
      'ShieldFinish': '',
      'LaserCode': '',
      'ShutterOpenGcode': '',
      'ShutterCloseGcode': '',
      'SeparationDetection': '',
      'ResinLevelDetection': '',
      'AutoLevelDetection': '',
      'CrashDetection': '',
      'DynamicWait': '',
      'SlowSectionHeight': 0.0,
      'SlowSectionStepWait': 1.0,
      'JumpPerLayer': 0,
      'DynamicWaitAfterLift': '',
      'DynamicLift': '',
      'JumpHeight': 0.0,
      'LowQualityCureTime': 0.0,
      'LowQualitySkipPerLayer': 0,
      'XYResPerc': 0.0,
    };
  }

  Map<String, dynamic> _buildOptionsJson(NanoDlpPlateMetadata m) {
    return {
      'Type': '',
      'URL': '',
      'PWidth': m.resolutionX,
      'PHeight': m.resolutionY,
      'ScaleFactor': 0,
      'StartLayer': 0,
      'SupportDepth': _roundDepth(m.layerHeightMm * 1000),
      'SupportLayerNumber': m.bottomLayerCount,
      'Thickness': _roundDepth(m.layerHeightMm * 1000),
      'XOffset': m.resolutionX ~/ 2,
      'YOffset': m.resolutionY ~/ 2,
      'ZOffset': 0,
      'XPixelSize': _roundPixelSize(m.xPixelSizeMm),
      'YPixelSize': _roundPixelSize(m.yPixelSizeMm),
      'Mask': null,
      'AutoCenter': 0,
      'SliceFromZero': false,
      'DisableValidator': false,
      'PreviewGenerate': false,
      'Running': false,
      'Debug': false,
      'IsFaulty': false,
      'Corrupted': false,
      'MultiMaterial': false,
      'AdaptExport': '',
      'PreviewColor': '',
      'FaultyLayers': null,
      'OverhangLayers': null,
      'LayerStatus': null,
      'Boundary': {
        'XMin': 0.0, 'XMax': 0.0, 'YMin': 0.0, 'YMax': 0.0,
        'ZMin': 0.0, 'ZMax': 0.0,
      },
      'Area': {'PlateID': 0, 'Layers': <dynamic>[], 'Kill': false},
      'MC': {
        'StartX': 0, 'StartY': 0, 'Width': 0, 'Height': 0,
        'X': null, 'Y': null, 'MultiCureGap': 0, 'Count': 0,
      },
      'MultiThickness': '',
      'ExportPath': '',
      'NetworkSave': '',
      'File': '',
      'FileSize': 0,
      'AdaptSlicing': 0,
      'AdaptSlicingMin': 0,
      'AdaptSlicingMax': 0,
      'SupportOffset': 0,
      'Offset': 0,
      'ErodeStartMode': 0,
      'ErodeStartLayer': 0,
      'ErodeStartHeight': 0,
      'FillColor': '#ffffff',
      'BlankColor': '#000000',
      'DimAmount': 0,
      'DimWall': 0,
      'DimBorder': 0,
      'DimSkip': 0,
      'PixelDiming': 0,
      'HatchingType': 0,
      'ElephantMidExposure': 0,
      'EFMEMode': 0,
      'EFMEMaxLayer': 0,
      'EFMEContinuous': 0,
      'EFMEGuardBand': 0,
      'ElephantType': 0,
      'ElephantAmount': 0,
      'ElephantWall': 0,
      'ElephantBorder': 0,
      'ElephantThickness': 0,
      'ElephantLayers': 0,
      'HatchingWall': 0,
      'HatchingGap': 0,
      'HatchingOuterWall': 0,
      'HatchingTopCap': 0,
      'HatchingBottomCap': 0,
      'HatchingBorder': 0,
      'HatchingSpace': 0,
      'HatchingOuter': 0,
      'HatchingTop': 0,
      'HatchingBottom': 0,
      'MultiCureGap': 0,
      'AntiAliasThreshold': 0,
      'AntiAlias': 0,
      'AntiAlias3D': 0,
      'ImageRotate': 0,
      'IgnoreMask': 0,
      'XYRes': 0,
      'ZResPerc': 0,
      'XScale': 100,
      'YScale': 100,
      'ZScale': 100,
      'AdvancedBaseLayer': 0,
      'BaseLayerSeedSize': 0,
      'BaseLayerSeedSpacing': 0,
      'BaseLayerSeedExposure': 0,
      'BaseLayerLatticeExposure': 0,
      'BaseLayerFinalExposure': 0,
      'BaseLayerMaxLayers': 0,
      'RingExposureEnabled': 0,
      'RingThickness': 1.5,
      'RingExposureReduction': 30,
      'RingGradientFalloff': 0,
      'RingExposureMode': 0,
      'RingMaxLayer': 20,
      'PreviewWidth': 0,
      'PreviewHeight': 0,
      'AreaPaddingTop': 0,
      'AreaPaddingBottom': 0,
      'AreaPaddingLeft': 0,
      'AreaPaddingRight': 0,
      'BarrelFactor': 0.0,
      'BarrelX': 0.0,
      'BarrelY': 0.0,
      'ImageMirror': 1,
      'DisplayController': 1,
      'LightOutputFormula': '',
      'ObjectCount': 0,
      'CurrentObjectCount': 0,
      'PlateID': 0,
      'LayerID': 0,
      'LayerCount': 0,
      'UUID': '',
      'DynamicThickness': null,
      'XRes': _roundToInt(m.xPixelSizeMm * 1000),
      'FillColorRGB': {'R': 255, 'G': 255, 'B': 255, 'A': 255},
      'BlankColorRGB': {'R': 0, 'G': 0, 'B': 0, 'A': 255},
      'ExportType': 0,
      'OutputPath': '',
      'Suffix': '',
      'SkipEmpty': 0,
    };
  }

  /// Round pixel size to avoid float precision noise (e.g. 0.0139999 → 0.014).
  static double _roundPixelSize(double value) {
    return (value * 1000).roundToDouble() / 1000;
  }

  /// Round depth (µm) to avoid float precision noise from IEEE 754.
  /// E.g. 0.05mm * 1000 = 50.00000074505806 → 50.
  static double _roundDepth(double value) {
    return (value * 10).roundToDouble() / 10;
  }

  /// Round to integer (for XRes in µm).
  static int _roundToInt(double value) {
    return value.round();
  }
}
