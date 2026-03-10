// lib/core/services/monitoring_service.dart
//
// Production monitoring service.
//
// Flow when a protected app opens:
//   1. UsageStats poll detects foreground app change
//   2. SilentFaceChannel.capture() → native gets JPEG silently
//   3. JPEG decoded → MlFaceService.processJpeg() → embedding
//   4. Embedding compared to stored vector
//   5. Match  → appOpened event (authorized, no log)
//   6. No match → appOpened event (unauthorized) → LogEntry created
//   7. Notification fired if unauthorized

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_usage/app_usage.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart'
    hide NotificationPermission;
import 'package:image/image.dart' as img;

import 'silent_face_channel.dart';
import 'ml_face_service.dart';
import 'storage_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Foreground task callback (background isolate heartbeat)
// ─────────────────────────────────────────────────────────────────────────────

@pragma('vm:entry-point')
void monitoringTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_MonitoringTaskHandler());
}

class _MonitoringTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    FlutterForegroundTask.updateService(
      notificationText:
      'Active — ${timestamp.hour}:${timestamp.minute.toString().padLeft(2, '0')}',
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}

// ─────────────────────────────────────────────────────────────────────────────
// Domain events
// ─────────────────────────────────────────────────────────────────────────────

enum MonitoringEventType { appOpened, appClosed, permissionRequired, error }

class MonitoringEvent {
  final MonitoringEventType type;
  final String packageName;
  final String appName;
  final DateTime timestamp;
  final bool isAuthorized;   // true = face matched, false = unauthorized
  final String? errorMessage;

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
// Monitoring Service — Singleton
// ─────────────────────────────────────────────────────────────────────────────

class MonitoringService {
  MonitoringService._();
  static final MonitoringService instance = MonitoringService._();

  // ── Config ───────────────────────────────────────────────────────────────────
  static const Duration _pollInterval    = Duration(seconds: 1);
  static const Duration _usageLookback   = Duration(seconds: 5);
  static const String   _alertChannel    = 'nanopanda_security_alerts';
  static const String   _statusChannel   = 'nanopanda_monitoring_status';
  static const String   _ownPackage      = 'com.example.nanospark';
  static const double   _matchThreshold  = 80.0; // % — same as login

  // ── State ─────────────────────────────────────────────────────────────────────
  Timer?         _pollTimer;
  bool           _initialized   = false;
  bool           _hasPermission = false;
  String?        _activePackage;
  List<String>   _watchedPackages = [];
  bool           _verifying     = false; // prevents concurrent face checks

  StorageService? _storage; // injected on start()

  final StreamController<MonitoringEvent> _events =
  StreamController<MonitoringEvent>.broadcast();

  // ── Public ────────────────────────────────────────────────────────────────────

  Stream<MonitoringEvent> get events      => _events.stream;
  bool get isRunning    => _pollTimer?.isActive ?? false;
  bool get hasPermission => _hasPermission;

  /// Call once at app startup, pass StorageService so we can read stored vector.
  Future<void> initialize({required StorageService storage}) async {
    if (_initialized) return;
    _storage     = storage;
    _initialized = true;
    await _setupNotifications();
    _setupForegroundTask();
    _hasPermission = await checkUsageStatsPermission();
    debugPrint('[MonitoringService] init — permission: $_hasPermission');
  }

  Future<bool> checkUsageStatsPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      await AppUsage().getAppUsage(
          DateTime.now().subtract(const Duration(seconds: 10)), DateTime.now());
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> openUsageAccessSettings() async {
    if (!Platform.isAndroid) return;
    // FIX: must call 'openUsageSettings' on nanopanda/monitoring channel
    // NOT FlutterForegroundTask.openSystemAlertWindowSettings() which opens
    // the wrong screen (System Alert Window, not Usage Access)
    const channel = MethodChannel('nanopanda/monitoring');
    try {
      await channel.invokeMethod<void>('openUsageSettings');
    } catch (e) {
      debugPrint('[MonitoringService] openUsageAccessSettings error: $e');
    }
  }

