import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:camera/camera.dart';

import '../../../../theme/theme.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../core/providers/app_state_provider.dart';
import '../../../../core/models/face_vector_model.dart';
import '../../../../core/services/camera_service.dart';
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
  final FaceAuthRepository _repository = FaceAuthRepository();
  late final CameraService _cameraService;

  late AnimationController _pulseController;

  bool _isCameraReady = false;
  bool _isCapturing = false;
  bool _isProcessing = false;
  bool _faceDetected = false;
  String _statusMessage = 'Initializing camera...';
  double _progress = 0.0;

  @override
  void initState() {
    super.initState();
    _cameraService = CameraService();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    Future.delayed(const Duration(milliseconds: 300), _initializeCamera);
  }

  Future<void> _initializeCamera() async {
    if (!mounted) return;

    try {
      setState(() {
        _isCameraReady = false;
        _statusMessage = 'Initializing camera...';
      });

      await _cameraService.initialize();

      if (!mounted) return;

      await Future.delayed(const Duration(milliseconds: 200));

      if (mounted) {
        setState(() {
          _isCameraReady = true;
          _statusMessage = 'Position your face in the frame';
          _faceDetected = true; // TODO: hook real detection later
        });
      }
    } catch (e) {
      debugPrint('Camera init error: $e');
      if (!mounted) return;
      setState(() {
        _isCameraReady = false;
        _statusMessage = 'Camera failed to initialize';
      });
      _showErrorSnackBar('Unable to access camera');
    }
  }

  Future<void> _captureAndRegister() async {
    if (_isCapturing || _isProcessing || !_isCameraReady) return;

    setState(() {
      _isCapturing = true;
      _statusMessage = 'Capturing face...';
    });

    HapticFeedback.mediumImpact();

    // TODO: capture actual frame from camera
    await Future.delayed(const Duration(milliseconds: 500));

    setState(() {
      _isCapturing = false;
      _isProcessing = true;
      _statusMessage = 'Processing face data...';
    });

    for (int i = 0; i <= 100; i += 10) {
      await Future.delayed(const Duration(milliseconds: 150));
      if (mounted) {
        setState(() => _progress = i / 100);
      }
    }

    final faceVector = FaceVectorModel.generateMock();

    setState(() => _statusMessage = 'Registering with server...');
    final result = await _repository.registerFace(faceVector.vector);

    if (result.isSuccess && mounted) {
      final storageService = context.read<StorageService>();
      await storageService.saveFaceVector(faceVector);
      if (result.userId != null) {
        await storageService.saveUserId(result.userId!);
      }

      await context.read<AppStateProvider>().setFaceRegistered(true);

      setState(() {
        _isProcessing = false;
        _statusMessage = 'Registration successful!';
      });

      HapticFeedback.heavyImpact();

      await Future.delayed(const Duration(seconds: 1));
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/login');
      }
    } else if (mounted) {
      setState(() {
        _isProcessing = false;
        _progress = 0;
        _statusMessage = result.message;
      });
      _showErrorSnackBar(result.message);
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
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
            style: GoogleFonts.inter(
              fontSize: 14,
              color: AppTheme.textSecondary,
            ),
          ).animate().fadeIn(delay: 200.ms),
        ],
      ),
    );
  }

  Widget _buildCameraSection(Size size) {
    final cameraSize = size.width * 0.85;
    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: cameraSize,
            height: cameraSize * 1.2,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.radiusXL),
              boxShadow: AppTheme.glowShadow(
                AppTheme.primaryPurple,
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
                    faceDetected: _faceDetected && _isCameraReady,
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
          if (_isProcessing) _buildProcessingOverlay(cameraSize),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    final controller = _cameraService.controller!;
    final size = controller.value.previewSize!;

    final screenAspectRatio = 1.0 / 1.2;
    final cameraAspectRatio = size.height / size.width;

    double scale;
    if (cameraAspectRatio < screenAspectRatio) {
      scale = screenAspectRatio / cameraAspectRatio;
    } else {
      scale = 1.0;
    }

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
              width: 50,
              height: 50,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation(
                  AppTheme.primaryPurple,
                ),
              ),
            )
                .animate(onPlay: (c) => c.repeat())
                .fadeIn(duration: 300.ms)
                .then()
                .shimmer(duration: 1000.ms),
            const SizedBox(height: 16),
            Text(
              'Initializing camera...',
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
                    value: _progress,
                    strokeWidth: 6,
                    backgroundColor: AppTheme.surfaceDark,
                    valueColor: AlwaysStoppedAnimation(
                      AppTheme.primaryPurple,
                    ),
                  ),
                ),
                Text(
                  '${(_progress * 100).toInt()}%',
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
            style: GoogleFonts.inter(
              fontSize: 16,
              color: AppTheme.textSecondary,
            ),
          ).animate().fadeIn(),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms);
  }

  Widget _buildBottomSection() {
    return Container(
      padding: const EdgeInsets.all(AppTheme.spacingL),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.spacingM,
              vertical: AppTheme.spacingS,
            ),
            decoration: AppTheme.glassDecoration(opacity: 0.05),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isProcessing
                      ? Icons.hourglass_top
                      : _faceDetected
                      ? Icons.check_circle
                      : Icons.info_outline,
                  size: 18,
                  color: _isProcessing
                      ? AppTheme.info
                      : _faceDetected
                      ? AppTheme.success
                      : AppTheme.warning,
                ),
                const SizedBox(width: 8),
                Text(
                  _statusMessage,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(delay: 300.ms),
          const SizedBox(height: AppTheme.spacingL),
          GestureDetector(
            onTap: _isCameraReady && _faceDetected && !_isProcessing
                ? _captureAndRegister
                : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: double.infinity,
              height: 56,
              decoration: BoxDecoration(
                gradient: _isCameraReady && _faceDetected && !_isProcessing
                    ? AppTheme.primaryGradient
                    : null,
                color: _isCameraReady && _faceDetected && !_isProcessing
                    ? null
                    : AppTheme.surfaceDark,
                borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                boxShadow:
                _isCameraReady && _faceDetected && !_isProcessing
                    ? AppTheme.glowShadow(
                  AppTheme.primaryPurple,
                  intensity: 0.3,
                )
                    : null,
              ),
              child: Center(
                child: _isCapturing
                    ? SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(
                      AppTheme.textPrimary,
                    ),
                  ),
                )
                    : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.camera_alt,
                      color: _isCameraReady &&
                          _faceDetected &&
                          !_isProcessing
                          ? AppTheme.textPrimary
                          : AppTheme.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Register Face',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _isCameraReady &&
                            _faceDetected &&
                            !_isProcessing
                            ? AppTheme.textPrimary
                            : AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ).animate().fadeIn(delay: 400.ms).slideY(begin: 0.2),
          const SizedBox(height: AppTheme.spacingM),
          Text(
            'Your face data is encrypted and stored securely',
            style: GoogleFonts.inter(
              fontSize: 12,
              color: AppTheme.textMuted,
            ),
            textAlign: TextAlign.center,
          ).animate().fadeIn(delay: 500.ms),
        ],
      ),
    );
  }
}