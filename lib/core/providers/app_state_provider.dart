import 'package:flutter/foundation.dart';

import '../services/storage_service.dart';

/// App State Provider
/// Manages global app state including authentication and initialization
class AppStateProvider extends ChangeNotifier {
  final StorageService _storageService;

  bool _isInitialized = false;
  bool _isFaceRegistered = false;
  bool _isAuthenticated = false;
  bool _isMonitoringEnabled = false;
  bool _isLogsEnabled = true;
  String? _userId;

  AppStateProvider(this._storageService);

  // === Getters ===
  bool get isInitialized => _isInitialized;
  bool get isFaceRegistered => _isFaceRegistered;
  bool get isAuthenticated => _isAuthenticated;
  bool get isMonitoringEnabled => _isMonitoringEnabled;
  bool get isLogsEnabled => _isLogsEnabled;
  String? get userId => _userId;

  /// Initialize app state from storage
  Future<void> initialize() async {
    _isFaceRegistered = await _storageService.isFaceRegistered();
    _isMonitoringEnabled = await _storageService.isMonitoringEnabled();
    _userId = await _storageService.getUserId();
    _isLogsEnabled = _storageService.getSetting<bool>('logs_enabled') ?? true;
    _isInitialized = true;
    notifyListeners();
  }

  /// Set face registered state
  Future<void> setFaceRegistered(bool value) async {
    _isFaceRegistered = value;
    notifyListeners();
  }

  /// Set authenticated state
  void setAuthenticated(bool value) {
    _isAuthenticated = value;
    notifyListeners();
  }

  /// Set monitoring enabled state
  Future<void> setMonitoringEnabled(bool value) async {
    _isMonitoringEnabled = value;
    await _storageService.setMonitoringEnabled(value);
    notifyListeners();
  }

  /// Set logs enabled state
  Future<void> setLogsEnabled(bool value) async {
    _isLogsEnabled = value;
    await _storageService.saveSetting('logs_enabled', value);
    notifyListeners();
  }

  /// Set user ID
  Future<void> setUserId(String userId) async {
    _userId = userId;
    await _storageService.saveUserId(userId);
    notifyListeners();
  }

  /// Logout - clear authentication but keep face registration
  void logout() {
    _isAuthenticated = false;
    notifyListeners();
  }

  /// Reset all data
  Future<void> resetAllData() async {
    await _storageService.clearAllData();
    _isFaceRegistered = false;
    _isAuthenticated = false;
    _isMonitoringEnabled = false;
    _userId = null;
    notifyListeners();
  }
}
