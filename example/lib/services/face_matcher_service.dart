import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

/// Loads the MobileFaceNet TFLite model, runs inference, and exposes
/// distance / similarity metrics for 1:1 face verification.
///
/// Typical usage:
/// ```dart
/// final matcher = FaceMatcherService();
/// await matcher.initialize();
///
/// final embeddingA = await matcher.getEmbedding(tensorFromPassport);
/// final embeddingB = await matcher.getEmbedding(tensorFromCamera);
///
/// if (matcher.isMatch(embeddingA, embeddingB)) {
///   // faces match
/// }
///
/// matcher.dispose();
/// ```
class FaceMatcherService {
  static const String _modelAsset = 'assets/models/mobilefacenet.tflite';

  /// Expected spatial input size (H = W = 112).
  static const int inputSize = 112;

  /// Number of output dimensions (embedding vector length).
  static const int embeddingSize = 192;

  late Interpreter _interpreter;
  bool _isInitialized = false;

  // ── Initialization ──────────────────────────────────────────────────────────

  /// Loads the TFLite model from the app bundle.
  ///
  /// Must be called (and awaited) before any call to [getEmbedding].
  Future<void> initialize() async {
    if (_isInitialized) return;

    final options = InterpreterOptions()..threads = 2;
    _interpreter = await Interpreter.fromAsset(
      _modelAsset,
      options: options,
    );

    // Optionally resize the input tensor to match the expected shape
    // [1, 112, 112, 3] in case the model was saved with a dynamic batch dim.
    _interpreter.resizeInputTensor(0, [1, inputSize, inputSize, 3]);
    _interpreter.allocateTensors();

    _isInitialized = true;
  }

  // ── Inference ───────────────────────────────────────────────────────────────

  /// Runs a forward pass through MobileFaceNet and returns the 192-d
  /// embedding vector for the provided [inputTensor].
  ///
  /// [inputTensor] must be a [Float32List] of length `112 * 112 * 3 = 37 632`
  /// produced by [ImageProcessor.preprocessImage].
  ///
  /// Throws a [StateError] if [initialize] has not been called yet.
  Future<List<double>> getEmbedding(Float32List inputTensor) async {
    _assertInitialized();

    // Reshape flat Float32List → [1, 112, 112, 3] nested list that tflite_flutter
    // expects when the tensor is specified as a List.
    final input = _reshapeToInputTensor(inputTensor);

    // Allocate output buffer: [1, 128]
    final outputBuffer = List.generate(1, (_) => List.filled(embeddingSize, 0.0));

    _interpreter.run(input, outputBuffer);

    // Return the 128-d embedding as a plain List<double>.
    return outputBuffer[0];
  }

  // ── Distance Metrics ────────────────────────────────────────────────────────

  /// Computes the **Euclidean distance** (L2) between two embedding vectors.
  ///
  /// Lower values indicate more similar faces.
  /// A typical acceptance threshold for MobileFaceNet is around **1.0**.
  double euclideanDistance(List<double> a, List<double> b) {
    _assertSameLength(a, b);
    double sum = 0.0;
    for (int i = 0; i < a.length; i++) {
      final diff = a[i] - b[i];
      sum += diff * diff;
    }
    return math.sqrt(sum);
  }

  /// Computes the **cosine similarity** between two embedding vectors.
  ///
  /// Returns a value in `[-1, 1]` where **1.0** means identical direction
  /// (same face) and **-1.0** means opposite (completely different).
  /// A typical acceptance threshold is **≥ 0.5**.
  double cosineSimilarity(List<double> a, List<double> b) {
    _assertSameLength(a, b);

    double dot = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    final magnitude = math.sqrt(normA) * math.sqrt(normB);
    if (magnitude == 0.0) return 0.0;
    return dot / magnitude;
  }

  /// Convenience method that returns `true` when the two embeddings are
  /// considered a **match**.
  ///
  /// Uses Euclidean distance by default with a [threshold] of **1.0**.
  /// Lower threshold = stricter matching.
  bool isMatch(
    List<double> embeddingA,
    List<double> embeddingB, {
    double threshold = 1.0,
  }) {
    return euclideanDistance(embeddingA, embeddingB) < threshold;
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  /// Releases the native TFLite interpreter. Call this when the service is
  /// no longer needed to avoid memory leaks.
  void dispose() {
    if (_isInitialized) {
      _interpreter.close();
      _isInitialized = false;
    }
  }

  // ── Private Helpers ─────────────────────────────────────────────────────────

  /// Reshapes a flat [Float32List] of length `112*112*3` into the nested
  /// `List<List<List<List<double>>>>` shape `[1, 112, 112, 3]` that
  /// tflite_flutter's `Interpreter.run` can consume directly.
  List _reshapeToInputTensor(Float32List flat) {
    // Build [112, 112, 3]
    final rows = <List<List<double>>>[];
    int idx = 0;
    for (int h = 0; h < inputSize; h++) {
      final cols = <List<double>>[];
      for (int w = 0; w < inputSize; w++) {
        cols.add([flat[idx], flat[idx + 1], flat[idx + 2]]);
        idx += 3;
      }
      rows.add(cols);
    }
    // Wrap in batch dimension → [1, 112, 112, 3]
    return [rows];
  }

  void _assertInitialized() {
    if (!_isInitialized) {
      throw StateError(
        'FaceMatcherService is not initialized. '
        'Call and await initialize() before using this service.',
      );
    }
  }

  void _assertSameLength(List<double> a, List<double> b) {
    if (a.length != b.length) {
      throw ArgumentError(
        'Embedding vectors must have the same length. '
        'Got ${a.length} and ${b.length}.',
      );
    }
  }
}
