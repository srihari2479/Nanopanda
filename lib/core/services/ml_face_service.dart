// lib/core/services/ml_face_service.dart
//
// Production ML face service — facenet_int_quantized.tflite + ML Kit.
//
// ROOT FIX: InputImageConverterError / IllegalArgumentException
// ─────────────────────────────────────────────────────────────────────────────
// The camera plugin gives YUV_420_888 frames where bytesPerRow > width
// (hardware row-stride padding). Passing raw concatenated plane bytes to ML Kit
// with format=yuv_420_888 causes byte-count mismatch → IllegalArgumentException
// on every single frame → "no face detected" forever.
//
// Correct approach:
//   1. Manually convert YUV420 → NV21 while STRIPPING row padding.
//   2. Pass NV21 bytes to ML Kit with format=nv21 and bytesPerRow=width.
//   NV21 has no padding — byte count is always exactly width*height*3/2.
//
// Model: assets/models/facenet_int_quantized.tflite
//   Input:  [1, 160, 160, 3]  uint8   values 0–255 (INT8 quantized)
//   Output: [1, 128]          float32 L2-normalised identity embedding
//   Threshold: cosine ≥ 0.50  →  matchPercentage ≥ 75 %
//   → AppConstants.faceMatchThreshold = 0.75
//
// HINT FIXES:
//   - Removed `import 'dart:typed_data'` (unnecessary — Uint8List is provided
//     by the camera package's transitive export; hint at line 24).
//   - Added explicit braces to single-statement for loops (hints at lines
//     377 and 424: "Statements in a for should be enclosed in a block").

import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Uint8List;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FaceFrameResult
// ─────────────────────────────────────────────────────────────────────────────

class FaceFrameResult {
  final bool          faceFound;
  final bool          goodQuality;
  final bool          hasEmbedding;
  final List<double>? embedding;
  final String        statusMessage;
  final double?       leftEyeOpenProb;
  final double?       rightEyeOpenProb;
  final double?       headEulerY;

  const FaceFrameResult({
    required this.faceFound,
    required this.goodQuality,
    required this.hasEmbedding,
    this.embedding,
    required this.statusMessage,
    this.leftEyeOpenProb,
    this.rightEyeOpenProb,
    this.headEulerY,
  });

