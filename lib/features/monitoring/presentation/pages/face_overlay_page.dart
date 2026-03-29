// lib/features/monitoring/presentation/pages/face_overlay_page.dart
//
// Full-screen overlay shown when a protected app is detected open.
//
// ── HOW IT WORKS ─────────────────────────────────────────────────────────────
//
//   1. MonitoringService detects a watched app in foreground.
//   2. It calls Navigator.pushNamed('/face-overlay', arguments: pkg) which
//      brings Nanopanda's Activity to the front with this page.
//   3. This page opens the front camera, runs ML Kit + FaceNet (same as login).
//   4. Results:
//        AUTHORIZED  → pop overlay → user lands back in recent apps naturally.
//        UNAUTHORIZED → saves face JPEG evidence, delivers result to provider,
//                       shows brief "Access Denied" screen, then pops.
//        NO FACE (3 attempts) → treated as unauthorized (unknown person).
//        SCREEN OFF  → cancels immediately (screen_events channel).
//
// ── CAMERA PERMISSION ────────────────────────────────────────────────────────
//   Camera permission is already granted for registration/login flows.
//   No extra request needed here.
//
// ── RESULT DELIVERY ──────────────────────────────────────────────────────────
//   Uses OverlayResult passed to MonitoringProvider via a static callback.
//   This avoids BuildContext crossing between isolates.

import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../../core/providers/monitoring_provider.dart';
import '../../../../core/services/camera_service.dart';
import '../../../../core/services/ml_face_service.dart';
import '../../../../theme/theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// OverlayResult — delivered to MonitoringProvider when overlay closes
// ─────────────────────────────────────────────────────────────────────────────

class OverlayResult {
  final String     packageName;
  final bool       authorized;
  final double?    matchScore;    // 0–100, null = no face
  final Uint8List? faceJpeg;     // null = no face captured
  final int        attemptCount;
  final DateTime   detectedAt;

  const OverlayResult({
    required this.packageName,
    required this.authorized,
    required this.attemptCount,
    required this.detectedAt,
    this.matchScore,
    this.faceJpeg,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// FaceOverlayPage
// ─────────────────────────────────────────────────────────────────────────────

class FaceOverlayPage extends StatefulWidget {
  final String   packageName;
  final String   appName;
  final DateTime detectedAt;

  const FaceOverlayPage({
    super.key,
    required this.packageName,
    required this.appName,
    required this.detectedAt,
  });

  @override
  State<FaceOverlayPage> createState() => _FaceOverlayPageState();
}

class _FaceOverlayPageState extends State<FaceOverlayPage>
    with WidgetsBindingObserver {

  static const _maxAttempts    = 5;   // good-quality frames to collect
  static const _minPassFrames  = 4;   // frames that must individually pass
  static const _cosineThresh   = 0.60; // MlFaceService.matchThreshold
  static const _resultHoldMs   = 1800;

  static const _screenChannel  = EventChannel('nanopanda/screen_events');

  final _cameraService = CameraService();

  // State
  _OverlayState _state      = _OverlayState.scanning;
  int           _goodFrames = 0;   // frames with a face + good quality
  double?       _lastScore;
  Uint8List?    _capturedJpeg;
  String        _statusMsg  = 'Look at the camera…';

  // Per-frame cosine tracking for consistency check
  final List<List<double>> _frameEmbeds  = [];
  final List<double>       _frameCosines = [];

  StreamSubscription<dynamic>?  _screenSub;
  bool                          _processingFrame = false;
  bool                          _done            = false;
  bool                          _streamStarted   = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenScreenOff();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _screenSub?.cancel();
    if (_streamStarted) {
      _cameraService.controller?.stopImageStream().catchError((_) {});
    }
    _cameraService.dispose();
    super.dispose();
  }

  // ── Screen off → cancel immediately ───────────────────────────────────────

  void _listenScreenOff() {
    _screenSub = _screenChannel.receiveBroadcastStream().listen((event) {
      if (event == 'screen_off' && !_done) {
        debugPrint('[FaceOverlay] screen off — cancelling');
        _finish(authorized: false, reason: 'screen_off');
      }
    });
  }

  // ── Camera init ────────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    try {
      await _cameraService.initialize();
      if (!mounted) return;
      setState(() {});
      _startFrameStream();
    } catch (e) {
      debugPrint('[FaceOverlay] camera init error: $e');
      if (mounted) setState(() => _statusMsg = 'Camera unavailable');
      await Future.delayed(const Duration(seconds: 2));
      _finish(authorized: false, reason: 'camera_unavailable');
    }
  }

