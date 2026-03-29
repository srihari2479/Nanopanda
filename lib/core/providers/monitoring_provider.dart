// lib/core/providers/monitoring_provider.dart
//
// CORRECT FLOW:
//
//   BACKGROUND (user opened protected app, Nanopanda is background):
//     BackgroundMonitorService.kt detects app → Camera2 API captures face →
//     saves JPEG to face_logs/ → saves pending log to SharedPrefs.
//     NO MainActivity launch. NO overlay. NO Flutter camera.
//
//   WHEN OWNER OPENS NANOPANDA:
//     _bootstrap() → _loadAndVerifyPendingLogs() → reads pending logs from
//     SharedPrefs → runs TFLite ML comparison → if unauthorized, saves to
//     logs storage → Logs page shows intruder photo + details.
//
//   MONITORING SERVICE:
//     Polls foreground app every 1.5s for appOpened/appClosed events only.
//     Used to track active sessions for UI dashboard display.
//     DOES NOT push any overlay or navigate anywhere.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../models/app_info_model.dart';
import '../models/log_entry_model.dart';
import '../services/ml_face_service.dart';
import '../services/monitoring_service.dart';
import '../services/storage_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Supporting types
// ─────────────────────────────────────────────────────────────────────────────

enum MonitoringStatus { idle, starting, active, stopping, error }

class MonitoringStats {
  final int              totalAlerts;
  final int              todayAlerts;
  final String           mostTargetedApp;
  final Map<String, int> alertsByApp;
  final Map<String, int> durationByApp;
  final Duration         totalUnauthorizedTime;

  const MonitoringStats({
    required this.totalAlerts,
    required this.todayAlerts,
    required this.mostTargetedApp,
    required this.alertsByApp,
    required this.durationByApp,
    required this.totalUnauthorizedTime,
  });

  factory MonitoringStats.empty() => const MonitoringStats(
    totalAlerts: 0, todayAlerts: 0, mostTargetedApp: '—',
    alertsByApp: {}, durationByApp: {}, totalUnauthorizedTime: Duration.zero,
  );
}

class ActiveSession {
  final String   packageName;
  final String   appName;
  final DateTime startedAt;
  const ActiveSession({
    required this.packageName,
    required this.appName,
    required this.startedAt,
  });
  Duration get elapsed => DateTime.now().difference(startedAt);
}

// ─────────────────────────────────────────────────────────────────────────────
// MonitoringProvider
// ─────────────────────────────────────────────────────────────────────────────

class MonitoringProvider extends ChangeNotifier with WidgetsBindingObserver {
  final StorageService _storage;

  MonitoringProvider(this._storage) {
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  bool _isAppForeground = true;

  MonitoringStatus    _status        = MonitoringStatus.idle;
  List<AppInfoModel>  _selectedApps  = [];
  List<LogEntryModel> _logs          = [];
  ActiveSession?      _activeSession;
  MonitoringStats     _stats         = MonitoringStats.empty();
  bool                _hasPermission = false;
  String?             _errorMessage;

  StreamSubscription<MonitoringEvent>? _eventSub;
  StreamSubscription<dynamic>?         _screenSub;
  Timer?                               _sessionTimer;

  static const _screenChannel    = EventChannel('nanopanda/screen_events');
  static const _bgMonitorChannel = MethodChannel('nanopanda/bg_monitor');

  // ── Getters ───────────────────────────────────────────────────────────────

  MonitoringStatus    get status        => _status;
  bool get isMonitoring                 => _status == MonitoringStatus.active;
  bool get isLoading                    => _status == MonitoringStatus.starting ||
      _status == MonitoringStatus.stopping;
  List<AppInfoModel>  get selectedApps  => List.unmodifiable(_selectedApps);
  List<LogEntryModel> get logs          => List.unmodifiable(_logs);
  ActiveSession?      get activeSession => _activeSession;
  MonitoringStats     get stats         => _stats;
  bool                get hasPermission => _hasPermission;
  String?             get errorMessage  => _errorMessage;
  int get selectedCount => _selectedApps.where((a) => a.isSelected).length;

  // ── Bootstrap ─────────────────────────────────────────────────────────────

  Future<void> _bootstrap() async {
    await MonitoringService.instance.initialize(storage: _storage);
    _hasPermission = await MonitoringService.instance.checkUsageStatsPermission();
    _selectedApps  = await _storage.getSelectedApps();
    _logs          = await _storage.getLogs();
    _logs.sort((a, b) => b.entryTime.compareTo(a.entryTime));
    _computeStats();
    _pushAppNameMap();
    notifyListeners();

    // When owner opens app — process any pending logs from background captures
    await _loadAndVerifyPendingLogs();

    final wasEnabled = await _storage.isMonitoringEnabled();
    final hasApps    = _selectedApps.any((a) => a.isSelected);
    if (wasEnabled && hasApps && _hasPermission) {
      debugPrint('[MonitoringProvider] cold-start: restarting monitoring');
      await Future.delayed(const Duration(milliseconds: 400));
      await startMonitoring();
    } else if (wasEnabled && (!hasApps || !_hasPermission)) {
      await _storage.setMonitoringEnabled(false);
      notifyListeners();
    }
  }

  Future<void> resumeIfNeeded() async {}

  void _pushAppNameMap() {
    MonitoringService.instance.updateAppNameMap({
      for (final a in _selectedApps) a.packageName: a.name,
    });
  }

  // ── App lifecycle ─────────────────────────────────────────────────────────
  // When owner returns to app — check for new pending logs from bg captures

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _isAppForeground;
    _isAppForeground = state == AppLifecycleState.resumed;

    if (!wasForeground && _isAppForeground && isMonitoring) {
      debugPrint('[MonitoringProvider] came to foreground — checking pending logs');
      _loadAndVerifyPendingLogs();
    }
  }

