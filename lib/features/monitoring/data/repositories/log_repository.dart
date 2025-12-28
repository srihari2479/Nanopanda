import 'dart:math' as math;

import '../../../../core/models/log_entry_model.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../core/utils/constants.dart';

/// Log Repository
/// Handles monitoring logs storage and API uploads
class LogRepository {
  final StorageService _storageService;

  LogRepository(this._storageService);

  /// Get all stored logs
  Future<List<LogEntryModel>> getLogs() async {
    return await _storageService.getLogs();
  }

  /// Add a new log entry
  Future<void> addLog(LogEntryModel log) async {
    await _storageService.addLog(log);
  }

  /// Save multiple logs
  Future<void> saveLogs(List<LogEntryModel> logs) async {
    await _storageService.saveLogs(logs);
  }

  /// Clear all logs
  Future<void> clearLogs() async {
    await _storageService.clearLogs();
  }

  /// Send logs to backend (MOCKED)
  Future<bool> sendLogsToBackend(LogUploadPayload payload) async {
    // Simulate API call
    await Future.delayed(AppConstants.apiSimulationDelay);

    // Simulate 90% success rate
    final random = math.Random();
    return random.nextDouble() > 0.1;
  }

  /// Generate mock logs for demo
  Future<List<LogEntryModel>> generateMockLogs() async {
    final random = math.Random();
    final apps = ['Instagram', 'Facebook', 'WhatsApp', 'TikTok', 'YouTube'];
    final packages = [
      'com.instagram.android',
      'com.facebook.katana',
      'com.whatsapp',
      'com.zhiliaoapp.musically',
      'com.google.android.youtube',
    ];
    final reasons = [
      'Face mismatch detected',
      'No face detected',
      'Blur detected',
      'Unknown person',
    ];

    final logs = <LogEntryModel>[];
    final now = DateTime.now();

    for (int i = 0; i < 10; i++) {
      final appIndex = random.nextInt(apps.length);
      final entryTime = now.subtract(Duration(
        hours: random.nextInt(24),
        minutes: random.nextInt(60),
      ));
      final duration = Duration(minutes: random.nextInt(30) + 5);

      logs.add(LogEntryModel(
        id: 'log_${DateTime.now().millisecondsSinceEpoch}_$i',
        appName: apps[appIndex],
        appPackageName: packages[appIndex],
        entryTime: entryTime,
        exitTime: entryTime.add(duration),
        detectionReason: reasons[random.nextInt(reasons.length)],
        isUnwantedPerson: true,
      ));
    }

    // Sort by entry time (newest first)
    logs.sort((a, b) => b.entryTime.compareTo(a.entryTime));

    // Save to storage
    await saveLogs(logs);

    return logs;
  }
}
