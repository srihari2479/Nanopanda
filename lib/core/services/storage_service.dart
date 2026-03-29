// lib/core/services/storage_service.dart
//
// Added face image persistence:
//   saveFaceImage(Uint8List jpeg) → absolute file path
//   deleteFaceImage(String path)
//   Face images are stored in getApplicationDocumentsDirectory()/face_logs/

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/constants.dart';
import '../models/face_vector_model.dart';
import '../models/log_entry_model.dart';
import '../models/app_info_model.dart';

/// Storage Service
/// Handles all local data persistence using secure storage and shared preferences
class StorageService {
  late FlutterSecureStorage _secureStorage;
  late SharedPreferences    _prefs;
  bool _isInitialized = false;

  /// Initialize storage services
  Future<void> init() async {
    if (_isInitialized) return;

    _secureStorage = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    _prefs = await SharedPreferences.getInstance();
    _isInitialized = true;
  }

  void _ensureInitialized() {
    if (!_isInitialized) {
      throw StateError('StorageService not initialized. Call init() first.');
    }
  }

  // ==================== FACE VECTOR STORAGE ====================

  Future<void> saveFaceVector(FaceVectorModel faceVector) async {
    _ensureInitialized();
    await _secureStorage.write(
      key:   AppConstants.keyFaceVector,
      value: faceVector.serialize(),
    );
    await _prefs.setBool(AppConstants.keyIsRegistered, true);
  }

  Future<FaceVectorModel?> getFaceVector() async {
    _ensureInitialized();
    final data = await _secureStorage.read(key: AppConstants.keyFaceVector);
    return FaceVectorModel.deserialize(data);
  }

  Future<void> deleteFaceVector() async {
    _ensureInitialized();
    await _secureStorage.delete(key: AppConstants.keyFaceVector);
    await _prefs.setBool(AppConstants.keyIsRegistered, false);
    await _prefs.remove(_kEmbeddingVersion); // clear stale version tag
  }

  Future<bool> isFaceRegistered() async {
    _ensureInitialized();
    return _prefs.getBool(AppConstants.keyIsRegistered) ?? false;
  }

  // ==================== USER ID STORAGE ====================

  Future<void> saveUserId(String userId) async {
    _ensureInitialized();
    await _secureStorage.write(key: AppConstants.keyUserId, value: userId);
  }

  Future<String?> getUserId() async {
    _ensureInitialized();
    return await _secureStorage.read(key: AppConstants.keyUserId);
  }

  // ==================== EMBEDDING VERSION ====================
  //
  // Tracks which preprocessing was used when the face vector was saved.
  // If version != MlFaceService.embeddingVersion, the stored vector is stale
  // (registered with old uint8 preprocessing) and must be discarded.
  //
  // Version history:
  //   (none / missing) → uint8 raw [0-255] input  ← WRONG, produces 99% for all
  //   'float32_v1'     → normalized [-1,1] input   ← CORRECT

  static const _kEmbeddingVersion = 'nanopanda_embedding_version';
  static const currentEmbeddingVersion = 'float32_v1';

  Future<void> saveEmbeddingVersion(String version) async {
    _ensureInitialized();
    await _prefs.setString(_kEmbeddingVersion, version);
  }

  String? getEmbeddingVersion() {
    _ensureInitialized();
    return _prefs.getString(_kEmbeddingVersion);
  }

  Future<void> clearEmbeddingVersion() async {
    _ensureInitialized();
    await _prefs.remove(_kEmbeddingVersion);
  }

  /// Returns true if the stored face vector was registered with the current
  /// (correct float32) preprocessing. Returns false if stale or missing.
  bool isEmbeddingVersionCurrent() {
    final v = getEmbeddingVersion();
    return v == currentEmbeddingVersion;
  }



