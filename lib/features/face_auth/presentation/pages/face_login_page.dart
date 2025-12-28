import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:camera/camera.dart';

import '../../../../core/providers/app_state_provider.dart';
import '../../../../theme/theme.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../core/models/face_vector_model.dart';
import '../../../../core/utils/constants.dart';
import '../../../../core/services/camera_service.dart';
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
  final FaceAuthRepository _repository = FaceAuthRepository();
  late final CameraService _cameraService;

  late AnimationController _pulseController;
  late AnimationController _shakeController;

  bool _isCameraReady = false;
  bool _isVerifying = false;
  bool _faceDetected = false;
  bool _verificationFailed = false;
  String _statusMessage = 'Initializing camera...';
  double? _matchPercentage;

  @override
  void initState() {
    super.initState();
    _cameraService = CameraService();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    // Delay camera initialization to ensure smooth page transition
    Future.delayed(const Duration(milliseconds: 300), _initializeCamera);
  }

  Future<void> _initializeCamera() async {
    if (!mounted) return;

    try {
      setState(() {
        _isCameraReady = false;
        _statusMessage = 'Initializing camera...';
        _faceDetected = false;
      });

      await _cameraService.initialize();

      if (!mounted) return;

      // Smooth transition to ready state
      await Future.delayed(const Duration(milliseconds: 200));

      if (mounted) {
        setState(() {
          _isCameraReady = true;
          _statusMessage = 'Position your face to verify';
          _faceDetected = true; // TODO: real detection
        });
      }
    } catch (e) {
      debugPrint('Camera init error: $e');
      if (!mounted) return;
      setState(() {
        _isCameraReady = false;
        _statusMessage = 'Camera initialization failed';
      });
      _showErrorSnackBar('Unable to access camera');
    }
  }

  Future<void> _verifyFace() async {
    if (_isVerifying || !_isCameraReady) return;

    setState(() {
      _isVerifying = true;
      _verificationFailed = false;
      _statusMessage = 'Verifying identity...';
    });

    HapticFeedback.mediumImpact();

    final storageService = context.read<StorageService>();
    final storedVector = await storageService.getFaceVector();

    if (storedVector == null) {
      setState(() {
        _isVerifying = false;
        _verificationFailed = true;
        _statusMessage = 'No registered face found';
      });
      _showErrorSnackBar('Please register your face first');
      return;
    }

    // TODO: generate live vector from camera frame
    final liveVector = FaceVectorModel.generateMock();

    final result = await _repository.verifyFace(
      liveVector: liveVector,
      storedVector: storedVector,
    );

    if (result.isMatch && mounted) {
      setState(() {
        _matchPercentage = result.matchPercentage;
        _statusMessage =
        'Verified! ${result.matchPercentage.toStringAsFixed(1)}% match';
      });

      HapticFeedback.heavyImpact();
      context.read<AppStateProvider>().setAuthenticated(true);

      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/dashboard');
      }
    } else if (mounted) {
      _shakeController.forward().then((_) => _shakeController.reset());
      setState(() {
        _isVerifying = false;
        _verificationFailed = true;
        _matchPercentage = null;
        _statusMessage = _getFailureMessage(result.status);
      });
      HapticFeedback.vibrate();
      _showErrorSnackBar(_statusMessage);
    }
  }

  String _getFailureMessage(FaceVerificationStatus status) {
    switch (status) {
      case FaceVerificationStatus.mismatch:
        return 'Face does not match. Unauthorized access.';
      case FaceVerificationStatus.noFaceDetected:
        return 'No face detected. Please try again.';
      case FaceVerificationStatus.blurDetected:
        return 'Image too blurry. Hold steady.';
      case FaceVerificationStatus.unknownError:
        return 'Verification failed. Please retry.';
      default:
        return 'Verification failed';
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.warning_amber, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: AppTheme.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _shakeController.dispose();
    _cameraService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: _buildCameraSection(size),
              ),
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
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  shape: BoxShape.circle,
                  boxShadow: AppTheme.glowShadow(
                    AppTheme.primaryPurple,
                    intensity: 0.3,
                  ),
                ),
                child: const Icon(
                  Icons.shield,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ],
          ).animate().fadeIn().scale(delay: 100.ms),
          const SizedBox(height: 16),
          Text(
            'Face Verification',
            style: GoogleFonts.poppins(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ).animate().fadeIn(delay: 200.ms),
          const SizedBox(height: 8),
          Text(
            'Look at the camera to unlock',
            style: GoogleFonts.inter(
              fontSize: 14,
              color: AppTheme.textSecondary,
            ),
          ).animate().fadeIn(delay: 300.ms),
        ],
      ),
    );
  }

  Widget _buildCameraSection(Size size) {
    // Make camera fill almost the entire width (left to right with minimal padding)
    final cameraSize = size.width - 32; // Full width minus small padding
    return Center(
      child: AnimatedBuilder(
        animation: _shakeController,
        builder: (context, child) {
          final shakeValue = _shakeController.value;
          final offset = shakeValue < 0.5
              ? (shakeValue * 20) - 5
              : ((1 - shakeValue) * 20) - 5;

          return Transform.translate(
            offset: Offset(_verificationFailed ? offset : 0, 0),
            child: child,
          );
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: cameraSize,
              height: cameraSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: _verificationFailed
                    ? AppTheme.glowShadow(AppTheme.error, intensity: 0.4)
                    : _matchPercentage != null
                    ? AppTheme.glowShadow(AppTheme.success, intensity: 0.4)
                    : AppTheme.glowShadow(
                  AppTheme.primaryPurple,
                  intensity: 0.2,
                ),
              ),
              child: ClipOval(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Camera preview with proper aspect ratio
                    if (_isCameraReady && _cameraService.isReady)
                      _buildCameraPreview()
                    else
                      _buildLoadingState(),
                    CameraOverlay(
                      faceDetected: _faceDetected && _isCameraReady,
                      isScanning: _isVerifying,
                      isCircular: true,
                      showError: _verificationFailed,
                    ),
                    if (_isVerifying &&
                        !_verificationFailed &&
                        _matchPercentage == null)
                      const ScanningAnimation(isCircular: true),
                  ],
                ),
              ),
            ).animate().fadeIn().scale(
              begin: const Offset(0.9, 0.9),
              duration: 500.ms,
              curve: Curves.easeOutBack,
            ),
            if (_matchPercentage != null)
              Container(
                width: cameraSize,
                height: cameraSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.success.withOpacity(0.8),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.check_circle,
                      size: 80,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '${_matchPercentage!.toStringAsFixed(1)}%',
                      style: GoogleFonts.poppins(
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      'VERIFIED',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withOpacity(0.9),
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ).animate().fadeIn().scale(),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    final controller = _cameraService.controller!;
    final size = controller.value.previewSize!;

    // Calculate scale to fill the circular frame completely
    final cameraAspectRatio = size.height / size.width;

    // Scale up significantly to ensure the camera fills the entire circle edge-to-edge
    double scale = 1.8; // Increased scale for better coverage

    return Transform.scale(
      scale: scale,
      child: Center(
        child: AspectRatio(
          aspectRatio: cameraAspectRatio,
          child: CameraPreview(controller),
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
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation(AppTheme.primaryPurple),
              ),
            )
                .animate(onPlay: (c) => c.repeat())
                .fadeIn(duration: 300.ms)
                .then()
                .shimmer(duration: 1000.ms),
            const SizedBox(height: 16),
            Text(
              'Loading camera...',
              style: GoogleFonts.inter(
                fontSize: 14,
                color: AppTheme.textSecondary,
              ),
            ).animate().fadeIn(delay: 200.ms),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomSection() {
    return Container(
      padding: const EdgeInsets.all(AppTheme.spacingL),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppTheme.spacingM),
            decoration: AppTheme.glassDecoration(
              opacity: _verificationFailed ? 0.1 : 0.05,
              borderColor: _verificationFailed
                  ? AppTheme.error.withOpacity(0.3)
                  : null,
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _verificationFailed
                        ? AppTheme.error.withOpacity(0.2)
                        : _matchPercentage != null
                        ? AppTheme.success.withOpacity(0.2)
                        : AppTheme.primaryPurple.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                  ),
                  child: Icon(
                    _verificationFailed
                        ? Icons.error_outline
                        : _matchPercentage != null
                        ? Icons.verified_user
                        : Icons.security,
                    color: _verificationFailed
                        ? AppTheme.error
                        : _matchPercentage != null
                        ? AppTheme.success
                        : AppTheme.primaryPurple,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _statusMessage,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      if (_matchPercentage == null && !_verificationFailed)
                        Text(
                          'Required: ${(AppConstants.faceMatchThreshold * 100).toInt()}%+ match',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: AppTheme.textMuted,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(delay: 400.ms),
          const SizedBox(height: AppTheme.spacingL),
          GestureDetector(
            onTap: _isCameraReady && _faceDetected && !_isVerifying
                ? _verifyFace
                : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: double.infinity,
              height: 56,
              decoration: BoxDecoration(
                gradient: _isCameraReady && _faceDetected && !_isVerifying
                    ? AppTheme.primaryGradient
                    : null,
                color: _isCameraReady && _faceDetected && !_isVerifying
                    ? null
                    : AppTheme.surfaceDark,
                borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                boxShadow: _isCameraReady && _faceDetected && !_isVerifying
                    ? AppTheme.glowShadow(
                  AppTheme.primaryPurple,
                  intensity: 0.3,
                )
                    : null,
              ),
              child: Center(
                child: _isVerifying && _matchPercentage == null
                    ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(
                          AppTheme.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Verifying...',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ],
                )
                    : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_open,
                      color:
                      _isCameraReady && _faceDetected && !_isVerifying
                          ? AppTheme.textPrimary
                          : AppTheme.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _verificationFailed ? 'Try Again' : 'Verify Identity',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _isCameraReady &&
                            _faceDetected &&
                            !_isVerifying
                            ? AppTheme.textPrimary
                            : AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ).animate().fadeIn(delay: 500.ms).slideY(begin: 0.2),
        ],
      ),
    );
  }
}