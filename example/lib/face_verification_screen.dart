import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'services/services.dart';

/// Displays the DG2 passport photo alongside the captured selfie, runs the
/// full face-matching pipeline, and shows the score + verdict.
///
/// Push this screen **after** both images are available:
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => FaceVerificationScreen(
///     passportImageBytes: dg2ImageBytes,
///     selfieBytes: selfieBytes,
///   ),
/// ));
/// ```
class FaceVerificationScreen extends StatefulWidget {
  /// Raw JPEG/PNG bytes of the passport photo extracted from EF.DG2.
  final Uint8List passportImageBytes;

  /// Raw JPEG bytes captured by [SelfieCaptureScreen].
  final Uint8List selfieBytes;

  const FaceVerificationScreen({
    Key? key,
    required this.passportImageBytes,
    required this.selfieBytes,
  }) : super(key: key);

  @override
  State<FaceVerificationScreen> createState() => _FaceVerificationScreenState();
}

class _FaceVerificationScreenState extends State<FaceVerificationScreen>
    with SingleTickerProviderStateMixin {
  // ── Services ──────────────────────────────────────────────────────────────
  final FaceDetectorService _faceDetector = FaceDetectorService();
  final FaceMatcherService _matcher = FaceMatcherService();

  // ── Result state ──────────────────────────────────────────────────────────
  _VerificationState _state = _VerificationState.idle;
  String? _errorMessage;
  double? _euclideanDistance;
  double? _cosineSimilarity;
  bool? _isMatch;

  // ── Animation ─────────────────────────────────────────────────────────────
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  // ── Threshold (tunable) ───────────────────────────────────────────────────
  static const double _matchThreshold = 1.0;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnimation =
        Tween<double>(begin: 0.95, end: 1.05).animate(CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    ));

    // Kick off matching immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) => _runMatching());
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _faceDetector.dispose();
    _matcher.dispose();
    super.dispose();
  }

  // ── Matching Pipeline ─────────────────────────────────────────────────────
  Future<void> _runMatching() async {
    setState(() {
      _state = _VerificationState.processing;
      _errorMessage = null;
    });

    try {
      // 1. Initialise TFLite model.
      await _matcher.initialize();

      // ── Passport photo ──────────────────────────────────────────────────
      List<Face> passportFaces;
      try {
        final passportInput = InputImage.fromBytes(
          bytes: widget.passportImageBytes,
          metadata: _buildMetadata(),
        );
        passportFaces = await _faceDetector.detectFaces(passportInput);
      } catch (_) {
        passportFaces = [];
      }

      ui.Rect passportRect;
      if (passportFaces.isEmpty) {
        final decoded = await _decodeImageSize(widget.passportImageBytes);
        passportRect = ui.Rect.fromLTWH(
          0, 0, decoded.width.toDouble(), decoded.height.toDouble(),
        );
      } else {
        passportRect =
            _faceDetector.largestFaceBoundingBox(passportFaces) ??
                ui.Rect.fromLTWH(0, 0, 1, 1);
      }

      final passportTensor = await ImageProcessor.preprocessImage(
        widget.passportImageBytes,
        passportRect,
      );
      final passportEmbedding = await _matcher.getEmbedding(passportTensor);

      // ── Selfie ──────────────────────────────────────────────────────────
      List<Face> selfieFaces;
      try {
        final selfieInput = InputImage.fromBytes(
          bytes: widget.selfieBytes,
          metadata: _buildMetadata(),
        );
        selfieFaces = await _faceDetector.detectFaces(selfieInput);
      } catch (_) {
        selfieFaces = [];
      }

      ui.Rect selfieRect;
      if (selfieFaces.isEmpty) {
        final decoded = await _decodeImageSize(widget.selfieBytes);
        selfieRect = ui.Rect.fromLTWH(
          0, 0, decoded.width.toDouble(), decoded.height.toDouble(),
        );
      } else {
        selfieRect =
            _faceDetector.largestFaceBoundingBox(selfieFaces) ??
                ui.Rect.fromLTWH(0, 0, 1, 1);
      }

      final selfieTensor = await ImageProcessor.preprocessImage(
        widget.selfieBytes,
        selfieRect,
      );
      final selfieEmbedding = await _matcher.getEmbedding(selfieTensor);

      // ── Compare ──────────────────────────────────────────────────────────
      final euclid =
          _matcher.euclideanDistance(passportEmbedding, selfieEmbedding);
      final cosine =
          _matcher.cosineSimilarity(passportEmbedding, selfieEmbedding);
      final match = _matcher.isMatch(
        passportEmbedding,
        selfieEmbedding,
        threshold: _matchThreshold,
      );

      setState(() {
        _euclideanDistance = euclid;
        _cosineSimilarity = cosine;
        _isMatch = match;
        _state = _VerificationState.done;
      });
      _pulseController.stop();
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _state = _VerificationState.error;
      });
      _pulseController.stop();
    }
  }

  /// Provides rough metadata so ML Kit can accept bytes-based InputImage.
  /// For better accuracy the selfie path uses `InputImage.fromFilePath` instead.
  InputImageMetadata _buildMetadata() {
    return InputImageMetadata(
      size: Size(480, 640),
      rotation: InputImageRotation.rotation0deg,
      format: InputImageFormat.nv21,
      bytesPerRow: 480,
    );
  }

  Future<({int width, int height})> _decodeImageSize(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return (width: frame.image.width, height: frame.image.height);
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F1A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Face Verification',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          children: [
            // ── Photo comparison row ────────────────────────────────────────
            _buildPhotoRow(),
            const SizedBox(height: 28),

            // ── Status / result card ────────────────────────────────────────
            _buildResultCard(),
            const SizedBox(height: 24),

            // ── Retry button ────────────────────────────────────────────────
            if (_state == _VerificationState.done ||
                _state == _VerificationState.error)
              _buildRetryButton(),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildPhotoRow() {
    return Row(
      children: [
        Expanded(
          child: _PhotoCard(
            label: 'Passport Photo',
            imageBytes: widget.passportImageBytes,
            icon: Icons.badge_outlined,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Icon(Icons.compare_arrows_rounded,
              color: Colors.white38, size: 32),
        ),
        Expanded(
          child: _PhotoCard(
            label: 'Selfie',
            imageBytes: widget.selfieBytes,
            icon: Icons.face,
          ),
        ),
      ],
    );
  }

  Widget _buildResultCard() {
    switch (_state) {
      case _VerificationState.idle:
        return const _StatusCard(
          color: Color(0xFF1E1E2E),
          icon: Icons.pending_outlined,
          title: 'Waiting…',
          subtitle: null,
        );

      case _VerificationState.processing:
        return ScaleTransition(
          scale: _pulseAnimation,
          child: Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1A237E), Color(0xFF283593)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.indigo.withValues(alpha: 0.35),
                  blurRadius: 24,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Column(
              children: [
                SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 3,
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  'Analyzing faces…',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Running MobileFaceNet inference',
                  style: TextStyle(color: Colors.white60, fontSize: 13),
                ),
              ],
            ),
          ),
        );

      case _VerificationState.done:
        return _buildMatchResultCard();

      case _VerificationState.error:
        return _StatusCard(
          color: const Color(0xFF3E0000),
          icon: Icons.error_outline_rounded,
          title: 'Analysis Failed',
          subtitle: _errorMessage ?? 'Unknown error',
        );
    }
  }

  Widget _buildMatchResultCard() {
    final match = _isMatch ?? false;
    final euclid = _euclideanDistance ?? 0;
    final cosine = _cosineSimilarity ?? 0;

    final cardGradient = match
        ? const LinearGradient(
            colors: [Color(0xFF1B5E20), Color(0xFF2E7D32)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
        : const LinearGradient(
            colors: [Color(0xFF4A0000), Color(0xFF7B0000)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );

    final glowColor =
        match ? Colors.green.withValues(alpha: 0.4) : Colors.red.withValues(alpha: 0.4);
    final verdictLabel = match ? '✅  MATCH' : '❌  NO MATCH';
    final verdictSubtitle = match
        ? 'The selfie matches the passport photo.'
        : 'The selfie does NOT match the passport photo.';

    // Clamp cosine to [0,1] for display bar.
    final cosinePercent = ((cosine + 1) / 2).clamp(0.0, 1.0);
    // Clamp euclidean for bar (0 = perfect, 2 = far).
    final euclidPercent = (1 - (euclid / 2)).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: cardGradient,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: glowColor, blurRadius: 28, spreadRadius: 2),
        ],
      ),
      child: Column(
        children: [
          // Verdict badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Text(
              verdictLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            verdictSubtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),

          const Divider(color: Colors.white24, height: 32),

          // ── Score rows ──────────────────────────────────────────────────
          _ScoreRow(
            label: 'Euclidean Distance',
            value: euclid.toStringAsFixed(4),
            subtitle: 'Threshold ≤ $_matchThreshold → Match',
            barFill: euclidPercent,
            barColor: match ? Colors.greenAccent : Colors.redAccent,
          ),
          const SizedBox(height: 16),
          _ScoreRow(
            label: 'Cosine Similarity',
            value: cosine.toStringAsFixed(4),
            subtitle: '1.0 = identical, −1.0 = opposite',
            barFill: cosinePercent,
            barColor: Colors.lightBlueAccent,
          ),
        ],
      ),
    );
  }

  Widget _buildRetryButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _runMatching,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Re-run Verification'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white70,
          side: const BorderSide(color: Colors.white24),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}

// ── State enum ────────────────────────────────────────────────────────────────
enum _VerificationState { idle, processing, done, error }

// ── Reusable sub-widgets ──────────────────────────────────────────────────────

class _PhotoCard extends StatelessWidget {
  final String label;
  final Uint8List imageBytes;
  final IconData icon;

  const _PhotoCard({
    required this.label,
    required this.imageBytes,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 160,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.memory(
              imageBytes,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: const Color(0xFF1E1E2E),
                child: Center(
                  child: Icon(icon, color: Colors.white24, size: 40),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white60,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String title;
  final String? subtitle;

  const _StatusCard({
    required this.color,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white54, size: 36),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      subtitle!,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ScoreRow extends StatelessWidget {
  final String label;
  final String value;
  final String subtitle;
  final double barFill; // 0.0 – 1.0
  final Color barColor;

  const _ScoreRow({
    required this.label,
    required this.value,
    required this.subtitle,
    required this.barFill,
    required this.barColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  fontFeatures: [ui.FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: barFill,
            minHeight: 6,
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation<Color>(barColor),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
      ],
    );
  }
}
