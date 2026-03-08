import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import '../providers/app_provider.dart';
import '../services/ocr_service.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({Key? key}) : super(key: key);

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _cameraController;
  OcrService? _ocrService;
  bool _isProcessing = false;
  String _ocrStatus = 'Initializing camera...';
  int? _detectedSpeed;
  int _frameCount = 0;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _ocrService = OcrService();
  }

  Future<void> _initializeCamera() async {
    try {
      final status = await Permission.camera.request();
      if (status.isDenied) {
        setState(() => _ocrStatus = 'Camera permission denied');
        return;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _ocrStatus = 'No cameras available');
        return;
      }

      _cameraController = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _cameraController!.initialize();

      if (!mounted) return;
      setState(() => _ocrStatus = 'Camera ready');

      _startFrameProcessing();
    } catch (e) {
      setState(() => _ocrStatus = 'Camera error: $e');
    }
  }

  void _startFrameProcessing() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    _cameraController!.startImageStream((CameraImage image) async {
      if (_isProcessing) {
        return;
      }

      _isProcessing = true;

      try {
        final detectedSpeed = await _ocrService?.recognizeSpeedLimit(image);

        if (mounted) {
          setState(() {
            _frameCount++;
            if (detectedSpeed != null) {
              _detectedSpeed = detectedSpeed;
              _ocrStatus =
                  'Detected: ${detectedSpeed}km/h (Frame: $_frameCount)';
            } else {
              _ocrStatus = 'Scanning... (Frame: $_frameCount)';
            }
          });

          // Update provider
          context.read<AppProvider>().updateDetectedSpeed(detectedSpeed);
        }
      } catch (e) {
        if (mounted) {
          setState(() => _ocrStatus = 'OCR error: $e');
        }
      } finally {
        _isProcessing = false;
      }
    });
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _ocrService?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('相機 OCR 測試'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Camera Preview
          Expanded(
            child: _cameraController != null &&
                    _cameraController!.value.isInitialized
                ? Stack(
                    children: [
                      CameraPreview(_cameraController!),
                      // ROI Rectangle Overlay (if available)
                      Consumer<AppProvider>(
                        builder: (context, provider, _) {
                          final placement = provider.getNearestSignPlacement();
                          if (placement.isEmpty) return const SizedBox();

                          return CustomPaint(
                            painter: RoiRectanglePainter(placement),
                            child: const SizedBox.expand(),
                          );
                        },
                      ),
                    ],
                  )
                : Container(
                    color: Colors.black,
                    child: Center(
                      child: Text(
                        _ocrStatus,
                        style: const TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
          ),
          // Status Panel
          Container(
            color: Colors.black87,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Status: $_ocrStatus',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 8),
                if (_detectedSpeed != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check, color: Colors.white),
                        const SizedBox(width: 8),
                        Text(
                          'Detected: $_detectedSpeed km/h',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('返回'),
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

class RoiRectanglePainter extends CustomPainter {
  final String placement;

  RoiRectanglePainter(this.placement);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.green.withOpacity(0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    final rect = _getRectForPlacement(placement, size);
    canvas.drawRect(rect, paint);
  }

  Rect _getRectForPlacement(String placement, Size size) {
    switch (placement) {
      case '左側':
        return Rect.fromLTRB(0, 0, 0.4 * size.width, 0.5 * size.height);
      case '右側':
        return Rect.fromLTRB(
            0.6 * size.width, 0, size.width, 0.5 * size.height);
      case '中央':
        return Rect.fromLTRB(0.2 * size.width, 0.2 * size.height,
            0.8 * size.width, 0.5 * size.height);
      default:
        return Rect.fromLTWH(0, 0, size.width, size.height);
    }
  }

  @override
  bool shouldRepaint(RoiRectanglePainter oldDelegate) {
    return oldDelegate.placement != placement;
  }
}
