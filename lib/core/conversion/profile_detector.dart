import '../models/printer_profile.dart';

/// Detects printer profiles based on CTB resolution.
class PrinterProfileDetector {
  /// Resolution equivalence classes - different pixel widths for same hardware.
  ///
  /// 16K panel variations:
  ///   - 15120: 8-bit RGB driver output (5040 RGB pixels @ 3 subpixels each)
  ///   - 15136: 3-bit greyscale driver output (7568 pixels @ 2 subpixels each)  
  ///   - 15360: Full panel resolution (generic slicer profiles)
  static const Map<String, List<int>> resolutionClasses = {
    '12K': [11520], // 12K hardware
    '16K': [15120, 15136, 15360], // 16K hardware (see above)
  };

  /// Get the hardware class for a given resolution.
  static String? getResolutionClass(int resolutionX) {
    for (final entry in resolutionClasses.entries) {
      if (entry.value.contains(resolutionX)) {
        return entry.key;
      }
    }
    return null;
  }

  /// Match a source CTB resolution to the corresponding Athena 2 profile.
  /// For 16K files (15120/15136/15360), defaults to 3-bit (user can override in UI).
  static PrinterProfile? detectTargetProfile(int resolutionX, int resolutionY) {
    final hwClass = getResolutionClass(resolutionX);
    if (hwClass == '16K') return PrinterProfile.athena2_16K_3Bit;
    if (hwClass == '12K') return PrinterProfile.athena2_12K;
    return null;
  }

  /// Try to identify the source slicer profile that produced the CTB.
  static PrinterProfile? detectSourceProfile(int resolutionX, int resolutionY) {
    final hwClass = getResolutionClass(resolutionX);
    if (hwClass == '16K') return PrinterProfile.saturn4Ultra_16K;
    if (hwClass == '12K') return PrinterProfile.saturn4Ultra_12K;
    return null;
  }

  /// Get all target profiles matching this resolution class.
  static List<PrinterProfile> getTargetProfilesForResolution(
    int resolutionX,
    int resolutionY,
  ) {
    final hwClass = getResolutionClass(resolutionX);
    if (hwClass == null) return [];

    return PrinterProfile.targetProfiles
        .where((p) => p.resolutionLabel == hwClass)
        .toList();
  }

  /// Validates that the CTB resolution is suitable for conversion.
  static (bool valid, String? error) validateResolution(int resolutionX, int resolutionY) {
    final hwClass = getResolutionClass(resolutionX);
    if (hwClass == null) {
      return (
        false,
        'Unsupported resolution ${resolutionX}x$resolutionY. '
            'Supported: 12K (11520px), 16K (15120/15136/15360px).',
      );
    }
    return (true, null);
  }
}
