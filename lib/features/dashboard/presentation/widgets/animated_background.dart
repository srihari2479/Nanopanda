// lib/features/dashboard/presentation/widgets/animated_background.dart
//
// NOTE: The uploaded animated_background.dart file contained the wrong content
// (it was a duplicate of monitoring_provider.dart). This file is the correct
// AnimatedBackground widget reconstructed from its usage in dashboard_page.dart:
//
//   AnimatedBackground(controller: _backgroundController)
//
// where _backgroundController is a 10-second repeating AnimationController.
//
// The widget renders a full-screen dark gradient background with two slowly
// drifting translucent blobs driven by the animation — a common glassmorphism
// style background used in the rest of the app.

import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../../../theme/theme.dart';

class AnimatedBackground extends StatelessWidget {
  final AnimationController controller;

  const AnimatedBackground({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = controller.value; // 0.0 → 1.0 repeating

        // Blob 1 — drifts top-left ↔ centre
        final blob1X = size.width  * (0.0 + 0.35 * math.sin(t * 2 * math.pi));
        final blob1Y = size.height * (0.0 + 0.25 * math.sin(t * 2 * math.pi + 1.0));

        // Blob 2 — drifts bottom-right ↔ centre (opposite phase)
        final blob2X = size.width  * (0.55 + 0.25 * math.sin(t * 2 * math.pi + math.pi));
        final blob2Y = size.height * (0.45 + 0.20 * math.sin(t * 2 * math.pi + math.pi + 0.5));

        return Stack(
          children: [
            // Base gradient — matches app-wide dark theme
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end:   Alignment.bottomRight,
                  colors: [
                    Color(0xFF0A0E21),
                    Color(0xFF1D1E33),
                  ],
                ),
              ),
            ),

            // Blob 1 — purple glow (top-left area)
            Positioned(
              left: blob1X - 160,
              top:  blob1Y - 160,
              child: Container(
                width:  320,
                height: 320,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      AppTheme.primaryPurple.withOpacity(0.18),
                      AppTheme.primaryPurple.withOpacity(0.0),
                    ],
                  ),
                ),
              ),
            ),

            // Blob 2 — accent blue-purple glow (bottom-right area)
            Positioned(
              left: blob2X - 140,
              top:  blob2Y - 140,
              child: Container(
                width:  280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFF9D4EDD).withOpacity(0.14),
                      const Color(0xFF9D4EDD).withOpacity(0.0),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}