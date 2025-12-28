import 'dart:convert';
import 'dart:math' as math;

/// Face Vector Model
/// Represents the 128-dimensional face embedding vector
class FaceVectorModel {
  final String id;
  final List<double> vector;
  final DateTime createdAt;
  final String? userId;

  FaceVectorModel({
    required this.id,
    required this.vector,
    required this.createdAt,
    this.userId,
  });

  /// Create from JSON
  factory FaceVectorModel.fromJson(Map<String, dynamic> json) {
    return FaceVectorModel(
      id: json['id'] as String,
      vector: (json['vector'] as List).map((e) => (e as num).toDouble()).toList(),
      createdAt: DateTime.parse(json['createdAt'] as String),
      userId: json['userId'] as String?,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'vector': vector,
      'createdAt': createdAt.toIso8601String(),
      'userId': userId,
    };
  }

  /// Serialize to string for storage
  String serialize() => jsonEncode(toJson());

  /// Deserialize from string
  static FaceVectorModel? deserialize(String? data) {
    if (data == null || data.isEmpty) return null;
    try {
      return FaceVectorModel.fromJson(jsonDecode(data));
    } catch (e) {
      return null;
    }
  }

  /// Generate a mock 128-dimensional face vector
  static FaceVectorModel generateMock({String? userId}) {
    final random = math.Random();
    final vector = List.generate(
      128,
          (_) => random.nextDouble() * 2 - 1, // Values between -1 and 1
    );

    // Normalize the vector
    final magnitude = math.sqrt(
      vector.fold<double>(0, (sum, val) => sum + val * val),
    );
    final normalizedVector = vector.map((v) => v / magnitude).toList();

    return FaceVectorModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      vector: normalizedVector,
      createdAt: DateTime.now(),
      userId: userId,
    );
  }

  /// Calculate cosine similarity between two face vectors
  static double cosineSimilarity(List<double> v1, List<double> v2) {
    if (v1.length != v2.length) return 0.0;

    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < v1.length; i++) {
      dotProduct += v1[i] * v2[i];
      normA += v1[i] * v1[i];
      normB += v2[i] * v2[i];
    }

    if (normA == 0 || normB == 0) return 0.0;

    return dotProduct / (math.sqrt(normA) * math.sqrt(normB));
  }

  /// Compare with another face vector and return match percentage
  double compareWith(FaceVectorModel other) {
    final similarity = cosineSimilarity(vector, other.vector);
    // Convert similarity (-1 to 1) to percentage (0 to 100)
    return ((similarity + 1) / 2) * 100;
  }

  @override
  String toString() => 'FaceVectorModel(id: $id, dimensions: ${vector.length})';
}

/// Face verification result
class FaceVerificationResult {
  final bool isMatch;
  final double matchPercentage;
  final String message;
  final FaceVerificationStatus status;

  FaceVerificationResult({
    required this.isMatch,
    required this.matchPercentage,
    required this.message,
    required this.status,
  });

  factory FaceVerificationResult.success(double percentage) {
    return FaceVerificationResult(
      isMatch: true,
      matchPercentage: percentage,
      message: 'Face verified successfully',
      status: FaceVerificationStatus.verified,
    );
  }

  factory FaceVerificationResult.failure(String reason, FaceVerificationStatus status) {
    return FaceVerificationResult(
      isMatch: false,
      matchPercentage: 0,
      message: reason,
      status: status,
    );
  }
}

enum FaceVerificationStatus {
  verified,
  mismatch,
  noFaceDetected,
  blurDetected,
  unknownError,
}