  // ── Load + ML-verify pending bg logs ──────────────────────────────────────
  // Called on app open and on foreground resume.
  // Reads capture results from SharedPrefs, runs TFLite ML match,
  // stores verified logs to storage.

  Future<void> _loadAndVerifyPendingLogs() async {
    try {
      final raw = await _bgMonitorChannel.invokeMethod<String>('getPendingLogs');
      if (raw == null || raw == '[]' || raw.isEmpty) return;

      final list = jsonDecode(raw) as List<dynamic>;
      if (list.isEmpty) return;

      debugPrint('[MonitoringProvider] verifying ${list.length} bg log(s)');

      for (final item in list) {
        final map           = item as Map<String, dynamic>;
        final pendingVerify = map['pendingVerify'] as bool? ?? false;
        final photoPath     = map['faceImagePath'] as String?;
        final pkg           = map['appPackageName'] as String? ?? '';
        final entryTime     = DateTime.fromMillisecondsSinceEpoch(
            (map['entryTime'] as num).toInt());
        final exitTime      = DateTime.fromMillisecondsSinceEpoch(
            (map['exitTime'] as num).toInt());

        double? verifiedScore;
        bool    isOwner         = false;
        String  detectionReason = map['detectionReason'] as String? ?? 'Background access';

        if (pendingVerify && photoPath != null) {
          final file = File(photoPath);
          if (file.existsSync()) {
            try {
              // FIX 1: Use extractEmbeddingFromFile() — runs ML Kit face
              // detection first, crops to the face, THEN runs FaceNet.
              // Returns null if the photo contains no detectable face.
              final embedding = await MlFaceService.instance
                  .extractEmbeddingFromFile(photoPath);
              final stored    = MlFaceService.instance.cachedStoredVector;

              if (embedding != null && stored != null) {
                // FIX 2: Compare raw cosine against matchThreshold (0.60).
                // New matchPercentage = cosine*100 (not (cosine+1)/2*100).
                // Owner: cosine ~0.75-0.95 → display 75-95%.
                // Stranger: cosine ~0.0-0.35 → display 0-35%.
                // NEW (CORRECT): isOwner = cosine >= 0.60
                final cosine = MlFaceService.cosineSimilarity(stored, embedding);
                final score  = MlFaceService.matchPercentage(stored, embedding);
                verifiedScore = score;
                isOwner       = cosine >= MlFaceService.matchThreshold; // 0.60

                if (isOwner) {
                  detectionReason = 'Authorized — owner verified (${score.toStringAsFixed(0)}% match)';
                  debugPrint('[MonitoringProvider] OWNER $pkg '
                      'cosine=${cosine.toStringAsFixed(3)} '
                      '(${score.toStringAsFixed(1)}%)');
                } else {
                  detectionReason = 'Unauthorized — ${score.toStringAsFixed(0)}% match (need ≥60%)';
                  debugPrint('[MonitoringProvider] UNAUTHORIZED $pkg '
                      'cosine=${cosine.toStringAsFixed(3)} '
                      '(${score.toStringAsFixed(1)}%)');
                }
              } else if (embedding == null) {
                // extractEmbeddingFromFile returned null → no face in photo
                detectionReason = 'No face detected — Unauthorized';
                isOwner = false;
                debugPrint('[MonitoringProvider] NO FACE in photo for $pkg');
              } else {
                // No stored vector yet (owner never registered)
                detectionReason = 'No owner face registered — cannot verify';
                isOwner = false;
              }
            } catch (e) {
              debugPrint('[MonitoringProvider] ML verify error: $e');
              detectionReason = 'Verification error — treated as unauthorized';
              isOwner = false;
            }
          } else {
            detectionReason = 'Background capture — photo file missing';
            isOwner = false;
          }
        } else if (photoPath == null) {
          // Camera failed — still log as unauthorized (unknown access)
          detectionReason = 'Background access — camera unavailable';
          isOwner = false;
        }

        // Always save the log — AUTH or UNAUTH, owner needs to see all access
        await _storage.addLog(LogEntryModel(
          id:              map['id'] as String? ?? 'bg_${DateTime.now().millisecondsSinceEpoch}',
          appName:         map['appName'] as String? ?? pkg,
          appPackageName:  pkg,
          entryTime:       entryTime,
          exitTime:        exitTime,
          detectionReason: detectionReason,
          isUnwantedPerson: !isOwner,   // false = AUTH (green), true = UNAUTH (red)
          faceImagePath:   photoPath,
          matchScore:      verifiedScore,
          attemptCount:    (map['attemptCount'] as num?)?.toInt() ?? 1,
        ));
      }

      _logs = await _storage.getLogs();
      _logs.sort((a, b) => b.entryTime.compareTo(a.entryTime));
      _computeStats();
      notifyListeners();
    } catch (e) {
      debugPrint('[MonitoringProvider] _loadAndVerifyPendingLogs error: $e');
    }
  }

