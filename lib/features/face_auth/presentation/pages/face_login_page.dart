// lib/features/face_auth/presentation/pages/face_login_page.dart
//
// Production face login — real camera, zero mocks.
//
// FLOW:
//   1. Camera + ML Kit init in parallel.
//      600 ms camera delay: Android needs time to release hardware after
//      registration page disposes it. Too short → silent camera init fail.
//   2. Collect 2 good-quality embeddings (fast but noise-resistant).
//   3. Average → L2-normalise → cosine similarity vs stored vector.
//   4. Score ≥ threshold → navigate to /dashboard.
//      Score < threshold → shake + auto-retry after 800 ms.
//
// BUG FIXES vs earlier version:
//   • _startStreamOnceReady — stream starts exactly once when BOTH ready.
//   • Camera retry path (1 s extra delay) for slow hardware release.
//   • Shake animation on mismatch for better UX feedback.
//   • Match percentage displayed on success overlay.
//   • _streamStopped guard prevents double stopImageStream on retry.

import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../../core/models/face_vector_model.dart';
import '../../../../core/providers/app_state_provider.dart';
import '../../../../core/services/camera_service.dart';
import '../../../../core/services/ml_face_service.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../theme/theme.dart';
import '../../data/repositories/face_auth_repository.dart';
import '../widgets/camera_overlay.dart';
import '../widgets/scanning_animation.dart';

class FaceLoginPage extends StatefulWidget {
  const FaceLoginPage({super.key});

  @override
  State<FaceLoginPage> createState() => _FaceLoginPageState();
}

