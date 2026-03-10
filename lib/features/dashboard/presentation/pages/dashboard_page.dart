import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';

import '../../../../theme/theme.dart';
import '../../../../core/providers/monitoring_provider.dart';
import '../widgets/dashboard_card.dart';
import '../widgets/animated_background.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _backgroundController;

  @override
  void initState() {
    super.initState();
    _backgroundController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
  }

  @override
  void dispose() {
    _backgroundController.dispose();
    super.dispose();
  }

  void _navigateTo(String route) {
    HapticFeedback.lightImpact();
    Navigator.of(context).pushNamed(route);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Animated background
          AnimatedBackground(controller: _backgroundController),

          // Main content
          SafeArea(
            child: CustomScrollView(
              slivers: [
                // Header
                SliverToBoxAdapter(
                  child: _buildHeader(),
                ),

                // Action cards
                SliverPadding(
                  padding: const EdgeInsets.all(AppTheme.spacingM),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      _buildActionCards(),
                      const SizedBox(height: AppTheme.spacingL),
                      _buildQuickStats(),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(AppTheme.spacingL),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Welcome Back',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      color: AppTheme.textSecondary,
                    ),
                  ).animate().fadeIn(delay: 100.ms),
                  const SizedBox(height: 4),
                  Text(
                    'Nanopanda',
                    style: GoogleFonts.poppins(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary,
                    ),
                  ).animate().fadeIn(delay: 200.ms).slideX(begin: -0.1),
                ],
              ),
              // Settings button
              GestureDetector(
                onTap: () => _navigateTo('/settings'),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: AppTheme.glassDecoration(opacity: 0.1),
                  child: const Icon(
                    Icons.settings,
                    color: AppTheme.textPrimary,
                    size: 24,
                  ),
                ),
              ).animate().fadeIn(delay: 300.ms).scale(),
            ],
          ),
          const SizedBox(height: 16),
          // Security status badge
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.spacingM,
              vertical: AppTheme.spacingS,
            ),
            decoration: BoxDecoration(
              color: AppTheme.success.withOpacity(0.15),
              borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
              border: Border.all(
                color: AppTheme.success.withOpacity(0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: AppTheme.success,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.success.withOpacity(0.5),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Device Protected',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.success,
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(delay: 400.ms),
        ],
      ),
    );
  }

  Widget _buildActionCards() {
    return Column(
      children: [
        // Emotion Detection Card - Full width
        DashboardCard(
          title: 'Emotion Detection',
          subtitle: 'Analyze facial expressions',
          icon: Icons.mood,
          gradientColors: const [
            Color(0xFF667EEA),
            Color(0xFF764BA2),
          ],
          onTap: () => _navigateTo('/emotion-detection'),
          isLarge: true,
        ).animate().fadeIn(delay: 500.ms).slideY(begin: 0.1),

        const SizedBox(height: AppTheme.spacingM),

        // FIX pixel overflow: DashboardCard has a fixed height already —
        // wrapping in IntrinsicHeight added extra constraints causing 1.8px overflow
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Monitor Apps Card
            Expanded(
              child: DashboardCard(
                title: 'Monitor Apps',
                subtitle: 'Track app usage',
                icon: Icons.apps,
                gradientColors: const [
                  Color(0xFF11998E),
                  Color(0xFF38EF7D),
                ],
                onTap: () => _navigateTo('/app-selection'),
              ),
            ),

            const SizedBox(width: AppTheme.spacingM),

            // Settings Card
            Expanded(
              child: DashboardCard(
                title: 'Settings',
                subtitle: 'Configure app',
                icon: Icons.settings,
                gradientColors: const [
                  Color(0xFFFF416C),
                  Color(0xFFFF4B2B),
                ],
                onTap: () => _navigateTo('/settings'),
              ),
            ),
          ],
        ).animate().fadeIn(delay: 600.ms).slideY(begin: 0.1),
      ],
    );
  }

  Widget _buildQuickStats() {
    return Consumer<MonitoringProvider>(
      builder: (context, monitoring, _) {
        final isActive      = monitoring.isMonitoring;
        final totalAlerts   = monitoring.stats.totalAlerts;
        final todayAlerts   = monitoring.stats.todayAlerts;
        final unauthTime    = monitoring.stats.totalUnauthorizedTime;
        final selectedCount = monitoring.selectedCount;
        final activeSession = monitoring.activeSession;

        // Security score: starts at 100%, drops 5 per today alert, min 50%
        final score = isActive
            ? (100 - (todayAlerts * 5)).clamp(50, 100)
            : selectedCount > 0 ? 72 : 50;

        final scoreColor = score >= 90
            ? AppTheme.success
            : score >= 70
            ? AppTheme.warning
            : AppTheme.error;

        return Container(
          padding: const EdgeInsets.all(AppTheme.spacingM),
          decoration: AppTheme.glassDecoration(opacity: 0.05),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Quick Stats',
                    style: GoogleFonts.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  // Live alert badge
                  if (todayAlerts > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppTheme.error.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: AppTheme.error.withOpacity(0.4)),
                      ),
                      child: Text(
                        '$todayAlerts alert${todayAlerts > 1 ? 's' : ''} today',
                        style: GoogleFonts.inter(
                            fontSize: 11,
                            color: AppTheme.error,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppTheme.spacingM),
              Row(
                children: [
                  Expanded(
                    child: _buildStatItem(
                      icon: Icons.shield_outlined,
                      label: 'Security Score',
                      value: '$score%',
                      color: scoreColor,
                    ),
                  ),
                  Container(
                    width: 1, height: 60,
                    color: AppTheme.textMuted.withOpacity(0.2),
                  ),
                  Expanded(
                    child: _buildStatItem(
                      icon: Icons.access_time,
                      label: 'Unauth Time',
                      value: _fmtDuration(unauthTime),
                      color: unauthTime.inSeconds > 0
                          ? AppTheme.error
                          : AppTheme.info,
                    ),
                  ),
                  Container(
                    width: 1, height: 60,
                    color: AppTheme.textMuted.withOpacity(0.2),
                  ),
                  Expanded(
                    child: _buildStatItem(
                      icon: Icons.warning_amber_outlined,
                      label: 'Total Alerts',
                      value: '$totalAlerts',
                      color: totalAlerts > 0
                          ? AppTheme.warning
                          : AppTheme.success,
                    ),
                  ),
                ],
              ),
              // Live session banner
              if (activeSession != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withOpacity(0.1),
                    borderRadius:
                    BorderRadius.circular(AppTheme.radiusMedium),
                    border: Border.all(
                        color: AppTheme.error.withOpacity(0.35)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8, height: 8,
                        decoration: const BoxDecoration(
                            color: AppTheme.error, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '⚠ LIVE: ${activeSession.appName} — '
                              '${_elapsed(activeSession.elapsed)}',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: AppTheme.error,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ).animate().fadeIn(delay: 700.ms).slideY(begin: 0.1);
      },
    );
  }

  String _fmtDuration(Duration d) {
    if (d.inSeconds == 0) return '0s';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
  }

  String _elapsed(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }

  Widget _buildStatItem({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(height: 8),
        Text(
          value,
          style: GoogleFonts.poppins(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: AppTheme.textPrimary,
          ),
        ),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            color: AppTheme.textMuted,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}