  // ── Native bg service ─────────────────────────────────────────────────────

  Future<void> _startBgService(List<String> packages) async {
    try {
      final stored = await _storage.getFaceVector();
      await _bgMonitorChannel.invokeMethod('startBgService', {
        'packages':  packages,
        'embedding': stored?.vector ?? <double>[],
        'threshold': 0.50,
      });
    } catch (e) {
      debugPrint('[MonitoringProvider] startBgService: $e');
    }
  }

  Future<void> _stopBgService() async {
    try {
      await _bgMonitorChannel.invokeMethod('stopBgService');
    } catch (e) {
      debugPrint('[MonitoringProvider] stopBgService: $e');
    }
  }

  // ── App selection ──────────────────────────────────────────────────────────

  void toggleApp(AppInfoModel app) {
    if (isMonitoring) return;
    final idx = _selectedApps.indexWhere(
            (a) => a.packageName == app.packageName);
    if (idx == -1) {
      _selectedApps.add(app.copyWith(isSelected: true));
    } else {
      _selectedApps[idx] =
          _selectedApps[idx].copyWith(isSelected: !_selectedApps[idx].isSelected);
    }
    notifyListeners();
  }

  Future<void> saveSelectedApps() async => _storage.saveSelectedApps(_selectedApps);

  void setApps(List<AppInfoModel> apps) {
    final prev = {
      for (final a in _selectedApps.where((x) => x.isSelected)) a.packageName
    };
    _selectedApps =
        apps.map((a) => a.copyWith(isSelected: prev.contains(a.packageName)))
            .toList();
    _pushAppNameMap();
    notifyListeners();
  }

  // ── Monitoring control ─────────────────────────────────────────────────────

