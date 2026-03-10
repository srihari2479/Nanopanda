// lib/features/face_auth/presentation/pages/face_registration_page.dart
//
// Production face-registration page — fully fixed & hardened.
//
// Flow:
//   1. Camera + MlFaceService initialise in parallel.
//   2. LivenessService: blink → head-turn (guards against photo attacks).
//   3. After liveness passes, collect _targetFrames good-quality embeddings.
//   4. FaceAuthRepository averages & L2-normalises → FaceVectorModel.
//   5. StorageService persists the vector in FlutterSecureStorage.
//   6. Navigate to /login.
//
// ── Bug-fixes vs original ────────────────────────────────────────────────────
//  • _isCapturing guard — listener sets flag atomically; frame handler checks
//    it before adding, preventing double-capture on fast callbacks.
//  • Stream stop race — stopImageStream() awaited inside the frame handler
//    with a _streamStopped flag so it is called exactly once.
//  • Dispose order — camera stream stopped before dispose() to avoid
//    "use after dispose" errors on CameraController.
//  • setState after dispose — every setState is guarded with `if (!mounted)`.
//  • Retry path — liveness reset + embeddings clear happen atomically.
//  • Progress clamped to [0,1] to avoid assert in LinearProgressIndicator.

import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../../core/providers/app_state_provider.dart';
import '../../../../core/services/camera_service.dart';
import '../../../../core/services/ml_face_service.dart';
import '../../../../core/services/liveness_service.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../theme/theme.dart';
import '../../data/repositories/face_auth_repository.dart';
import '../widgets/camera_overlay.dart';
import '../widgets/scanning_animation.dart';

class FaceRegistrationPage extends StatefulWidget {
  const FaceRegistrationPage({super.key});

  @override
  State<FaceRegistrationPage> createState() => _FaceRegistrationPageState();
}

