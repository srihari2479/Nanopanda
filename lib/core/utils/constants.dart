/// Contains all constant values used throughout the app
library;

class AppConstants {
  AppConstants._();

  // === App Info ===
  static const String appName = 'Nanopanda';
  static const String appVersion = '1.0.0';
  static const String appTagline = 'Secure • Smart • Simple';

  // === Face Recognition Settings ===
  static const int faceVectorDimension = 128;
  static const double faceMatchThreshold = 0.80; // 80% match required
  static const double faceMatchHighConfidence = 0.95;

  // === API Endpoints (Mocked) ===
  static const String baseUrl = 'https://api.Nanopanda.mock';
  static const String registerFaceEndpoint = '/auth/face/register';
  static const String verifyFaceEndpoint = '/auth/face/verify';
  static const String detectEmotionEndpoint = '/emotion/detect';
  static const String uploadLogsEndpoint = '/logs/upload';

  // === Storage Keys ===
  static const String keyFaceVector = 'face_vector_data';
  static const String keyUserId = 'user_id';
  static const String keyIsRegistered = 'is_face_registered';
  static const String keyMonitoringEnabled = 'monitoring_enabled';
  static const String keySelectedApps = 'selected_apps';
  static const String keyLogs = 'monitoring_logs';
  static const String keySettings = 'app_settings';

  // === Timing Constants ===
  static const Duration apiSimulationDelay = Duration(seconds: 2);
  static const Duration animationDuration = Duration(milliseconds: 300);
  static const Duration splashDuration = Duration(seconds: 2);
  static const Duration snackBarDuration = Duration(seconds: 3);

  // === Monitoring Settings ===
  static const int maxAppsToMonitor = 5;
  static const Duration monitoringInterval = Duration(seconds: 30);

  // === Emotions ===
  static const List<String> emotions = [
    'happy',
    'sad',
    'angry',
    'fear',
    'disgust',
    'neutral',
  ];

  // === Emotion Icons ===
  static const Map<String, String> emotionEmojis = {
    'happy': '😊',
    'sad': '😢',
    'angry': '😠',
    'fear': '😰',
    'disgust': '🤢',
    'neutral': '😐',
  };

  // === Emotion Descriptions ===
  static const Map<String, String> emotionDescriptions = {
    'happy': 'Feeling joyful and content',
    'sad': 'Experiencing melancholy or sorrow',
    'angry': 'Displaying frustration or irritation',
    'fear': 'Sensing anxiety or unease',
    'disgust': 'Showing aversion or distaste',
    'neutral': 'Calm and composed expression',
  };
}

/// Validation utility class
class Validators {
  Validators._();

  /// Check if face match percentage is valid
  static bool isValidFaceMatch(double matchPercentage) {
    return matchPercentage >= AppConstants.faceMatchThreshold;
  }

  /// Check if face match has high confidence
  static bool isHighConfidenceMatch(double matchPercentage) {
    return matchPercentage >= AppConstants.faceMatchHighConfidence;
  }

  /// Validate face vector dimensions
  static bool isValidFaceVector(List<double>? vector) {
    return vector != null && vector.length == AppConstants.faceVectorDimension;
  }
}
