import 'board_type.dart';

/// Known printer profile for auto-detection based on CTB resolution.
class PrinterProfile {
  final String name;
  final String manufacturer;
  final BoardType board;
  final int resolutionX;
  final int resolutionY;
  final double displayWidth; // mm
  final double displayHeight; // mm
  final double maxZHeight; // mm
  final String resolutionLabel;

  /// The native PNG output width for the board's driver.
  ///
  /// 8-bit RGB: subpixelWidth / 3 (RGB pixels).
  /// 3-bit greyscale: subpixelWidth / 2 (greyscale pixels).
  final int pngOutputWidth;

  const PrinterProfile({
    required this.name,
    required this.manufacturer,
    required this.board,
    required this.resolutionX,
    required this.resolutionY,
    required this.displayWidth,
    required this.displayHeight,
    required this.maxZHeight,
    required this.resolutionLabel,
    required this.pngOutputWidth,
  });

  /// Pixel pitch in µm.
  double get pixelPitchUm => displayWidth / resolutionX * 1000;

  // ── Well-known profiles ──────────────────────────────────────

  // ── Well-known output widths ─────────────────────────────────
  //
  // 12K panel:
  //   8-bit RGB driver:  11520 subpixels → 11520/3 = 3840 RGB pixels
  //
  // 16K panel:
  //   8-bit RGB driver:  15120 subpixels → 15120/3 = 5040 RGB pixels
  //   3-bit driver:      15136 subpixels → 15136/2 = 7568 greyscale pixels

  static const athena2_12K = PrinterProfile(
    name: 'Athena 2 12K',
    manufacturer: 'Concepts3D',
    board: BoardType.rgb8Bit,
    resolutionX: 11520,
    resolutionY: 5120,
    displayWidth: 218.88,
    displayHeight: 122.88,
    maxZHeight: 235,
    resolutionLabel: '12K',
    pngOutputWidth: 3840,   // 11520 / 3
  );

  static const athena2_16K = PrinterProfile(
    name: 'Athena 2 16K (8-bit)',
    manufacturer: 'Concepts3D',
    board: BoardType.rgb8Bit,
    resolutionX: 15360,
    resolutionY: 5120,
    displayWidth: 291.84,
    displayHeight: 122.88,
    maxZHeight: 235,
    resolutionLabel: '16K',
    pngOutputWidth: 5040,   // 15120 / 3
  );

  static const athena2_16K_3Bit = PrinterProfile(
    name: 'Athena 2 16K (3-bit)',
    manufacturer: 'Concepts3D',
    board: BoardType.twoBit3Subpixel,
    resolutionX: 15360,
    resolutionY: 5120,
    displayWidth: 291.84,
    displayHeight: 122.88,
    maxZHeight: 235,
    resolutionLabel: '16K',
    pngOutputWidth: 7568,   // 15136 / 2
  );

  static const saturn4Ultra_12K = PrinterProfile(
    name: 'Saturn 4 Ultra (12K)',
    manufacturer: 'Elegoo',
    board: BoardType.rgb8Bit,
    resolutionX: 11520,
    resolutionY: 5120,
    displayWidth: 218.88,
    displayHeight: 122.88,
    maxZHeight: 220,
    resolutionLabel: '12K',
    pngOutputWidth: 3840,   // 11520 / 3
  );

  static const saturn4Ultra_16K = PrinterProfile(
    name: 'Saturn 4 Ultra (16K)',
    manufacturer: 'Elegoo',
    board: BoardType.rgb8Bit,
    resolutionX: 15360,
    resolutionY: 5120,
    displayWidth: 291.84,
    displayHeight: 122.88,
    maxZHeight: 220,
    resolutionLabel: '16K',
    pngOutputWidth: 5040,   // 15120 / 3
  );

  /// All known profiles.
  static const List<PrinterProfile> all = [
    saturn4Ultra_12K,
    saturn4Ultra_16K,
    athena2_12K,
    athena2_16K_3Bit,  // Prefer 3-bit for 16K
    athena2_16K,
  ];

  /// Target profiles only (Athena 2 variants).
  static List<PrinterProfile> get targetProfiles => all
      .where((p) => p.manufacturer == 'Concepts3D')
      .toList();

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PrinterProfile &&
          name == other.name &&
          board == other.board;

  @override
  int get hashCode => Object.hash(name, board);
}
