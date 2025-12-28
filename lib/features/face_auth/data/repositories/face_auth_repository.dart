import 'dart:math' as math;

import '../../../../core/models/face_vector_model.dart';
import '../../../../core/utils/constants.dart';

/// Face Authentication Repository
/// Handles all face authentication operations with mocked backend
class FaceAuthRepository {
  /// Register face with backend (MOCKED)
  /// Returns success after simulated delay
  Future<FaceRegistrationResult> registerFace(List<double> vector) async {
    // Simulate API call delay
    await Future.delayed(AppConstants.apiSimulationDelay);

    // Generate mock user ID
    final userId = 'user_${DateTime.now().millisecondsSinceEpoch}';

    // Simulate 95% success rate
    final random = math.Random();
    if (random.nextDouble() > 0.05) {
      return FaceRegistrationResult.success(
        userId: userId,
        message: 'Face registered successfully',
      );
    } else {
      return FaceRegistrationResult.failure(
        message: 'Registration failed. Please try again.',
      );
    }
  }

  /// Verify face against stored vector (LOCAL)
  /// Compares live face vector with stored vector
  Future<FaceVerificationResult> verifyFace({
    required FaceVectorModel liveVector,
    required FaceVectorModel storedVector,
  }) async {
    // Simulate processing delay
    await Future.delayed(const Duration(milliseconds: 500));

    // In production, this would use the actual calculated match:
    // final actualMatch = liveVector.compareWith(storedVector);

    // For demo: generate realistic match percentage (80-98%)
    final random = math.Random();
    final simulatedMatch = 80 + random.nextDouble() * 18;

    if (simulatedMatch >= AppConstants.faceMatchThreshold * 100) {
      return FaceVerificationResult.success(simulatedMatch);
    } else {
      return FaceVerificationResult.failure(
        'Face mismatch detected',
        FaceVerificationStatus.mismatch,
      );
    }
  }

  /// Upload face vector to backend (MOCKED)
  Future<bool> uploadToBackend({
    required String userId,
    required List<double> vector,
  }) async {
    // Simulate API call
    await Future.delayed(AppConstants.apiSimulationDelay);

    // Simulate 90% success rate
    final random = math.Random();
    return random.nextDouble() > 0.1;
  }

  /// Generate mock face vector from image
  /// In production, this would use ML model for face embedding
  Future<FaceVectorModel?> generateFaceVector({
    required List<int> imageBytes,
    String? userId,
  }) async {
    // Simulate processing delay
    await Future.delayed(const Duration(seconds: 1));

    // Generate mock vector
    return FaceVectorModel.generateMock(userId: userId);
  }

  /// Check if face is detected in image (MOCKED)
  Future<FaceDetectionResult> detectFace(List<int> imageBytes) async {
    // Simulate processing
    await Future.delayed(const Duration(milliseconds: 300));

    // Simulate detection results
    final random = math.Random();
    final detectionScore = random.nextDouble();

    if (detectionScore > 0.2) {
      // Face detected
      return FaceDetectionResult(
        faceDetected: true,
        isBlurry: detectionScore < 0.4,
        confidence: detectionScore,
        boundingBox: FaceBoundingBox(
          left: 100 + random.nextInt(50).toDouble(),
          top: 150 + random.nextInt(50).toDouble(),
          width: 200 + random.nextInt(50).toDouble(),
          height: 250 + random.nextInt(50).toDouble(),
        ),
      );
    } else {
      // No face detected
      return FaceDetectionResult(
        faceDetected: false,
        isBlurry: false,
        confidence: 0,
      );
    }
  }
}

/// Face registration result
class FaceRegistrationResult {
  final bool isSuccess;
  final String? userId;
  final String message;

  FaceRegistrationResult({
    required this.isSuccess,
    this.userId,
    required this.message,
  });

  factory FaceRegistrationResult.success({
    required String userId,
    required String message,
  }) {
    return FaceRegistrationResult(
      isSuccess: true,
      userId: userId,
      message: message,
    );
  }

  factory FaceRegistrationResult.failure({required String message}) {
    return FaceRegistrationResult(
      isSuccess: false,
      message: message,
    );
  }
}

/// Face detection result
class FaceDetectionResult {
  final bool faceDetected;
  final bool isBlurry;
  final double confidence;
  final FaceBoundingBox? boundingBox;

  FaceDetectionResult({
    required this.faceDetected,
    required this.isBlurry,
    required this.confidence,
    this.boundingBox,
  });
}

/// Face bounding box coordinates
class FaceBoundingBox {
  final double left;
  final double top;
  final double width;
  final double height;

  FaceBoundingBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
}