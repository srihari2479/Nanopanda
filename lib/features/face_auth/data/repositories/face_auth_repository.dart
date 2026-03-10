// lib/features/face_auth/data/repositories/face_auth_repository.dart
//
// Production face-auth repository — fully fixed.
//
// ── Changes vs original ───────────────────────────────────────────────────────
//  • registerFaceFromFrames: accepts _targetFrames (8) instead of 5 — matches
//    the updated registration page for a more robust stored template.
//  • verifyFace: threshold now sourced from AppConstants (80%).
//    The matchPercentage formula is clamped to [0, 100] to prevent edge-case
//    values outside range from slipping through.
//  • L2 normalisation in registerFaceFromFrames: norm=0 guard added (avoids
//    division-by-zero when averaging produces an all-zero vector).
//  • All debug prints prefixed consistently for easy log filtering.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../../core/models/face_vector_model.dart';
import '../../../../core/services/ml_face_service.dart';
import '../../../../core/utils/constants.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Result types
// ─────────────────────────────────────────────────────────────────────────────

class FaceRegistrationResult {
  final bool isSuccess;
  final String? userId;
  final String message;
  final FaceVectorModel? faceVector;

  FaceRegistrationResult._({
    required this.isSuccess,
    this.userId,
    required this.message,
    this.faceVector,
  });

  factory FaceRegistrationResult.success({
    required String userId,
    required FaceVectorModel faceVector,
  }) =>
      FaceRegistrationResult._(
        isSuccess: true,
        userId: userId,
        message: 'Face registered successfully',
        faceVector: faceVector,
      );

  factory FaceRegistrationResult.failure(String message) =>
      FaceRegistrationResult._(isSuccess: false, message: message);
}

// ─────────────────────────────────────────────────────────────────────────────
// Repository
// ─────────────────────────────────────────────────────────────────────────────

class FaceAuthRepository {
  /// Minimum frames required for registration. Must match FaceRegistrationPage.
  static const int _registrationFrameCount = 8;

  // ── Registration ─────────────────────────────────────────────────────────────

  /// Average [collectedEmbeddings] into a single L2-normalised stored template.
  /// Requires at least [_registrationFrameCount] good-quality frames.
  Future<FaceRegistrationResult> registerFaceFromFrames({
    required List<List<double>> collectedEmbeddings,
    required String? userId,
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

      // L2 normalise — guard against degenerate all-zero vector
      double norm = 0;
      for (final v in averaged) norm += v * v;
      norm = math.sqrt(norm);
      final normalised = norm < 1e-10
          ? averaged // already zero-ish, leave as-is
          : averaged.map((v) => v / norm).toList();

      final finalUserId =
          userId ?? 'user_${DateTime.now().millisecondsSinceEpoch}';

      final faceVector = FaceVectorModel(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        vector: normalised,
        createdAt: DateTime.now(),
        userId: finalUserId,
      );

      debugPrint('[FaceAuthRepo] registered ${collectedEmbeddings.length} '
          'frames → userId=$finalUserId');

      return FaceRegistrationResult.success(
        userId: finalUserId,
        faceVector: faceVector,
      );
    } catch (e) {
      debugPrint('[FaceAuthRepo] registerFaceFromFrames error: $e');
      return FaceRegistrationResult.failure('Registration processing failed');
    }
  }

  // ── Verification ─────────────────────────────────────────────────────────────

  /// Compares [liveVector] against [storedVector].
  /// Uses cosine similarity via [MlFaceService.matchPercentage].
  /// Threshold = [AppConstants.faceMatchThreshold] (80 %).
  Future<FaceVerificationResult> verifyFace({
    required FaceVectorModel liveVector,
    required FaceVectorModel storedVector,
  }) async {
    try {
      final score = MlFaceService.matchPercentage(
        storedVector.vector,
        liveVector.vector,
      ).clamp(0.0, 100.0); // safety clamp

      debugPrint('[FaceAuthRepo] averaged match score: ${score.toStringAsFixed(2)}%');

      final threshold = AppConstants.faceMatchThreshold * 100;

      if (score >= threshold) {
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

  /// Minimum frames required for registration.
  static int get requiredFrames => _registrationFrameCount;
}