  void _startFrameStream() {
    if (_streamStarted || _done) return;
    _streamStarted = true;
    _cameraService.controller?.startImageStream(_onFrame);
    debugPrint('[FaceOverlay] frame stream started');
  }

  Future<void> _stopFrameStream() async {
    if (!_streamStarted) return;
    _streamStarted = false;
    try {
      await _cameraService.controller?.stopImageStream();
    } catch (_) {}
  }

  // ── Frame handler (image stream) ──────────────────────────────────────────
  //
  // Uses MlFaceService.processFrame() — same pipeline as face_login_page:
  //   YUV → NV21 → ML Kit face detection → face crop → FaceNet embedding.
  // Only good-quality frontal frames (eulerY<25°, eyes open) are counted.
  //
  // Consistency check:
  //   Collect _maxAttempts good frames.
  //   Require _minPassFrames to individually pass cosine ≥ _cosineThresh.
  //   Only then declare authorized.

  Future<void> _onFrame(CameraImage frame) async {
    if (_processingFrame || _done || !_cameraService.isReady) return;
    _processingFrame = true;

    try {
      final result = await MlFaceService.instance.processFrame(
        frame,
        _cameraService.controller!.description.sensorOrientation,
      );

      if (_done) return;

      if (!result.faceFound) {
        if (mounted) setState(() => _statusMsg = 'No face — look at camera');
        return;
      }

      if (!result.goodQuality) {
        if (mounted) setState(() => _statusMsg = result.statusMessage);
        return;
      }

      if (!result.hasEmbedding || result.embedding == null) return;

      _goodFrames++;

      // Capture first JPEG as evidence (take picture once)
      if (_capturedJpeg == null) {
        try {
          final xfile = await _cameraService.controller!.takePicture();
          _capturedJpeg = await xfile.readAsBytes();
        } catch (_) {}
      }

      final stored = MlFaceService.instance.cachedStoredVector;
      if (stored == null) {
        _finish(authorized: true, reason: 'no_stored_vector');
        return;
      }

      final cosine = MlFaceService.cosineSimilarity(stored, result.embedding!);
      final score  = MlFaceService.matchPercentage(stored, result.embedding!);
      _frameEmbeds.add(result.embedding!);
      _frameCosines.add(cosine);
      _lastScore = score;

      final passing = _frameCosines.where((c) => c >= _cosineThresh).length;

      debugPrint('[FaceOverlay] frame $_goodFrames — '
          'cosine=${cosine.toStringAsFixed(3)} '
          'score=${score.toStringAsFixed(1)}% passing=$passing');

      if (mounted) {
        setState(() => _statusMsg =
        'Scanning… $_goodFrames/$_maxAttempts  ✓$passing');
      }

      if (_goodFrames >= _maxAttempts) {
        await _stopFrameStream();
        _evaluateResult();
      }
    } catch (e) {
      debugPrint('[FaceOverlay] _onFrame error: $e');
    } finally {
      _processingFrame = false;
    }
  }

  void _evaluateResult() {
    final passing = _frameCosines.where((c) => c >= _cosineThresh).length;

    debugPrint('[FaceOverlay] evaluation: passing=$passing/$_maxAttempts '
        'need=$_minPassFrames');

    if (passing >= _minPassFrames) {
      _finish(authorized: true, reason: 'match');
    } else {
      _finish(authorized: false, reason: 'mismatch');
    }
  }

