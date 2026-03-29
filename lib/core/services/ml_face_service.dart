// lib/core/services/ml_face_service.dart
//
// Production ML face service — facenet_int_quantized.tflite + ML Kit.
//
// FIX (2025-03-21):
//   extractEmbeddingFromFile() replaces extractEmbeddingFromBytes() for
//   background-capture verification.
//
//   OLD BUG: extractEmbeddingFromBytes() resized the ENTIRE photo to 160×160
//   and fed it to FaceNet with NO face detection / face crop.  Because
//   FaceNet still produces an output for any image, it returned an embedding
//   even when the photo contained no face.  That embedding happened to sit
//   ~0.64 cosine away from the stored owner vector (= 82 % in the display
//   scale), which is above the (wrong) 50 % threshold → everything showed
//   AUTH.
//
//   NEW:
//     extractEmbeddingFromFile(path)
//       1. Runs ML Kit face detection via InputImage.fromFilePath().
//       2. Returns null immediately if no face is found in the photo.
//       3. Crops the image to the detected face bounding box (+20 % padding).
//       4. Runs FaceNet on the 160 × 160 crop.
//       5. Returns the L2-normalised 128-d embedding.
//
//   This means a photo without a face now correctly returns null →
//   _loadAndVerifyPendingLogs() logs it as "No face detected — Unauthorized".
//
// Threshold reminder (unchanged):
//   matchThreshold = 0.50  (cosine similarity, raw)
//   matchPercentage maps cosine [-1, 1] → [0, 100 %]
//   cosine 0.50 → display 75 %
//   The CALLER must compare against 75.0, NOT 0.50 * 100 = 50.0.
//   See monitoring_provider.dart: `isOwner = cosine >= MlFaceService.matchThreshold`

