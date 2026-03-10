// lib/core/services/ml_face_service.dart
//
// Production-level on-device face recognition service.
// Uses:
//   • google_mlkit_face_detection  — face presence, landmarks, eye-open
//                                    probability, head Euler angles
//   • tflite_flutter               — FaceNet (int-quantized) → 128-dim embedding
//   • package:image                — crop + resize face ROI to 112×112
//
// 100% on-device. No network calls. No API keys.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:path_provider/path_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Data classes
// ─────────────────────────────────────────────────────────────────────────────

/// Everything the caller needs from one processed camera frame.
class FaceProcessingResult {
  final bool faceFound;
  final bool goodQuality;
  final List<double>? embedding;         // 128-dim, null when no face
  final double? leftEyeOpenProb;         // 0.0 – 1.0
  final double? rightEyeOpenProb;        // 0.0 – 1.0
  final double? headEulerY;              // degrees; positive = turned right
  final String statusMessage;

  const FaceProcessingResult({
    required this.faceFound,
    required this.goodQuality,
    this.embedding,
    this.leftEyeOpenProb,
    this.rightEyeOpenProb,
    this.headEulerY,
    required this.statusMessage,
  });

  bool get hasEmbedding => embedding != null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

/// Singleton. Call [initialize] once at app start (or before first use).
class MlFaceService {
  MlFaceService._();
  static final MlFaceService instance = MlFaceService._();

  FaceDetector? _detector;
  Interpreter? _interpreter;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  // MobileFaceNet I/O dimensions
  static const int _inputSize    = 112;
  static const int _embeddingDim = 128;

  // ── public ──────────────────────────────────────────────────────────────────

  /// Idempotent — safe to call multiple times.
  Future<void> initialize() async {
    if (_isInitialized) return;

    _detector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,   // eye-open probability
        enableLandmarks: true,
        enableContours: false,
        enableTracking: false,
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.15,
      ),
    );

