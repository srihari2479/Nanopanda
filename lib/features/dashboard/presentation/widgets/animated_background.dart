import 'package:flutter/material.dart';
import 'dart:math' as math;

import '../../../../theme/theme.dart';

/// Animated Background Widget
/// Creates floating particle effect for dashboard
class AnimatedBackground extends StatelessWidget {
  final AnimationController controller;

  const AnimatedBackground({
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: AppTheme.backgroundGradient,
      ),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          return CustomPaint(
            size: Size.infinite,
            painter: ParticlesPainter(
              animationValue: controller.value,
            ),
          );
        },
      ),
    );
  }
}

class ParticlesPainter extends CustomPainter {
  final double animationValue;
  final List<Particle> particles;

  ParticlesPainter({
    required this.animationValue,
  }) : particles = _generateParticles();

  static List<Particle> _generateParticles() {
    final random = math.Random(42); // Fixed seed for consistent particles
    return List.generate(20, (index) {
      return Particle(
        x: random.nextDouble(),
        y: random.nextDouble(),
        radius: random.nextDouble() * 3 + 1,
        speed: random.nextDouble() * 0.5 + 0.2,
        opacity: random.nextDouble() * 0.3 + 0.1,
      );
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Draw subtle gradient circles in background
    _drawBackgroundOrbs(canvas, size);

    // Draw floating particles
    for (final particle in particles) {
      final y = ((particle.y + animationValue * particle.speed) % 1.2) - 0.1;
      final x = particle.x + math.sin(animationValue * 2 * math.pi + particle.y * 10) * 0.02;

      final paint = Paint()
        ..color = AppTheme.primaryPurple.withOpacity(particle.opacity)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(
        Offset(x * size.width, y * size.height),
        particle.radius,
        paint,
      );
    }
  }

  void _drawBackgroundOrbs(Canvas canvas, Size size) {
    // Large orb top-right
    final orb1Paint = Paint()
      ..shader = RadialGradient(
        colors: [
          AppTheme.primaryPurple.withOpacity(0.15),
          AppTheme.primaryPurple.withOpacity(0),
        ],
      ).createShader(Rect.fromCircle(
        center: Offset(size.width * 0.9, size.height * 0.1),
        radius: size.width * 0.4,
      ));

    canvas.drawCircle(
      Offset(
        size.width * 0.9 + math.sin(animationValue * 2 * math.pi) * 20,
        size.height * 0.1 + math.cos(animationValue * 2 * math.pi) * 20,
      ),
      size.width * 0.4,
      orb1Paint,
    );

    // Medium orb bottom-left
    final orb2Paint = Paint()
      ..shader = RadialGradient(
        colors: [
          AppTheme.secondaryPurple.withOpacity(0.1),
          AppTheme.secondaryPurple.withOpacity(0),
        ],
      ).createShader(Rect.fromCircle(
        center: Offset(size.width * 0.1, size.height * 0.8),
        radius: size.width * 0.35,
      ));

    canvas.drawCircle(
      Offset(
        size.width * 0.1 + math.cos(animationValue * 2 * math.pi) * 15,
        size.height * 0.8 + math.sin(animationValue * 2 * math.pi) * 15,
      ),
      size.width * 0.35,
      orb2Paint,
    );

    // Small orb center
    final orb3Paint = Paint()
      ..shader = RadialGradient(
        colors: [
          AppTheme.accentCyan.withOpacity(0.08),
          AppTheme.accentCyan.withOpacity(0),
        ],
      ).createShader(Rect.fromCircle(
        center: Offset(size.width * 0.5, size.height * 0.5),
        radius: size.width * 0.25,
      ));

    canvas.drawCircle(
      Offset(
        size.width * 0.5 + math.sin(animationValue * 4 * math.pi) * 10,
        size.height * 0.5 + math.cos(animationValue * 4 * math.pi) * 10,
      ),
      size.width * 0.25,
      orb3Paint,
    );
  }

  @override
  bool shouldRepaint(covariant ParticlesPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue;
  }
}

class Particle {
  final double x;
  final double y;
  final double radius;
  final double speed;
  final double opacity;

  Particle({
    required this.x,
    required this.y,
    required this.radius,
    required this.speed,
    required this.opacity,
  });
}
