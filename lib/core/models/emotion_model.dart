import 'dart:convert';

/// Emotion Result Model
/// Represents the result of emotion detection API
class EmotionResultModel {
  final String emotion;
  final double confidence;
  final DateTime detectedAt;
  final Map<String, double>? allEmotions;

  EmotionResultModel({
    required this.emotion,
    required this.confidence,
    required this.detectedAt,
    this.allEmotions,
  });

  /// Get emoji for the emotion
  String get emoji {
    switch (emotion.toLowerCase()) {
      case 'happy':
        return '🐼';
      case 'sad':
        return '😢';
      case 'angry':
        return '😠';
      case 'fear':
        return '😰';
      case 'disgust':
        return '🤢';
      case 'neutral':
      default:
        return '😐';
    }
  }

  /// Get description for the emotion
  String get description {
    switch (emotion.toLowerCase()) {
      case 'happy':
        return 'You seem to be in a great mood! Keep spreading those positive vibes.';
      case 'sad':
        return 'It\'s okay to feel down sometimes. Take a moment to breathe.';
      case 'angry':
        return 'Take a deep breath. Would you like some calming exercises?';
      case 'fear':
        return 'Remember, you\'re safe. Try some grounding techniques.';
      case 'disgust':
        return 'Something seems off. Take a moment to process your feelings.';
      case 'neutral':
      default:
        return 'You appear calm and composed. A balanced state of mind.';
    }
  }

  /// Get confidence percentage string
  String get confidencePercentage => '${(confidence * 100).toStringAsFixed(1)}%';

  /// Create from JSON
  factory EmotionResultModel.fromJson(Map<String, dynamic> json) {
    return EmotionResultModel(
      emotion: json['emotion'] as String,
      confidence: (json['confidence'] as num).toDouble(),
      detectedAt: json['detectedAt'] != null
          ? DateTime.parse(json['detectedAt'] as String)
          : DateTime.now(),
      allEmotions: json['allEmotions'] != null
          ? Map<String, double>.from(
        (json['allEmotions'] as Map).map(
              (k, v) => MapEntry(k as String, (v as num).toDouble()),
        ),
      )
          : null,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'emotion': emotion,
      'confidence': confidence,
      'detectedAt': detectedAt.toIso8601String(),
      'allEmotions': allEmotions,
    };
  }

  /// Serialize to string
  String serialize() => jsonEncode(toJson());

  /// Deserialize from string
  static EmotionResultModel? deserialize(String? data) {
    if (data == null || data.isEmpty) return null;
    try {
      return EmotionResultModel.fromJson(jsonDecode(data));
    } catch (e) {
      return null;
    }
  }

  @override
  String toString() => 'EmotionResult(emotion: $emotion, confidence: $confidencePercentage)';
}

/// Emotion type enum for type safety
enum EmotionType {
  happy,
  sad,
  angry,
  fear,
  disgust,
  neutral;

  String get displayName {
    switch (this) {
      case EmotionType.happy:
        return 'Happy';
      case EmotionType.sad:
        return 'Sad';
      case EmotionType.angry:
        return 'Angry';
      case EmotionType.fear:
        return 'Fear';
      case EmotionType.disgust:
        return 'Disgust';
      case EmotionType.neutral:
        return 'Neutral';
    }
  }

  static EmotionType fromString(String value) {
    return EmotionType.values.firstWhere(
          (e) => e.name.toLowerCase() == value.toLowerCase(),
      orElse: () => EmotionType.neutral,
    );
  }
}
