import 'dart:typed_data';

/// Metadata passed from the converter to the file writer.
class NanoDlpPlateMetadata {
  String? sourceFile;
  String? sourcePrinterProfile;
  String? targetPrinterProfile;
  int resolutionX;
  int resolutionY;
  double displayWidthMm;
  double displayHeightMm;
  double maxZHeightMm;
  double layerHeightMm;
  int layerCount;
  double bottomExposureTimeSec;
  double normalExposureTimeSec;
  int bottomLayerCount;
  double liftHeightMm;
  double liftSpeedMmPerMin;
  double retractSpeedMmPerMin;
  double xPixelSizeMm;
  double yPixelSizeMm;
  Uint8List? thumbnailPng;

  NanoDlpPlateMetadata({
    this.sourceFile,
    this.sourcePrinterProfile,
    this.targetPrinterProfile,
    this.resolutionX = 0,
    this.resolutionY = 0,
    this.displayWidthMm = 0,
    this.displayHeightMm = 0,
    this.maxZHeightMm = 0,
    this.layerHeightMm = 0,
    this.layerCount = 0,
    this.bottomExposureTimeSec = 0,
    this.normalExposureTimeSec = 0,
    this.bottomLayerCount = 0,
    this.liftHeightMm = 0,
    this.liftSpeedMmPerMin = 0,
    this.retractSpeedMmPerMin = 0,
    this.xPixelSizeMm = 0,
    this.yPixelSizeMm = 0,
    this.thumbnailPng,
  });
}