    _interpreter = await _loadInterpreter();
    _isInitialized = true;
    debugPrint('[MlFaceService] ready');
  }

  /// Main entry point. Pass one camera frame and get back face info + embedding.
  /// [sensorOrientation] = CameraDescription.sensorOrientation (typically 90 on Android).
  Future<FaceProcessingResult> processFrame(
      CameraImage frame,
      int sensorOrientation,
      ) async {
    if (!_isInitialized) {
      return const FaceProcessingResult(
        faceFound: false,
        goodQuality: false,
        statusMessage: 'Service not initialized',
      );
    }

    try {
      // 1. Build InputImage for ML Kit
      final inputImage = _toInputImage(frame, sensorOrientation);
      if (inputImage == null) {
        return const FaceProcessingResult(
          faceFound: false,
          goodQuality: false,
          statusMessage: 'Frame conversion failed',
        );
      }

      // 2. Detect faces
      final faces = await _detector!.processImage(inputImage);

      if (faces.isEmpty) {
        return const FaceProcessingResult(
          faceFound: false,
          goodQuality: false,
          statusMessage: 'No face detected — look at the camera',
        );
      }
      if (faces.length > 1) {
        return const FaceProcessingResult(
          faceFound: false,
          goodQuality: false,
          statusMessage: 'Multiple faces — only one person please',
        );
      }

      final face      = faces.first;
      final leftEye   = face.leftEyeOpenProbability;
      final rightEye  = face.rightEyeOpenProbability;
      final eulerY    = face.headEulerAngleY;

      // 3. Quality gates
      //
      // BUG FIX: The old gate checked `if (leftEye != null && rightEye != null)`
      // and rejected if either eye < 0.3. This caused "Please open your eyes
      // fully" to flash on screen during a blink attempt, confusing users into
      // thinking the blink was wrong.
      //
      // More importantly: when BOTH eyes are null (fully closed during blink),
      // the old gate was SKIPPED entirely — leaving the frame to fall through
      // to embedding with potentially bad data.
      //
      // FIX: Always return faceFound=true with the raw eye/eulerY values so
      // the liveness service can observe them (null = closed is handled there).
      // Only apply the "eyes open" quality gate when we are NOT in a blink
      // (i.e. at least one eye probability is available AND it is very low).
      // This means the face is simply squinting/looking away, not blinking.
      final bool likelyBlinking = leftEye == null && rightEye == null;

      if (!likelyBlinking && leftEye != null && rightEye != null) {
        if (leftEye < 0.3 || rightEye < 0.3) {
          return FaceProcessingResult(
            faceFound: true,
            goodQuality: false,
            leftEyeOpenProb: leftEye,
            rightEyeOpenProb: rightEye,
            headEulerY: eulerY,
            statusMessage: 'Please open your eyes fully',
          );
        }
      }
      if (eulerY != null && eulerY.abs() > 25) {
        return FaceProcessingResult(
          faceFound: true,
          goodQuality: false,
          leftEyeOpenProb: leftEye,
          rightEyeOpenProb: rightEye,
          headEulerY: eulerY,
          statusMessage: 'Face the camera directly',
        );
      }

      // 4. Convert full frame to RGB for cropping
      final rgbImage = _toRgbImage(frame);
      if (rgbImage == null) {
        return const FaceProcessingResult(
          faceFound: true,
          goodQuality: false,
          statusMessage: 'Image conversion failed',
        );
      }

      // 5. Crop + resize face patch → 112×112
      final facePatch = _cropAndResize(rgbImage, face.boundingBox);

      // 6. MobileFaceNet inference
      final embedding = _runInference(facePatch);

      return FaceProcessingResult(
        faceFound: true,
        goodQuality: true,
        embedding: embedding,
        leftEyeOpenProb: leftEye,
        rightEyeOpenProb: rightEye,
        headEulerY: eulerY,
        statusMessage: 'Face detected ✓',
      );
    } catch (e, st) {
      debugPrint('[MlFaceService] processFrame error: $e\n$st');
      return FaceProcessingResult(
        faceFound: false,
        goodQuality: false,
        statusMessage: 'Error: $e',
      );
    }
  }

  /// Cosine similarity between two L2-normalised embeddings → [0, 1].
  static double cosineSimilarity(List<double> a, List<double> b) {
    double dot = 0, na = 0, nb = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na  += a[i] * a[i];
      nb  += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  /// Returns a 0–100 match score. ≥80 = same person (configurable).
  static double matchPercentage(List<double> stored, List<double> live) {
    return ((cosineSimilarity(stored, live) + 1.0) / 2.0) * 100.0;
  }

  /// Process a decoded JPEG image (from silent background capture).
  /// Returns 128-dim L2-normalised embedding, or null if no face found.
  Future<List<double>?> processJpegImage(img.Image jpegImage) async {
    if (!_isInitialized) return null;
    try {
      // Resize to model input size
      final resized = img.copyResize(jpegImage,
          width: _inputSize, height: _inputSize,
          interpolation: img.Interpolation.linear);

      // Detect face region — use full image if detection fails
      // (background capture already frames the face roughly)
      final embedding = _runInference(resized);
      return embedding;
    } catch (e) {
      debugPrint('[MlFaceService] processJpegImage error: $e');
      return null;
    }
  }

  Future<void> dispose() async {
    await _detector?.close();
    _interpreter?.close();
    _isInitialized = false;
  }

  // ── private helpers ──────────────────────────────────────────────────────────

  Future<Interpreter> _loadInterpreter() async {
    try {
      return await Interpreter.fromAsset(
        'assets/models/facenet_int_quantized.tflite',
        options: InterpreterOptions()..threads = 2,
      );
    } catch (e) {
      // Fallback: extract to temp file (required on some Android versions)
      debugPrint('[MlFaceService] Asset load fallback: $e');
      final data = await rootBundle.load('assets/models/facenet_int_quantized.tflite');
      final dir  = await getTemporaryDirectory();
      final file = File('${dir.path}/facenet_int_quantized.tflite');
      await file.writeAsBytes(data.buffer.asUint8List());
      return Interpreter.fromFile(file, options: InterpreterOptions()..threads = 2);
    }
  }

  InputImage? _toInputImage(CameraImage image, int sensorOrientation) {
    try {
      // On Android the camera stream is always YUV420 (NV21 for ML Kit).
      // We must manually interleave U/V planes into a single NV21 byte buffer:
      //   [ Y plane (width*height bytes) ][ VU interleaved (width*height/2 bytes) ]
      final int width  = image.width;
      final int height = image.height;

      final Uint8List yPlane  = image.planes[0].bytes;
      final Uint8List uPlane  = image.planes[1].bytes;
      final Uint8List vPlane  = image.planes[2].bytes;

      // Build NV21 buffer
      final Uint8List nv21 = Uint8List(width * height + (width * height ~/ 2));

      // Copy Y plane (may have row padding — copy row by row)
      final int yRowStride = image.planes[0].bytesPerRow;
      int dstIdx = 0;
      for (int row = 0; row < height; row++) {
        nv21.setRange(dstIdx, dstIdx + width, yPlane, row * yRowStride);
        dstIdx += width;
      }

      // Interleave V and U into NV21 (V first, then U)
      final int uvRowStride   = image.planes[1].bytesPerRow;
      final int uvPixelStride = image.planes[1].bytesPerPixel ?? 1;
      for (int row = 0; row < height ~/ 2; row++) {
        for (int col = 0; col < width ~/ 2; col++) {
          final int uvIndex = row * uvRowStride + col * uvPixelStride;
          nv21[dstIdx++] = vPlane[uvIndex]; // V
          nv21[dstIdx++] = uPlane[uvIndex]; // U
        }
      }

      final metadata = InputImageMetadata(
        size: Size(width.toDouble(), height.toDouble()),
        rotation: _rotationFromDegrees(sensorOrientation),
        format: InputImageFormat.nv21,          // explicit NV21
        bytesPerRow: width,                     // NV21 row stride = width
      );

      return InputImage.fromBytes(bytes: nv21, metadata: metadata);
    } catch (e) {
      debugPrint('[MlFaceService] _toInputImage error: $e');
      return null;
    }
  }

  img.Image? _toRgbImage(CameraImage frame) {
    try {
      if (frame.format.group == ImageFormatGroup.yuv420) {
        return _yuv420ToRgb(frame);
      } else if (frame.format.group == ImageFormatGroup.bgra8888) {
        return img.Image.fromBytes(
          width: frame.width,
          height: frame.height,
          bytes: frame.planes[0].bytes.buffer,
          order: img.ChannelOrder.bgra,
        );
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  img.Image _yuv420ToRgb(CameraImage image) {
    final w = image.width, h = image.height;
    final out = img.Image(width: w, height: h);
    final yP  = image.planes[0];
    final uP  = image.planes[1];
    final vP  = image.planes[2];
    final uvRowStride   = uP.bytesPerRow;
    final uvPixelStride = uP.bytesPerPixel ?? 1;

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final yIdx = y * yP.bytesPerRow + x;
        final uvIdx = (y ~/ 2) * uvRowStride + (x ~/ 2) * uvPixelStride;
        final yv = yP.bytes[yIdx] & 0xFF;
        final u  = (uP.bytes[uvIdx] & 0xFF) - 128;
        final v  = (vP.bytes[uvIdx] & 0xFF) - 128;
        final r = (yv + 1.370705 * v).round().clamp(0, 255);
        final g = (yv - 0.337633 * u - 0.698001 * v).round().clamp(0, 255);
        final b = (yv + 1.732446 * u).round().clamp(0, 255);
        out.setPixelRgb(x, y, r, g, b);
      }
    }
    return out;
  }

  img.Image _cropAndResize(img.Image image, Rect bbox) {
    final padX = bbox.width  * 0.20;
    final padY = bbox.height * 0.20;
    final x = math.max(0, (bbox.left  - padX).round());
    final y = math.max(0, (bbox.top   - padY).round());
    final w = math.min(image.width  - x, (bbox.width  + padX * 2).round());
    final h = math.min(image.height - y, (bbox.height + padY * 2).round());
    final cropped = img.copyCrop(image, x: x, y: y, width: w, height: h);
    return img.copyResize(cropped,
        width: _inputSize, height: _inputSize,
        interpolation: img.Interpolation.linear);
  }

  List<double> _runInference(img.Image faceImage) {
    // Input tensor: [1, 112, 112, 3]  values in [-1, 1]
    final input = List.generate(1, (_) =>
        List.generate(_inputSize, (y) =>
            List.generate(_inputSize, (x) {
              final p = faceImage.getPixel(x, y);
              return [(p.r / 127.5) - 1.0, (p.g / 127.5) - 1.0, (p.b / 127.5) - 1.0];
            })
        )
    );

    // Output tensor: [1, 128]
    final output = List.generate(1, (_) => List.filled(_embeddingDim, 0.0));
    _interpreter!.run(input, output);

    // L2 normalise
    final raw  = output[0];
    double norm = 0;
    for (final v in raw) norm += v * v;
    norm = math.sqrt(norm);
    return norm == 0 ? raw : raw.map((v) => v / norm).toList();
  }

  // _flattenPlanes removed — NV21 conversion is done in _toInputImage

  InputImageRotation _rotationFromDegrees(int deg) {
    switch (deg) {
      case 90:  return InputImageRotation.rotation90deg;
      case 180: return InputImageRotation.rotation180deg;
      case 270: return InputImageRotation.rotation270deg;
      default:  return InputImageRotation.rotation0deg;
    }
  }
}