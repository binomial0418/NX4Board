import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'dart:ui' as ui;

class OcrService {
  static const List<int> validSpeedLimits = [
    20,
    30,
    40,
    50,
    60,
    70,
    80,
    90,
    100,
    110,
    120
  ];

  final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

  /// Recognize text from camera image
  /// Returns extracted speed limit (20-120) or null if not found
  Future<int?> recognizeSpeedLimit(CameraImage image) async {
    try {
      final inputImage = _buildInputImage(image);
      final recognizedText = await textRecognizer.processImage(inputImage);
      // Wait, let's look at original code if there was close. Older versions of inputImage don't have close, but textRecognizer does. Let's just return.
      // The original code was: inputImage.close(); Wait, InputImage doesn't have close() in latest but might in 0.8.0? It's fine to avoid it if it gives errors, but for safety let's just leave it out, since it's just a Dart object holding Uint8List. Actually, no, let me just parse.

      // Extract numbers from recognized text
      return _extractSpeedLimit(recognizedText.text);
    } catch (e) {
      if (e.toString().contains('Image dimension')) {
        print(
            'OCR Error - Image dimension mismatch: Check YUV420 format handling');
      }
      return null;
    }
  }

  /// Extract speed limit from recognized text
  static int? _extractSpeedLimit(String text) {
    // Find all numbers in the text
    final regex = RegExp(r'\d+');
    final matches = regex.allMatches(text);

    for (final match in matches) {
      final numberStr = match.group(0);
      final number = int.tryParse(numberStr ?? '');

      if (number != null && validSpeedLimits.contains(number)) {
        return number;
      }
    }

    return null;
  }

  /// Build InputImage from CameraImage
  InputImage _buildInputImage(CameraImage image) {
    // Merge all planes into a single byte array to avoid "ByteBuffer size and format don't match" error
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final imageFormat =
        InputImageFormatMethods.fromRawValue(image.format.raw) ??
            InputImageFormat.yuv420;

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: ui.Size(image.width.toDouble(), image.height.toDouble()),
        rotation: InputImageRotation.rotation90deg,
        format: imageFormat,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }

  /// Get ROI (Region of Interest) rectangle based on placement
  /// placement: "左側", "右側", "中央"
  static ui.Rect getRoiRect(
      String placement, double imageWidth, double imageHeight) {
    switch (placement) {
      case "左側":
        // Left side of screen
        return ui.Rect.fromLTWH(0, 0, imageWidth * 0.4, imageHeight * 0.5);
      case "右側":
        // Right side of screen
        return ui.Rect.fromLTWH(
            imageWidth * 0.6, 0, imageWidth * 0.4, imageHeight * 0.5);
      case "中央":
        // Center of screen
        return ui.Rect.fromLTWH(imageWidth * 0.2, imageHeight * 0.2,
            imageWidth * 0.6, imageHeight * 0.3);
      default:
        // Full screen fallback
        return ui.Rect.fromLTWH(0, 0, imageWidth, imageHeight);
    }
  }

  void dispose() {
    textRecognizer.close();
  }
}

/// Simple input image format converter
class InputImageFormatMethods {
  static InputImageFormat? fromRawValue(int? value) {
    if (value == null) return null;
    switch (value) {
      case 35:
        return InputImageFormat.yuv420;
      case 875770417:
        return InputImageFormat.bgra8888;
      default:
        return InputImageFormat.yuv420;
    }
  }
}