  /// Start monitoring given package names.
  Future<bool> start(List<String> packages) async {
    if (!_initialized) {
      debugPrint('[MonitoringService] not initialized');
      return false;
    }
    if (isRunning) await stop();

    _hasPermission = await checkUsageStatsPermission();
    if (!_hasPermission) {
      _emit(MonitoringEvent(
        type: MonitoringEventType.permissionRequired,
        packageName: '', appName: '',
        timestamp: DateTime.now(),
        errorMessage: 'Usage Stats permission not granted',
      ));
      return false;
    }

    _watchedPackages = List.from(packages);
    _activePackage   = null;

    if (Platform.isAndroid) await _startForegroundService(packages.length);

    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
    debugPrint('[MonitoringService] started — watching ${packages.length} apps');
    return true;
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;

    if (_activePackage != null) {
      _emit(MonitoringEvent(
        type: MonitoringEventType.appClosed,
        packageName: _activePackage!, appName: _humanName(_activePackage!),
        timestamp: DateTime.now(),
      ));
      _activePackage = null;
    }

    if (Platform.isAndroid) await FlutterForegroundTask.stopService();
    debugPrint('[MonitoringService] stopped');
  }

  void updateWatchedPackages(List<String> packages) {
    _watchedPackages = List.from(packages);
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  // ── Polling ───────────────────────────────────────────────────────────────────

  Future<void> _poll() async {
    try {
      final current = await _getForegroundApp();
      final watched = current != null && _watchedPackages.contains(current);

      if (watched && current != _activePackage) {
        // Protected app just opened → silent face check
        if (_activePackage != null) {
          _emit(MonitoringEvent(
            type: MonitoringEventType.appClosed,
            packageName: _activePackage!, appName: _humanName(_activePackage!),
            timestamp: DateTime.now(),
          ));
        }
        _activePackage = current;
        await _handleProtectedAppOpened(current);

      } else if (!watched && _activePackage != null) {
        _emit(MonitoringEvent(
          type: MonitoringEventType.appClosed,
          packageName: _activePackage!, appName: _humanName(_activePackage!),
          timestamp: DateTime.now(),
        ));
        _activePackage = null;
      }
    } catch (e) {
      debugPrint('[MonitoringService] poll error: $e');
    }
  }

  // ── Silent face check ─────────────────────────────────────────────────────────

  Future<void> _handleProtectedAppOpened(String packageName) async {
    if (_verifying) return; // already checking previous app
    _verifying = true;

    bool authorized = false;

    try {
      // Step 1 — capture JPEG silently via native service
      final jpeg = await SilentFaceChannel.capture();
      if (jpeg == null) {
        debugPrint('[MonitoringService] silent capture failed → treat as unauthorized');
      } else {
        // Step 2 — decode JPEG → img.Image
        final decoded = img.decodeJpg(jpeg);
        if (decoded != null && _storage != null) {
          // Step 3 — get embedding from JPEG image
          final embedding = await MlFaceService.instance.processJpegImage(decoded);
          if (embedding != null) {
            // Step 4 — compare with stored vector
            final stored = await _storage!.getFaceVector();
            if (stored != null) {
              final score = MlFaceService.matchPercentage(stored.vector, embedding);
              debugPrint('[MonitoringService] face score: ${score.toStringAsFixed(1)}%');
              authorized = score >= _matchThreshold;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[MonitoringService] face check error: $e');
    } finally {
      _verifying = false;
    }

    _emit(MonitoringEvent(
      type: MonitoringEventType.appOpened,
      packageName: packageName,
      appName: _humanName(packageName),
      timestamp: DateTime.now(),
      isAuthorized: authorized,
    ));

    if (!authorized) {
      await _sendSecurityAlert(packageName);
      debugPrint('[MonitoringService] UNAUTHORIZED: $packageName');
    } else {
      debugPrint('[MonitoringService] authorized: $packageName');
    }
  }

  // ── UsageStats ────────────────────────────────────────────────────────────────

  Future<String?> _getForegroundApp() async {
    try {
      final end   = DateTime.now();
      // 3-second window: only apps active RIGHT NOW will appear with usage > 0
      final start = end.subtract(const Duration(seconds: 3));
      final infos = await AppUsage().getAppUsage(start, end);
      if (infos.isEmpty) return null;

      final filtered = infos.where((i) =>
      i.packageName != _ownPackage &&
          !i.packageName.startsWith('android') &&
          !i.packageName.startsWith('com.android') &&
          !i.packageName.startsWith('com.google.android.inputmethod') &&
          i.usage.inSeconds > 0,
      ).toList();

      if (filtered.isEmpty) return null;
      // Highest usage in this tiny window = currently in foreground
      filtered.sort((a, b) => b.usage.compareTo(a.usage));
      return filtered.first.packageName;
    } catch (_) {
      return null;
    }
  }

  // ── Notifications ─────────────────────────────────────────────────────────────

  Future<void> _sendSecurityAlert(String pkg) async {
    final name = _humanName(pkg);
    final now  = DateTime.now();
    final time = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    await AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: pkg.hashCode.abs() % 99999,
        channelKey: _alertChannel,
        title: '⚠️ Unauthorized Access',
        body: '$name opened at $time — face not recognised',
        notificationLayout: NotificationLayout.Default,
        category: NotificationCategory.Alarm,
        wakeUpScreen: true,
        autoDismissible: false,
        payload: {'packageName': pkg},
      ),
      actionButtons: [
        NotificationActionButton(
          key: 'VERIFY_NOW',
          label: '🔒 Verify Now',
          autoDismissible: true,
        ),
      ],
    );
  }

  Future<void> _setupNotifications() async {
    await AwesomeNotifications().initialize(null, [
      NotificationChannel(
        channelKey: _alertChannel,
        channelName: 'Security Alerts',
        channelDescription: 'Unauthorized app access alerts',
        importance: NotificationImportance.High,
        defaultColor: const Color(0xFF6C63FF),
        ledColor: const Color(0xFFEF5350),
        playSound: true,
        enableVibration: true,
        criticalAlerts: true,
      ),
      NotificationChannel(
        channelKey: _statusChannel,
        channelName: 'Monitoring Status',
        channelDescription: 'Background monitoring status',
        importance: NotificationImportance.Min,
        playSound: false,
        enableVibration: false,
      ),
    ], debug: kDebugMode);

    await AwesomeNotifications().requestPermissionToSendNotifications(
      channelKey: _alertChannel,
      permissions: [
        NotificationPermission.Alert,
        NotificationPermission.Sound,
        NotificationPermission.Vibration,
        NotificationPermission.Badge,
        NotificationPermission.CriticalAlert,
      ],
    );
  }

  void _setupForegroundTask() {
    if (!Platform.isAndroid) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _statusChannel,
        channelName: 'Monitoring Status',
        channelDescription: 'Nanopanda is protecting your apps',
        channelImportance: NotificationChannelImportance.MIN,
        priority: NotificationPriority.MIN,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: false,
        allowWifiLock: false,
      ),
    );
  }

  Future<void> _startForegroundService(int count) async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Nanopanda Active',
        notificationText: 'Protecting $count apps',
      );
    } else {
      await FlutterForegroundTask.startService(
        serviceId: 1001,
        notificationTitle: 'Nanopanda Active',
        notificationText: 'Protecting $count apps',
        callback: monitoringTaskCallback,
      );
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  void _emit(MonitoringEvent e) => _events.add(e);

  String _humanName(String pkg) {
    final parts = pkg.split('.');
    final raw   = parts.isNotEmpty ? parts.last : pkg;
    if (raw.isEmpty) return pkg;
    return raw[0].toUpperCase() + raw.substring(1).toLowerCase();
  }
}