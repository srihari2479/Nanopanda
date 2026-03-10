import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/app_info_model.dart';
import '../models/log_entry_model.dart';
import '../services/monitoring_service.dart';
import '../services/storage_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Supporting types
// ─────────────────────────────────────────────────────────────────────────────

enum MonitoringStatus { idle, starting, active, stopping, error }

class MonitoringStats {
  final int totalAlerts;
  final int todayAlerts;
  final String mostTargetedApp;
  final Map<String, int> alertsByApp;       // packageName → count
  final Map<String, int> durationByApp;     // packageName → seconds
  final Duration totalUnauthorizedTime;

  const MonitoringStats({
    required this.totalAlerts,
    required this.todayAlerts,
    required this.mostTargetedApp,
    required this.alertsByApp,
    required this.durationByApp,
    required this.totalUnauthorizedTime,
  });

  factory MonitoringStats.empty() => const MonitoringStats(
    totalAlerts: 0,
    todayAlerts: 0,
    mostTargetedApp: '—',
    alertsByApp: {},
    durationByApp: {},
    totalUnauthorizedTime: Duration.zero,
  );
}

/// A live, in-progress monitoring session (app opened but not yet closed).
class ActiveSession {
  final String packageName;
  final String appName;
  final DateTime startedAt;

  const ActiveSession({
    required this.packageName,
    required this.appName,
    required this.startedAt,
  });

  Duration get elapsed => DateTime.now().difference(startedAt);
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────

class MonitoringProvider extends ChangeNotifier {
  final StorageService _storage;

  MonitoringProvider(this._storage) {
    _bootstrap();
  }

  // ── State ────────────────────────────────────────────────────────────────────
  MonitoringStatus _status        = MonitoringStatus.idle;
  List<AppInfoModel> _selectedApps = [];
  List<LogEntryModel> _logs        = [];
  ActiveSession?      _activeSession;
  MonitoringStats     _stats        = MonitoringStats.empty();
  bool                _hasPermission = false;
  String?             _errorMessage;

  StreamSubscription<MonitoringEvent>? _eventSub;
  Timer? _sessionTimer; // refreshes elapsed time every second for live UI

  // ── Getters ──────────────────────────────────────────────────────────────────
  MonitoringStatus   get status         => _status;
  bool get isMonitoring  => _status == MonitoringStatus.active;
  bool get isLoading     => _status == MonitoringStatus.starting ||
      _status == MonitoringStatus.stopping;
  List<AppInfoModel> get selectedApps   => List.unmodifiable(_selectedApps);
  List<LogEntryModel> get logs           => List.unmodifiable(_logs);
  ActiveSession?     get activeSession  => _activeSession;
  MonitoringStats    get stats          => _stats;
  bool               get hasPermission  => _hasPermission;
  String?            get errorMessage   => _errorMessage;
  int                get selectedCount  => _selectedApps.where((a) => a.isSelected).length;

  // ── Bootstrap ────────────────────────────────────────────────────────────────

  Future<void> _bootstrap() async {
    await MonitoringService.instance.initialize(storage: _storage);

    _hasPermission = await MonitoringService.instance.checkUsageStatsPermission();
    _selectedApps  = await _storage.getSelectedApps();
    _logs          = await _storage.getLogs();
    _computeStats();

    final wasRunning = await _storage.isMonitoringEnabled();
    if (wasRunning && _selectedApps.any((a) => a.isSelected)) {
      // Re-attach service events but don't restart the service itself
      // (it may still be alive from before); just subscribe to events.
      _subscribeToEvents();
      _status = MonitoringStatus.active;
    }

    notifyListeners();
  }

  // ── App Selection ────────────────────────────────────────────────────────────

  void toggleApp(AppInfoModel app) {
    if (isMonitoring) return;
    final idx = _selectedApps.indexWhere((a) => a.packageName == app.packageName);
    if (idx == -1) {
      _selectedApps.add(app.copyWith(isSelected: true));
    } else {
      final current = _selectedApps[idx];
      _selectedApps[idx] = current.copyWith(isSelected: !current.isSelected);
    }
    notifyListeners();
  }

  Future<void> saveSelectedApps() async {
    await _storage.saveSelectedApps(_selectedApps);
  }

  void setApps(List<AppInfoModel> apps) {
    // Merge with previous selections
    final prevSelected = {for (final a in _selectedApps.where((x) => x.isSelected)) a.packageName};
    _selectedApps = apps.map((a) {
      return a.copyWith(isSelected: prevSelected.contains(a.packageName));
    }).toList();
    notifyListeners();
  }

  // ── Monitoring Control ───────────────────────────────────────────────────────

  Future<bool> startMonitoring() async {
    if (isMonitoring || isLoading) return false;

    final watchedPackages = _selectedApps
        .where((a) => a.isSelected)
        .map((a) => a.packageName)
        .toList();

    if (watchedPackages.isEmpty) {
      _errorMessage = 'Select at least one app to monitor';
      notifyListeners();
      return false;
    }

    _status       = MonitoringStatus.starting;
    _errorMessage = null;
    notifyListeners();

    await saveSelectedApps();

    final ok = await MonitoringService.instance.start(watchedPackages);

    if (ok) {
      _status = MonitoringStatus.active;
      await _storage.setMonitoringEnabled(true);
      _subscribeToEvents();
    } else {
      _status       = MonitoringStatus.error;
      _hasPermission = false;
      _errorMessage = 'Usage Stats permission required.\n'
          'Settings → Apps → Special App Access → Usage Access → Nanopanda';
    }

    notifyListeners();
    return ok;
  }

  /// Called from SettingsPage toggle — starts or stops monitoring accordingly.
  Future<void> setMonitoringEnabledFromSettings(bool enabled) async {
    if (enabled) {
      await startMonitoring();
    } else {
      await stopMonitoring();
    }
  }

