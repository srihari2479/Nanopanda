import 'package:flutter/material.dart';
import 'dart:math' as math;

import '../../../../theme/theme.dart';

/// Scanning Animation Widget
/// Shows animated scanning effect during face capture/verification
class ScanningAnimation extends StatefulWidget {
  final bool isCircular;

  const ScanningAnimation({
    super.key,
    this.isCircular = false,
  });

  @override
  State<ScanningAnimation> createState() => _ScanningAnimationState();
}

class _ScanningAnimationState extends State<ScanningAnimation>
    with TickerProviderStateMixin {
  late AnimationController _scanController;
  late AnimationController _pulseController;
  late Animation<double> _scanAnimation;

  @override
  void initState() {
    super.initState();

    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _scanAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _scanController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _scanController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.isCircular
        ? _buildCircularScanning()
        : _buildRectangularScanning();
  }

  Widget _buildCircularScanning() {
    return AnimatedBuilder(
      animation: Listenable.merge([_scanController, _pulseController]),
      builder: (context, child) {
        return CustomPaint(
          size: Size.infinite,
          painter: CircularScanPainter(
            progress: _scanAnimation.value,
            pulseValue: _pulseController.value,
          ),
        );
      },
    );
  }

  Widget _buildRectangularScanning() {
    return AnimatedBuilder(
      animation: Listenable.merge([_scanController, _pulseController]),
      builder: (context, child) {
        return CustomPaint(
          size: Size.infinite,
          painter: RectangularScanPainter(
            progress: _scanAnimation.value,
            pulseValue: _pulseController.value,
          ),
        );
      },
    );
  }
}

/// Circular scanning painter
class CircularScanPainter extends CustomPainter {
  final double progress;
  final double pulseValue;

  CircularScanPainter({
    required this.progress,
    required this.pulseValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = math.min(size.width, size.height) / 2 - 20;

    // Draw pulse rings
    for (int i = 0; i < 3; i++) {
      final ringProgress = (progress + i * 0.33) % 1.0;
      final radius = maxRadius * 0.3 + (maxRadius * 0.7 * ringProgress);
      final opacity = (1 - ringProgress) * 0.3;

      final paint = Paint()
        ..color = AppTheme.primaryPurple.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;

      canvas.drawCircle(center, radius, paint);
    }

    // Draw scanning beam
    final beamPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          AppTheme.primaryPurple.withOpacity(0.5),
          AppTheme.primaryPurple.withOpacity(0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: maxRadius));

    final angle = progress * 2 * math.pi;
    final path = Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(
        Rect.fromCircle(center: center, radius: maxRadius),
        angle,
        math.pi / 4,
        false,
      )
      ..close();

    canvas.drawPath(path, beamPaint);

    // Draw center glow
    final glowRadius = 30 + pulseValue * 10;
    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          AppTheme.primaryPurple.withOpacity(0.4),
          AppTheme.primaryPurple.withOpacity(0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: glowRadius));

    canvas.drawCircle(center, glowRadius, glowPaint);
  }

  @override
  bool shouldRepaint(covariant CircularScanPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.pulseValue != pulseValue;
  }
}

/// Rectangular scanning painter
class RectangularScanPainter extends CustomPainter {
  final double progress;
  final double pulseValue;

  RectangularScanPainter({
    required this.progress,
    required this.pulseValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: size.width * 0.65,
      height: size.height * 0.55,
    );

    // Draw scanning line
    final y = rect.top + rect.height * progress;

    final linePaint = Paint()
      ..shader = LinearGradient(
        colors: [
          AppTheme.primaryPurple.withOpacity(0),
          AppTheme.primaryPurple,
          AppTheme.primaryPurple.withOpacity(0),
        ],
      ).createShader(Rect.fromLTWH(rect.left, y - 1, rect.width, 2))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    canvas.drawLine(
      Offset(rect.left + 15, y),
      Offset(rect.right - 15, y),
      linePaint,
    );

    // Draw glow effect below scan line
    final glowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          AppTheme.primaryPurple.withOpacity(0.4),
          AppTheme.primaryPurple.withOpacity(0),
        ],
      ).createShader(Rect.fromLTWH(rect.left, y, rect.width, 50));

    canvas.drawRect(
      Rect.fromLTWH(rect.left + 15, y, rect.width - 30, 40),
      glowPaint,
    );

    // Draw corner pulse effect
    final pulseSize = 10 + pulseValue * 5;
    final cornerPaint = Paint()
      ..color = AppTheme.primaryPurple.withOpacity(0.5 - pulseValue * 0.3)
      ..style = PaintingStyle.fill;

    // Top-left corner pulse
    canvas.drawCircle(rect.topLeft, pulseSize, cornerPaint);
    // Top-right corner pulse
    canvas.drawCircle(rect.topRight, pulseSize, cornerPaint);
    // Bottom-left corner pulse
    canvas.drawCircle(rect.bottomLeft, pulseSize, cornerPaint);
    // Bottom-right corner pulse
    canvas.drawCircle(rect.bottomRight, pulseSize, cornerPaint);
  }

  @override
  bool shouldRepaint(covariant RectangularScanPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.pulseValue != pulseValue;
  }
}
