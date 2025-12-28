import '../../../../core/models/app_info_model.dart';

/// App Monitor Repository
/// Handles fetching installed apps and monitoring logic
class AppMonitorRepository {
  /// Get list of installed apps (MOCKED)
  /// In production, use device_apps package
  Future<List<AppInfoModel>> getInstalledApps() async {
    // Simulate loading delay
    await Future.delayed(const Duration(milliseconds: 800));

    // Return mock apps
    return MockApps.getMockApps();
  }

  /// Start monitoring selected apps (MOCKED)
  Future<bool> startMonitoring(List<AppInfoModel> selectedApps) async {
    // Simulate setup delay
    await Future.delayed(const Duration(milliseconds: 500));

    // In production, this would:
    // 1. Register with WorkManager for background tasks
    // 2. Set up accessibility service listeners
    // 3. Initialize camera for silent capture

    return true;
  }

  /// Stop monitoring (MOCKED)
  Future<bool> stopMonitoring() async {
    await Future.delayed(const Duration(milliseconds: 300));

    // In production, this would:
    // 1. Cancel WorkManager tasks
    // 2. Stop accessibility listeners
    // 3. Save any pending logs

    return true;
  }

  /// Check if an app is currently in foreground (MOCKED)
  Future<bool> isAppInForeground(String packageName) async {
    // Mock implementation
    return false;
  }
}