  factory FaceFrameResult.noFace() => const FaceFrameResult(
    faceFound:     false,
    goodQuality:   false,
    hasEmbedding:  false,
    statusMessage: 'Look at the camera…',
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// MlFaceService
// ─────────────────────────────────────────────────────────────────────────────

class MlFaceService {
  MlFaceService._();
  static final MlFaceService instance = MlFaceService._();

  // cosine ≥ 0.50 → matchPercentage ≥ 75 %
  // Set AppConstants.faceMatchThreshold = 0.75
  static const double matchThreshold = 0.50;

  static const int    _inputSize  = 160;
  static const int    _embedDim   = 128;
  static const String _modelAsset = 'assets/models/facenet_int_quantized.tflite';

  late FaceDetector _detector;
  Interpreter?      _interpreter;
  bool              _initialized = false;

  List<double>? _cachedStoredVector;
  List<double>? get cachedStoredVector => _cachedStoredVector;

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_initialized) return;

    _detector = FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks:      false,
        enableContours:       false,
        enableClassification: true,  // eye open prob + euler for liveness
        enableTracking:       false,
        performanceMode:      FaceDetectorMode.accurate,
        minFaceSize:          0.15,
      ),
    );

    try {
      _interpreter = await Interpreter.fromAsset(
        _modelAsset,
        options: InterpreterOptions()..threads = 2,
      );
      debugPrint('[MlFaceService] facenet_int_quantized loaded ✓ '
          'in=${_interpreter!.getInputTensor(0).shape} '
          'out=${_interpreter!.getOutputTensor(0).shape}');
    } catch (e) {
      debugPrint('[MlFaceService] TFLite load FAILED: $e');
    }

    _initialized = true;
  }

  void cacheStoredVector(List<double> v) {
    _cachedStoredVector = v;
    debugPrint('[MlFaceService] stored vector cached (${v.length}d)');
  }

  void clearCachedVector() => _cachedStoredVector = null;

  // ── processFrame ──────────────────────────────────────────────────────────

  Future<FaceFrameResult> processFrame(
      CameraImage cameraImage,
      int         sensorOrientation,
      ) async {
    if (!_initialized) await initialize();

    try {
      // Convert YUV420 → NV21, stripping row-stride padding so that
      // byte count = width*height*3/2 exactly (what ML Kit demands).
      final nv21 = _yuv420ToNv21(cameraImage);

      final inputImage = InputImage.fromBytes(
        bytes: nv21,
        metadata: InputImageMetadata(
          size: Size(
            cameraImage.width.toDouble(),
            cameraImage.height.toDouble(),
          ),
          rotation:    _rotationFromSensor(sensorOrientation),
          format:      InputImageFormat.nv21,  // ← NV21, not yuv_420_888
          bytesPerRow: cameraImage.width,      // ← no padding in NV21
        ),
      );

      final faces = await _detector.processImage(inputImage);
      if (faces.isEmpty) return FaceFrameResult.noFace();

      final face = faces.reduce(
            (a, b) => a.boundingBox.width > b.boundingBox.width ? a : b,
      );

      final eulerY   = face.headEulerAngleY ?? 0.0;
      final eulerZ   = face.headEulerAngleZ ?? 0.0;
      final leftEye  = face.leftEyeOpenProbability;
      final rightEye = face.rightEyeOpenProbability;

      final isFrontal   = eulerY.abs() < 25 && eulerZ.abs() < 20;
      final eyesOpen    = (leftEye  == null || leftEye  > 0.4) &&
          (rightEye == null || rightEye > 0.4);
      final goodQuality = isFrontal && eyesOpen;

      String statusMessage = 'Hold still…';
      if (!isFrontal) {
        statusMessage = 'Face the camera directly';
      } else if (!eyesOpen) {
        statusMessage = 'Open your eyes';
      }

      List<double>? embedding;
      if (goodQuality && _interpreter != null) {
        embedding = _runFaceNet(cameraImage, face, sensorOrientation);
      }

      return FaceFrameResult(
        faceFound:        true,
        goodQuality:      goodQuality,
        hasEmbedding:     embedding != null,
        embedding:        embedding,
        statusMessage:    statusMessage,
        leftEyeOpenProb:  leftEye,
        rightEyeOpenProb: rightEye,
        headEulerY:       eulerY,
      );
    } catch (e) {
      debugPrint('[MlFaceService] processFrame error: $e');
      return FaceFrameResult.noFace();
    }
  }

  // ── YUV420 → NV21 conversion ──────────────────────────────────────────────
  //
  // YUV420 from camera plugin:
  //   plane[0] = Y,  bytesPerRow may be padded  (e.g. 512 for width=480)
  //   plane[1] = U,  bytesPerRow may be padded
  //   plane[2] = V,  bytesPerRow may be padded
  //
  // NV21 layout (no padding):
  //   [Y0 Y1 Y2 … Yn]  [V0 U0 V1 U1 … Vn Un]
  //   total bytes = width * height * 3 / 2

  Uint8List _yuv420ToNv21(CameraImage cam) {
    final int w = cam.width;
    final int h = cam.height;

    final yPlane = cam.planes[0];
    final uPlane = cam.planes[1];
    final vPlane = cam.planes[2];

    final nv21  = Uint8List(w * h * 3 ~/ 2);
    int   index = 0;

    // Copy Y plane — strip horizontal padding
    for (int row = 0; row < h; row++) {
      final rowStart = row * yPlane.bytesPerRow;
      for (int col = 0; col < w; col++) {
        nv21[index++] = yPlane.bytes[rowStart + col];
      }
    }

    // Interleave V,U — NV21 = V first, then U
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;
    for (int row = 0; row < h ~/ 2; row++) {
      final rowStart = row * vPlane.bytesPerRow;
      for (int col = 0; col < w ~/ 2; col++) {
        final uvIdx = rowStart + col * uvPixelStride;
        nv21[index++] = vPlane.bytes[uvIdx];
        nv21[index++] = uPlane.bytes[uvIdx];
      }
    }

    return nv21;
  }

  // ── FaceNet inference ─────────────────────────────────────────────────────

  List<double>? _runFaceNet(
      CameraImage cam,
      Face        face,
      int         sensorOrientation,
      ) {
    try {
      final rgb = _nv21ToRgb(cam);
      if (rgb == null) return null;

      final oriented = _applyRotation(rgb, sensorOrientation);
      final cropped  = _cropFace(oriented, face.boundingBox);
      if (cropped == null) return null;

      final resized = img.copyResize(
        cropped,
        width:         _inputSize,
        height:        _inputSize,
        interpolation: img.Interpolation.linear,
      );

      final input  = _buildUint8Input(resized);
      final output = List.generate(1, (_) => List<double>.filled(_embedDim, 0.0));

      _interpreter!.run(input, output);

      return _l2Normalize(List<double>.from(output[0]));
    } catch (e) {
      debugPrint('[MlFaceService] _runFaceNet error: $e');
      return null;
    }
  }

  // ── Image helpers ─────────────────────────────────────────────────────────

  img.Image? _nv21ToRgb(CameraImage cam) {
    try {
      final int w = cam.width;
      final int h = cam.height;

      final yPlane = cam.planes[0];
      final uPlane = cam.planes[1];
      final vPlane = cam.planes[2];

      final yBytes = yPlane.bytes;
      final uBytes = uPlane.bytes;
      final vBytes = vPlane.bytes;

      final uvRowStride   = uPlane.bytesPerRow;
      final uvPixelStride = uPlane.bytesPerPixel ?? 1;

      final image = img.Image(width: w, height: h);

      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final yIdx  = y * yPlane.bytesPerRow + x;
          final uvIdx = (y ~/ 2) * uvRowStride + (x ~/ 2) * uvPixelStride;

          if (yIdx  >= yBytes.length) { continue; }
          if (uvIdx >= uBytes.length || uvIdx >= vBytes.length) { continue; }

          final yv = yBytes[yIdx]  & 0xFF;
          final uv = uBytes[uvIdx] & 0xFF;
          final vv = vBytes[uvIdx] & 0xFF;

          final c = yv - 16;
          final d = uv - 128;
          final e = vv - 128;

          final r = ((298 * c + 409 * e + 128) >> 8).clamp(0, 255);
          final g = ((298 * c - 100 * d - 208 * e + 128) >> 8).clamp(0, 255);
          final b = ((298 * c + 516 * d + 128) >> 8).clamp(0, 255);

          image.setPixelRgb(x, y, r, g, b);
        }
      }
      return image;
    } catch (e) {
      debugPrint('[MlFaceService] nv21→rgb error: $e');
      return null;
    }
  }

  img.Image _applyRotation(img.Image image, int degrees) {
    switch (degrees) {
      case 90:  return img.copyRotate(image, angle: 90);
      case 180: return img.copyRotate(image, angle: 180);
      case 270: return img.copyRotate(image, angle: 270);
      default:  return image;
    }
  }

  img.Image? _cropFace(img.Image image, Rect bb) {
    final padX = bb.width  * 0.20;
    final padY = bb.height * 0.20;

    final left   = (bb.left   - padX).clamp(0.0, (image.width  - 1).toDouble()).toInt();
    final top    = (bb.top    - padY).clamp(0.0, (image.height - 1).toDouble()).toInt();
    final right  = (bb.right  + padX).clamp(0.0,  image.width.toDouble()).toInt();
    final bottom = (bb.bottom + padY).clamp(0.0,  image.height.toDouble()).toInt();

    final w = right - left;
    final h = bottom - top;
    if (w <= 0 || h <= 0) return null;

    return img.copyCrop(image, x: left, y: top, width: w, height: h);
  }

  /// [1, 160, 160, 3] uint8 tensor for INT8 quantized FaceNet.
  List<List<List<List<int>>>> _buildUint8Input(img.Image image) {
    return List.generate(1, (_) =>
        List.generate(_inputSize, (y) =>
            List.generate(_inputSize, (x) {
              final p = image.getPixel(x, y);
              return [p.r.toInt(), p.g.toInt(), p.b.toInt()];
            }),
        ),
    );
  }

  // ── Matching ──────────────────────────────────────────────────────────────

  static double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;
    double dot = 0.0;
    // FIX: enclosed in braces to clear "Statements in a for should be
    // enclosed in a block" hint (line 377 in original).
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot.clamp(-1.0, 1.0);
  }

  static double matchPercentage(List<double> stored, List<double> live) {
    return ((cosineSimilarity(stored, live) + 1.0) / 2.0 * 100.0)
        .clamp(0.0, 100.0);
  }

  bool isMatch(List<double> stored, List<double> live) {
    final sim = cosineSimilarity(stored, live);
    debugPrint('[MlFaceService] cosine=${sim.toStringAsFixed(4)} '
        'threshold=$matchThreshold');
    return sim >= matchThreshold;
  }

  // ── Standalone JPEG extraction (SilentFaceChannel / monitoring) ───────────

  Future<List<double>?> extractEmbeddingFromBytes(Uint8List jpegBytes) async {
    if (!_initialized) await initialize();
    if (_interpreter == null) return null;

    try {
      final decoded = img.decodeImage(jpegBytes);
      if (decoded == null) return null;

      final resized = img.copyResize(
        decoded,
        width:  _inputSize,
        height: _inputSize,
      );

      final input  = _buildUint8Input(resized);
      final output = List.generate(1, (_) => List<double>.filled(_embedDim, 0.0));
      _interpreter!.run(input, output);

      return _l2Normalize(List<double>.from(output[0]));
    } catch (e) {
      debugPrint('[MlFaceService] extractEmbeddingFromBytes error: $e');
      return null;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  List<double> _l2Normalize(List<double> v) {
    double norm = 0.0;
    // FIX: enclosed in braces to clear "Statements in a for should be
    // enclosed in a block" hint (line 424 in original).
    for (final x in v) {
      norm += x * x;
    }
    norm = math.sqrt(norm);
    if (norm < 1e-10) return v;
    return v.map((x) => x / norm).toList();
  }

  InputImageRotation _rotationFromSensor(int degrees) {
    switch (degrees) {
      case 0:   return InputImageRotation.rotation0deg;
      case 90:  return InputImageRotation.rotation90deg;
      case 180: return InputImageRotation.rotation180deg;
      case 270: return InputImageRotation.rotation270deg;
      default:  return InputImageRotation.rotation270deg;
    }
  }

  Future<void> dispose() async {
    if (_initialized) {
      await _detector.close();
      _interpreter?.close();
      _interpreter = null;
      _initialized = false;
    }
  }
}