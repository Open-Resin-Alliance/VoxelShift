import 'dart:typed_data';
import 'package:image/image.dart' as img;

import '../models/board_type.dart';
import '../models/layer_area_info.dart';

/// Encodes greyscale layer data to PNG for NanoDLP's sub-pixel display.
///
/// 8-bit RGB board: 3 greyscale subpixels → RGB channels (width / 3)
/// 3-bit board: 2 greyscale subpixels → 1 greyscale pixel (width / 2)
class LayerEncoder {
  /// Encode a greyscale layer image to PNG bytes.
  ///
  /// [greyPixels] is a flat array of width * height greyscale pixels.
  /// [width] and [height] are the source image dimensions.
  /// [boardType] controls the sub-pixel encoding mode.
  /// [targetWidth] is the expected output PNG width from the target profile.
  /// If the source subpixel count doesn't match, the data is centered and
  /// padded with black pixels.
  static Uint8List encodeToPng(
    Uint8List greyPixels,
    int width,
    int height,
    BoardType boardType, {
    int? targetWidth,
  }) {

    final img.Image outImage;

    switch (boardType) {
      case BoardType.rgb8Bit:
        outImage = _encodeRgb8Bit(greyPixels, width, height,
            targetWidth: targetWidth);
      case BoardType.twoBit3Subpixel:
        outImage = _encode2Subpixel(greyPixels, width, height,
            targetWidth: targetWidth);
    }

    return Uint8List.fromList(img.encodePng(outImage, level: 9));
  }

  /// 8-bit RGB: 3 consecutive greyscale pixels → 1 RGB pixel (R, G, B).
  ///
  /// If [targetWidth] is specified and differs from width÷3, the source
  /// subpixels are centered and padded with black.
  static img.Image _encodeRgb8Bit(
    Uint8List greyPixels, int width, int height, {
    int? targetWidth,
  }) {
    final outWidth = targetWidth ?? (width ~/ 3);
    final requiredSubpixels = outWidth * 3;
    final padTotal = requiredSubpixels - width;
    final padLeft = padTotal > 0 ? padTotal ~/ 2 : 0;

    final image = img.Image(width: outWidth, height: height, numChannels: 3);

    for (int y = 0; y < height; y++) {
      final rowOffset = y * width;
      for (int x = 0; x < outWidth; x++) {
        final si = x * 3 - padLeft;
        final r = (si >= 0 && si < width) ? greyPixels[rowOffset + si] : 0;
        final g = (si + 1 >= 0 && si + 1 < width) ? greyPixels[rowOffset + si + 1] : 0;
        final b = (si + 2 >= 0 && si + 2 < width) ? greyPixels[rowOffset + si + 2] : 0;
        image.setPixelRgb(x, y, r, g, b);
      }
    }

    return image;
  }

  /// 3-bit greyscale: 2 consecutive greyscale pixels → 1 greyscale pixel.
  ///
  /// If [targetWidth] is specified and differs from width÷2, the source
  /// subpixels are centered and padded with black.
  static img.Image _encode2Subpixel(
    Uint8List greyPixels, int width, int height, {
    int? targetWidth,
  }) {
    final outWidth = targetWidth ?? (width ~/ 2);
    final requiredSubpixels = outWidth * 2;
    final padTotal = requiredSubpixels - width;
    final padLeft = padTotal > 0 ? padTotal ~/ 2 : 0;

    final image = img.Image(
        width: outWidth, height: height, numChannels: 1,
        format: img.Format.uint8);

    for (int y = 0; y < height; y++) {
      final rowOffset = y * width;
      for (int x = 0; x < outWidth; x++) {
        final si = x * 2 - padLeft;
        final a = (si >= 0 && si < width) ? greyPixels[rowOffset + si] : 0;
        final b = (si + 1 >= 0 && si + 1 < width)
            ? greyPixels[rowOffset + si + 1]
            : 0;
        final grey = (a + b) >> 1;
        image.setPixel(x, y, image.getColor(grey, grey, grey));
      }
    }

    return image;
  }