import 'dart:io';
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

  // cosine ≥ 0.60 → matchPercentage ≥ 60% (with new intuitive formula)
  //
  // DISPLAY FORMULA CHANGE:
  //   OLD: (cosine + 1) / 2 * 100  →  maps cosine 0.0 (stranger) to 50%
  //        This made different people appear to have 50-65% "match" which
  //        looked dangerously close to the owner even when labeled UNAUTH.
  //
  //   NEW: cosine * 100, clamped [0, 100]
  //        cosine 0.0  (stranger)  →   0%   ← clearly no match
  //        cosine 0.26 (stranger)  →  26%   ← clearly no match
  //        cosine 0.60 (threshold) →  60%   ← minimum to pass
  //        cosine 0.88 (owner)     →  88%   ← strong match
  //
  // Threshold raised 0.50 → 0.60 for extra safety margin.
  // Owner typically scores 0.75–0.95 with correct float32 preprocessing.
  // Strangers typically score 0.0–0.35 → display 0–35%.
  static const double matchThreshold = 0.60;

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

  // ── processFrame (live camera — unchanged) ────────────────────────────────

  Future<FaceFrameResult> processFrame(
      CameraImage cameraImage,
      int         sensorOrientation,
      ) async {
    if (!_initialized) await initialize();

    try {
      final nv21 = _yuv420ToNv21(cameraImage);

      final inputImage = InputImage.fromBytes(
        bytes: nv21,
        metadata: InputImageMetadata(
          size: Size(
            cameraImage.width.toDouble(),
            cameraImage.height.toDouble(),
          ),
          rotation:    _rotationFromSensor(sensorOrientation),
          format:      InputImageFormat.nv21,
          bytesPerRow: cameraImage.width,
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

  // ── Lenient detector for saved-file verification ─────────────────────────
  // Separate from the live detector: minFaceSize 0.15 → 0.08 so smaller
  // faces captured by Camera2 (wider field of view) are still found.
  FaceDetector? _fileDetector;
  FaceDetector _getFileDetector() {
    _fileDetector ??= FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks:      false,
        enableContours:       false,
        enableClassification: false,
        enableTracking:       false,
        performanceMode:      FaceDetectorMode.accurate,
        minFaceSize:          0.08,
      ),
    );
    return _fileDetector!;
  }

  // ── extractEmbeddingFromFile ──────────────────────────────────────────────
  //
  // WHY "No face detected" even when the face is clearly visible:
  //   Camera2 saves the JPEG in sensor-native orientation (usually 90° or 270°
  //   rotated for front cameras). The EXIF rotation tag is set, but
  //   ML Kit's InputImage.fromFilePath() on Android does NOT apply EXIF
  //   rotation — it processes raw pixels as-is → sideways face → no detection.
  //
  // FIX:
  //   1. Decode JPEG with the `image` package + bakeOrientation() → pixels are
  //      always visually upright, regardless of EXIF.
  //   2. Try face detection on the baked image.
  //   3. If still no face, retry with 90°/270°/180° rotations (covers phones
  //      where EXIF itself is missing or wrong).
  //   4. Only after all 4 orientations fail → truly no face → return null.

  Future<List<double>?> extractEmbeddingFromFile(String filePath) async {
    if (!_initialized) await initialize();
    if (_interpreter == null) return null;

    try {
      // ── Step 1: Decode JPEG and bake EXIF rotation ───────────────────────
      final fileBytes  = await File(filePath).readAsBytes();
      final rawDecoded = img.decodeImage(fileBytes);
      if (rawDecoded == null) {
        debugPrint('[MlFaceService] file decode failed: $filePath');
        return null;
      }
      // bakeOrientation rotates pixel data to match the EXIF tag,
      // then strips the tag → result is always right-side-up at rotation 0.
      final upright = img.bakeOrientation(rawDecoded);

      // ── Step 2: Try face detection at 4 orientations ─────────────────────
      // Order: 0° first (most common after bake), then 90°, 270°, 180°.
      const angles = [0, 90, 270, 180];
      final detector       = _getFileDetector();
      img.Image? bestImage;
      Face?      bestFace;

      for (final angle in angles) {
        final candidate = angle == 0
            ? upright
            : img.copyRotate(upright, angle: angle);

        // Write candidate to a temp file so ML Kit can read it via fromFilePath
        // (fromFilePath handles JPEG decoding correctly without byte-format issues)
        final tmpPath = '${filePath}_rot$angle.jpg';
        final tmpFile = File(tmpPath);
        await tmpFile.writeAsBytes(img.encodeJpg(candidate, quality: 90));

        List<Face> faces = [];
        try {
          faces = await detector.processImage(
              InputImage.fromFilePath(tmpPath));
        } catch (e) {
          debugPrint('[MlFaceService] detector error at ${angle}°: $e');
        } finally {
          try { tmpFile.deleteSync(); } catch (_) {}
        }

        if (faces.isNotEmpty) {
          bestFace  = faces.reduce(
                  (a, b) => a.boundingBox.width > b.boundingBox.width ? a : b);
          bestImage = candidate;
          debugPrint('[MlFaceService] ✓ face found at ${angle}° '
              '(${bestFace.boundingBox.width.toInt()}×'
              '${bestFace.boundingBox.height.toInt()})');
          break;
        }
        debugPrint('[MlFaceService] no face at ${angle}° — trying next…');
      }

      if (bestFace == null || bestImage == null) {
        debugPrint('[MlFaceService] NO FACE in any orientation: $filePath');
        return null;
      }

      // ── Step 3: Crop face + run FaceNet ──────────────────────────────────
      final cropped = _cropFace(bestImage, bestFace.boundingBox);
      if (cropped == null) {
        debugPrint('[MlFaceService] face crop failed');
        return null;
      }

      final resized = img.copyResize(
        cropped,
        width:         _inputSize,
        height:        _inputSize,
        interpolation: img.Interpolation.linear,
      );

      final input  = _buildFloat32Input(resized);
      final output = List.generate(1, (_) => List<double>.filled(_embedDim, 0.0));
      _interpreter!.run(input, output);

      return _l2Normalize(List<double>.from(output[0]));
    } catch (e) {
      debugPrint('[MlFaceService] extractEmbeddingFromFile error: $e');
      return null;
    }
  }

  // ── extractEmbeddingFromBytes (kept for backwards compat — NOT recommended) ─
  //
  // WARNING: This method has NO face detection or cropping.
  // It feeds the entire image to FaceNet, which produces a non-null embedding
  // even when the photo contains no face. Use extractEmbeddingFromFile() instead.

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

      final input  = _buildFloat32Input(resized);
      final output = List.generate(1, (_) => List<double>.filled(_embedDim, 0.0));
      _interpreter!.run(input, output);

      return _l2Normalize(List<double>.from(output[0]));
    } catch (e) {
      debugPrint('[MlFaceService] extractEmbeddingFromBytes error: $e');
      return null;
    }
  }

  // ── YUV420 → NV21 conversion ──────────────────────────────────────────────

  Uint8List _yuv420ToNv21(CameraImage cam) {
    final int w = cam.width;
    final int h = cam.height;

    final yPlane = cam.planes[0];
    final uPlane = cam.planes[1];
    final vPlane = cam.planes[2];

    final nv21  = Uint8List(w * h * 3 ~/ 2);
    int   index = 0;

    for (int row = 0; row < h; row++) {
      final rowStart = row * yPlane.bytesPerRow;
      for (int col = 0; col < w; col++) {
        nv21[index++] = yPlane.bytes[rowStart + col];
      }
    }

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

      final input  = _buildFloat32Input(resized);
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

  /// [1, 160, 160, 3] float32 tensor — standard FaceNet preprocessing.
  ///
  /// ROOT CAUSE OF "99% match for everyone" was this function using uint8:
  ///   OLD: return [p.r.toInt(), p.g.toInt(), p.b.toInt()]  ← values 0–255
  ///
  ///   FaceNet (ALL variants) requires float32 normalized to [-1.0, +1.0]:
  ///     value = (pixel - 127.5) / 128.0
  ///
  ///   Raw 0–255 integers cause the model's activations to saturate for EVERY
  ///   image → output embedding is nearly CONSTANT → cosine ≈ 0.98 for any
  ///   two faces → displays as 99% match for everyone.
  List<List<List<List<double>>>> _buildFloat32Input(img.Image image) {
    return List.generate(1, (_) =>
        List.generate(_inputSize, (y) =>
            List.generate(_inputSize, (x) {
              final p = image.getPixel(x, y);
              // (pixel - 127.5) / 128.0 maps [0,255] → [-0.996, +1.0]
              return [
                (p.r.toDouble() - 127.5) / 128.0,
                (p.g.toDouble() - 127.5) / 128.0,
                (p.b.toDouble() - 127.5) / 128.0,
              ];
            }),
        ),
    );
  }

  // ── Matching ──────────────────────────────────────────────────────────────

  static double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;
    double dot = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot.clamp(-1.0, 1.0);
  }

  /// Maps cosine [0, 1] → percentage [0, 100] (intuitive display).
  ///
  /// NEW formula: cosine * 100, clamped to [0, 100].
  ///   cosine 0.00 (stranger)  →   0%
  ///   cosine 0.26 (stranger)  →  26%
  ///   cosine 0.60 (threshold) →  60%
  ///   cosine 0.88 (owner)     →  88%
  ///
  /// OLD formula (cosine+1)/2*100 mapped cosine 0.0 to 50%, making
  /// strangers appear to "match" at 50–65% which was visually confusing.
  static double matchPercentage(List<double> stored, List<double> live) {
    final cosine = cosineSimilarity(stored, live);
    return (cosine * 100.0).clamp(0.0, 100.0);
  }

  /// Returns true when cosine similarity ≥ matchThreshold (0.50).
  /// Equivalent to matchPercentage ≥ 75 %.
  bool isMatch(List<double> stored, List<double> live) {
    final sim = cosineSimilarity(stored, live);
    debugPrint('[MlFaceService] cosine=${sim.toStringAsFixed(4)} '
        'threshold=$matchThreshold');
    return sim >= matchThreshold;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  List<double> _l2Normalize(List<double> v) {
    double norm = 0.0;
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
      await _fileDetector?.close();
      _fileDetector    = null;
      _interpreter?.close();
      _interpreter = null;
      _initialized = false;
    }
  }
}