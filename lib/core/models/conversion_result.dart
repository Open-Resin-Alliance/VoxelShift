import 'printer_profile.dart';
import 'slice_file_info.dart';

/// Result returned after a conversion attempt.
class ConversionResult {
  final bool success;
  final String? errorMessage;
  final String outputPath;
  final SliceFileInfo sourceInfo;
  final PrinterProfile targetProfile;
  final int layerCount;
  final int outputFileSizeBytes;
  final Duration duration;

  const ConversionResult({
    required this.success,
    this.errorMessage,
    required this.outputPath,
    required this.sourceInfo,
    required this.targetProfile,
    required this.layerCount,
    required this.outputFileSizeBytes,
    required this.duration,
  });
}