  Future<bool> startMonitoring() async {
    if (isMonitoring || isLoading) return false;

    final watched = _selectedApps
        .where((a) => a.isSelected)
        .map((a) => a.packageName)
        .toList();
    if (watched.isEmpty) {
      _errorMessage = 'Select at least one app to monitor';
      notifyListeners();
      return false;
    }

    _status = MonitoringStatus.starting;
    _errorMessage = null;
    notifyListeners();

    await saveSelectedApps();
    _pushAppNameMap();

    final ok = await MonitoringService.instance.start(watched);

    if (ok) {
      _status        = MonitoringStatus.active;
      _hasPermission = true;
      await _storage.setMonitoringEnabled(true);
      _subscribeToEvents();
      _subscribeToScreenEvents();
      await _startBgService(watched);
      debugPrint('[MonitoringProvider] monitoring ACTIVE ✓');
    } else {
      _status        = MonitoringStatus.error;
      _hasPermission = false;
      _errorMessage  = 'Usage Stats permission required.\n'
          'Settings → Apps → Special App Access → Usage Access → Nanopanda';
    }

    notifyListeners();
    return ok;
  }

  Future<void> stopMonitoring() async {
    if (!isMonitoring) return;
    _status = MonitoringStatus.stopping;
    notifyListeners();

    if (_activeSession != null) await _closeSession(reason: 'Monitoring stopped');

    await _sendLogsToWebhookAndClear();
    await MonitoringService.instance.stop();
    await _stopBgService();
    await _storage.setMonitoringEnabled(false);

    _eventSub?.cancel();
    _screenSub?.cancel();
    _sessionTimer?.cancel();
    _activeSession = null;
    _status        = MonitoringStatus.idle;
    notifyListeners();
  }

  Future<void> setMonitoringEnabledFromSettings(bool enabled) async {
    if (enabled) await startMonitoring(); else await stopMonitoring();
  }

  // ── Screen events ──────────────────────────────────────────────────────────

  void _subscribeToScreenEvents() {
    _screenSub?.cancel();
    _screenSub = _screenChannel.receiveBroadcastStream().listen(
          (event) { if (event == 'screen_off') _onScreenOff(); },
      onError: (e) => debugPrint('[MonitoringProvider] screen error: $e'),
    );
  }

  // ── Monitoring events (appOpened/appClosed for session tracking) ──────────

  void _subscribeToEvents() {
    _eventSub?.cancel();
    _eventSub = MonitoringService.instance.events.listen(
      _handleEvent,
      onError: (e) => debugPrint('[MonitoringProvider] stream error: $e'),
    );
  }

  void _handleEvent(MonitoringEvent event) {
    switch (event.type) {
      case MonitoringEventType.appClosed:
        _onAppClosed(event);
        break;
      case MonitoringEventType.appOpened:
      // Track session for dashboard "active session" display only
        if (_activeSession == null) {
          _activeSession = ActiveSession(
            packageName: event.packageName,
            appName:     _resolveAppName(event.packageName),
            startedAt:   event.timestamp,
          );
          _sessionTimer?.cancel();
          _sessionTimer = Timer.periodic(
              const Duration(seconds: 1), (_) => notifyListeners());
          notifyListeners();
        }
        break;
      case MonitoringEventType.permissionRequired:
        _status = MonitoringStatus.error;
        _hasPermission = false;
        _errorMessage = event.errorMessage;
        notifyListeners();
        break;
      case MonitoringEventType.error:
        _errorMessage = event.errorMessage;
        notifyListeners();
        break;
    }
  }

  Future<void> _onAppClosed(MonitoringEvent event) async {
    _sessionTimer?.cancel();
    _sessionTimer = null;
    if (_activeSession?.packageName == event.packageName) {
      _activeSession = null;
      notifyListeners();
    }
  }

  Future<void> _closeSession({DateTime? closeTime, String? reason}) async {
    _sessionTimer?.cancel();
    _sessionTimer  = null;
    _activeSession = null;
    notifyListeners();
  }

  // Kept for compile compatibility with face_overlay_page.dart
  // Background capture flow is now handled entirely by BackgroundMonitorService.kt
  Future<void> onOverlayResult(dynamic result) async {
    debugPrint('[MonitoringProvider] onOverlayResult (no-op — bg capture mode)');
  }

  String _resolveAppName(String pkg) => _selectedApps
      .firstWhere((a) => a.packageName == pkg,
      orElse: () => AppInfoModel(name: pkg, packageName: pkg))
      .name;

  // ── Screen off ────────────────────────────────────────────────────────────

  Future<void> _onScreenOff() async {
    debugPrint('[MonitoringProvider] screen off → send + clear');
    _sessionTimer?.cancel();
    _sessionTimer  = null;
    _activeSession = null;
    await _sendLogsToWebhookAndClear();
  }

  // ── Logs ──────────────────────────────────────────────────────────────────

