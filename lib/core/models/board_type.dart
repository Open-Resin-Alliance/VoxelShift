/// Board type: determines how greyscale subpixels are packed into output pixels.
enum BoardType {
  /// 8-bit RGB: 3 greyscale subpixels encoded as R, G, B channels.
  /// Output width = input / 3.
  rgb8Bit,

  /// 3-bit greyscale: 2 greyscale subpixels encoded as a single greyscale pixel.
  /// Output width = input / 2.
  twoBit3Subpixel,
}