class _FaceRegistrationPageState extends State<FaceRegistrationPage>
    with SingleTickerProviderStateMixin {
  // ── services ─────────────────────────────────────────────────────────────────
  final _cameraService   = CameraService();
  final _mlService       = MlFaceService.instance;
  final _livenessService = LivenessService();
  final _repository      = FaceAuthRepository();

  // ── animation ────────────────────────────────────────────────────────────────
  late final AnimationController _pulseController;

  // ── state ─────────────────────────────────────────────────────────────────────
  bool _isCameraReady   = false;
  bool _isMlReady       = false;
  bool _isCapturing     = false;   // collecting frames
  bool _isProcessing    = false;   // averaging + saving
  bool _isDone          = false;   // success overlay
  bool _processingFrame = false;   // frame-level re-entrancy guard
  bool _streamStopped   = false;   // ensures stopImageStream called once

  String _statusMessage = 'Initializing…';
  double _progress      = 0.0;

  final List<List<double>> _embeddings = [];
  static const int _targetFrames = 8; // more frames = more robust template

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _livenessService.addListener(_onLivenessChanged);
    Future.delayed(const Duration(milliseconds: 300), _initAll);
  }

  // ── initialisation ───────────────────────────────────────────────────────────

  Future<void> _initAll() async {
    await Future.wait([_initCamera(), _initMl()]);
  }

  Future<void> _initCamera() async {
    if (!mounted) return;
    _safeSetState(() => _statusMessage = 'Starting camera…');
    try {
      await _cameraService.initialize();
      if (!mounted) return;
      _safeSetState(() {
        _isCameraReady = true;
        _statusMessage = _isMlReady ? 'Blink your eyes slowly' : 'Loading face model…';
      });
      _startFrameStream();
    } catch (e) {
      _safeSetState(() => _statusMessage = 'Camera error: $e');
      _showError('Unable to access camera');
    }
  }

  Future<void> _initMl() async {
    if (!mounted) return;
    try {
      await _mlService.initialize();
      if (!mounted) return;
      _safeSetState(() {
        _isMlReady     = true;
        _statusMessage = _isCameraReady ? 'Blink your eyes slowly' : 'Starting camera…';
      });
    } catch (e) {
      _safeSetState(() => _statusMessage = 'ML model error: $e');
      _showError('Face model failed to load');
    }
  }

  // ── frame stream ─────────────────────────────────────────────────────────────

  void _startFrameStream() {
    _streamStopped = false;
    _cameraService.controller?.startImageStream(_onFrame);
  }

  Future<void> _stopFrameStream() async {
    if (_streamStopped) return;
    _streamStopped = true;
    try {
      await _cameraService.controller?.stopImageStream();
    } catch (_) {}
  }

  Future<void> _onFrame(CameraImage frame) async {
    if (!mounted) return;
    if (!_isMlReady || !_isCameraReady) return;
    if (_processingFrame || _isProcessing || _isDone) return;
    if (_streamStopped) return;

    _processingFrame = true;
    try {
      final sensorOrientation =
          _cameraService.controller!.description.sensorOrientation;
      final result = await _mlService.processFrame(frame, sensorOrientation);

      if (!mounted) return;

      // No face at all
      if (!result.faceFound) {
        if (!_isCapturing) {
          _safeSetState(() => _statusMessage = result.statusMessage);
        }
        return;
      }

      // ── Liveness phase ───────────────────────────────────────────────────────
      // Feed EVERY frame with a face — including bad-quality ones — so that
      // the blink (eyes closing = goodQuality false) is always observed.
      if (!_livenessService.state.isPassed) {
        _livenessService.processFrame(
          leftEye:  result.leftEyeOpenProb,
          rightEye: result.rightEyeOpenProb,
          eulerY:   result.headEulerY,
        );
        if (!result.goodQuality && !_isCapturing) {
          _safeSetState(() => _statusMessage = result.statusMessage);
        }
        return;
      }

      // ── Capture phase ────────────────────────────────────────────────────────
      if (!_isCapturing || !result.goodQuality || !result.hasEmbedding) return;

      _embeddings.add(result.embedding!);
      final captured = _embeddings.length;
      _safeSetState(() {
        _progress      = (captured / _targetFrames).clamp(0.0, 1.0);
        _statusMessage = 'Capturing… $captured/$_targetFrames';
      });

      if (captured >= _targetFrames) {
        await _stopFrameStream();
        await _finalizeRegistration();
      }
    } finally {
      _processingFrame = false;
    }
  }

  // ── liveness callback ────────────────────────────────────────────────────────

  void _onLivenessChanged() {
    if (!mounted) return;
    final ls = _livenessService.state;
    _safeSetState(() => _statusMessage = ls.instruction);

    if (ls.isPassed && !_isCapturing && !_isProcessing && !_isDone) {
      _safeSetState(() {
        _isCapturing   = true;
        _statusMessage = 'Liveness verified! Capturing face…';
      });
      HapticFeedback.mediumImpact();
    }
  }

  // ── finalise registration ────────────────────────────────────────────────────

  Future<void> _finalizeRegistration() async {
    if (!mounted) return;
    _safeSetState(() {
      _isCapturing  = false;
      _isProcessing = true;
      _statusMessage = 'Processing face data…';
      _progress      = 0.85;
    });

    try {
      final storageService = context.read<StorageService>();
      final appState       = context.read<AppStateProvider>();
      final existingUserId = await storageService.getUserId();

      final result = await _repository.registerFaceFromFrames(
        collectedEmbeddings: _embeddings,
        userId: existingUserId,
      );

      if (!mounted) return;

      if (result.isSuccess) {
        _safeSetState(() {
          _progress      = 1.0;
          _statusMessage = 'Registration successful!';
          _isProcessing  = false;
          _isDone        = true;
        });

        await storageService.saveFaceVector(result.faceVector!);
        if (result.userId != null) {
          await storageService.saveUserId(result.userId!);
        }
        await appState.setFaceRegistered(true);

        HapticFeedback.heavyImpact();
        // BUG FIX: Stop and dispose the camera BEFORE navigating to the
        // login page. If we navigate immediately, the login page tries to
        // open the same camera hardware while this page is still holding it
        // (dispose() runs asynchronously during page pop). This caused the
        // camera to silently fail on the login page — showing only the radar
        // animation with a black/empty circle instead of the camera preview.
        await _stopFrameStream();
        await _cameraService.dispose();
        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) Navigator.of(context).pushReplacementNamed('/login');
      } else {
        _safeSetState(() {
          _isProcessing  = false;
          _isCapturing   = false;
          _statusMessage = result.message;
          _progress      = 0.0;
        });
        _embeddings.clear();
        _livenessService.reset();
        _showError(result.message);
        _startFrameStream(); // retry
      }
    } catch (e) {
      _safeSetState(() {
        _isProcessing  = false;
        _isCapturing   = false;
        _statusMessage = 'Registration failed. Try again.';
        _progress      = 0.0;
      });
      _embeddings.clear();
      _livenessService.reset();
      _showError('Registration failed. Please try again.');
      _startFrameStream();
    }
  }

  // ── helpers ──────────────────────────────────────────────────────────────────

  void _safeSetState(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(msg, style: const TextStyle(color: Colors.white))),
          ],
        ),
        backgroundColor: AppTheme.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _livenessService.removeListener(_onLivenessChanged);
    _livenessService.dispose();
    // Only stop stream + dispose camera if not already done in _finalizeRegistration.
    // Calling stopImageStream on an already-disposed controller crashes on some devices.
    if (!_streamStopped) {
      _cameraService.controller?.stopImageStream().catchError((_) {});
    }
    _cameraService.dispose();
    super.dispose();
  }

  // ── UI ───────────────────────────────────────────────────────────────────────

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
              _buildLivenessIndicator(),
              _buildBottomSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(AppTheme.spacingM),
      child: Column(
        children: [
          Text(
            'Face Registration',
            style: GoogleFonts.poppins(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ).animate().fadeIn(duration: 500.ms).slideY(begin: -0.2),
          const SizedBox(height: 8),
          Text(
            'Secure your device with facial recognition',
            style: GoogleFonts.inter(fontSize: 14, color: AppTheme.textSecondary),
          ).animate().fadeIn(delay: 200.ms),
        ],
      ),
    );
  }

  Widget _buildCameraSection(Size size) {
    final camSize = size.width * 0.85;
    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: camSize,
            height: camSize * 1.2,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.radiusXL),
              boxShadow: AppTheme.glowShadow(
                _isDone ? AppTheme.success : AppTheme.primaryPurple,
                intensity: 0.2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTheme.radiusXL),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_isCameraReady && _cameraService.isReady)
                    _buildCameraPreview()
                  else
                    _buildLoadingState(),
                  CameraOverlay(
                    faceDetected: _isCameraReady && _isMlReady,
                    isScanning: _isCapturing,
                  ),
                  if (_isCapturing) const ScanningAnimation(),
                ],
              ),
            ),
          ).animate().fadeIn().scale(
            begin: const Offset(0.95, 0.95),
            duration: 600.ms,
            curve: Curves.easeOutBack,
          ),

          // Success overlay
          if (_isDone)
            Container(
              width: camSize,
              height: camSize * 1.2,
              decoration: BoxDecoration(
                color: AppTheme.success.withOpacity(0.88),
                borderRadius: BorderRadius.circular(AppTheme.radiusXL),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.check_circle_rounded, size: 80,
                      color: Colors.white),
                  const SizedBox(height: 16),
                  Text(
                    'Registered!',
                    style: GoogleFonts.poppins(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your face is securely saved',
                    style: GoogleFonts.inter(
                        fontSize: 14, color: Colors.white.withOpacity(0.85)),
                  ),
                ],
              ),
            ).animate().fadeIn().scale(),

          // Processing overlay
          if (_isProcessing && !_isDone) _buildProcessingOverlay(camSize),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    final ctrl        = _cameraService.controller!;
    final previewSize = ctrl.value.previewSize!;
    final aspectRatio = previewSize.height / previewSize.width;
    final scale       = math.max(1.0 / (1.2 * aspectRatio), 1.0);
    return Transform.scale(
      scale: scale,
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
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 50,
              height: 50,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation(AppTheme.primaryPurple),
              ),
            ).animate(onPlay: (c) => c.repeat())
                .fadeIn(duration: 300.ms)
                .then()
                .shimmer(duration: 1000.ms),
            const SizedBox(height: 16),
            Text('Loading…',
                style: GoogleFonts.inter(
                    fontSize: 14, color: AppTheme.textSecondary))
                .animate()
                .fadeIn(delay: 200.ms),
          ],
        ),
      ),
    );
  }

  Widget _buildProcessingOverlay(double size) {
    return Container(
      width: size,
      height: size * 1.2,
      decoration: BoxDecoration(
        color: AppTheme.primaryDark.withOpacity(0.95),
        borderRadius: BorderRadius.circular(AppTheme.radiusXL),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 100,
            height: 100,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 100,
                  height: 100,
                  child: CircularProgressIndicator(
                    value: _progress.clamp(0.0, 1.0),
                    strokeWidth: 6,
                    backgroundColor: AppTheme.surfaceDark,
                    valueColor: AlwaysStoppedAnimation(AppTheme.primaryPurple),
                  ),
                ),
                Text(
                  '${(_progress.clamp(0.0, 1.0) * 100).toInt()}%',
                  style: GoogleFonts.poppins(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ],
            ),
          ).animate(onPlay: (c) => c.repeat()).shimmer(duration: 1500.ms),
          const SizedBox(height: 24),
          Text(
            _statusMessage,
            style: GoogleFonts.inter(fontSize: 16, color: AppTheme.textSecondary),
          ).animate().fadeIn(),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms);
  }

  Widget _buildLivenessIndicator() {
    if (!_isCameraReady || !_isMlReady || _isDone) return const SizedBox.shrink();
    final ls = _livenessService.state;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              _livenessStepIcon(
                icon: Icons.remove_red_eye,
                done: ls.step.index > LivenessStep.waitingForBlink.index,
                active: ls.step == LivenessStep.waitingForBlink,
                label: 'Blink',
              ),
              Expanded(
                child: Divider(
                  color: ls.step.index > LivenessStep.blinkDetected.index
                      ? AppTheme.success
                      : AppTheme.surfaceDark,
                  thickness: 2,
                ),
              ),
              _livenessStepIcon(
                icon: Icons.swap_horiz,
                done: ls.step.index >= LivenessStep.passed.index,
                active: ls.step == LivenessStep.waitingForTurn ||
                    ls.step == LivenessStep.turnDetected,
                label: 'Turn',
              ),
              Expanded(
                child: Divider(
                  color: ls.step == LivenessStep.passed || _isCapturing
                      ? AppTheme.success
                      : AppTheme.surfaceDark,
                  thickness: 2,
                ),
              ),
              _livenessStepIcon(
                icon: Icons.camera_alt,
                done: _isDone,
                active: _isCapturing,
                label: 'Capture',
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (_isCapturing)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progress.clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: AppTheme.surfaceDark,
                valueColor: AlwaysStoppedAnimation(AppTheme.primaryPurple),
              ),
            ).animate().fadeIn(),
        ],
      ),
    );
  }

  Widget _livenessStepIcon({
    required IconData icon,
    required bool done,
    required bool active,
    required String label,
  }) {
    final color = done
        ? AppTheme.success
        : active
        ? AppTheme.primaryPurple
        : AppTheme.textMuted;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withOpacity(0.15),
            border: Border.all(color: color, width: active ? 2 : 1),
          ),
          child: Icon(
            done ? Icons.check_rounded : icon,
            color: color,
            size: 18,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: GoogleFonts.inter(fontSize: 10, color: color)),
      ],
    );
  }

  Widget _buildBottomSection() {
    return Container(
      padding: const EdgeInsets.all(AppTheme.spacingL),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spacingM, vertical: AppTheme.spacingS),
            decoration: AppTheme.glassDecoration(opacity: 0.05),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isDone
                      ? Icons.check_circle_rounded
                      : _isCapturing
                      ? Icons.camera_alt
                      : _isCameraReady && _isMlReady
                      ? Icons.face
                      : Icons.hourglass_top,
                  size: 18,
                  color: _isDone
                      ? AppTheme.success
                      : _isCapturing
                      ? AppTheme.primaryPurple
                      : AppTheme.textMuted,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _statusMessage,
                    style: GoogleFonts.inter(
                        fontSize: 14, color: AppTheme.textSecondary),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(delay: 300.ms),
          const SizedBox(height: AppTheme.spacingM),
          Text(
            'Your face data is encrypted and stored locally only',
            style: GoogleFonts.inter(fontSize: 12, color: AppTheme.textMuted),
            textAlign: TextAlign.center,
          ).animate().fadeIn(delay: 500.ms),
        ],
      ),
    );
  }
}