  Future<void> _finish({
    required bool   authorized,
    required String reason,
  }) async {
    if (_done) return;
    _done = true;
    await _stopFrameStream();

    if (mounted) {
      setState(() {
        _state = authorized ? _OverlayState.authorized : _OverlayState.denied;
      });
    }

    final result = OverlayResult(
      packageName:  widget.packageName,
      authorized:   authorized,
      matchScore:   _lastScore,
      faceJpeg:     authorized ? null : _capturedJpeg,
      attemptCount: _goodFrames.clamp(1, _maxAttempts),
      detectedAt:   widget.detectedAt,
    );

    if (mounted) {
      context.read<MonitoringProvider>().onOverlayResult(result);
    }

    await Future.delayed(const Duration(milliseconds: _resultHoldMs));
    if (mounted) Navigator.of(context).pop();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => false, // prevent back-swipe
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Camera preview
            if (_cameraService.isReady && _state == _OverlayState.scanning)
              _CameraPreviewLayer(controller: _cameraService.controller!),

            // Dark overlay
            Container(color: Colors.black.withOpacity(0.55)),

            // Content
            _buildContent(),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    switch (_state) {
      case _OverlayState.scanning:
        return _ScanningView(
          appName:    widget.appName,
          statusMsg:  _statusMsg,
          attempts:   _goodFrames,
          maxAttempts: _maxAttempts,
        );
      case _OverlayState.authorized:
        return const _ResultView(authorized: true);
      case _OverlayState.denied:
        return _ResultView(
          authorized: false,
          score:      _lastScore,
        );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// State enum
// ─────────────────────────────────────────────────────────────────────────────

enum _OverlayState { scanning, authorized, denied }

// ─────────────────────────────────────────────────────────────────────────────
// Camera preview layer (mirrored for front cam)
// ─────────────────────────────────────────────────────────────────────────────

class _CameraPreviewLayer extends StatelessWidget {
  final CameraController controller;
  const _CameraPreviewLayer({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()..scale(-1.0, 1.0), // mirror
      child: CameraPreview(controller),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Scanning view
// ─────────────────────────────────────────────────────────────────────────────

class _ScanningView extends StatelessWidget {
  final String appName;
  final String statusMsg;
  final int    attempts;
  final int    maxAttempts;

  const _ScanningView({
    required this.appName,
    required this.statusMsg,
    required this.attempts,
    required this.maxAttempts,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          const Spacer(),

          // Face scan ring
          _FaceScanRing(progress: attempts / maxAttempts),

          const SizedBox(height: 32),

          // App name
          Text(
            appName,
            style: GoogleFonts.poppins(
              fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Face verification required',
            style: GoogleFonts.inter(fontSize: 14, color: Colors.white70),
          ),

          const SizedBox(height: 24),

          // Status
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 40),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color:        Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(24),
              border:       Border.all(color: Colors.white24),
            ),
            child: Text(
              statusMsg,
              style: GoogleFonts.inter(fontSize: 13, color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ),

          const SizedBox(height: 16),

          // Attempt dots
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(maxAttempts, (i) => Container(
              width: 8, height: 8,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < attempts
                    ? AppTheme.primaryPurple
                    : Colors.white24,
              ),
            )),
          ),

          const Spacer(),

          Padding(
            padding: const EdgeInsets.only(bottom: 32),
            child: Text(
              'Look directly at the camera',
              style: GoogleFonts.inter(fontSize: 12, color: Colors.white38),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Face scan ring (animated)
// ─────────────────────────────────────────────────────────────────────────────

class _FaceScanRing extends StatefulWidget {
  final double progress;
  const _FaceScanRing({required this.progress});

  @override
  State<_FaceScanRing> createState() => _FaceScanRingState();
}

class _FaceScanRingState extends State<_FaceScanRing>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  late Animation<double>   _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.9, end: 1.05).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (_, __) => Transform.scale(
        scale: _pulseAnim.value,
        child: Container(
          width:  160,
          height: 160,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: AppTheme.primaryPurple.withOpacity(0.7),
              width: 3,
            ),
            boxShadow: [
              BoxShadow(
                color:      AppTheme.primaryPurple.withOpacity(0.3),
                blurRadius: 24,
                spreadRadius: 4,
              ),
            ],
          ),
          child: const Icon(
            Icons.face_retouching_natural,
            size:  72,
            color: Colors.white70,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Result view
// ─────────────────────────────────────────────────────────────────────────────

class _ResultView extends StatelessWidget {
  final bool   authorized;
  final double? score;

  const _ResultView({required this.authorized, this.score});

  @override
  Widget build(BuildContext context) {
    final color = authorized ? AppTheme.success : AppTheme.error;
    final icon  = authorized ? Icons.check_circle_outline : Icons.block;
    final label = authorized ? 'Identity Verified' : 'Access Denied';
    final sub   = authorized
        ? 'Welcome back!'
        : score != null
        ? 'Match: ${score!.toStringAsFixed(0)}% — not your face'
        : 'No face detected — logged as unknown';

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width:  100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withOpacity(0.15),
              border: Border.all(color: color, width: 2),
            ),
            child: Icon(icon, color: color, size: 48),
          ),
          const SizedBox(height: 20),
          Text(label, style: GoogleFonts.poppins(
            fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white,
          )),
          const SizedBox(height: 8),
          Text(sub, style: GoogleFonts.inter(
            fontSize: 14, color: Colors.white60,
          ), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}