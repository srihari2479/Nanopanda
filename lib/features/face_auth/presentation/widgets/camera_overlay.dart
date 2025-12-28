import 'package:flutter/material.dart';
import 'dart:math' as math;

import '../../../../theme/theme.dart';

/// Camera Overlay Widget
/// Displays face detection frame with animated corners
class CameraOverlay extends StatefulWidget {
  final bool faceDetected;
  final bool isScanning;
  final bool isCircular;
  final bool showError;

  const CameraOverlay({
    super.key,
    this.faceDetected = false,
    this.isScanning = false,
    this.isCircular = false,
    this.showError = false,
  });

  @override
  State<CameraOverlay> createState() => _CameraOverlayState();
}

class _CameraOverlayState extends State<CameraOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.isCircular
        ? _buildCircularOverlay()
        : _buildRectangularOverlay();
  }

  Widget _buildCircularOverlay() {
    final color = widget.showError
        ? AppTheme.error
        : widget.faceDetected
        ? AppTheme.success
        : AppTheme.primaryPurple;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          size: Size.infinite,
          painter: CircularOverlayPainter(
            color: color,
            rotation: _controller.value * 2 * math.pi,
            isAnimating: widget.isScanning,
          ),
        );
      },
    );
  }

  Widget _buildRectangularOverlay() {
    final color = widget.showError
        ? AppTheme.error
        : widget.faceDetected
        ? AppTheme.success
        : AppTheme.primaryPurple;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          size: Size.infinite,
          painter: FaceFramePainter(
            color: color,
            progress: widget.isScanning ? _controller.value : 0,
            cornerLength: 40,
            strokeWidth: 4,
          ),
        );
      },
    );
  }
}

/// Circular overlay painter for login screen
class CircularOverlayPainter extends CustomPainter {
  final Color color;
  final double rotation;
  final bool isAnimating;

  CircularOverlayPainter({
    required this.color,
    required this.rotation,
    required this.isAnimating,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 10;

    // Draw outer ring segments
    final paint = Paint()
      ..color = color.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < 4; i++) {
      final startAngle = (i * math.pi / 2) + rotation;
      final sweepAngle = math.pi / 4;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        paint,
      );
    }

    // Draw animated scanning arc
    if (isAnimating) {
      final scanPaint = Paint()
        ..shader = SweepGradient(
          center: Alignment.center,
          startAngle: 0,
          endAngle: math.pi,
          colors: [
            color.withOpacity(0),
            color,
            color.withOpacity(0),
          ],
          stops: const [0.0, 0.5, 1.0],
          transform: GradientRotation(rotation),
        ).createShader(Rect.fromCircle(center: center, radius: radius))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6;

      canvas.drawCircle(center, radius, scanPaint);
    }

    // Draw corner accents
    final accentPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < 4; i++) {
      final angle = (i * math.pi / 2) - math.pi / 4 + rotation;
      final startPoint = Offset(
        center.dx + (radius - 15) * math.cos(angle - 0.1),
        center.dy + (radius - 15) * math.sin(angle - 0.1),
      );
      final endPoint = Offset(
        center.dx + (radius - 15) * math.cos(angle + 0.1),
        center.dy + (radius - 15) * math.sin(angle + 0.1),
      );

      canvas.drawLine(startPoint, endPoint, accentPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CircularOverlayPainter oldDelegate) {
    return oldDelegate.rotation != rotation ||
        oldDelegate.color != color ||
        oldDelegate.isAnimating != isAnimating;
  }
}

/// Face frame painter for registration screen
class FaceFramePainter extends CustomPainter {
  final Color color;
  final double progress;
  final double cornerLength;
  final double strokeWidth;

  FaceFramePainter({
    required this.color,
    required this.progress,
    required this.cornerLength,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: size.width * 0.7,
      height: size.height * 0.6,
    );

    // Draw corners
    _drawCorner(canvas, rect.topLeft, 1, 1, paint);
    _drawCorner(canvas, rect.topRight, -1, 1, paint);
    _drawCorner(canvas, rect.bottomLeft, 1, -1, paint);
    _drawCorner(canvas, rect.bottomRight, -1, -1, paint);

    // Draw scanning line if animating
    if (progress > 0) {
      final scanPaint = Paint()
        ..shader = LinearGradient(
          colors: [
            color.withOpacity(0),
            color,
            color.withOpacity(0),
          ],
        ).createShader(Rect.fromLTWH(
          rect.left,
          rect.top + rect.height * progress - 10,
          rect.width,
          20,
        ))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;

      final y = rect.top + rect.height * progress;
      canvas.drawLine(
        Offset(rect.left + 20, y),
        Offset(rect.right - 20, y),
        scanPaint,
      );
    }
  }

  void _drawCorner(
      Canvas canvas,
      Offset corner,
      int xDir,
      int yDir,
      Paint paint,
      ) {
    final path = Path()
      ..moveTo(corner.dx + xDir * cornerLength, corner.dy)
      ..lineTo(corner.dx, corner.dy)
      ..lineTo(corner.dx, corner.dy + yDir * cornerLength);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant FaceFramePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
