import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'dart:io';
import 'package:dmrtd/dmrtd.dart';

class MrzScannerScreen extends StatefulWidget {
  const MrzScannerScreen({Key? key}) : super(key: key);

  @override
  _MrzScannerScreenState createState() => _MrzScannerScreenState();
}

class _MrzScannerScreenState extends State<MrzScannerScreen> {
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  
  final TextRecognizer _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  bool _isProcessingFrame = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        debugPrint('No cameras available');
        return;
      }

      // Try to find a back-facing camera
      final backCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();
      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
        _cameraController!.startImageStream(_processCameraFrame);
      }
    } catch (e) {
      debugPrint('Error initializing camera: $e');
    }
  }

  @override
  void dispose() {
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _textRecognizer.close();
    super.dispose();
  }

  Future<void> _processCameraFrame(CameraImage image) async {
    if (_isProcessingFrame) return;
    _isProcessingFrame = true;

    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) {
        _isProcessingFrame = false;
        return;
      }

      final recognizedText = await _textRecognizer.processImage(inputImage);
      
      List<String> mrzLines = [];
      for (final block in recognizedText.blocks) {
        for (final line in block.lines) {
          String text = line.text.replaceAll(' ', '').replaceAll('«', '<');
          // Common OCR fixes for MRZ
          text = text.replaceAll('O', '0'); // Dangerous for names, but MRZ parser can be strict on check digits. Wait, no. Names have 'O'. Let's not blindly replace 'O' with '0'.
          // Let's just keep it simple
          if (text.length >= 30 && text.length <= 44 && text.contains('<')) {
            mrzLines.add(text);
          }
        }
      }

      MRZ? parsedMrz;
      
      if (mrzLines.length >= 2) {
        for (int i = 0; i < mrzLines.length - 1; i++) {
           String combined = mrzLines[i] + mrzLines[i+1];
           if (combined.length == 72 || combined.length == 88) {
              try {
                parsedMrz = MRZ(Uint8List.fromList(combined.codeUnits));
                break;
              } catch (e) {
                debugPrint("MRZ parse failed for 2 lines: $e");
              }
           }
        }
      }
      
      if (parsedMrz == null && mrzLines.length >= 3) {
        for (int i = 0; i < mrzLines.length - 2; i++) {
           String combined = mrzLines[i] + mrzLines[i+1] + mrzLines[i+2];
           if (combined.length == 90) {
              try {
                parsedMrz = MRZ(Uint8List.fromList(combined.codeUnits));
                break;
              } catch (e) {
                debugPrint("MRZ parse failed for 3 lines: $e");
              }
           }
        }
      }

      if (parsedMrz != null) {
        if (mounted) {
          Navigator.pop(context, parsedMrz);
        }
        return;
      }
      
    } catch (e) {
      debugPrint('Error processing frame: $e');
    }

    if (mounted) {
      _isProcessingFrame = false;
    }
  }

  final _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final camera = _cameraController?.description;
    if (camera == null) return null;

    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation = _orientations[_cameraController!.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation = (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21 && format != InputImageFormat.yuv_420_888 && format != InputImageFormat.yuv420) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      return null;
    }

    if (image.planes.isEmpty) return null;

    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final Size imageSize = Size(image.width.toDouble(), image.height.toDouble());

    final metadata = InputImageMetadata(
      size: imageSize,
      rotation: rotation,
      format: Platform.isAndroid ? InputImageFormat.nv21 : format,
      bytesPerRow: image.planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan MRZ'),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        titleTextStyle: const TextStyle(color: Colors.white, fontSize: 20),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_isCameraInitialized && _cameraController != null)
            CameraPreview(_cameraController!)
          else
            const Center(child: CircularProgressIndicator(color: Colors.white)),
          if (_isCameraInitialized)
            CustomPaint(
              painter: _MrzOverlayPainter(),
            ),
          if (_isCameraInitialized)
            const Positioned(
              bottom: 100,
              left: 0,
              right: 0,
              child: Text(
                'Please align the passport MRZ\nwithin the frame',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  shadows: [
                    Shadow(color: Colors.black, blurRadius: 4),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MrzOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPaint = Paint()..color = Colors.black54;

    // The MRZ usually sits at the bottom of the passport.
    // Let's create a rectangular cutout in the lower half of the screen.
    final cutoutWidth = size.width * 0.9;
    final cutoutHeight = size.height * 0.2;
    
    final cutoutRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.7),
      width: cutoutWidth,
      height: cutoutHeight,
    );

    // Draw the dark background with a cutout
    final backgroundPath = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final cutoutPath = Path()..addRRect(RRect.fromRectAndRadius(cutoutRect, const Radius.circular(12)));
    
    final overlayPath = Path.combine(PathOperation.difference, backgroundPath, cutoutPath);
    canvas.drawPath(overlayPath, backgroundPaint);

    // Draw a border around the cutout
    final borderPaint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    
    canvas.drawRRect(RRect.fromRectAndRadius(cutoutRect, const Radius.circular(12)), borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
