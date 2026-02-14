import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Utilities for processing and enhancing thumbnails.
class ThumbnailProcessor {
  /// Target dimensions for VoxelShift thumbnails (NanoDLP standard).
  static const int targetWidth = 800;
  static const int targetHeight = 480;
  static const int _blackThreshold = 20;

  /// Process a thumbnail: crop pure-black borders and regenerate with
  /// VoxelShift branding (gradient background).
  static Uint8List? processThumbail(Uint8List? inputPng) {
    if (inputPng == null || inputPng.isEmpty) return null;

    try {
      final original = img.decodeImage(inputPng);
      if (original == null) return null;

      final cropped = _cropBlackBorders(original);
      return _generateBrandedThumbnail(cropped);
    } catch (_) {
      return inputPng;
    }
  }

  static bool _isBlack(img.Pixel p) =>
      p.r < _blackThreshold &&
      p.g < _blackThreshold &&
      p.b < _blackThreshold;

  /// Crop pure-black borders from all sides of the image.
  static img.Image _cropBlackBorders(img.Image image) {
    int left = 0;
    int right = image.width - 1;
    int top = 0;
    int bottom = image.height - 1;

    outer:
    for (int x = 0; x < image.width; x++) {
      for (int y = 0; y < image.height; y++) {
        if (!_isBlack(image.getPixel(x, y))) {
          left = x;
          break outer;
        }
      }
    }
    outer:
    for (int x = image.width - 1; x >= left; x--) {
      for (int y = 0; y < image.height; y++) {
        if (!_isBlack(image.getPixel(x, y))) {
          right = x;
          break outer;
        }
      }
    }
    outer:
    for (int y = 0; y < image.height; y++) {
      for (int x = left; x <= right; x++) {
        if (!_isBlack(image.getPixel(x, y))) {
          top = y;
          break outer;
        }
      }
    }
    outer:
    for (int y = image.height - 1; y >= top; y--) {
      for (int x = left; x <= right; x++) {
        if (!_isBlack(image.getPixel(x, y))) {
          bottom = y;
          break outer;
        }
      }
    }

    if (left >= right || top >= bottom) return image;

    return img.copyCrop(
      image,
      x: left,
      y: top,
      width: right - left + 1,
      height: bottom - top + 1,
    );
  }

  static int _lerp(int a, int b, double t) =>
      (a + (b - a) * t).round().clamp(0, 255);

  /// Generate a VoxelShift-branded thumbnail with gradient background.
  static Uint8List _generateBrandedThumbnail(img.Image croppedModel) {
    // 1. Create RGBA canvas
    final canvas = img.Image(
      width: targetWidth,
      height: targetHeight,
      numChannels: 4,
    );

    // 2. Fill with dark gradient (dark navy → slightly lighter)
    for (int y = 0; y < targetHeight; y++) {
      final t = y / targetHeight;
      final r = _lerp(18, 30, t);
      final g = _lerp(24, 42, t);
      final b = _lerp(38, 58, t);
      for (int x = 0; x < targetWidth; x++) {
        canvas.setPixelRgba(x, y, r, g, b, 255);
      }
    }

    // 3. Scale model to fit within padded area
    const pad = 40;
    final maxW = targetWidth - pad * 2;
    final maxH = targetHeight - pad * 2;
    final scaleX = maxW / croppedModel.width;
    final scaleY = maxH / croppedModel.height;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final sw = (croppedModel.width * scale).round().clamp(1, maxW);
    final sh = (croppedModel.height * scale).round().clamp(1, maxH);

    final resized = img.copyResize(
      croppedModel,
      width: sw,
      height: sh,
      interpolation: img.Interpolation.average,
    );

    // 4. Create RGBA copy, making black pixels fully transparent
    //    (the resized image may be RGB with no alpha channel, so we
    //    must build a fresh 4-channel image for compositing to work)
    final rgbaModel = img.Image(width: sw, height: sh, numChannels: 4);
    for (int y = 0; y < sh; y++) {
      for (int x = 0; x < sw; x++) {
        final p = resized.getPixel(x, y);
        if (_isBlack(p)) {
          rgbaModel.setPixelRgba(x, y, 0, 0, 0, 0);
        } else {
          rgbaModel.setPixelRgba(
            x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), 255,
          );
        }
      }
    }

    // 5. Composite model centered on gradient canvas
    final ox = ((targetWidth - sw) / 2).round();
    final oy = ((targetHeight - sh) / 2).round();
    img.compositeImage(canvas, rgbaModel, dstX: ox, dstY: oy);

    return Uint8List.fromList(img.encodePng(canvas, level: 6));
  }
}