class _FaceLoginPageState extends State<FaceLoginPage>
    with TickerProviderStateMixin {

  // ── Services ─────────────────────────────────────────────────────────────────
  final _cameraService = CameraService();
  final _mlService     = MlFaceService.instance;
  final _repository    = FaceAuthRepository();

  late final AnimationController _pulseController;
  late final AnimationController _shakeController;

  // ── Init flags ────────────────────────────────────────────────────────────────
  bool _isCameraReady  = false;
  bool _isMlReady      = false;
  bool _streamStarted  = false;
  bool _streamStopped  = false;

  // ── Flow state ────────────────────────────────────────────────────────────────
  bool    _isScanning          = false;
  bool    _isVerifying         = false;
  bool    _verificationFailed  = false;
  bool    _isDone              = false;
  bool    _processingFrame     = false;

  String  _statusMessage       = 'Initializing…';
  double? _matchPercentage;

  // 2 frames: fast + noise-resistant for unlock flow
  static const int _verifyFrames = 2;
  final List<List<double>> _embeds = [];

  // ── Lifecycle ─────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _shakeController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 400),
    );
    Future.delayed(const Duration(milliseconds: 100), _initAll);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _shakeController.dispose();
    if (!_streamStopped) {
      _cameraService.controller?.stopImageStream().catchError((_) {});
    }
    _cameraService.dispose();
    super.dispose();
  }

  // ── Init ──────────────────────────────────────────────────────────────────────

  Future<void> _initAll() async {
    await Future.wait([_initCamera(), _initMl()]);
  }

  Future<void> _initCamera() async {
    try {
      // Android needs 600 ms to fully release camera after registration page
      // disposes it. A shorter delay causes a silent init failure.
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;

      await _cameraService.initialize();
      if (!mounted) return;
      _isCameraReady = true;
      _safeSetState(() {});
      _startStreamOnceReady();
    } catch (e) {
      debugPrint('[FaceLogin] camera init error: $e — retrying in 1 s');
      await Future.delayed(const Duration(milliseconds: 1000));
      if (!mounted) return;
      try {
        await _cameraService.initialize();
        if (!mounted) return;
        _isCameraReady = true;
        _safeSetState(() {});
        _startStreamOnceReady();
      } catch (e2) {
        debugPrint('[FaceLogin] camera retry failed: $e2');
        _safeSetState(() => _statusMessage = 'Camera error — please restart app');
      }
    }
  }

  Future<void> _initMl() async {
    try {
      await _mlService.initialize();
      if (!mounted) return;
      _isMlReady = true;
      _safeSetState(() {});
      _startStreamOnceReady();
    } catch (e) {
      debugPrint('[FaceLogin] ML init error: $e');
      _safeSetState(() => _statusMessage = 'Model error');
    }
  }

  /// Start exactly once — only when BOTH camera AND ML are ready.
  void _startStreamOnceReady() {
    if (!_isCameraReady || !_isMlReady) return;
    if (_streamStarted || _streamStopped) return;
    _streamStarted = true;
    _safeSetState(() {
      _isScanning    = true;
      _statusMessage = 'Look at the camera…';
    });
    _cameraService.controller?.startImageStream(_onFrame);
    debugPrint('[FaceLogin] frame stream started');
  }

  // ── Frame stream ──────────────────────────────────────────────────────────────

  /// Restarts the stream after a failed verification retry.
  void _restartFrameStream() {
    _streamStopped = false;
    try {
      _cameraService.controller?.startImageStream(_onFrame);
    } catch (_) {
      // Stream may still be running — stop first, then restart
      _cameraService.controller?.stopImageStream().then((_) {
        if (!_streamStopped && mounted) {
          _cameraService.controller?.startImageStream(_onFrame);
        }
      }).catchError((_) {});
    }
  }

  Future<void> _stopFrameStream() async {
    if (_streamStopped) return;
    _streamStopped = true;
    try { await _cameraService.controller?.stopImageStream(); } catch (_) {}
  }

  Future<void> _onFrame(CameraImage frame) async {
    if (!mounted || !_isScanning) return;
    if (!_isMlReady || !_isCameraReady) return;
    if (_processingFrame || _isVerifying || _isDone || _streamStopped) return;

    _processingFrame = true;
    try {
      final result = await _mlService.processFrame(
        frame,
        _cameraService.controller!.description.sensorOrientation,
      );
      if (!mounted || _isDone || _streamStopped) return;

      if (!result.faceFound || !result.goodQuality || !result.hasEmbedding) {
        _safeSetState(() => _statusMessage =
        result.faceFound ? 'Hold still…' : 'Look at the camera…');
        return;
      }

      _embeds.add(result.embedding!);
      _safeSetState(() =>
      _statusMessage = 'Scanning… ${_embeds.length}/$_verifyFrames');

      if (_embeds.length >= _verifyFrames) {
        _isScanning = false;
        await _stopFrameStream();
        await _runVerification();
      }
    } finally {
      _processingFrame = false;
    }
  }

  // ── Verification ──────────────────────────────────────────────────────────────

  Future<void> _runVerification() async {
    if (!mounted || _isVerifying) return;
    _safeSetState(() { _isVerifying = true; _statusMessage = 'Verifying…'; });

    try {
      final storedVector = await context.read<StorageService>().getFaceVector();
      if (storedVector == null) {
        _handleFailure('No registered face found');
        return;
      }

      // Average collected embeddings then L2-normalise
      final dim      = _embeds.first.length;
      final averaged = List<double>.filled(dim, 0.0);
      for (final e in _embeds) {
        for (int i = 0; i < dim; i++) averaged[i] += e[i];
      }
      for (int i = 0; i < dim; i++) averaged[i] /= _embeds.length;

      double norm = 0;
      for (final v in averaged) norm += v * v;
      norm = math.sqrt(norm);
      final normalised =
      norm < 1e-10 ? averaged : averaged.map((v) => v / norm).toList();

      final liveVector = FaceVectorModel(
        id:        'live_${DateTime.now().millisecondsSinceEpoch}',
        vector:    normalised,
        createdAt: DateTime.now(),
        userId:    storedVector.userId,
      );

      final result = await _repository.verifyFace(
        liveVector:   liveVector,
        storedVector: storedVector,
      );

      if (!mounted) return;

      if (result.isMatch) {
        _safeSetState(() {
          _isVerifying      = false;
          _isDone           = true;
          _matchPercentage  = result.matchPercentage;
          _statusMessage    = 'Verified! Unlocking…';
        });
        HapticFeedback.heavyImpact();

        await context.read<AppStateProvider>().setAuthenticated(true);
        await Future.delayed(const Duration(milliseconds: 1200));
        if (mounted) Navigator.of(context).pushReplacementNamed('/dashboard');
      } else {
        _handleFailure(result.message);
      }
    } catch (e) {
      debugPrint('[FaceLogin] verification error: $e');
      _handleFailure('Verification error — try again');
    }
  }

  void _handleFailure(String msg) {
    if (!mounted) return;
    _safeSetState(() {
      _isVerifying         = false;
      _verificationFailed  = true;
      _statusMessage       = msg;
    });
    HapticFeedback.mediumImpact();
    _shakeController.forward(from: 0.0);

    // Auto-retry after 800 ms
    Future.delayed(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      _embeds.clear();
      _safeSetState(() {
        _verificationFailed = false;
        _isScanning         = true;
        _statusMessage      = 'Look at the camera…';
      });
      _streamStopped = false;
      _restartFrameStream();
    });
  }

  void _safeSetState(VoidCallback fn) { if (mounted) setState(fn); }

  // ── BUILD ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(child: _buildCameraSection(size)),
              _buildStatus(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Widgets ───────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: AppTheme.primaryGradient,
              shape: BoxShape.circle,
              boxShadow: AppTheme.glowShadow(AppTheme.primaryPurple, intensity: 0.35),
            ),
            child: const Icon(Icons.shield, color: Colors.white, size: 30),
          ).animate().fadeIn().scale(delay: 50.ms),
          const SizedBox(height: 14),
          Text('Welcome Back',
              style: GoogleFonts.poppins(
                  fontSize: 24, fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary))
              .animate().fadeIn(delay: 100.ms),
          const SizedBox(height: 4),
          Text('Look at the camera to unlock',
              style: GoogleFonts.inter(fontSize: 14, color: AppTheme.textSecondary))
              .animate().fadeIn(delay: 150.ms),
        ],
      ),
    );
  }

  Widget _buildCameraSection(Size size) {
    final camSize = size.width - 48;
    return Center(
      child: AnimatedBuilder(
        animation: _shakeController,
        builder: (context, child) {
          final t      = _shakeController.value;
          final offset = t < 0.5 ? (t * 24) - 6.0 : ((1 - t) * 24) - 6.0;
          return Transform.translate(
            offset: Offset(_verificationFailed ? offset : 0, 0),
            child: child,
          );
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Glow ring — colour changes per state
            Container(
              width: camSize + 8, height: camSize + 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: _verificationFailed
                    ? AppTheme.glowShadow(AppTheme.error,   intensity: 0.5)
                    : _isDone
                    ? AppTheme.glowShadow(AppTheme.success, intensity: 0.5)
                    : AppTheme.glowShadow(AppTheme.primaryPurple, intensity: 0.25),
              ),
            ),

            // Camera circle
            SizedBox(
              width: camSize, height: camSize,
              child: ClipOval(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_isCameraReady && _cameraService.isReady)
                      _buildCameraPreview()
                    else
                      _buildLoadingState(),
                    CameraOverlay(
                      faceDetected: _isCameraReady && _isMlReady,
                      isScanning:   _isScanning || _isVerifying,
                      isCircular:   true,
                      showError:    _verificationFailed,
                    ),
                    if ((_isScanning || _isVerifying) && !_isDone)
                      const ScanningAnimation(isCircular: true),
                  ],
                ),
              ),
            ),

            // Frame-collection progress arc (outside the circle)
            if (_isScanning && _embeds.isNotEmpty && !_isDone)
              SizedBox(
                width: camSize + 10, height: camSize + 10,
                child: CircularProgressIndicator(
                  value: (_embeds.length / _verifyFrames).clamp(0.0, 1.0),
                  strokeWidth: 4,
                  backgroundColor: AppTheme.surfaceDark.withOpacity(0.3),
                  valueColor: AlwaysStoppedAnimation(AppTheme.primaryPurple),
                ),
              ),

            // Success overlay
            if (_isDone)
              SizedBox(
                width: camSize, height: camSize,
                child: ClipOval(
                  child: Container(
                    color: AppTheme.success.withOpacity(0.92),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.check_circle_rounded,
                            size: 80, color: Colors.white),
                        const SizedBox(height: 12),
                        Text('${_matchPercentage!.toStringAsFixed(1)}%',
                            style: GoogleFonts.poppins(
                                fontSize: 34, fontWeight: FontWeight.bold,
                                color: Colors.white)),
                        Text('VERIFIED',
                            style: GoogleFonts.inter(
                                fontSize: 15, fontWeight: FontWeight.w600,
                                color: Colors.white.withOpacity(0.9),
                                letterSpacing: 2.5)),
                      ],
                    ),
                  ),
                ),
              ).animate().fadeIn().scale(),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    final ctrl        = _cameraService.controller!;
    final previewSize = ctrl.value.previewSize!;
    final aspectRatio = previewSize.height / previewSize.width;
    return Transform.scale(
      scale: 1.8,
      child: Center(
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: CameraPreview(ctrl),
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return Container(
      color: AppTheme.surfaceDark,
      child: Center(
        child: CircularProgressIndicator(
          strokeWidth: 3,
          valueColor: AlwaysStoppedAnimation(AppTheme.primaryPurple),
        ).animate(onPlay: (c) => c.repeat()).fadeIn(),
      ),
    );
  }

  Widget _buildStatus() {
    final Color iconColor = _verificationFailed
        ? AppTheme.error
        : _isDone ? AppTheme.success : AppTheme.primaryPurple;

    final IconData icon = _verificationFailed
        ? Icons.error_outline_rounded
        : _isDone ? Icons.verified_user : Icons.face_rounded;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: AppTheme.glassDecoration(
          opacity: _verificationFailed ? 0.12 : 0.06,
          borderColor: _verificationFailed
              ? AppTheme.error.withOpacity(0.4)
              : _isDone
              ? AppTheme.success.withOpacity(0.4)
              : null,
        ),
        child: Row(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(icon,
                  key: ValueKey(iconColor), color: iconColor, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(_statusMessage,
                    key: ValueKey(_statusMessage),
                    style: GoogleFonts.inter(
                        fontSize: 14, fontWeight: FontWeight.w500,
                        color: AppTheme.textPrimary)),
              ),
            ),
            // Scanning dots shown while collecting frames
            if (_isScanning && !_isDone)
              Row(
                children: List.generate(3, (i) =>
                    Container(
                      margin: const EdgeInsets.only(left: 4),
                      width: 6, height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppTheme.primaryPurple.withOpacity(0.7),
                      ),
                    ).animate(onPlay: (c) => c.repeat())
                        .fadeIn(delay: Duration(milliseconds: i * 200))
                        .then()
                        .fadeOut(),
                ),
              ),
          ],
        ),
      ).animate().fadeIn(delay: 200.ms),
    );
  }
}