  /// Compute area statistics for a greyscale layer.
  static LayerAreaInfo computeLayerArea(
    Uint8List greyPixels,
    int width,
    int height,
    double xPixelSizeMm,
    double yPixelSizeMm,
  ) {
    final totalPixels = width * height;
    final visited = Uint8List(totalPixels);

    int totalSolidPixels = 0;
    int areaCount = 0;
    int largestPixels = 0;
    int smallestPixels = 0;

    int minX = width, minY = height, maxX = 0, maxY = 0;

    final queue = <int>[];

    for (int y = 0; y < height; y++) {
      final rowOffset = y * width;
      for (int x = 0; x < width; x++) {
        final idx = rowOffset + x;
        if (greyPixels[idx] == 0 || visited[idx] != 0) {
          continue;
        }

        // New island (8-connected)
        areaCount++;
        int islandPixels = 0;
        queue.clear();
        queue.add(idx);
        visited[idx] = 1;

        int qi = 0;
        while (qi < queue.length) {
          final i = queue[qi++];
          islandPixels++;

          final iy = i ~/ width;
          final ix = i - iy * width;

          if (ix < minX) minX = ix;
          if (ix > maxX) maxX = ix;
          if (iy < minY) minY = iy;
          if (iy > maxY) maxY = iy;

          final hasLeft = ix > 0;
          final hasRight = ix < width - 1;
          final hasUp = iy > 0;
          final hasDown = iy < height - 1;

          if (hasLeft) {
            final ni = i - 1;
            if (visited[ni] == 0 && greyPixels[ni] > 0) {
              visited[ni] = 1;
              queue.add(ni);
            }
          }
          if (hasRight) {
            final ni = i + 1;
            if (visited[ni] == 0 && greyPixels[ni] > 0) {
              visited[ni] = 1;
              queue.add(ni);
            }
          }
          if (hasUp) {
            final ni = i - width;
            if (visited[ni] == 0 && greyPixels[ni] > 0) {
              visited[ni] = 1;
              queue.add(ni);
            }
          }
          if (hasDown) {
            final ni = i + width;
            if (visited[ni] == 0 && greyPixels[ni] > 0) {
              visited[ni] = 1;
              queue.add(ni);
            }
          }

          // Diagonals
          if (hasUp && hasLeft) {
            final ni = i - width - 1;
            if (visited[ni] == 0 && greyPixels[ni] > 0) {
              visited[ni] = 1;
              queue.add(ni);
            }
          }
          if (hasUp && hasRight) {
            final ni = i - width + 1;
            if (visited[ni] == 0 && greyPixels[ni] > 0) {
              visited[ni] = 1;
              queue.add(ni);
            }
          }
          if (hasDown && hasLeft) {
            final ni = i + width - 1;
            if (visited[ni] == 0 && greyPixels[ni] > 0) {
              visited[ni] = 1;
              queue.add(ni);
            }
          }
          if (hasDown && hasRight) {
            final ni = i + width + 1;
            if (visited[ni] == 0 && greyPixels[ni] > 0) {
              visited[ni] = 1;
              queue.add(ni);
            }
          }
        }

        totalSolidPixels += islandPixels;
        if (largestPixels == 0 || islandPixels > largestPixels) {
          largestPixels = islandPixels;
        }
        if (smallestPixels == 0 || islandPixels < smallestPixels) {
          smallestPixels = islandPixels;
        }
      }
    }

    if (totalSolidPixels == 0) return LayerAreaInfo.empty;

    final pixelArea = xPixelSizeMm * yPixelSizeMm;
    final totalArea = totalSolidPixels * pixelArea;

    return LayerAreaInfo(
      totalSolidArea: totalArea,
      largestArea: largestPixels * pixelArea,
      smallestArea: smallestPixels * pixelArea,
      minX: minX,
      minY: minY,
      maxX: maxX,
      maxY: maxY,
      areaCount: areaCount,
    );
  }
}
