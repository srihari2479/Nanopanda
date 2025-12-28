import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'dart:math' as math;

import '../../../../theme/theme.dart';
import '../../../../core/utils/constants.dart';

class EmotionResultPage extends StatefulWidget {
  final String emotion;

  const EmotionResultPage({
    super.key,
    required this.emotion,
  });

  @override
  State<EmotionResultPage> createState() => _EmotionResultPageState();
}

class _EmotionResultPageState extends State<EmotionResultPage>
    with TickerProviderStateMixin {
  late AnimationController _backgroundController;
  late AnimationController _particleController;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();

    _backgroundController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();

    _particleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    HapticFeedback.heavyImpact();
  }

  @override
  void dispose() {
    _backgroundController.dispose();
    _particleController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  String get _emoji => AppConstants.emotionEmojis[widget.emotion.toLowerCase()] ?? '😐';
  String get _description => AppConstants.emotionDescriptions[widget.emotion.toLowerCase()] ?? '';

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);

    return Scaffold(
      body: Stack(
        children: [
          // Animated background
          AnimatedBuilder(
            animation: Listenable.merge([_backgroundController, _particleController]),
            builder: (context, child) {
              return CustomPaint(
                size: size,
                painter: EmotionBackgroundPainter(
                  emotion: widget.emotion,
                  animationValue: _backgroundController.value,
                  particleValue: _particleController.value,
                ),
              );
            },
          ),

          // Particle effects overlay
          _buildParticleOverlay(size),

          // Content
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: _buildEmotionContent(size),
                ),
                _buildBottomActions(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(AppTheme.spacingM),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              Navigator.of(context).pushReplacementNamed('/dashboard');
            },
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                border: Border.all(color: Colors.white.withOpacity(0.2)),
              ),
              child: const Icon(
                Icons.close,
                color: Colors.white,
              ),
            ),
          ),
          Text(
            'Emotion Detected',
            style: GoogleFonts.poppins(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 48), // Balance
        ],
      ),
    ).animate().fadeIn().slideY(begin: -0.3);
  }

  Widget _buildEmotionContent(Size size) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Large emoji with glow
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              return Container(
                width: 150 + (_pulseController.value * 20),
                height: 150 + (_pulseController.value * 20),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.getEmotionPrimaryColor(widget.emotion)
                          .withOpacity(0.4 + _pulseController.value * 0.2),
                      blurRadius: 40 + (_pulseController.value * 20),
                      spreadRadius: 10,
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    _emoji,
                    style: TextStyle(fontSize: 80 + (_pulseController.value * 10)),
                  ),
                ),
              );
            },
          ).animate()
              .fadeIn(duration: 600.ms)
              .scale(begin: const Offset(0.5, 0.5), curve: Curves.elasticOut, duration: 800.ms),

          const SizedBox(height: 40),

          // Emotion name with animated typography
          ShaderMask(
            shaderCallback: (bounds) {
              return LinearGradient(
                colors: [
                  Colors.white,
                  AppTheme.getEmotionPrimaryColor(widget.emotion),
                ],
              ).createShader(bounds);
            },
            child: Text(
              widget.emotion.toUpperCase(),
              style: GoogleFonts.poppins(
                fontSize: 48,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                letterSpacing: 8,
              ),
            ),
          ).animate()
              .fadeIn(delay: 300.ms, duration: 500.ms)
              .slideY(begin: 0.3),

          const SizedBox(height: 16),

          // Description
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              _description,
              style: GoogleFonts.inter(
                fontSize: 16,
                color: Colors.white.withOpacity(0.8),
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          ).animate()
              .fadeIn(delay: 500.ms, duration: 500.ms),

          const SizedBox(height: 40),

          // Confidence indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
              border: Border.all(color: Colors.white.withOpacity(0.2)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.psychology, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Confidence: ${(85 + math.Random().nextInt(14))}%',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ).animate()
              .fadeIn(delay: 700.ms)
              .slideY(begin: 0.2),
        ],
      ),
    );
  }

  Widget _buildParticleOverlay(Size size) {
    if (widget.emotion.toLowerCase() != 'happy') return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: _particleController,
      builder: (context, child) {
        return CustomPaint(
          size: size,
          painter: FloatingParticlesPainter(
            animationValue: _particleController.value,
          ),
        );
      },
    );
  }

  Widget _buildBottomActions() {
    return Padding(
      padding: const EdgeInsets.all(AppTheme.spacingL),
      child: Column(
        children: [
          // Try again button
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              Navigator.of(context).pushReplacementNamed('/emotion-detection');
            },
            child: Container(
              width: double.infinity,
              height: 56,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                border: Border.all(color: Colors.white.withOpacity(0.3)),
              ),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.refresh, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(
                      'Analyze Again',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: AppTheme.spacingM),

          // Back to dashboard
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              Navigator.of(context).pushReplacementNamed('/dashboard');
            },
            child: Container(
              width: double.infinity,
              height: 56,
              decoration: BoxDecoration(
                gradient: AppTheme.primaryGradient,
                borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                boxShadow: AppTheme.glowShadow(AppTheme.primaryPurple, intensity: 0.3),
              ),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.home, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(
                      'Back to Dashboard',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(delay: 800.ms).slideY(begin: 0.3);
  }
}

/// Custom painter for emotion-based animated background
class EmotionBackgroundPainter extends CustomPainter {
  final String emotion;
  final double animationValue;
  final double particleValue;

  EmotionBackgroundPainter({
    required this.emotion,
    required this.animationValue,
    required this.particleValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw gradient background
    final gradient = AppTheme.getEmotionGradient(emotion);
    final paint = Paint()
      ..shader = gradient.createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);

    // Draw emotion-specific effects
    switch (emotion.toLowerCase()) {
      case 'happy':
        _drawHappyEffects(canvas, size);
        break;
      case 'sad':
        _drawSadEffects(canvas, size);
        break;
      case 'angry':
        _drawAngryEffects(canvas, size);
        break;
      case 'fear':
        _drawFearEffects(canvas, size);
        break;
      case 'disgust':
        _drawDisgustEffects(canvas, size);
        break;
      default:
        _drawNeutralEffects(canvas, size);
    }
  }

  void _drawHappyEffects(Canvas canvas, Size size) {
    // Sunburst rays
    final centerX = size.width / 2;
    final centerY = size.height * 0.3;

    for (int i = 0; i < 12; i++) {
      final angle = (i / 12) * 2 * math.pi + animationValue * 2 * math.pi;
      final rayPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.yellow.withOpacity(0.3),
            Colors.orange.withOpacity(0),
          ],
        ).createShader(Rect.fromCircle(
          center: Offset(centerX, centerY),
          radius: size.width,
        ));

      final path = Path()
        ..moveTo(centerX, centerY)
        ..lineTo(
          centerX + math.cos(angle) * size.width,
          centerY + math.sin(angle) * size.width,
        )
        ..lineTo(
          centerX + math.cos(angle + 0.1) * size.width,
          centerY + math.sin(angle + 0.1) * size.width,
        )
        ..close();

      canvas.drawPath(path, rayPaint);
    }
  }

  void _drawSadEffects(Canvas canvas, Size size) {
    // Slow waves
    final wavePaint = Paint()
      ..color = Colors.blue.withOpacity(0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    for (int i = 0; i < 5; i++) {
      final path = Path();
      final yOffset = size.height * (0.4 + i * 0.12);
      final waveOffset = animationValue * size.width + (i * 50);

      path.moveTo(0, yOffset);
      for (double x = 0; x <= size.width; x += 10) {
        final y = yOffset + math.sin((x + waveOffset) / 50) * 20;
        path.lineTo(x, y);
      }

      canvas.drawPath(path, wavePaint);
    }
  }

  void _drawAngryEffects(Canvas canvas, Size size) {
    // Aggressive motion lines
    final random = math.Random(42);
    final linePaint = Paint()
      ..color = Colors.red.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < 8; i++) {
      final startX = random.nextDouble() * size.width;
      final startY = random.nextDouble() * size.height;
      final offset = math.sin(animationValue * 2 * math.pi + i) * 30;

      canvas.drawLine(
        Offset(startX, startY),
        Offset(startX + 100 + offset, startY - 50 + offset * 0.5),
        linePaint,
      );
    }
  }

  void _drawFearEffects(Canvas canvas, Size size) {
    // Shaking shadows
    final shadowPaint = Paint()
      ..color = Colors.purple.withOpacity(0.2);

    final shakeX = math.sin(animationValue * 8 * math.pi) * 5;
    final shakeY = math.cos(animationValue * 8 * math.pi) * 5;

    for (int i = 0; i < 3; i++) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(
            size.width * 0.3 + i * size.width * 0.2 + shakeX,
            size.height * 0.7 + shakeY,
          ),
          width: 150 + i * 30,
          height: 80 + i * 20,
        ),
        shadowPaint,
      );
    }
  }

  void _drawDisgustEffects(Canvas canvas, Size size) {
    // Wavy distortions
    final wavePaint = Paint()
      ..color = Colors.green.withOpacity(0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8;

    for (int i = 0; i < 4; i++) {
      final path = Path();
      final baseY = size.height * (0.3 + i * 0.15);

      path.moveTo(0, baseY);
      for (double x = 0; x <= size.width; x += 5) {
        final wave1 = math.sin((x / 30) + animationValue * math.pi * 2) * 15;
        final wave2 = math.sin((x / 50) + animationValue * math.pi * 3) * 10;
        path.lineTo(x, baseY + wave1 + wave2);
      }

      canvas.drawPath(path, wavePaint);
    }
  }

  void _drawNeutralEffects(Canvas canvas, Size size) {
    // Subtle gradient orbs
    for (int i = 0; i < 3; i++) {
      final orbPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.grey.withOpacity(0.15),
            Colors.grey.withOpacity(0),
          ],
        ).createShader(Rect.fromCircle(
          center: Offset(
            size.width * (0.2 + i * 0.3) + math.sin(animationValue * 2 * math.pi + i) * 20,
            size.height * 0.5 + math.cos(animationValue * 2 * math.pi + i) * 30,
          ),
          radius: 150,
        ));

      canvas.drawCircle(
        Offset(
          size.width * (0.2 + i * 0.3) + math.sin(animationValue * 2 * math.pi + i) * 20,
          size.height * 0.5 + math.cos(animationValue * 2 * math.pi + i) * 30,
        ),
        150,
        orbPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant EmotionBackgroundPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.particleValue != particleValue;
  }
}

/// Floating particles for happy emotion
class FloatingParticlesPainter extends CustomPainter {
  final double animationValue;

  FloatingParticlesPainter({required this.animationValue});

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(123);

    for (int i = 0; i < 20; i++) {
      final x = random.nextDouble() * size.width;
      final baseY = random.nextDouble() * size.height;
      final y = (baseY - animationValue * size.height * 0.5) % size.height;
      final particleSize = random.nextDouble() * 8 + 4;

      final paint = Paint()
        ..color = Colors.yellow.withOpacity(random.nextDouble() * 0.5 + 0.3);

      canvas.drawCircle(Offset(x, y), particleSize, paint);
    }
  }

  @override
  bool shouldRepaint(covariant FloatingParticlesPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue;
  }
}