  /// Saves a JPEG of an intruder's face to documents/face_logs/.
  /// Returns the absolute file path to store in LogEntryModel.faceImagePath.
  Future<String?> saveFaceImage(Uint8List jpeg) async {
    try {
      final dir = await _faceLogsDir();
      final filename = 'face_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final file = File(p.join(dir.path, filename));
      await file.writeAsBytes(jpeg, flush: true);
      debugPrint('[StorageService] face image saved: ${file.path}');
      return file.path;
    } catch (e) {
      debugPrint('[StorageService] saveFaceImage error: $e');
      return null;
    }
  }

  /// Deletes a previously saved face image. Safe to call with null.
  Future<void> deleteFaceImage(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[StorageService] deleteFaceImage error: $e');
    }
  }

  Future<Directory> _faceLogsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir  = Directory(p.join(base.path, 'face_logs'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ==================== MONITORING LOGS STORAGE ====================

  Future<void> saveLogs(List<LogEntryModel> logs) async {
    _ensureInitialized();
    await _prefs.setString(
      AppConstants.keyLogs,
      LogEntryModel.serializeList(logs),
    );
  }

  Future<List<LogEntryModel>> getLogs() async {
    _ensureInitialized();
    final data = _prefs.getString(AppConstants.keyLogs);
    return LogEntryModel.deserializeList(data);
  }

  Future<void> addLog(LogEntryModel log) async {
    final logs = await getLogs();
    logs.add(log);
    await saveLogs(logs);
  }

  Future<void> clearLogs() async {
    _ensureInitialized();
    await _prefs.remove(AppConstants.keyLogs);
  }

  // ==================== SELECTED APPS STORAGE ====================

  Future<void> saveSelectedApps(List<AppInfoModel> apps) async {
    _ensureInitialized();
    await _prefs.setString(
      AppConstants.keySelectedApps,
      AppInfoModel.serializeList(apps),
    );
  }

  Future<List<AppInfoModel>> getSelectedApps() async {
    _ensureInitialized();
    final data = _prefs.getString(AppConstants.keySelectedApps);
    return AppInfoModel.deserializeList(data);
  }

  // ==================== SETTINGS STORAGE ====================

  Future<void> setMonitoringEnabled(bool enabled) async {
    _ensureInitialized();
    await _prefs.setBool(AppConstants.keyMonitoringEnabled, enabled);
  }

  Future<bool> isMonitoringEnabled() async {
    _ensureInitialized();
    return _prefs.getBool(AppConstants.keyMonitoringEnabled) ?? false;
  }

  Future<void> saveSetting(String key, dynamic value) async {
    _ensureInitialized();
    if (value is bool)   await _prefs.setBool(key,   value);
    else if (value is int)    await _prefs.setInt(key,    value);
    else if (value is double) await _prefs.setDouble(key, value);
    else if (value is String) await _prefs.setString(key, value);
  }

  T? getSetting<T>(String key) {
    _ensureInitialized();
    return _prefs.get(key) as T?;
  }

  // ==================== INSTALLED APPS CACHE ====================

  static const _kAppsCache   = 'installed_apps_cache';
  static const _kAppsCacheTs = 'installed_apps_cache_ts';

  Future<void> saveInstalledAppsCache(List<AppInfoModel> apps) async {
    _ensureInitialized();
    await _prefs.setString(_kAppsCache, AppInfoModel.serializeList(apps));
    await _prefs.setInt(_kAppsCacheTs, DateTime.now().millisecondsSinceEpoch);
  }

  Future<List<AppInfoModel>> getInstalledAppsCache() async {
    _ensureInitialized();
    final data = _prefs.getString(_kAppsCache);
    return AppInfoModel.deserializeList(data);
  }

  Duration? getInstalledAppsCacheAge() {
    _ensureInitialized();
    final ts = _prefs.getInt(_kAppsCacheTs);
    if (ts == null) return null;
    return DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts));
  }

  Future<void> clearInstalledAppsCache() async {
    _ensureInitialized();
    await _prefs.remove(_kAppsCache);
    await _prefs.remove(_kAppsCacheTs);
  }

  // ==================== CLEAR ALL ====================

  Future<void> clearAllData() async {
    _ensureInitialized();
    await _secureStorage.deleteAll();
    await _prefs.clear();
  }
}