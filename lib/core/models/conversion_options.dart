import 'printer_profile.dart';

/// Options controlling the CTB → NanoDLP conversion.
class ConversionOptions {
  /// Override the target printer profile (null = auto-detect).
  PrinterProfile? targetProfile;

  /// Override the max Z height in mm (null = use profile default).
  double? maxZHeightOverride;

  /// Output directory. Defaults to same directory as the input file.
  String? outputDirectory;

  /// Output file name without extension. Defaults to input file name.
  String? outputFileName;

  /// Use GPU packing when available (default true).
  bool useGpuPacking;

  ConversionOptions({
    this.targetProfile,
    this.maxZHeightOverride,
    this.outputDirectory,
    this.outputFileName,
    this.useGpuPacking = true,
  });
}