  Future<void> reloadLogs() async {
    _logs = await _storage.getLogs();
    _logs.sort((a, b) => b.entryTime.compareTo(a.entryTime));
    _computeStats();
    notifyListeners();
  }

  Future<void> clearLogs() async {
    for (final log in _logs) {
      if (log.faceImagePath != null) {
        try { File(log.faceImagePath!).deleteSync(); } catch (_) {}
      }
      await _storage.deleteFaceImage(log.faceImagePath);
    }
    await _storage.clearLogs();
    _logs  = [];
    _stats = MonitoringStats.empty();
    notifyListeners();
  }

  Future<void> deleteLog(String id) async {
    final log = _logs.firstWhere(
          (l) => l.id == id,
      orElse: () => LogEntryModel(
        id: id, appName: '', appPackageName: '',
        entryTime: DateTime.now(), exitTime: DateTime.now(),
        detectionReason: '', isUnwantedPerson: false,
      ),
    );
    if (log.faceImagePath != null) {
      try { File(log.faceImagePath!).deleteSync(); } catch (_) {}
    }
    await _storage.deleteFaceImage(log.faceImagePath);
    _logs.removeWhere((l) => l.id == id);
    await _storage.saveLogs(_logs);
    _computeStats();
    notifyListeners();
  }

  // ── Permission ────────────────────────────────────────────────────────────

  Future<void> refreshPermissionStatus() async {
    _hasPermission = await MonitoringService.instance.checkUsageStatsPermission();
    if (_hasPermission && _status == MonitoringStatus.error) {
      _status = MonitoringStatus.idle;
      _errorMessage = null;
    }
    notifyListeners();
  }

  Future<void> openUsageAccessSettings() async =>
      MonitoringService.instance.openUsageAccessSettings();

  // ── Webhook send + clear ──────────────────────────────────────────────────

  Future<void> _sendLogsToWebhookAndClear() async {
    const url =
        'https://johnharry.app.n8n.cloud/webhook/c979a31d-a9cc-4327-a927-ba2ce38ade3a';
    final logs = await _storage.getLogs();
    if (logs.isEmpty) return;

    try {
      await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'sentAt':    DateTime.now().toIso8601String(),
          'totalLogs': logs.length,
          'logs':      logs.map((l) => l.toJson()).toList(),
        }),
      ).timeout(const Duration(seconds: 10));
      debugPrint('[MonitoringProvider] webhook sent ✓');
    } catch (e) {
      debugPrint('[MonitoringProvider] webhook error: $e');
    }

    for (final log in logs) {
      if (log.faceImagePath != null) {
        try { File(log.faceImagePath!).deleteSync(); } catch (_) {}
      }
      await _storage.deleteFaceImage(log.faceImagePath);
    }
    await _storage.clearLogs();
    _logs  = [];
    _stats = MonitoringStats.empty();
    notifyListeners();
  }

  // ── Stats ─────────────────────────────────────────────────────────────────

  void _computeStats() {
    if (_logs.isEmpty) { _stats = MonitoringStats.empty(); return; }
    final todayStart = DateTime.now();
    final today      = DateTime(todayStart.year, todayStart.month, todayStart.day);
    int todayAlerts  = 0;
    final alertsByApp   = <String, int>{};
    final durationByApp = <String, int>{};
    for (final log in _logs) {
      if (!log.isUnwantedPerson) continue;
      if (log.entryTime.isAfter(today)) todayAlerts++;
      alertsByApp[log.appName]   = (alertsByApp[log.appName]   ?? 0) + 1;
      durationByApp[log.appName] =
          (durationByApp[log.appName] ?? 0) + log.durationInSeconds;
    }
    _stats = MonitoringStats(
      totalAlerts:  _logs.where((l) => l.isUnwantedPerson).length,
      todayAlerts:  todayAlerts,
      mostTargetedApp: alertsByApp.isEmpty ? '—'
          : alertsByApp.entries.reduce((a, b) => a.value > b.value ? a : b).key,
      alertsByApp:           alertsByApp,
      durationByApp:         durationByApp,
      totalUnauthorizedTime: Duration(
          seconds: durationByApp.values.fold(0, (s, v) => s + v)),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventSub?.cancel();
    _screenSub?.cancel();
    _sessionTimer?.cancel();
    super.dispose();
  }
}