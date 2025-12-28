import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:camera/camera.dart';

import '../../../../theme/theme.dart';
import '../../data/repositories/emotion_repository.dart';
import '../../../../core/services/camera_service.dart';
import '../../../face_auth/presentation/widgets/camera_overlay.dart';

class EmotionDetectionPage extends StatefulWidget {
  const EmotionDetectionPage({super.key});

  @override
  State<EmotionDetectionPage> createState() => _EmotionDetectionPageState();
}

class _EmotionDetectionPageState extends State<EmotionDetectionPage>
    with SingleTickerProviderStateMixin {
  final EmotionRepository _repository = EmotionRepository();
  late final CameraService _cameraService;

  late AnimationController _pulseController;

  bool _isCameraReady = false;
  bool _isAnalyzing = false;
  bool _faceDetected = false;
  String _statusMessage = 'Initializing camera...';

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
          _statusMessage = 'Position your face and tap Analyze';
          _faceDetected = true; // TODO: real detection
        });
      }
    } catch (e) {
      debugPrint('Camera init error: $e');
      if (!mounted) return;
      setState(() {
        _isCameraReady = false;
        _statusMessage = 'Camera failed to start';
      });
      _showErrorSnackBar('Unable to access camera');
    }
  }

  Future<void> _analyzeEmotion() async {
    if (_isAnalyzing || !_isCameraReady) return;

    setState(() {
      _isAnalyzing = true;
      _statusMessage = 'Analyzing expression...';
    });

    HapticFeedback.mediumImpact();

    try {
      // TODO: capture frame bytes from camera
      final result = await _repository.detectEmotion([]);

      if (mounted) {
        setState(() => _isAnalyzing = false);
        Navigator.pushReplacementNamed(
          context,
          '/emotion-result',
          arguments: result.emotion,
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isAnalyzing = false;
          _statusMessage = 'Analysis failed. Try again.';
        });
        _showErrorSnackBar('Failed to analyze emotion');
      }
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
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              Navigator.pop(context);
            },
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: AppTheme.glassDecoration(opacity: 0.1),
              child: const Icon(
                Icons.arrow_back,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: AppTheme.spacingM),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Emotion Detection',
                  style: GoogleFonts.poppins(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                Text(
                  'AI-powered facial analysis',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: ['😊', '😢', '😠'].map((emoji) {
              return Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  emoji,
                  style: const TextStyle(fontSize: 20),
                )
                    .animate(onPlay: (c) => c.repeat(reverse: true))
                    .fadeIn(duration: 800.ms)
                    .then()
                    .fadeOut(duration: 800.ms),
              );
            }).toList(),
          ),
        ],
      ),
    ).animate().fadeIn().slideY(begin: -0.2);
  }

  Widget _buildCameraSection(Size size) {
    final cameraWidth = size.width * 0.9;
    final cameraHeight = cameraWidth * 1.2;
    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: cameraWidth,
            height: cameraHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.radiusXL),
              boxShadow: AppTheme.glowShadow(
                const Color(0xFF667EEA),
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
                    isScanning: _isAnalyzing,
                  ),
                ],
              ),
            ),
          ).animate().fadeIn().scale(
            begin: const Offset(0.95, 0.95),
            duration: 500.ms,
            curve: Curves.easeOutBack,
          ),
          if (_isAnalyzing)
            _buildAnalyzingOverlay(cameraWidth, cameraHeight),
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
                valueColor: AlwaysStoppedAnimation(AppTheme.primaryPurple),
              ),
            )
                .animate(onPlay: (c) => c.repeat())
                .fadeIn(duration: 300.ms)
                .then()
                .shimmer(duration: 1000.ms),
            const SizedBox(height: 16),
            Text(
              'Starting camera...',
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

  Widget _buildAnalyzingOverlay(double width, double height) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppTheme.primaryDark.withOpacity(0.95),
        borderRadius: BorderRadius.circular(AppTheme.radiusXL),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 80,
            height: 80,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 80,
                  height: 80,
                  child: CircularProgressIndicator(
                    strokeWidth: 4,
                    valueColor: AlwaysStoppedAnimation(AppTheme.primaryPurple),
                  ),
                ),
                const Text('🤔', style: TextStyle(fontSize: 40)),
              ],
            ),
          )
              .animate(onPlay: (c) => c.repeat())
              .shimmer(duration: 1500.ms)
              .then()
              .rotate(begin: 0, end: 0.05, duration: 200.ms)
              .then()
              .rotate(begin: 0.05, end: -0.05, duration: 200.ms)
              .then()
              .rotate(begin: -0.05, end: 0, duration: 200.ms),
          const SizedBox(height: 24),
          Text(
            'Analyzing Expression',
            style: GoogleFonts.poppins(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ).animate().fadeIn(),
          const SizedBox(height: 8),
          Text(
            'Processing with AI...',
            style: GoogleFonts.inter(
              fontSize: 14,
              color: AppTheme.textSecondary,
            ),
          ).animate().fadeIn(delay: 100.ms),
          const SizedBox(height: 24),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (index) {
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: AppTheme.primaryPurple,
                  shape: BoxShape.circle,
                ),
              )
                  .animate(onPlay: (c) => c.repeat())
                  .fadeIn(delay: Duration(milliseconds: index * 200))
                  .scale(
                begin: const Offset(0.5, 0.5),
                end: const Offset(1.2, 1.2),
                duration: 400.ms,
              )
                  .then()
                  .fadeOut(delay: const Duration(milliseconds: 200));
            }),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms).scale(
      begin: const Offset(0.95, 0.95),
      duration: 300.ms,
      curve: Curves.easeOut,
    );
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
                  _isAnalyzing
                      ? Icons.psychology
                      : _faceDetected
                      ? Icons.check_circle
                      : Icons.info_outline,
                  size: 18,
                  color: _isAnalyzing
                      ? AppTheme.info
                      : _faceDetected
                      ? AppTheme.success
                      : AppTheme.warning,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _statusMessage,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(delay: 300.ms),
          const SizedBox(height: AppTheme.spacingL),
          GestureDetector(
            onTap: _isCameraReady && _faceDetected && !_isAnalyzing
                ? _analyzeEmotion
                : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: double.infinity,
              height: 56,
              decoration: BoxDecoration(
                gradient: _isCameraReady && _faceDetected && !_isAnalyzing
                    ? const LinearGradient(
                  colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
                )
                    : null,
                color: _isCameraReady && _faceDetected && !_isAnalyzing
                    ? null
                    : AppTheme.surfaceDark,
                borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                boxShadow: _isCameraReady && _faceDetected && !_isAnalyzing
                    ? AppTheme.glowShadow(
                  const Color(0xFF667EEA),
                  intensity: 0.3,
                )
                    : null,
              ),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      color:
                      _isCameraReady && _faceDetected && !_isAnalyzing
                          ? AppTheme.textPrimary
                          : AppTheme.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Analyze Emotion',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _isCameraReady &&
                            _faceDetected &&
                            !_isAnalyzing
                            ? AppTheme.textPrimary
                            : AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ).animate().fadeIn(delay: 400.ms).slideY(begin: 0.2),
        ],
      ),
    );
  }
}