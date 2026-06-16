import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:image/image.dart' as img;

/// Crops, resizes, and normalises a face region so it is ready to be fed into
/// MobileFaceNet.
///
/// MobileFaceNet input requirements:
///   - Shape  : [1, 112, 112, 3]  (batch=1, H=112, W=112, RGB channels)
///   - Dtype  : float32
///   - Range  : [-1.0, 1.0]  — normalised as `pixel / 127.5 - 1.0`
class ImageProcessor {
  /// The target spatial dimension expected by MobileFaceNet.
  static const int targetSize = 112;

  /// Pre-processes an image for face embedding extraction.
  ///
  /// [imageBytes] — raw JPEG (or other format decodable by the `image`
  ///                package) bytes, e.g. `EfDG2.imageData`.
  /// [boundingBox] — the face ROI returned by [FaceDetectorService].  When
  ///                 calling this with a passport photo that has no separate
  ///                 bounding box, pass a rectangle that covers the entire
  ///                 image: `Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble())`.
  ///
  /// Returns a [Float32List] of length `112 * 112 * 3 = 37 632` in
  /// **RGB channel-last** (HWC) order, normalised to [-1, 1].
  ///
  /// Throws [ArgumentError] if [imageBytes] cannot be decoded.
  static Future<Float32List> preprocessImage(
    Uint8List imageBytes,
    Rect boundingBox,
  ) async {
    // ── 1. Decode ────────────────────────────────────────────────────────────
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw ArgumentError(
        'ImageProcessor: could not decode the provided image bytes. '
        'Ensure the data is a valid JPEG, PNG, BMP, or GIF.',
      );
    }

    // ── 2. Crop to bounding box (clamped to image bounds) ───────────────────
    final imgW = decoded.width;
    final imgH = decoded.height;

    final x = boundingBox.left.clamp(0.0, imgW.toDouble()).toInt();
    final y = boundingBox.top.clamp(0.0, imgH.toDouble()).toInt();
    final w = boundingBox.width
        .clamp(1.0, (imgW - x).toDouble())
        .toInt();
    final h = boundingBox.height
        .clamp(1.0, (imgH - y).toDouble())
        .toInt();

    final cropped = img.copyCrop(decoded, x: x, y: y, width: w, height: h);

    // ── 3. Resize to 112×112 ─────────────────────────────────────────────────
    final resized = img.copyResize(
      cropped,
      width: targetSize,
      height: targetSize,
      interpolation: img.Interpolation.linear,
    );

    // ── 4. Normalise pixels to [-1, 1] and pack into Float32List ─────────────
    // Layout: [H, W, C] — matches the [1, 112, 112, 3] TFLite input tensor
    // (the batch dimension is added by FaceMatcherService before inference).
    final output = Float32List(targetSize * targetSize * 3);
    int idx = 0;

    for (int row = 0; row < targetSize; row++) {
      for (int col = 0; col < targetSize; col++) {
        final pixel = resized.getPixel(col, row);
        // `img.Pixel` exposes channels as num; cast to int for bit-safety.
        output[idx++] = pixel.r.toInt() / 127.5 - 1.0;
        output[idx++] = pixel.g.toInt() / 127.5 - 1.0;
        output[idx++] = pixel.b.toInt() / 127.5 - 1.0;
      }
    }

    return output;
  }
}
