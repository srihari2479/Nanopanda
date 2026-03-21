// lib/core/services/monitoring_service.dart
//
// OVERLAY ARCHITECTURE:
//
//   When a watched app is detected:
//     1. MonitoringService calls the global navigatorKey to push /face-overlay.
//        This brings Nanopanda's Activity to the front instantly.
//     2. FaceOverlayPage opens camera, runs ML, delivers OverlayResult.
//     3. MonitoringProvider.onOverlayResult() saves the log entry.
//
//   flutter_foreground_task keepalive is still used (non-fatal if fails).
//   NO SilentFaceService. Camera only opens inside FaceOverlayPage.

import 'dart:async';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

  /// Set this from main.dart BEFORE runApp.
  /// MonitoringService uses it to push /face-overlay from background polling.
  static GlobalKey<NavigatorState>? navigatorKey;

  final _eventController = StreamController<MonitoringEvent>.broadcast();
  Stream<MonitoringEvent> get events => _eventController.stream;

  bool _initialized       = false;
  bool _foregroundRunning = false;

  Set<String>         _watchedPackages = {};
  Map<String, String> _appNameMap      = {};
  String?             _currentForeground;
  Timer?              _pollTimer;

  // Packages for which overlay is currently visible — prevents double-trigger
  final Set<String> _overlayActive = {};

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
      debugPrint('[MonitoringService] WARNING: no face vector — '
          'all faces will be treated as unauthorized.');
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
    debugPrint('[MonitoringService] polling started (main isolate)');
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer         = null;
    _currentForeground = null;
    _overlayActive.clear();
    debugPrint('[MonitoringService] polling stopped');
  }

  Future<void> _poll() async {
    try {
      final pkg = await _channel.invokeMethod<String>('getForegroundApp');
      if (pkg == null || pkg.isEmpty) return;
      if (pkg == _currentForeground)  return;

      final previous     = _currentForeground;
      _currentForeground = pkg;

      // ── App closed ────────────────────────────────────────────────────────
      if (previous != null && _watchedPackages.contains(previous)) {
        _overlayActive.remove(previous);
        _eventController.add(MonitoringEvent(
          type:        MonitoringEventType.appClosed,
          packageName: previous,
          appName:     _resolveAppName(previous),
          timestamp:   DateTime.now(),
        ));
        debugPrint('[MonitoringService] app closed: $previous');
      }

      // ── Watched app opened ────────────────────────────────────────────────
      if (_watchedPackages.contains(pkg) && !_overlayActive.contains(pkg)) {
        _overlayActive.add(pkg);
        debugPrint('[MonitoringService] watched app opened: $pkg → overlay');
        _showOverlay(pkg);
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

  // ── Overlay trigger ───────────────────────────────────────────────────────

  void _showOverlay(String packageName) {
    final now = DateTime.now();
    final nav = navigatorKey?.currentState;

    if (nav == null) {
      // App is fully backgrounded — navigator not available.
      // BackgroundMonitorService already wrote a capture request to SharedPrefs.
      // MonitoringProvider will handle it when app comes to foreground:
      //   _pollAndCapture() → _executeSilentCapture() → _pushOverlayAfterCapture()
      // Do NOT emit an unauthorized event here — that would create a duplicate
      // log entry alongside the one from the bg capture flow.
      debugPrint('[MonitoringService] navigator unavailable — '
          'bg capture will handle $packageName when app foregrounds');
      _overlayActive.remove(packageName); // allow re-trigger when foreground
      return;
    }

    debugPrint('[MonitoringService] pushing overlay for $packageName');
    nav.pushNamed(
      '/face-overlay',
      arguments: {
        'packageName': packageName,
        'appName':     _resolveAppName(packageName),
        'detectedAt':  now.toIso8601String(),
      },
    );
  }

  /// Call when overlay is dismissed so next open re-triggers correctly.
  void onOverlayDismissed(String packageName) {
    _overlayActive.remove(packageName);
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

    debugPrint('[MonitoringService] ✓ started — watching: $_watchedPackages  '
        'foreground: $_foregroundRunning');
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