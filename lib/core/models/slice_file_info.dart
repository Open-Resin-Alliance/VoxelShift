import 'dart:typed_data';

/// Metadata read from a CTB (or compatible) slice file.
class SliceFileInfo {
  final String sourcePath;
  final int resolutionX;
  final int resolutionY;
  final double displayWidth;
  final double displayHeight;
  final double machineZ;
  final double layerHeight;
  final int layerCount;
  final double bottomExposureTime;
  final double exposureTime;
  final int bottomLayerCount;
  final double liftHeight;
  final double liftSpeed;
  final double retractSpeed;
  final String? machineName;
  final Uint8List? thumbnailPng;

  const SliceFileInfo({
    required this.sourcePath,
    required this.resolutionX,
    required this.resolutionY,
    required this.displayWidth,
    required this.displayHeight,
    required this.machineZ,
    required this.layerHeight,
    required this.layerCount,
    required this.bottomExposureTime,
    required this.exposureTime,
    required this.bottomLayerCount,
    required this.liftHeight,
    required this.liftSpeed,
    required this.retractSpeed,
    this.machineName,
    this.thumbnailPng,
  });

  /// Detected resolution class (e.g. "12K" or "16K").
  String get detectedResolutionLabel {
    if (resolutionX >= 15000) return '16K';
    if (resolutionX >= 11000) return '12K';
    if (resolutionX >= 7500) return '8K';
    return '${resolutionX}x$resolutionY';
  }
}
