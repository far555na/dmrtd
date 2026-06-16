import 'dart:ui';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Wraps Google ML Kit [FaceDetector] to locate faces in an image and expose
/// bounding-box helpers.
class FaceDetectorService {
  late final FaceDetector _detector;

  FaceDetectorService() {
    _detector = FaceDetector(
      options: FaceDetectorOptions(
        // Accurate mode gives better bounding boxes at the cost of speed —
        // acceptable for a 1:1 verification flow (not real-time tracking).
        performanceMode: FaceDetectorMode.accurate,
        // Contours / landmarks are not needed for embedding extraction.
        enableContours: false,
        enableLandmarks: false,
        enableClassification: false,
        enableTracking: false,
        // Ignore faces that occupy less than 10 % of the image width.
        minFaceSize: 0.1,
      ),
    );
  }

  /// Runs face detection on the provided [InputImage] and returns all
  /// detected [Face] objects.
  ///
  /// The caller is responsible for constructing the [InputImage] from either
  /// a file path (`InputImage.fromFilePath`) or raw bytes
  /// (`InputImage.fromBytes`).
  Future<List<Face>> detectFaces(InputImage image) async {
    return _detector.processImage(image);
  }

  /// Returns the bounding box of the face with the **largest area** among
  /// [faces], or `null` if the list is empty.
  ///
  /// Picking the largest face is a sensible heuristic for a selfie-vs-passport
  /// 1:1 matching flow where only one subject should appear in frame.
  Rect? largestFaceBoundingBox(List<Face> faces) {
    if (faces.isEmpty) return null;

    Face largest = faces.first;
    double maxArea = _area(faces.first.boundingBox);

    for (final face in faces.skip(1)) {
      final area = _area(face.boundingBox);
      if (area > maxArea) {
        maxArea = area;
        largest = face;
      }
    }

    return largest.boundingBox;
  }

  double _area(Rect rect) => rect.width * rect.height;

  /// Releases the underlying ML Kit detector. Call this when the service is
  /// no longer needed to free native resources.
  Future<void> dispose() async {
    await _detector.close();
  }
}
