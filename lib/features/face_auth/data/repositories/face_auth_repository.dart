// lib/features/face_auth/data/repositories/face_auth_repository.dart
//
// Production face-auth repository.
//
// Threshold change for FaceNet-512 int-quantized (128-d output):
//   MlFaceService.matchThreshold  = 0.50  (cosine similarity)
//   matchPercentage formula        = (cosine + 1) / 2 * 100
//   0.50 cosine → 75 % display
//   AppConstants.faceMatchThreshold must be 0.75  ← update constants.dart

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../../core/models/face_vector_model.dart';
import '../../../../core/services/ml_face_service.dart';
import '../../../../core/utils/constants.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FaceVerificationStatus
// ─────────────────────────────────────────────────────────────────────────────

enum FaceVerificationStatus {
  success,
  mismatch,
  noFaceDetected,
  unknownError,
}

// ─────────────────────────────────────────────────────────────────────────────
// FaceVerificationResult
// ─────────────────────────────────────────────────────────────────────────────

class FaceVerificationResult {
  final bool                   isMatch;
  final double                 matchPercentage;
  final FaceVerificationStatus status;
  final String                 message;

  const FaceVerificationResult._({
    required this.isMatch,
    required this.matchPercentage,
    required this.status,
    required this.message,
  });

  factory FaceVerificationResult.success(double score) =>
      FaceVerificationResult._(
        isMatch:         true,
        matchPercentage: score,
        status:          FaceVerificationStatus.success,
        message:         'Face verified (${score.toStringAsFixed(1)}%)',
      );

  factory FaceVerificationResult.failure(
      String message,
      FaceVerificationStatus status,
      ) =>
      FaceVerificationResult._(
        isMatch:         false,
        matchPercentage: 0.0,
        status:          status,
        message:         message,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// FaceRegistrationResult
// ─────────────────────────────────────────────────────────────────────────────

class FaceRegistrationResult {
  final bool            isSuccess;
  final String?         userId;
  final String          message;
  final FaceVectorModel? faceVector;

  FaceRegistrationResult._({
    required this.isSuccess,
    this.userId,
    required this.message,
    this.faceVector,
  });

  factory FaceRegistrationResult.success({
    required String         userId,
    required FaceVectorModel faceVector,
  }) =>
      FaceRegistrationResult._(
        isSuccess:  true,
        userId:     userId,
        message:    'Face registered successfully',
        faceVector: faceVector,
      );

  factory FaceRegistrationResult.failure(String message) =>
      FaceRegistrationResult._(isSuccess: false, message: message);
}

// ─────────────────────────────────────────────────────────────────────────────
// FaceAuthRepository
// ─────────────────────────────────────────────────────────────────────────────

class FaceAuthRepository {
  static const int _registrationFrameCount = 8;

  // ── Registration ────────────────────────────────────────────────────────────

  Future<FaceRegistrationResult> registerFaceFromFrames({
    required List<List<double>> collectedEmbeddings,
    required String?            userId,
  }) async {
    if (collectedEmbeddings.length < _registrationFrameCount) {
      return FaceRegistrationResult.failure(
        'Not enough frames captured '
            '(${collectedEmbeddings.length}/$_registrationFrameCount). '
            'Hold still and ensure good lighting.',
      );
    }

    try {
      final dim      = collectedEmbeddings.first.length;
      final averaged = List<double>.filled(dim, 0.0);

      for (final emb in collectedEmbeddings) {
        for (int i = 0; i < dim; i++) {
          averaged[i] += emb[i];
        }
      }
      for (int i = 0; i < dim; i++) {
        averaged[i] /= collectedEmbeddings.length;
      }

      // L2 normalise the averaged embedding
      double norm = 0.0;
      for (final v in averaged) norm += v * v;
      norm = math.sqrt(norm);
      final normalised = norm < 1e-10
          ? averaged
          : averaged.map((v) => v / norm).toList();

      final finalUserId =
          userId ?? 'user_${DateTime.now().millisecondsSinceEpoch}';

      final faceVector = FaceVectorModel(
        id:        DateTime.now().millisecondsSinceEpoch.toString(),
        vector:    normalised,
        createdAt: DateTime.now(),
        userId:    finalUserId,
      );

      debugPrint('[FaceAuthRepo] registered ${collectedEmbeddings.length} '
          'frames → userId=$finalUserId  dim=$dim');

      return FaceRegistrationResult.success(
        userId:     finalUserId,
        faceVector: faceVector,
      );
    } catch (e) {
      debugPrint('[FaceAuthRepo] registerFaceFromFrames error: $e');
      return FaceRegistrationResult.failure('Registration processing failed');
    }
  }

  // ── Verification ────────────────────────────────────────────────────────────

  Future<FaceVerificationResult> verifyFace({
    required FaceVectorModel liveVector,
    required FaceVectorModel storedVector,
  }) async {
    try {
      // Use raw cosine comparison against matchThreshold (0.60).
      // New matchPercentage = cosine*100: owner ~75-95%, strangers ~0-35%.
      final cosine = MlFaceService.cosineSimilarity(
        storedVector.vector,
        liveVector.vector,
      );
      final score = MlFaceService.matchPercentage(
        storedVector.vector,
        liveVector.vector,
      ).clamp(0.0, 100.0);

      debugPrint('[FaceAuthRepo] cosine=${cosine.toStringAsFixed(4)} '
          'score=${score.toStringAsFixed(2)}%  '
          'threshold=${MlFaceService.matchThreshold}');

      if (cosine >= MlFaceService.matchThreshold) {
        return FaceVerificationResult.success(score);
      } else {
        return FaceVerificationResult.failure(
          'Face does not match (${score.toStringAsFixed(1)}%)',
          FaceVerificationStatus.mismatch,
        );
      }
    } catch (e) {
      debugPrint('[FaceAuthRepo] verifyFace error: $e');
      return FaceVerificationResult.failure(
        'Verification error',
        FaceVerificationStatus.unknownError,
      );
    }
  }

  static int get requiredFrames => _registrationFrameCount;
}