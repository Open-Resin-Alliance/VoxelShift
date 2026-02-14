import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  final scriptDir = File(Platform.script.toFilePath()).parent;
  final repoRoot = scriptDir.parent.parent; // distribution/msi -> distribution -> repo root
  final logoPath = File('${repoRoot.path}/assets/open_resin_alliance_logo_darkmode.png');

  if (!logoPath.existsSync()) {
    stderr.writeln('Logo not found: ${logoPath.path}');
    exit(1);
  }

  final logoBytes = logoPath.readAsBytesSync();
  final logo = img.decodeImage(logoBytes);
  if (logo == null) {
    stderr.writeln('Failed to decode logo image.');
    exit(1);
  }

  final assetsDir = Directory('${scriptDir.path}/assets');
  if (!assetsDir.existsSync()) {
    assetsDir.createSync(recursive: true);
  }

  _buildBanner(logo, '${assetsDir.path}/ora_banner.png');
  _buildDialog(logo, '${assetsDir.path}/ora_dialog.png');

  stdout.writeln('Generated WiX UI images in ${assetsDir.path}');
}

void _buildBanner(img.Image logo, String outPath) {
  const width = 493;
  const height = 58;
  final background = img.ColorRgba8(255, 255, 255, 255); // white
  final stripColor = img.ColorRgba8(15, 23, 42, 255); // #0F172A
  final banner = img.Image(width: width, height: height);
  img.fill(banner, color: background);

  const stripWidth = 90;
  final stripX1 = width - stripWidth;
  img.fillRect(banner,
      x1: stripX1,
      y1: 0,
      x2: width - 1,
      y2: height - 1,
      color: stripColor);

    final maxLogoHeight = 46;
    final maxLogoWidth = 150;
  final scale = _computeScale(logo.width, logo.height, maxLogoWidth, maxLogoHeight);
  final resized = img.copyResize(logo,
      width: (logo.width * scale).round(),
      height: (logo.height * scale).round(),
      interpolation: img.Interpolation.cubic);

  final x = width - resized.width - 12;
  final y = ((height - resized.height) / 2).round();
  img.compositeImage(banner, resized, dstX: x, dstY: y);

  File(outPath).writeAsBytesSync(img.encodePng(banner));
}

void _buildDialog(img.Image logo, String outPath) {
  const width = 493;
  const height = 312;
  final background = img.ColorRgba8(255, 255, 255, 255); // white background
  final stripColor = img.ColorRgba8(15, 23, 42, 255); // #0F172A
  final dialog = img.Image(width: width, height: height);
  img.fill(dialog, color: background);

  const stripWidth = 170;
  img.fillRect(dialog,
      x1: 0, y1: 0, x2: stripWidth - 1, y2: height - 1, color: stripColor);

    final maxLogoHeight = 200;
    final maxLogoWidth = 155;
  final scale = _computeScale(logo.width, logo.height, maxLogoWidth, maxLogoHeight);
  final resized = img.copyResize(logo,
      width: (logo.width * scale).round(),
      height: (logo.height * scale).round(),
      interpolation: img.Interpolation.cubic);

  final x = ((stripWidth - resized.width) / 2).round();
  final y = 20;
  img.compositeImage(dialog, resized, dstX: x, dstY: y);

  File(outPath).writeAsBytesSync(img.encodePng(dialog));
}

double _computeScale(int srcW, int srcH, int maxW, int maxH) {
  final scaleW = maxW / srcW;
  final scaleH = maxH / srcH;
  return scaleW < scaleH ? scaleW : scaleH;
}
