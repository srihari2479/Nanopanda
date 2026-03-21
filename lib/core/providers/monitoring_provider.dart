// lib/core/providers/monitoring_provider.dart
//
// ROOT FIX: Silent background capture — EventChannel-driven, not timer-polled.
//
// WHY THE OLD APPROACH FAILED:
//   The 2-second timer poller called _silentCapture() while MainActivity was
//   in the BACKGROUND (user had opened happyPay). Even though CameraService
//   uses the Flutter camera plugin, OEM ROMs (Tecno/Transsion etc.) block
//   op=CAMERA for any Activity that is not in the foreground.
//   Result: "Operation not started: op=CAMERA" → null photo → "camera unavailable".
//
// NEW FLOW:
//   1. BackgroundMonitorService detects watched app → writes capture request
//      to SharedPrefs → calls startActivity(MainActivity, EXTRA_SILENT_CAPTURE).
//   2. MainActivity comes to the foreground (Activity.onNewIntent fires).
//   3. MainActivity pushes {"event":"silentCaptureReady", "pkg":..., "entryTime":...}
//      on the "nanopanda/capture_events" EventChannel.
//   4. MonitoringProvider receives the event and calls _silentCapture() — NOW
//      the Activity IS in the foreground, so the camera plugin works.
//   5. After capture, writeCaptureResult is called and then
//      _returnToWatchedApp() relaunches the watched app so the user barely
//      notices the brief Nanopanda foreground flash.
//
// The 2-second backup poller is kept as a safety net for the first cold-start
// but the primary trigger is now the EventChannel push.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../models/app_info_model.dart';
import '../models/log_entry_model.dart';
import '../services/camera_service.dart';
import '../services/ml_face_service.dart';
import '../services/monitoring_service.dart';
import '../services/storage_service.dart';
import '../../features/monitoring/presentation/pages/face_overlay_page.dart';

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
  const ActiveSession({required this.packageName, required this.appName, required this.startedAt});
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

  // Track foreground/background state so we only attempt camera when visible
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
  StreamSubscription<dynamic>?         _captureEventSub;  // EventChannel listener
  Timer?                               _sessionTimer;
  Timer?                               _capturePoller;    // backup poll (2s)

  static const _screenChannel       = EventChannel('nanopanda/screen_events');
  static const _bgMonitorChannel    = MethodChannel('nanopanda/bg_monitor');
  static const _bgCaptureChannel    = MethodChannel('nanopanda/bg_capture');
  // NEW: EventChannel that Kotlin pushes "silentCaptureReady" on
  static const _captureEventChannel = EventChannel('nanopanda/capture_events');

  String? _pendingFaceImagePath;
  double? _pendingMatchScore;
  int     _pendingAttemptCount = 1;
  String? _pendingReason;

  bool _silentCapturing = false;

  // ── Getters ───────────────────────────────────────────────────────────────

  MonitoringStatus    get status        => _status;
  bool get isMonitoring                 => _status == MonitoringStatus.active;
  bool get isLoading                    => _status == MonitoringStatus.starting || _status == MonitoringStatus.stopping;
  List<AppInfoModel>  get selectedApps  => List.unmodifiable(_selectedApps);
  List<LogEntryModel> get logs          => List.unmodifiable(_logs);
  ActiveSession?      get activeSession => _activeSession;
  MonitoringStats     get stats         => _stats;
  bool                get hasPermission => _hasPermission;
  String?             get errorMessage  => _errorMessage;
  int get selectedCount                 => _selectedApps.where((a) => a.isSelected).length;

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

  // ── KEY FIX: Listen for capture events pushed by MainActivity ────────────
  //
  // MainActivity pushes {"event":"silentCaptureReady", "pkg":..., "entryTime":...}
  // on this EventChannel whenever the service detects a watched app.
  // We capture immediately because the Activity is now in the foreground.

  void _subscribeToCaptureEvents() {
    _captureEventSub?.cancel();
    _captureEventSub = _captureEventChannel
        .receiveBroadcastStream()
        .listen(_onCaptureEvent, onError: (e) {
      debugPrint('[MonitoringProvider] captureEventChannel error: $e');
    });
    debugPrint('[MonitoringProvider] capture event listener started');
  }

  void _unsubscribeCaptureEvents() {
    _captureEventSub?.cancel();
    _captureEventSub = null;
  }

  void _onCaptureEvent(dynamic event) {
    if (event is! Map) return;
    final eventName = event['event'] as String?;
    if (eventName != 'silentCaptureReady') return;

    final pkg       = event['pkg']       as String? ?? '';
    final entryTime = event['entryTime'] as int?    ?? DateTime.now().millisecondsSinceEpoch;

    debugPrint('[MonitoringProvider] silentCaptureReady event: pkg=$pkg');
    _executeSilentCapture(pkg, entryTime);
  }

  // ── Backup poller (2s) — safety net only ──────────────────────────────────
  // This handles the rare case where the EventChannel event was missed
  // (e.g. engine not yet attached when the intent arrived).

  void _startCapturePoller() {
    _capturePoller?.cancel();
    _capturePoller = Timer.periodic(const Duration(seconds: 2), (_) {
      _pollAndCapture();
    });
    debugPrint('[MonitoringProvider] capture poller started');
  }

  void _stopCapturePoller() {
    _capturePoller?.cancel();
    _capturePoller = null;
  }

  // ── App lifecycle ─────────────────────────────────────────────────────────
  // When app comes to foreground, immediately check for any pending capture
  // request that arrived while we were in the background.

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _isAppForeground;
    _isAppForeground = state == AppLifecycleState.resumed;

    if (!wasForeground && _isAppForeground && isMonitoring) {
      // Just came to foreground.
      // Only poll if NOT already capturing — a second camera open while the
      // first is still closing causes "No supported surface combination" crash.
      if (!_silentCapturing) {
        debugPrint('[MonitoringProvider] came to foreground — checking pending capture');
        _pollAndCapture();
      } else {
        debugPrint('[MonitoringProvider] came to foreground — capture in progress, skipping poll');
      }
    }
  }

  Future<void> _pollAndCapture() async {
    if (_silentCapturing) return;
    // Only capture when app is in foreground — OEM ROMs block camera otherwise
    if (!_isAppForeground) {
      debugPrint('[MonitoringProvider] skipping capture — app is in background');
      return;
    }
    try {
      final req = await _bgCaptureChannel.invokeMethod<Map?>('pollCaptureRequest');
      if (req == null) return;

      final pkg       = req['pkg'] as String;
      final entryTime = req['entryTime'] as int;
      debugPrint('[MonitoringProvider] poll found pending capture: pkg=$pkg');
      _executeSilentCapture(pkg, entryTime);
    } catch (e) {
      debugPrint('[MonitoringProvider] _pollAndCapture error: $e');
    }
  }

  // ── Silent capture execution ──────────────────────────────────────────────
  // Called either from EventChannel push (primary) or backup poll.
  // At this point MainActivity is in the foreground — camera works.

  Future<void> _executeSilentCapture(String pkg, int entryTime) async {
    if (_silentCapturing) return;
    _silentCapturing = true;
    String? photoPath;
    try {
      photoPath = await _silentCapture(pkg);
    } finally {
      _silentCapturing = false;
    }

    // Write result so the Kotlin service can save the pending log
    await _bgCaptureChannel.invokeMethod('writeCaptureResult', {
      'pkg':       pkg,
      'entryTime': entryTime,
      'photoPath': photoPath,
    });

    debugPrint('[MonitoringProvider] capture result written: $photoPath');

    // Camera is now fully released — safe to push FaceOverlay if app is
    // foreground. Give a small breathing room for camera resources to free.
    await Future.delayed(const Duration(milliseconds: 400));
    _pushOverlayAfterCapture(pkg);
  }

  /// After silent capture is done and camera is released, push FaceOverlay
  /// so the owner can verify. Only runs when app is in foreground.
  void _pushOverlayAfterCapture(String packageName) {
    if (!_isAppForeground) {
      debugPrint('[MonitoringProvider] not pushing overlay — still in background');
      return;
    }
    final nav = MonitoringService.navigatorKey?.currentState;
    if (nav == null) {
      debugPrint('[MonitoringProvider] navigator unavailable — skipping overlay push');
      return;
    }

    final appName = _resolveAppName(packageName);
    debugPrint('[MonitoringProvider] pushing overlay for $packageName after capture');

    // Tell MonitoringService so it tracks _overlayActive correctly
    MonitoringService.instance.onOverlayDismissed(packageName); // reset first
    nav.pushNamed(
      '/face-overlay',
      arguments: {
        'packageName': packageName,
        'appName':     appName,
        'detectedAt':  DateTime.now().toIso8601String(),
      },
    );
  }

  /// Opens front camera silently, captures one JPEG, saves it.
  /// Returns absolute path or null on failure.
  /// This MUST be called while the Activity is in the foreground.
  Future<String?> _silentCapture(String pkg) async {
    final cam = CameraService();
    try {
      await cam.initialize();
      if (!cam.isReady) {
        debugPrint('[MonitoringProvider] silent capture: camera not ready');
        return null;
      }

      // Let auto-exposure and AF settle
      await Future.delayed(const Duration(milliseconds: 700));

      final xfile = await cam.controller!.takePicture();
      final bytes = await xfile.readAsBytes();

      final baseDir  = await getApplicationDocumentsDirectory();
      final dir      = Directory(p.join(baseDir.path, 'face_logs'));
      if (!await dir.exists()) await dir.create(recursive: true);

      final filename = 'face_${pkg.replaceAll('.', '_')}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final file     = File(p.join(dir.path, filename));
      await file.writeAsBytes(bytes, flush: true);

      debugPrint('[MonitoringProvider] silent capture saved: ${file.path}');
      return file.path;
    } catch (e) {
      debugPrint('[MonitoringProvider] _silentCapture error: $e');
      return null;
    } finally {
      await cam.dispose();
    }
  }

  // ── Load + ML-verify pending bg logs ──────────────────────────────────────

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
        final entryTime     = DateTime.fromMillisecondsSinceEpoch((map['entryTime'] as num).toInt());
        final exitTime      = DateTime.fromMillisecondsSinceEpoch((map['exitTime'] as num).toInt());

        double? verifiedScore;
        String  detectionReason = map['detectionReason'] as String? ?? 'Background access';
        bool    keepLog = true;

        if (pendingVerify && photoPath != null) {
          final file = File(photoPath);
          if (file.existsSync()) {
            try {
              final jpeg      = await file.readAsBytes();
              final embedding = await MlFaceService.instance.extractEmbeddingFromBytes(jpeg);
              final stored    = MlFaceService.instance.cachedStoredVector;

              if (embedding != null && stored != null) {
                final score   = MlFaceService.matchPercentage(stored, embedding);
                final matched = score >= MlFaceService.matchThreshold * 100;
                verifiedScore = score;

                if (matched) {
                  keepLog = false;
                  try { file.deleteSync(); } catch (_) {}
                  debugPrint('[MonitoringProvider] OWNER verified $pkg (${score.toStringAsFixed(1)}%) — discarded');
                } else {
                  detectionReason = 'Unauthorized — ${score.toStringAsFixed(0)}% match (need ≥75%)';
                  debugPrint('[MonitoringProvider] UNAUTHORIZED $pkg (${score.toStringAsFixed(1)}%)');
                }
              } else if (embedding == null) {
                detectionReason = 'No face detected in background capture';
              }
            } catch (e) {
              debugPrint('[MonitoringProvider] ML verify error: $e');
            }
          } else {
            detectionReason = 'Background access — photo file missing';
          }
        }

        if (!keepLog) continue;

        await _storage.addLog(LogEntryModel(
          id:               map['id'] as String? ?? 'bg_${DateTime.now().millisecondsSinceEpoch}',
          appName:          map['appName'] as String? ?? pkg,
          appPackageName:   pkg,
          entryTime:        entryTime,
          exitTime:         exitTime,
          detectionReason:  detectionReason,
          isUnwantedPerson: true,
          faceImagePath:    photoPath,
          matchScore:       verifiedScore,
          attemptCount:     (map['attemptCount'] as num?)?.toInt() ?? 1,
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
    } catch (e) { debugPrint('[MonitoringProvider] startBgService: $e'); }
  }

  Future<void> _stopBgService() async {
    try { await _bgMonitorChannel.invokeMethod('stopBgService'); }
    catch (e) { debugPrint('[MonitoringProvider] stopBgService: $e'); }
  }

  // ── App selection ──────────────────────────────────────────────────────────

  void toggleApp(AppInfoModel app) {
    if (isMonitoring) return;
    final idx = _selectedApps.indexWhere((a) => a.packageName == app.packageName);
    if (idx == -1) {
      _selectedApps.add(app.copyWith(isSelected: true));
    } else {
      _selectedApps[idx] = _selectedApps[idx].copyWith(isSelected: !_selectedApps[idx].isSelected);
    }
    notifyListeners();
  }

  Future<void> saveSelectedApps() async => _storage.saveSelectedApps(_selectedApps);

  void setApps(List<AppInfoModel> apps) {
    final prev = { for (final a in _selectedApps.where((x) => x.isSelected)) a.packageName };
    _selectedApps = apps.map((a) => a.copyWith(isSelected: prev.contains(a.packageName))).toList();
    _pushAppNameMap();
    notifyListeners();
  }

  // ── Monitoring control ─────────────────────────────────────────────────────

  Future<bool> startMonitoring() async {
    if (isMonitoring || isLoading) return false;

    final watched = _selectedApps.where((a) => a.isSelected).map((a) => a.packageName).toList();
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
      _subscribeToCaptureEvents();  // KEY: listen for push from MainActivity
      _startCapturePoller();        // backup 2s poll
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

    _stopCapturePoller();
    _unsubscribeCaptureEvents();
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

  // ── Screen off → send + clear ─────────────────────────────────────────────

  Future<void> _onScreenOff() async {
    debugPrint('[MonitoringProvider] screen off → send + clear');
    _sessionTimer?.cancel();
    _sessionTimer = null;
    if (_activeSession != null) await _closeSession(reason: 'Screen turned off');
    await _sendLogsToWebhookAndClear();
  }

  Future<void> _sendLogsToWebhookAndClear() async {
    const url = 'https://johnharry.app.n8n.cloud/webhook/c979a31d-a9cc-4327-a927-ba2ce38ade3a';
    final logs = await _storage.getLogs();
    if (logs.isEmpty) return;

    try {
      await http.post(Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'sentAt': DateTime.now().toIso8601String(), 'totalLogs': logs.length,
          'logs': logs.map((l) => l.toJson()).toList()}),
      ).timeout(const Duration(seconds: 10));
      debugPrint('[MonitoringProvider] webhook sent ✓');
    } catch (e) { debugPrint('[MonitoringProvider] webhook error: $e'); }

    for (final log in logs) {
      if (log.faceImagePath != null) try { File(log.faceImagePath!).deleteSync(); } catch (_) {}
      await _storage.deleteFaceImage(log.faceImagePath);
    }
    await _storage.clearLogs();
    _logs  = [];
    _stats = MonitoringStats.empty();
    notifyListeners();
  }

  Future<void> setMonitoringEnabledFromSettings(bool enabled) async {
    if (enabled) await startMonitoring(); else await stopMonitoring();
  }

  // ── Overlay result ─────────────────────────────────────────────────────────

  Future<void> onOverlayResult(OverlayResult result) async {
    MonitoringService.instance.onOverlayDismissed(result.packageName);
    if (result.authorized) {
      _activeSession = null; _sessionTimer?.cancel(); _sessionTimer = null;
      notifyListeners(); return;
    }

    _activeSession = ActiveSession(packageName: result.packageName,
        appName: _resolveAppName(result.packageName), startedAt: result.detectedAt);
    _sessionTimer?.cancel();
    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());

    String? faceImagePath;
    if (result.faceJpeg != null) faceImagePath = await _storage.saveFaceImage(result.faceJpeg!);

    _pendingFaceImagePath = faceImagePath;
    _pendingMatchScore    = result.matchScore;
    _pendingAttemptCount  = result.attemptCount;
    _pendingReason        = _buildReason(matchScore: result.matchScore, attemptCount: result.attemptCount);
    notifyListeners();
  }

  String _buildReason({double? matchScore, required int attemptCount}) {
    if (matchScore == null) return 'No face detected — $attemptCount attempt${attemptCount > 1 ? "s" : ""}';
    return 'Face mismatch — ${matchScore.toStringAsFixed(1)}% (need ≥75%) — $attemptCount attempt${attemptCount > 1 ? "s" : ""}';
  }

  // ── Screen events ──────────────────────────────────────────────────────────

  void _subscribeToScreenEvents() {
    _screenSub?.cancel();
    _screenSub = _screenChannel.receiveBroadcastStream().listen(
          (event) { if (event == 'screen_off') _onScreenOff(); },
      onError: (e) => debugPrint('[MonitoringProvider] screen error: $e'),
    );
  }

  // ── Monitoring events ─────────────────────────────────────────────────────

  void _subscribeToEvents() {
    _eventSub?.cancel();
    _eventSub = MonitoringService.instance.events.listen(_handleEvent,
        onError: (e) => debugPrint('[MonitoringProvider] stream error: $e'));
  }

  void _handleEvent(MonitoringEvent event) {
    switch (event.type) {
      case MonitoringEventType.appClosed:   _onAppClosed(event); break;
      case MonitoringEventType.appOpened:
        if (!event.isAuthorized && _activeSession == null) {
          _activeSession = ActiveSession(packageName: event.packageName,
              appName: _resolveAppName(event.packageName), startedAt: event.timestamp);
          _pendingReason = 'Unauthorized access — face check unavailable';
          _sessionTimer?.cancel();
          _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
          notifyListeners();
        }
        break;
      case MonitoringEventType.permissionRequired:
        _status = MonitoringStatus.error; _hasPermission = false;
        _errorMessage = event.errorMessage; notifyListeners(); break;
      case MonitoringEventType.error:
        _errorMessage = event.errorMessage; notifyListeners(); break;
    }
  }

  Future<void> _onAppClosed(MonitoringEvent event) async {
    _sessionTimer?.cancel(); _sessionTimer = null;
    if (_activeSession?.packageName == event.packageName) await _closeSession(closeTime: event.timestamp);
  }

  Future<void> _closeSession({DateTime? closeTime, String? reason}) async {
    final session = _activeSession;
    if (session == null) return;

    final appModel = _selectedApps.firstWhere((a) => a.packageName == session.packageName,
        orElse: () => AppInfoModel(name: session.appName, packageName: session.packageName));

    await _storage.addLog(LogEntryModel(
      id:               'log_${DateTime.now().millisecondsSinceEpoch}',
      appName:          appModel.name,
      appPackageName:   session.packageName,
      entryTime:        session.startedAt,
      exitTime:         closeTime ?? DateTime.now(),
      detectionReason:  reason ?? _pendingReason ?? 'Unauthorized access',
      isUnwantedPerson: true,
      faceImagePath:    _pendingFaceImagePath,
      matchScore:       _pendingMatchScore,
      attemptCount:     _pendingAttemptCount,
    ));

    _pendingFaceImagePath = null; _pendingMatchScore = null;
    _pendingAttemptCount  = 1;   _pendingReason     = null;
    _logs = await _storage.getLogs();
    _logs.sort((a, b) => b.entryTime.compareTo(a.entryTime));
    _computeStats();
    _activeSession = null;
    notifyListeners();
  }

  String _resolveAppName(String pkg) => _selectedApps
      .firstWhere((a) => a.packageName == pkg,
      orElse: () => AppInfoModel(name: pkg, packageName: pkg))
      .name;

  // ── Logs ──────────────────────────────────────────────────────────────────

  Future<void> reloadLogs() async {
    _logs = await _storage.getLogs();
    _logs.sort((a, b) => b.entryTime.compareTo(a.entryTime));
    _computeStats(); notifyListeners();
  }

  Future<void> clearLogs() async {
    for (final log in _logs) {
      if (log.faceImagePath != null) try { File(log.faceImagePath!).deleteSync(); } catch (_) {}
      await _storage.deleteFaceImage(log.faceImagePath);
    }
    await _storage.clearLogs();
    _logs = []; _stats = MonitoringStats.empty(); notifyListeners();
  }

  Future<void> deleteLog(String id) async {
    final log = _logs.firstWhere((l) => l.id == id, orElse: () => LogEntryModel(
        id: id, appName: '', appPackageName: '', entryTime: DateTime.now(),
        exitTime: DateTime.now(), detectionReason: '', isUnwantedPerson: false));
    if (log.faceImagePath != null) try { File(log.faceImagePath!).deleteSync(); } catch (_) {}
    await _storage.deleteFaceImage(log.faceImagePath);
    _logs.removeWhere((l) => l.id == id);
    await _storage.saveLogs(_logs); _computeStats(); notifyListeners();
  }

  // ── Permission ────────────────────────────────────────────────────────────

  Future<void> refreshPermissionStatus() async {
    _hasPermission = await MonitoringService.instance.checkUsageStatsPermission();
    if (_hasPermission && _status == MonitoringStatus.error) {
      _status = MonitoringStatus.idle; _errorMessage = null;
    }
    notifyListeners();
  }

  Future<void> openUsageAccessSettings() async =>
      MonitoringService.instance.openUsageAccessSettings();

  // ── Stats ─────────────────────────────────────────────────────────────────

  void _computeStats() {
    if (_logs.isEmpty) { _stats = MonitoringStats.empty(); return; }
    final todayStart = DateTime.now().let((n) => DateTime(n.year, n.month, n.day));
    int todayAlerts = 0;
    final alertsByApp = <String, int>{};
    final durationByApp = <String, int>{};
    for (final log in _logs) {
      if (!log.isUnwantedPerson) continue;
      if (log.entryTime.isAfter(todayStart)) todayAlerts++;
      alertsByApp[log.appName]   = (alertsByApp[log.appName]   ?? 0) + 1;
      durationByApp[log.appName] = (durationByApp[log.appName] ?? 0) + log.durationInSeconds;
    }
    _stats = MonitoringStats(
      totalAlerts:           _logs.where((l) => l.isUnwantedPerson).length,
      todayAlerts:           todayAlerts,
      mostTargetedApp:       alertsByApp.isEmpty ? '—'
          : alertsByApp.entries.reduce((a, b) => a.value > b.value ? a : b).key,
      alertsByApp:           alertsByApp,
      durationByApp:         durationByApp,
      totalUnauthorizedTime: Duration(seconds: durationByApp.values.fold(0, (s, v) => s + v)),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventSub?.cancel(); _screenSub?.cancel();
    _captureEventSub?.cancel();
    _sessionTimer?.cancel(); _capturePoller?.cancel();
    super.dispose();
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T) block) => block(this);
}