import 'package:flutter/foundation.dart';

import '../services/storage_service.dart';
import '../utils/constants.dart';

/// App State Provider
/// Manages global app state including authentication and initialization
class AppStateProvider extends ChangeNotifier {
  final StorageService _storageService;

  bool _isInitialized      = false;
  bool _isFaceRegistered   = false;
  bool _isAuthenticated    = false; // IN-MEMORY ONLY — never persisted.
  //   Cold start always forces face login.
  bool _isMonitoringEnabled = false;
  bool _isLogsEnabled       = true;
  String? _userId;

  AppStateProvider(this._storageService);

  // === Getters ===
  bool    get isInitialized      => _isInitialized;
  bool    get isFaceRegistered   => _isFaceRegistered;
  bool    get isAuthenticated    => _isAuthenticated;
  bool    get isMonitoringEnabled => _isMonitoringEnabled;
  bool    get isLogsEnabled      => _isLogsEnabled;
  String? get userId             => _userId;

  /// Initialize app state from storage.
  ///
  /// ── BUG FIX: Stale SharedPreferences surviving reinstall ──────────────────
  /// On Android, SharedPreferences data can SURVIVE an uninstall/reinstall on
  /// some devices — especially installs done via ADB, Play Internal Testing,
  /// or any install that doesn't explicitly wipe user data first.
  ///
  /// This was causing a fresh install on a friend's phone to jump straight to
  /// the Login screen instead of Registration, because `keyIsRegistered=true`
  /// was left over in SharedPreferences from a previous install.
  ///
  /// FIX — Cross-validate against FlutterSecureStorage (Android Keystore):
  /// The Keystore IS reliably cleared on uninstall. So if SharedPreferences
  /// says "registered" but there is no face vector in secure storage, we know
  /// it is stale data from a previous install. We reset everything so the new
  /// user is correctly routed to Registration first.
  Future<void> initialize() async {
    final registeredFlag = await _storageService.isFaceRegistered();

    if (registeredFlag) {
      // Cross-check: actual face vector must exist in Keystore-backed storage.
      // If it doesn't, SharedPreferences has stale data from a previous install.
      final faceVector = await _storageService.getFaceVector();

      if (faceVector == null) {
        // ── Stale install detected — reset to clean state ──
        debugPrint(
          '[AppState] initialize: keyIsRegistered=true but no face vector '
              'found in secure storage. Stale SharedPreferences from previous '
              'install detected. Resetting to fresh-install state.',
        );
        await _storageService.clearAllData();
        _isFaceRegistered    = false;
        _isMonitoringEnabled = false;
        _userId              = null;
      } else {
        // ── Genuine returning user ──
        _isFaceRegistered    = true;
        _isMonitoringEnabled = await _storageService.isMonitoringEnabled();
        _userId              = await _storageService.getUserId();
      }
    } else {
      // ── Fresh install or data was explicitly cleared ──
      _isFaceRegistered    = false;
      _isMonitoringEnabled = await _storageService.isMonitoringEnabled();
      _userId              = await _storageService.getUserId();
    }

    _isLogsEnabled   = _storageService.getSetting<bool>('logs_enabled') ?? true;
    _isAuthenticated = false; // always require login on cold start
    _isInitialized   = true;
    notifyListeners();
  }

  /// Set face registered state AND persist to storage.
  Future<void> setFaceRegistered(bool value) async {
    _isFaceRegistered = value;
    await _storageService.saveSetting(AppConstants.keyIsRegistered, value);
    notifyListeners();
  }

  /// Set authenticated — in-memory ONLY.
  /// Survives recent-apps resume (process alive) but always false on cold start.
  Future<void> setAuthenticated(bool value) async {
    _isAuthenticated = value;
    // Do NOT persist to SharedPreferences — cold start must always show login.
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

  /// Logout — clears in-memory auth flag only.
  Future<void> logout() async {
    _isAuthenticated = false;
    notifyListeners();
  }

  /// Reset all data (e.g. from Settings → Reset)
  Future<void> resetAllData() async {
    await _storageService.clearAllData();
    _isFaceRegistered    = false;
    _isAuthenticated     = false;
    _isMonitoringEnabled = false;
    _userId              = null;
    notifyListeners();
  }
}