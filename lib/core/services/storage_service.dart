import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/constants.dart';
import '../models/face_vector_model.dart';
import '../models/log_entry_model.dart';
import '../models/app_info_model.dart';

/// Storage Service
/// Handles all local data persistence using secure storage and shared preferences
class StorageService {
  late FlutterSecureStorage _secureStorage;
  late SharedPreferences _prefs;
  bool _isInitialized = false;

  /// Initialize storage services
  Future<void> init() async {
    if (_isInitialized) return;

    _secureStorage = const FlutterSecureStorage(
      aOptions: AndroidOptions(
        encryptedSharedPreferences: true,
      ),
    );
    _prefs = await SharedPreferences.getInstance();
    _isInitialized = true;
  }

  /// Ensure initialized
  void _ensureInitialized() {
    if (!_isInitialized) {
      throw StateError('StorageService not initialized. Call init() first.');
    }
  }

  // ==================== FACE VECTOR STORAGE ====================

  /// Save face vector securely
  Future<void> saveFaceVector(FaceVectorModel faceVector) async {
    _ensureInitialized();
    await _secureStorage.write(
      key: AppConstants.keyFaceVector,
      value: faceVector.serialize(),
    );
    await _prefs.setBool(AppConstants.keyIsRegistered, true);
  }

  /// Get stored face vector
  Future<FaceVectorModel?> getFaceVector() async {
    _ensureInitialized();
    final data = await _secureStorage.read(key: AppConstants.keyFaceVector);
    return FaceVectorModel.deserialize(data);
  }

  /// Delete face vector
  Future<void> deleteFaceVector() async {
    _ensureInitialized();
    await _secureStorage.delete(key: AppConstants.keyFaceVector);
    await _prefs.setBool(AppConstants.keyIsRegistered, false);
  }

  /// Check if face is registered
  Future<bool> isFaceRegistered() async {
    _ensureInitialized();
    return _prefs.getBool(AppConstants.keyIsRegistered) ?? false;
  }

  // ==================== USER ID STORAGE ====================

  /// Save user ID
  Future<void> saveUserId(String userId) async {
    _ensureInitialized();
    await _secureStorage.write(key: AppConstants.keyUserId, value: userId);
  }

  /// Get user ID
  Future<String?> getUserId() async {
    _ensureInitialized();
    return await _secureStorage.read(key: AppConstants.keyUserId);
  }

  // ==================== MONITORING LOGS STORAGE ====================

  /// Save monitoring logs
  Future<void> saveLogs(List<LogEntryModel> logs) async {
    _ensureInitialized();
    await _prefs.setString(
      AppConstants.keyLogs,
      LogEntryModel.serializeList(logs),
    );
  }

  /// Get monitoring logs
  Future<List<LogEntryModel>> getLogs() async {
    _ensureInitialized();
    final data = _prefs.getString(AppConstants.keyLogs);
    return LogEntryModel.deserializeList(data);
  }

  /// Add single log entry
  Future<void> addLog(LogEntryModel log) async {
    final logs = await getLogs();
    logs.add(log);
    await saveLogs(logs);
  }

  /// Clear all logs
  Future<void> clearLogs() async {
    _ensureInitialized();
    await _prefs.remove(AppConstants.keyLogs);
  }

  // ==================== SELECTED APPS STORAGE ====================

  /// Save selected apps for monitoring
  Future<void> saveSelectedApps(List<AppInfoModel> apps) async {
    _ensureInitialized();
    await _prefs.setString(
      AppConstants.keySelectedApps,
      AppInfoModel.serializeList(apps),
    );
  }

  /// Get selected apps
  Future<List<AppInfoModel>> getSelectedApps() async {
    _ensureInitialized();
    final data = _prefs.getString(AppConstants.keySelectedApps);
    return AppInfoModel.deserializeList(data);
  }

  // ==================== SETTINGS STORAGE ====================

  /// Save monitoring enabled state
  Future<void> setMonitoringEnabled(bool enabled) async {
    _ensureInitialized();
    await _prefs.setBool(AppConstants.keyMonitoringEnabled, enabled);
  }

  /// Get monitoring enabled state
  Future<bool> isMonitoringEnabled() async {
    _ensureInitialized();
    return _prefs.getBool(AppConstants.keyMonitoringEnabled) ?? false;
  }

  /// Save generic setting
  Future<void> saveSetting(String key, dynamic value) async {
    _ensureInitialized();
    if (value is bool) {
      await _prefs.setBool(key, value);
    } else if (value is int) {
      await _prefs.setInt(key, value);
    } else if (value is double) {
      await _prefs.setDouble(key, value);
    } else if (value is String) {
      await _prefs.setString(key, value);
    }
  }

  /// Get generic setting
  T? getSetting<T>(String key) {
    _ensureInitialized();
    return _prefs.get(key) as T?;
  }

  // ==================== CLEAR ALL DATA ====================

  /// Clear all stored data (for logout/reset)
  Future<void> clearAllData() async {
    _ensureInitialized();
    await _secureStorage.deleteAll();
    await _prefs.clear();
  }
}
