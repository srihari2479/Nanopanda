import 'dart:math' as math;

import '../../../../core/models/emotion_model.dart';
import '../../../../core/utils/constants.dart';

/// Emotion Detection Repository
/// Handles emotion detection API calls (MOCKED)
class EmotionRepository {
  /// Detect emotion from image (MOCKED)
  /// Returns random emotion after simulated processing
  Future<EmotionResultModel> detectEmotion(List<int> imageBytes) async {
    // Simulate API call with processing delay
    await Future.delayed(const Duration(seconds: 3));

    final random = math.Random();

    // Select random emotion
    final emotions = AppConstants.emotions;
    final selectedEmotion = emotions[random.nextInt(emotions.length)];

    // Generate confidence score (70-99%)
    final confidence = 0.7 + (random.nextDouble() * 0.29);

    // Generate all emotion scores for detailed view
    final allEmotions = <String, double>{};
    double remainingScore = 1.0 - confidence;

    for (final emotion in emotions) {
      if (emotion == selectedEmotion) {
        allEmotions[emotion] = confidence;
      } else {
        final score = remainingScore / (emotions.length - 1) * (0.5 + random.nextDouble());
        allEmotions[emotion] = score.clamp(0.01, 0.3);
      }
    }

    // Normalize scores to sum to 1
    final total = allEmotions.values.fold(0.0, (sum, val) => sum + val);
    allEmotions.updateAll((key, value) => value / total);

    return EmotionResultModel(
      emotion: selectedEmotion,
      confidence: confidence,
      detectedAt: DateTime.now(),
      allEmotions: allEmotions,
    );
  }

  /// Detect emotion with specific result (for testing)
  Future<EmotionResultModel> detectEmotionWithResult(String emotion) async {
    await Future.delayed(const Duration(seconds: 2));

    final random = math.Random();
    final confidence = 0.85 + (random.nextDouble() * 0.14);

    return EmotionResultModel(
      emotion: emotion,
      confidence: confidence,
      detectedAt: DateTime.now(),
    );
  }
}
