import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'services/services.dart';

/// A full-screen camera screen that captures a selfie using the front camera.
///
/// On capture it runs ML Kit face detection, validates that exactly one face
/// is present, and returns the JPEG [Uint8List] to the caller via
/// `Navigator.pop`.  If no face is detected the user sees an error and can
/// retry without leaving the screen.
class SelfieCaptureScreen extends StatefulWidget {
  const SelfieCaptureScreen({Key? key}) : super(key: key);

  @override
  State<SelfieCaptureScreen> createState() => _SelfieCaptureScreenState();
}

class _SelfieCaptureScreenState extends State<SelfieCaptureScreen>
    with WidgetsBindingObserver {
  // ── Camera ──────────────────────────────────────────────────────────────────
  CameraController? _controller;
  bool _isCameraReady = false;

  // ── ML Kit face detector ────────────────────────────────────────────────────
  late final FaceDetectorService _faceDetector;

  // ── UI state ─────────────────────────────────────────────────────────────────
  bool _isCapturing = false;
  String? _hintMessage;
  bool _faceDetectedInPreview = false;
  bool _isProcessingPreview = false;

  // ── Orientation map (same pattern used in MrzScannerScreen) ─────────────────
  static const _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  // ── Life-cycle ───────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _faceDetector = FaceDetectorService();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.stopImageStream();
    _controller?.dispose();
    _faceDetector.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _controller?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  // ── Camera initialization ────────────────────────────────────────────────────
  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _setHint('No camera found on this device.');
        return;
      }

      // Prefer front camera for selfie; fall back to first available.
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        front,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup:
            Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );

      await controller.initialize();
      if (!mounted) return;

      _controller = controller;
      setState(() => _isCameraReady = true);

      // Start a lightweight live face-detection stream to drive the oval overlay.
      _controller!.startImageStream(_onPreviewFrame);
    } catch (e) {
      _setHint('Camera error: $e');
    }
  }

  // ── Live preview face-detection ──────────────────────────────────────────────
  Future<void> _onPreviewFrame(CameraImage frame) async {
    if (_isProcessingPreview || _isCapturing) return;
    _isProcessingPreview = true;

    try {
      final inputImage = _toInputImage(frame);
      if (inputImage == null) return;

      final faces = await _faceDetector.detectFaces(inputImage);
      if (mounted) {
        setState(() => _faceDetectedInPreview = faces.isNotEmpty);
      }
    } catch (_) {
      // Silently ignore per-frame errors.
    } finally {
      _isProcessingPreview = false;
    }
  }

  // ── Convert CameraImage → InputImage (same logic as MrzScannerScreen) ───────
  InputImage? _toInputImage(CameraImage image) {
    final camera = _controller?.description;
    if (camera == null) return null;

    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation;

    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var compensation =
          _orientations[_controller!.value.deviceOrientation] ?? 0;
      if (camera.lensDirection == CameraLensDirection.front) {
        compensation = (sensorOrientation + compensation) % 360;
      } else {
        compensation = (sensorOrientation - compensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(compensation);
    }
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;
    if (Platform.isAndroid &&
        format != InputImageFormat.nv21 &&
        format != InputImageFormat.yuv_420_888 &&
        format != InputImageFormat.yuv420) {
      return null;
    }
    if (Platform.isIOS && format != InputImageFormat.bgra8888) {
      return null;
    }

    if (image.planes.isEmpty) return null;

    final allBytes = WriteBuffer();
    for (final plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: Platform.isAndroid ? InputImageFormat.nv21 : format,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }

  // ── Capture ──────────────────────────────────────────────────────────────────
  Future<void> _capture() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isCapturing) {
      return;
    }

    setState(() {
      _isCapturing = true;
      _hintMessage = null;
    });

    try {
      // Stop preview stream while taking the still so there's no race.
      await _controller!.stopImageStream();

      final xFile = await _controller!.takePicture();
      final jpegBytes = await xFile.readAsBytes();

      // Validate that at least one face is visible in the captured image.
      final inputImage = InputImage.fromFilePath(xFile.path);
      final faces = await _faceDetector.detectFaces(inputImage);

      if (faces.isEmpty) {
        _setHint('No face detected — please look directly at the camera and try again.');
        // Resume stream so the user can retry.
        await _controller!.startImageStream(_onPreviewFrame);
        setState(() => _isCapturing = false);
        return;
      }

      // Pop with the JPEG bytes; the caller will handle everything from here.
      if (mounted) Navigator.pop(context, jpegBytes);
    } catch (e) {
      _setHint('Capture failed: $e');
      await _controller?.startImageStream(_onPreviewFrame);
      setState(() => _isCapturing = false);
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────
  void _setHint(String msg) {
    if (mounted) setState(() => _hintMessage = msg);
  }

  // ── Build ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Camera preview ─────────────────────────────────────────────────
          if (_isCameraReady && _controller != null)
            CameraPreview(_controller!)
          else
            const Center(child: CircularProgressIndicator(color: Colors.white)),

          // ── Darkened overlay with oval cutout ──────────────────────────────
          if (_isCameraReady)
            CustomPaint(
              painter: _FaceOvalOverlayPainter(
                faceDetected: _faceDetectedInPreview,
              ),
            ),

          // ── Instruction / error text ───────────────────────────────────────
          Positioned(
            top: 60,
            left: 24,
            right: 24,
            child: Column(
              children: [
                // Back button row
                Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.arrow_back_ios_new,
                            color: Colors.white, size: 20),
                      ),
                    ),
                    const SizedBox(width: 16),
                    const Text(
                      'Take a Selfie',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  _hintMessage ??
                      (_faceDetectedInPreview
                          ? '✅ Face detected — press capture when ready'
                          : 'Position your face inside the oval'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _hintMessage != null ? Colors.redAccent : Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
                  ),
                ),
              ],
            ),
          ),

          // ── Capture button ─────────────────────────────────────────────────
          Positioned(
            bottom: 60,
            left: 0,
            right: 0,
            child: Center(
              child: _isCapturing
                  ? const SizedBox(
                      width: 72,
                      height: 72,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 3,
                      ),
                    )
                  : GestureDetector(
                      onTap: _capture,
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.white.withValues(alpha: 0.35),
                              blurRadius: 20,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                        child: Container(
                          margin: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _faceDetectedInPreview
                                ? const Color(0xFF00C853)
                                : Colors.white70,
                          ),
                          child: Icon(
                            Icons.camera_alt,
                            color: _faceDetectedInPreview
                                ? Colors.white
                                : Colors.grey.shade600,
                            size: 32,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Oval overlay painter ──────────────────────────────────────────────────────
class _FaceOvalOverlayPainter extends CustomPainter {
  final bool faceDetected;
  const _FaceOvalOverlayPainter({required this.faceDetected});

  @override
  void paint(Canvas canvas, Size size) {
    final ovalW = size.width * 0.65;
    final ovalH = ovalW * 1.35; // portrait aspect ratio
    final ovalRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.47),
      width: ovalW,
      height: ovalH,
    );

    // Dimmed background with oval cutout
    final bgPaint = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final bgPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final ovalPath = Path()..addOval(ovalRect);
    canvas.drawPath(
      Path.combine(PathOperation.difference, bgPath, ovalPath),
      bgPaint,
    );

    // Oval border — green when face detected, white otherwise
    final borderPaint = Paint()
      ..color = faceDetected ? const Color(0xFF00C853) : Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    canvas.drawOval(ovalRect, borderPaint);
  }

  @override
  bool shouldRepaint(_FaceOvalOverlayPainter oldDelegate) =>
      oldDelegate.faceDetected != faceDetected;
}
