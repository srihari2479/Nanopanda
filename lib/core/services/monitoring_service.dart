// lib/core/services/monitoring_service.dart
//
// CORRECT FLOW:
//   MonitoringService polls foreground app every 1.5s.
//   When a watched app is detected → emits appOpened event (for dashboard UI).
//   When it closes → emits appClosed event.
//   NO overlay push. NO navigator. NO FaceOverlay.
//   Background capture is handled entirely by BackgroundMonitorService.kt
//   using Camera2 API — no Flutter involvement needed.

import 'dart:async';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart'
    hide NotificationPermission;

import 'storage_service.dart';
import 'ml_face_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Event types
// ─────────────────────────────────────────────────────────────────────────────

enum MonitoringEventType {
  appOpened,
  appClosed,
  permissionRequired,
  error,
}

class MonitoringEvent {
  final MonitoringEventType type;
  final String              packageName;
  final String              appName;
  final DateTime            timestamp;
  final bool                isAuthorized;
  final String?             errorMessage;

  const MonitoringEvent({
    required this.type,
    required this.packageName,
    required this.appName,
    required this.timestamp,
    this.isAuthorized = true,
    this.errorMessage,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Background keepalive task handler
// ─────────────────────────────────────────────────────────────────────────────

@pragma('vm:entry-point')
void startMonitoringCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[KeepAlive] foreground service started');
  }
  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {}
  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('[KeepAlive] foreground service stopped');
  }
  @override
  void onReceiveData(Object data) {}
}

// ─────────────────────────────────────────────────────────────────────────────
// MonitoringService
// ─────────────────────────────────────────────────────────────────────────────

class MonitoringService {
  MonitoringService._();
  static final MonitoringService instance = MonitoringService._();

  static const _channel = MethodChannel('nanopanda/monitoring');

  // navigatorKey kept for compile-compat with main.dart — NOT used for overlay.
  // Background capture does not require MainActivity to come to foreground.
  static dynamic navigatorKey;

  final _eventController = StreamController<MonitoringEvent>.broadcast();
  Stream<MonitoringEvent> get events => _eventController.stream;

  bool _initialized       = false;
  bool _foregroundRunning = false;

  Set<String>         _watchedPackages  = {};
  Map<String, String> _appNameMap       = {};
  String?             _currentForeground;
  Timer?              _pollTimer;

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> initialize({required StorageService storage}) async {
    if (_initialized) return;

    await MlFaceService.instance.initialize();

    final faceVector = await storage.getFaceVector();
    if (faceVector != null) {
      MlFaceService.instance.cacheStoredVector(faceVector.vector);
      debugPrint('[MonitoringService] face vector cached '
          '(${faceVector.vector.length}d)');
    } else {
      debugPrint('[MonitoringService] WARNING: no face vector stored yet.');
    }

    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    _initialized = true;
    debugPrint('[MonitoringService] initialized');
  }

  void _onTaskData(Object data) {}

  // ── App name map ──────────────────────────────────────────────────────────

  void updateAppNameMap(Map<String, String> packageToName) {
    _appNameMap = Map.from(packageToName);
  }

  String _resolveAppName(String pkg) =>
      _appNameMap[pkg] ?? _friendlyName(pkg);

  String _friendlyName(String pkg) {
    final parts = pkg.split('.');
    if (parts.isEmpty) return pkg;
    final last = parts.last;
    return last[0].toUpperCase() + last.substring(1);
  }

  // ── Polling ───────────────────────────────────────────────────────────────

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
          (_) => _poll(),
    );
    debugPrint('[MonitoringService] polling started');
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer         = null;
    _currentForeground = null;
    debugPrint('[MonitoringService] polling stopped');
  }

  Future<void> _poll() async {
    try {
      final pkg = await _channel.invokeMethod<String>('getForegroundApp');
      if (pkg == null || pkg.isEmpty) return;
      if (pkg == _currentForeground)  return;

      final previous     = _currentForeground;
      _currentForeground = pkg;

      // App closed
      if (previous != null && _watchedPackages.contains(previous)) {
        _eventController.add(MonitoringEvent(
          type:        MonitoringEventType.appClosed,
          packageName: previous,
          appName:     _resolveAppName(previous),
          timestamp:   DateTime.now(),
        ));
        debugPrint('[MonitoringService] app closed: $previous');
      }

      // Watched app opened — emit event for dashboard session display only
      if (_watchedPackages.contains(pkg)) {
        debugPrint('[MonitoringService] watched app opened: $pkg '
            '(bg capture handled by Kotlin service)');
        _eventController.add(MonitoringEvent(
          type:         MonitoringEventType.appOpened,
          packageName:  pkg,
          appName:      _resolveAppName(pkg),
          timestamp:    DateTime.now(),
          isAuthorized: false, // unknown until ML verify on app open
        ));
      }
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') {
        _eventController.add(MonitoringEvent(
          type:         MonitoringEventType.permissionRequired,
          packageName:  '',
          appName:      '',
          timestamp:    DateTime.now(),
          isAuthorized: false,
          errorMessage: 'Usage Stats permission required',
        ));
      }
    } catch (e) {
      debugPrint('[MonitoringService] poll error: $e');
    }
  }

  // ── Public: start / stop ──────────────────────────────────────────────────

  Future<bool> start(List<String> watchedPackages) async {
    final hasUsage = await checkUsageStatsPermission();
    if (!hasUsage) {
      debugPrint('[MonitoringService] ✗ no usage stats permission');
      return false;
    }

    // Request notification permission — non-fatal
    final isAllowed = await AwesomeNotifications().isNotificationAllowed();
    if (!isAllowed) {
      await AwesomeNotifications().requestPermissionToSendNotifications();
    }

    // Keepalive foreground service — non-fatal
    try {
      final result = await FlutterForegroundTask.startService(
        serviceId:         1001,
        notificationTitle: 'Nanopanda Protection Active',
        notificationText:  'Monitoring ${watchedPackages.length} app(s)',
        callback:          startMonitoringCallback,
      );
      _foregroundRunning = result is ServiceRequestSuccess;
      debugPrint('[MonitoringService] keepalive: '
          '${_foregroundRunning ? "started ✓" : "unavailable ($result)"}');
    } catch (e) {
      _foregroundRunning = false;
      debugPrint('[MonitoringService] keepalive exception: $e');
    }

    _watchedPackages = Set<String>.from(watchedPackages);
    _startPolling();

    debugPrint('[MonitoringService] ✓ started — watching: $_watchedPackages');
    return true;
  }

  Future<void> stop() async {
    _stopPolling();
    if (_foregroundRunning) {
      await FlutterForegroundTask.stopService();
      _foregroundRunning = false;
    }
    _watchedPackages = {};
    debugPrint('[MonitoringService] stopped');
  }

  Future<void> updateWatchedPackages(List<String> packages) async {
    _watchedPackages = Set<String>.from(packages);
    debugPrint('[MonitoringService] updated watched: $packages');
  }

  // ── Permissions ───────────────────────────────────────────────────────────

  Future<bool> checkUsageStatsPermission() async {
    try {
      return await _channel.invokeMethod<bool>(
          'checkUsageStatsPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openUsageAccessSettings() async {
    try {
      await _channel.invokeMethod('openUsageSettings');
    } catch (e) {
      debugPrint('[MonitoringService] open settings error: $e');
    }
  }

  bool get isForegroundServiceRunning => _foregroundRunning;

  void dispose() {
    _stopPolling();
    _eventController.close();
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
  }
}