  Future<void> stopMonitoring() async {
    if (!isMonitoring) return;

    _status = MonitoringStatus.stopping;
    notifyListeners();

    // Close active session if any
    if (_activeSession != null) {
      await _closeSession();
    }

    await MonitoringService.instance.stop();
    await _storage.setMonitoringEnabled(false);
    _eventSub?.cancel();
    _eventSub = null;
    _sessionTimer?.cancel();
    _sessionTimer = null;
    _activeSession = null;
    _status        = MonitoringStatus.idle;

    notifyListeners();
  }

  // ── Logs ─────────────────────────────────────────────────────────────────────

  Future<void> reloadLogs() async {
    _logs = await _storage.getLogs();
    _computeStats();
    notifyListeners();
  }

  Future<void> clearLogs() async {
    await _storage.clearLogs();
    _logs = [];
    _stats = MonitoringStats.empty();
    notifyListeners();
  }

  Future<void> deleteLog(String id) async {
    _logs.removeWhere((l) => l.id == id);
    await _storage.saveLogs(_logs);
    _computeStats();
    notifyListeners();
  }

  // ── Permission ───────────────────────────────────────────────────────────────

  Future<void> refreshPermissionStatus() async {
    _hasPermission = await MonitoringService.instance.checkUsageStatsPermission();
    if (_hasPermission && _status == MonitoringStatus.error) {
      _status = MonitoringStatus.idle;
      _errorMessage = null;
    }
    notifyListeners();
  }

  Future<void> openUsageAccessSettings() async {
    await MonitoringService.instance.openUsageAccessSettings();
  }

  // ── Event Handling (internal) ────────────────────────────────────────────────

  void _subscribeToEvents() {
    _eventSub?.cancel();
    _eventSub = MonitoringService.instance.events.listen(
      _handleEvent,
      onError: (e) {
        debugPrint('[MonitoringProvider] stream error: $e');
      },
    );
  }

  void _handleEvent(MonitoringEvent event) {
    switch (event.type) {
      case MonitoringEventType.appOpened:
        _onAppOpened(event);
        break;
      case MonitoringEventType.appClosed:
        _onAppClosed(event);
        break;
      case MonitoringEventType.permissionRequired:
        _status       = MonitoringStatus.error;
        _hasPermission = false;
        _errorMessage = event.errorMessage;
        notifyListeners();
        break;
      case MonitoringEventType.error:
        _status       = MonitoringStatus.error;
        _errorMessage = event.errorMessage;
        notifyListeners();
        break;
    }
  }

  void _onAppOpened(MonitoringEvent event) {
    _activeSession = ActiveSession(
      packageName: event.packageName,
      appName: event.appName,
      startedAt: event.timestamp,
    );

    // Only create log immediately if unauthorized
    // Authorized access is silent — no log, no session tracking
    if (!event.isAuthorized) {
      _sessionTimer?.cancel();
      _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        notifyListeners();
      });
    } else {
      // Authorized — clear active session, nothing to log
      _activeSession = null;
    }

    notifyListeners();
  }

  Future<void> _onAppClosed(MonitoringEvent event) async {
    _sessionTimer?.cancel();
    _sessionTimer = null;

    if (_activeSession?.packageName == event.packageName) {
      await _closeSession(closeTime: event.timestamp);
    }
  }

  Future<void> _closeSession({DateTime? closeTime}) async {
    final session = _activeSession;
    if (session == null) return;

    // Find app name from selected list
    final appModel = _selectedApps.firstWhere(
          (a) => a.packageName == session.packageName,
      orElse: () => AppInfoModel(
        name: session.appName,
        packageName: session.packageName,
      ),
    );

    final entry = LogEntryModel(
      id: 'log_${DateTime.now().millisecondsSinceEpoch}',
      appName: appModel.name,
      appPackageName: session.packageName,
      entryTime: session.startedAt,
      exitTime: closeTime ?? DateTime.now(),
      detectionReason: 'Accessed without face verification',
      isUnwantedPerson: true,
    );

    // FIX: only write to storage once — no in-memory insert before reload
    // Previously _logs.insert(0, entry) + _storage.addLog() caused duplicates
    await _storage.addLog(entry);
    _logs = await _storage.getLogs();
    _logs.sort((a, b) => b.entryTime.compareTo(a.entryTime));
    _computeStats();

    _activeSession = null;
    notifyListeners();
  }

  // ── Statistics ───────────────────────────────────────────────────────────────

  void _computeStats() {
    if (_logs.isEmpty) {
      _stats = MonitoringStats.empty();
      return;
    }

    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    int todayAlerts = 0;
    final alertsByApp   = <String, int>{};
    final durationByApp = <String, int>{};

    for (final log in _logs) {
      if (!log.isUnwantedPerson) continue;

      if (log.entryTime.isAfter(today)) todayAlerts++;

      alertsByApp[log.appName] = (alertsByApp[log.appName] ?? 0) + 1;
      durationByApp[log.appName] =
          (durationByApp[log.appName] ?? 0) + log.durationInSeconds;
    }

    final mostTargeted = alertsByApp.isEmpty
        ? '—'
        : (alertsByApp.entries.reduce((a, b) => a.value > b.value ? a : b)).key;

    final totalSecs = durationByApp.values.fold(0, (s, v) => s + v);

    _stats = MonitoringStats(
      totalAlerts: _logs.where((l) => l.isUnwantedPerson).length,
      todayAlerts: todayAlerts,
      mostTargetedApp: mostTargeted,
      alertsByApp: alertsByApp,
      durationByApp: durationByApp,
      totalUnauthorizedTime: Duration(seconds: totalSecs),
    );
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _sessionTimer?.cancel();
    super.dispose();
  }
}