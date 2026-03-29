// lib/features/face_auth/presentation/pages/face_registration_page.dart
//
// Production face registration — real camera, zero mocks.
//
// FLOW:
//   1. Camera + ML Kit init in parallel (300 ms startup delay).
//   2. Liveness:  Blink  → sliding window 3/5 frames, threshold 0.45.
//                Turn   → 15°, 2 consecutive frames above threshold.
//   3. Capture:   8 good-quality frames → average → L2-normalise → save.
//   4. Dispose camera fully before navigating to /login (hardware release).
//
// BUG FIXES vs earlier version:
//   • Stream starts ONLY when BOTH camera AND ML are ready (_startStreamOnceReady).
//   • Liveness instruction shown instead of ML Kit "Open your eyes" during blink.
//   • Blink progress ring gives real-time feedback (sliding window progress).
//   • _resetAndRetry properly guards stream restart (no double-start PlatformException).
//   • Camera disposed before Navigator.pushReplacementNamed → login gets hardware.

import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../../core/providers/app_state_provider.dart';
import '../../../../core/services/camera_service.dart';
import '../../../../core/services/liveness_service.dart';
import '../../../../core/services/ml_face_service.dart';
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

  // ── Services ─────────────────────────────────────────────────────────────────
  final _cameraService   = CameraService();
  final _mlService       = MlFaceService.instance;
  final _livenessService = LivenessService();
  final _repository      = FaceAuthRepository();

  late final AnimationController _pulseController;

  // ── Init flags ────────────────────────────────────────────────────────────────
  bool _isCameraReady = false;
  bool _isMlReady     = false;
  bool _streamStarted = false;
  bool _streamStopped = false;

  // ── Flow state ────────────────────────────────────────────────────────────────
  bool   _isCapturing     = false;
  bool   _isProcessing    = false;
  bool   _isDone          = false;
  bool   _processingFrame = false;

  String _statusMessage   = 'Initializing…';
  String _subMessage      = '';
  double _captureProgress = 0.0;

  final List<List<double>> _embeddings = [];
  static const int _targetFrames = 8;

  // ── Lifecycle ─────────────────────────────────────────────────────────────────

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

  @override
  void dispose() {
    _pulseController.dispose();
    _livenessService.removeListener(_onLivenessChanged);
    _livenessService.dispose();
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
    if (!mounted) return;
    try {
      await _cameraService.initialize();
      if (!mounted) return;
      _isCameraReady = true;
      _safeSetState(() {});
      _startStreamOnceReady();
    } catch (e) {
      debugPrint('[FaceReg] camera error: $e');
      _safeSetState(() => _statusMessage = 'Camera error — please retry');
      _showError('Unable to access camera');
    }
  }

  Future<void> _initMl() async {
    if (!mounted) return;
    try {
      await _mlService.initialize();
      if (!mounted) return;
      _isMlReady = true;
      _safeSetState(() {});
      _startStreamOnceReady();
    } catch (e) {
      debugPrint('[FaceReg] ML error: $e');
      _safeSetState(() => _statusMessage = 'Model failed to load');
      _showError('Face model failed to load');
    }
  }

  /// Start exactly once — only when BOTH camera AND ML are ready.
  void _startStreamOnceReady() {
    if (!_isCameraReady || !_isMlReady) return;
    if (_streamStarted || _streamStopped) return;
    _streamStarted = true;
    _safeSetState(() {
      _statusMessage = _livenessService.state.instruction;
      _subMessage    = _livenessService.state.subInstruction;
    });
    _cameraService.controller?.startImageStream(_onFrame);
    debugPrint('[FaceReg] frame stream started');
  }

  Future<void> _stopStream() async {
    if (_streamStopped) return;
    _streamStopped = true;
    try { await _cameraService.controller?.stopImageStream(); } catch (_) {}
  }

  // ── Frame handler ─────────────────────────────────────────────────────────────

  Future<void> _onFrame(CameraImage frame) async {
    if (!mounted || !_isMlReady || !_isCameraReady) return;
    if (_processingFrame || _isProcessing || _isDone || _streamStopped) return;

    _processingFrame = true;
    try {
      final result = await _mlService.processFrame(
        frame,
        _cameraService.controller!.description.sensorOrientation,
      );
      if (!mounted || _isDone || _streamStopped) return;

      // No face
      if (!result.faceFound) {
        if (!_isCapturing && !_livenessService.state.isPassed) {
          _safeSetState(() {
            _statusMessage = _livenessService.state.instruction;
            _subMessage    = 'No face detected — look at camera';
          });
        }
        return;
      }

      // Liveness phase — feed every frame (even low-quality / eyes-closed).
      // NEVER show ML Kit's "Open your eyes" here; user wants eyes closed to blink.
      if (!_livenessService.state.isPassed) {
        _livenessService.processFrame(
          leftEye:  result.leftEyeOpenProb,
          rightEye: result.rightEyeOpenProb,
          eulerY:   result.headEulerY,
        );
        return; // UI driven by _onLivenessChanged
      }

      // Capture phase — good frames only
      if (!_isCapturing) return;
      if (!result.goodQuality || !result.hasEmbedding) return;

      _embeddings.add(result.embedding!);
      final n = _embeddings.length;
      _safeSetState(() {
        _captureProgress = (n / _targetFrames).clamp(0.0, 1.0);
        _statusMessage   = 'Hold still… $n/$_targetFrames';
        _subMessage      = 'Keep looking at the camera';
      });

      if (n >= _targetFrames) {
        await _stopStream();
        await _finalize();
      }
    } finally {
      _processingFrame = false;
    }
  }

  // ── Liveness listener ─────────────────────────────────────────────────────────

  void _onLivenessChanged() {
    if (!mounted) return;
    final ls = _livenessService.state;

    if (ls.isPassed && !_isCapturing && !_isProcessing && !_isDone) {
      _safeSetState(() {
        _isCapturing   = true;
        _statusMessage = 'Face verified! Hold still…';
        _subMessage    = 'Capturing your face…';
      });
      HapticFeedback.mediumImpact();
      return;
    }

    if (!_isCapturing && !_isDone) {
      _safeSetState(() {
        _statusMessage = ls.instruction;
        _subMessage    = ls.subInstruction;
      });
    }
  }

  // ── Finalize ──────────────────────────────────────────────────────────────────

  Future<void> _finalize() async {
    if (!mounted) return;
    _safeSetState(() {
      _isCapturing     = false;
      _isProcessing    = true;
      _statusMessage   = 'Processing face data…';
      _subMessage      = 'This takes just a moment';
      _captureProgress = 0.9;
    });

    try {
      final storage        = context.read<StorageService>();
      final appState       = context.read<AppStateProvider>();
      final existingUserId = await storage.getUserId();

      final result = await _repository.registerFaceFromFrames(
        collectedEmbeddings: _embeddings,
        userId: existingUserId,
      );

      if (!mounted) return;

      if (result.isSuccess) {
        _safeSetState(() {
          _captureProgress = 1.0;
          _isProcessing    = false;
          _isDone          = true;
          _statusMessage   = 'Registered!';
          _subMessage      = 'Your face is securely saved';
        });
        await storage.saveFaceVector(result.faceVector!);
        if (result.userId != null) await storage.saveUserId(result.userId!);
        // Mark that this vector was saved with correct float32 preprocessing.
        // face_login_page checks this on startup and forces re-registration
        // if the stored vector is stale (old uint8 preprocessing).
        await storage.saveEmbeddingVersion(StorageService.currentEmbeddingVersion);
        await appState.setFaceRegistered(true);
        HapticFeedback.heavyImpact();

        // Fully release camera BEFORE navigating — login page needs hardware
        await _stopStream();
        await _cameraService.dispose();
        await Future.delayed(const Duration(milliseconds: 900));
        if (mounted) Navigator.of(context).pushReplacementNamed('/login');
      } else {
        _resetAndRetry(result.message);
      }
    } catch (e) {
      debugPrint('[FaceReg] finalize error: $e');
      _resetAndRetry('Registration failed — try again');
    }
  }

  void _resetAndRetry(String msg) {
    _embeddings.clear();
    _livenessService.reset();
    _streamStopped = false;
    _safeSetState(() {
      _isProcessing    = false;
      _isCapturing     = false;
      _captureProgress = 0.0;
      _statusMessage   = _livenessService.state.instruction;
      _subMessage      = _livenessService.state.subInstruction;
    });
    _showError(msg);
    try {
      _cameraService.controller?.startImageStream(_onFrame);
    } catch (e) {
      debugPrint('[FaceReg] stream restart after retry failed: $e');
    }
  }

  void _safeSetState(VoidCallback fn) { if (mounted) setState(fn); }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(msg, style: const TextStyle(color: Colors.white))),
      ]),
      backgroundColor: AppTheme.error,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
      duration: const Duration(seconds: 3),
    ));
  }

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
              _buildLivenessProgress(),
              _buildStatusCard(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Widgets ───────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        children: [
          Text('Face Registration',
              style: GoogleFonts.poppins(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary))
              .animate().fadeIn(duration: 400.ms).slideY(begin: -0.2),
          const SizedBox(height: 4),
          Text('Secure your device with facial recognition',
              style: GoogleFonts.inter(fontSize: 13, color: AppTheme.textSecondary))
              .animate().fadeIn(delay: 150.ms),
        ],
      ),
    );
  }

  Widget _buildCameraSection(Size size) {
    final camW = size.width * 0.85;
    final camH = camW * 1.2;

    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: camW, height: camH,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.radiusXL),
              boxShadow: AppTheme.glowShadow(
                _isDone ? AppTheme.success : AppTheme.primaryPurple,
                intensity: _isDone ? 0.55 : _isCapturing ? 0.45 : 0.15,
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
                    _buildLoadingPlaceholder(),
                  CameraOverlay(
                    faceDetected: _isCameraReady && _isMlReady,
                    isScanning:   _isCapturing,
                  ),
                  if (_isCapturing && !_isDone) const ScanningAnimation(),
                  if (!_livenessService.state.isPassed &&
                      _isCameraReady && _isMlReady && !_isDone)
                    _buildLivenessOverlay(),
                ],
              ),
            ),
          ).animate().fadeIn().scale(
            begin: const Offset(0.95, 0.95),
            duration: 500.ms,
            curve: Curves.easeOutBack,
          ),
          if (_isProcessing && !_isDone) _buildProcessingOverlay(camW, camH),
          if (_isDone)                   _buildSuccessOverlay(camW, camH),
        ],
      ),
    );
  }

  /// Blink progress badge — bottom of camera view, only during blink step.
  Widget _buildLivenessOverlay() {
    final ls = _livenessService.state;
    if (ls.step != LivenessStep.waitingForBlink) return const SizedBox.shrink();
    return Positioned(
      bottom: 16, left: 0, right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.60),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(
                  value: ls.blinkProgress,
                  strokeWidth: 3,
                  backgroundColor: Colors.white24,
                  valueColor: AlwaysStoppedAnimation(AppTheme.primaryPurple),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                ls.blinkProgress > 0.1 ? 'Keep blinking…' : 'Blink your eyes',
                style: GoogleFonts.inter(
                    fontSize: 13, color: Colors.white, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    final ctrl        = _cameraService.controller!;
    final previewSize = ctrl.value.previewSize!;
    final aspect      = previewSize.height / previewSize.width;
    final scale       = math.max(1.0 / (1.2 * aspect), 1.0);
    return Transform.scale(
      scale: scale,
      child: Center(
        child: AspectRatio(
          aspectRatio: aspect,
          child: CameraPreview(ctrl),
        ),
      ),
    );
  }

  Widget _buildLoadingPlaceholder() {
    return Container(
      color: AppTheme.surfaceDark,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 48, height: 48,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation(AppTheme.primaryPurple),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              !_isCameraReady ? 'Starting camera…'
                  : !_isMlReady   ? 'Loading face model…'
                  : 'Almost ready…',
              style: GoogleFonts.inter(fontSize: 13, color: AppTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProcessingOverlay(double w, double h) {
    return Container(
      width: w, height: h,
      decoration: BoxDecoration(
        color: AppTheme.primaryDark.withOpacity(0.96),
        borderRadius: BorderRadius.circular(AppTheme.radiusXL),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 90, height: 90,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: _captureProgress.clamp(0.0, 1.0),
                  strokeWidth: 7,
                  backgroundColor: AppTheme.surfaceDark,
                  valueColor: AlwaysStoppedAnimation(AppTheme.primaryPurple),
                ),
                Text('${(_captureProgress * 100).toInt()}%',
                    style: GoogleFonts.poppins(
                        fontSize: 20, fontWeight: FontWeight.bold,
                        color: AppTheme.textPrimary)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(_statusMessage,
              style: GoogleFonts.inter(
                  fontSize: 15, color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          Text(_subMessage,
              style: GoogleFonts.inter(fontSize: 13, color: AppTheme.textSecondary)),
        ],
      ),
    ).animate().fadeIn(duration: 250.ms);
  }

  Widget _buildSuccessOverlay(double w, double h) {
    return Container(
      width: w, height: h,
      decoration: BoxDecoration(
        color: AppTheme.success.withOpacity(0.92),
        borderRadius: BorderRadius.circular(AppTheme.radiusXL),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle_rounded, size: 80, color: Colors.white),
          const SizedBox(height: 16),
          Text('Registered!',
              style: GoogleFonts.poppins(
                  fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 8),
          Text('Your face is securely saved',
              style: GoogleFonts.inter(
                  fontSize: 14, color: Colors.white.withOpacity(0.85))),
        ],
      ),
    ).animate().fadeIn().scale();
  }

  // ── Liveness step bar ─────────────────────────────────────────────────────────

  Widget _buildLivenessProgress() {
    if (!_isCameraReady || !_isMlReady || _isDone) return const SizedBox.shrink();
    final ls = _livenessService.state;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 6),
      child: Row(
        children: [
          _step(
            icon: Icons.remove_red_eye_outlined,
            label: 'Blink',
            done: ls.step.index > LivenessStep.waitingForBlink.index,
            active: ls.step == LivenessStep.waitingForBlink,
            progress: ls.step == LivenessStep.waitingForBlink ? ls.blinkProgress : null,
          ),
          Expanded(child: AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            height: 2,
            color: ls.step.index > LivenessStep.waitingForBlink.index
                ? AppTheme.success : AppTheme.surfaceDark,
          )),
          _step(
            icon: Icons.swap_horiz_rounded,
            label: 'Turn',
            done: ls.isPassed,
            active: ls.step == LivenessStep.waitingForTurn,
          ),
          Expanded(child: AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            height: 2,
            color: ls.isPassed || _isCapturing ? AppTheme.success : AppTheme.surfaceDark,
          )),
          _step(
            icon: Icons.camera_alt_rounded,
            label: 'Capture',
            done: _isDone,
            active: _isCapturing,
            progress: _isCapturing ? _captureProgress : null,
          ),
        ],
      ),
    );
  }

  Widget _step({
    required IconData icon,
    required String label,
    required bool done,
    required bool active,
    double? progress,
  }) {
    final color = done
        ? AppTheme.success
        : active ? AppTheme.primaryPurple : AppTheme.textMuted;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withOpacity(0.12),
                border: Border.all(color: color, width: active ? 2 : 1),
              ),
              child: Icon(done ? Icons.check_rounded : icon, color: color, size: 18),
            ),
            if (progress != null && !done)
              SizedBox(
                width: 38, height: 38,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 3,
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation(color.withOpacity(0.8)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 3),
        Text(label,
            style: GoogleFonts.inter(
                fontSize: 10, color: color, fontWeight: FontWeight.w500)),
      ],
    );
  }

  // ── Status card ───────────────────────────────────────────────────────────────

  Widget _buildStatusCard() {
    final color = _isDone ? AppTheme.success
        : _isCapturing ? AppTheme.primaryPurple
        : AppTheme.textMuted;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: AppTheme.glassDecoration(
          opacity: 0.06,
          borderColor: color.withOpacity(0.25),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Icon(
                    _isDone     ? Icons.check_circle_rounded
                        : _isCapturing  ? Icons.camera_alt_rounded
                        : _isProcessing ? Icons.hourglass_top_rounded
                        : Icons.face_rounded,
                    key: ValueKey(_statusMessage),
                    color: color, size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      _statusMessage,
                      key: ValueKey(_statusMessage),
                      style: GoogleFonts.inter(
                          fontSize: 14, fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary),
                    ),
                  ),
                ),
              ],
            ),
            if (_subMessage.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(_subMessage,
                  style: GoogleFonts.inter(
                      fontSize: 12, color: AppTheme.textSecondary)),
            ],
          ],
        ),
      ).animate().fadeIn(delay: 300.ms),
    );
  }
}