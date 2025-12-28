import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../../theme/theme.dart';
import '../../../../core/providers/app_state_provider.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../core/utils/constants.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _backgroundMonitoring = false;
  bool _logsEnabled = true;
  bool _notificationsEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final appState = context.read<AppStateProvider>();
    setState(() {
      _backgroundMonitoring = appState.isMonitoringEnabled;
      _logsEnabled = appState.isLogsEnabled;
    });
  }

  Future<void> _handleReRegisterFace() async {
    final confirmed = await _showConfirmDialog(
      title: 'Re-register Face',
      message: 'This will delete your current face data and require new registration. Continue?',
    );

    if (confirmed && mounted) {
      final storageService = context.read<StorageService>();
      await storageService.deleteFaceVector();
      await context.read<AppStateProvider>().setFaceRegistered(false);

      if (mounted) {
        Navigator.of(context).pushNamedAndRemoveUntil('/registration', (route) => false);
      }
    }
  }

  Future<void> _handleResetData() async {
    final confirmed = await _showConfirmDialog(
      title: 'Reset All Data',
      message: 'This will delete all app data including face registration and logs. This cannot be undone.',
      isDestructive: true,
    );

    if (confirmed && mounted) {
      await context.read<AppStateProvider>().resetAllData();

      if (mounted) {
        Navigator.of(context).pushNamedAndRemoveUntil('/registration', (route) => false);
      }
    }
  }

  Future<void> _handleLogout() async {
    final confirmed = await _showConfirmDialog(
      title: 'Logout',
      message: 'You will need to verify your face again to access the app.',
    );

    if (confirmed && mounted) {
      context.read<AppStateProvider>().logout();
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
    }
  }

  Future<bool> _showConfirmDialog({
    required String title,
    required String message,
    bool isDestructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: Text(
          title,
          style: GoogleFonts.poppins(
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
        content: Text(
          message,
          style: GoogleFonts.inter(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancel',
              style: GoogleFonts.inter(color: AppTheme.textMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Confirm',
              style: GoogleFonts.inter(
                color: isDestructive ? AppTheme.error : AppTheme.primaryPurple,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              // Header
              SliverToBoxAdapter(
                child: _buildHeader(),
              ),

              // Settings sections
              SliverPadding(
                padding: const EdgeInsets.all(AppTheme.spacingM),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    _buildFaceSection().animate().fadeIn(delay: 200.ms),
                    const SizedBox(height: AppTheme.spacingM),
                    _buildMonitoringSection().animate().fadeIn(delay: 300.ms),
                    const SizedBox(height: AppTheme.spacingM),
                    _buildPrivacySection().animate().fadeIn(delay: 400.ms),
                    const SizedBox(height: AppTheme.spacingM),
                    _buildAboutSection().animate().fadeIn(delay: 500.ms),
                    const SizedBox(height: AppTheme.spacingL),
                    _buildLogoutButton().animate().fadeIn(delay: 600.ms),
                    const SizedBox(height: AppTheme.spacingXL),
                  ]),
                ),
              ),
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
          Text(
            'Settings',
            style: GoogleFonts.poppins(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
        ],
      ),
    ).animate().fadeIn().slideX(begin: -0.1);
  }

  Widget _buildFaceSection() {
    return _buildSection(
      title: 'Face Recognition',
      icon: Icons.face,
      children: [
        _buildSettingsTile(
          icon: Icons.refresh,
          title: 'Re-register Face',
          subtitle: 'Update your face data',
          onTap: _handleReRegisterFace,
        ),
        _buildSettingsTile(
          icon: Icons.delete_outline,
          title: 'Reset Face Data',
          subtitle: 'Delete stored face vector',
          onTap: _handleResetData,
          isDestructive: true,
        ),
      ],
    );
  }

  Widget _buildMonitoringSection() {
    return _buildSection(
      title: 'Monitoring',
      icon: Icons.monitor_heart,
      children: [
        _buildSwitchTile(
          icon: Icons.play_circle_outline,
          title: 'Background Monitoring',
          subtitle: 'Monitor apps in background',
          value: _backgroundMonitoring,
          onChanged: (value) async {
            setState(() => _backgroundMonitoring = value);
            await context.read<AppStateProvider>().setMonitoringEnabled(value);
          },
        ),
        _buildSwitchTile(
          icon: Icons.article_outlined,
          title: 'Enable Logs',
          subtitle: 'Record monitoring activity',
          value: _logsEnabled,
          onChanged: (value) async {
            setState(() => _logsEnabled = value);
            await context.read<AppStateProvider>().setLogsEnabled(value);
          },
        ),
        _buildSettingsTile(
          icon: Icons.history,
          title: 'View Logs',
          subtitle: 'See monitoring history',
          onTap: () => Navigator.pushNamed(context, '/logs'),
        ),
      ],
    );
  }

  Widget _buildPrivacySection() {
    return _buildSection(
      title: 'Privacy & Security',
      icon: Icons.shield_outlined,
      children: [
        _buildSwitchTile(
          icon: Icons.notifications_outlined,
          title: 'Notifications',
          subtitle: 'Security alerts and updates',
          value: _notificationsEnabled,
          onChanged: (value) {
            setState(() => _notificationsEnabled = value);
          },
        ),
        _buildSettingsTile(
          icon: Icons.privacy_tip_outlined,
          title: 'Privacy Policy',
          subtitle: 'Read our privacy terms',
          onTap: () => _showInfoSnackBar('Privacy Policy - Coming Soon'),
        ),
        _buildSettingsTile(
          icon: Icons.description_outlined,
          title: 'Terms of Service',
          subtitle: 'Read our terms',
          onTap: () => _showInfoSnackBar('Terms of Service - Coming Soon'),
        ),
      ],
    );
  }

  Widget _buildAboutSection() {
    return _buildSection(
      title: 'About',
      icon: Icons.info_outline,
      children: [
        _buildInfoTile(
          icon: Icons.apps,
          title: 'App Name',
          value: AppConstants.appName,
        ),
        _buildInfoTile(
          icon: Icons.new_releases_outlined,
          title: 'Version',
          value: AppConstants.appVersion,
        ),
        _buildSettingsTile(
          icon: Icons.star_outline,
          title: 'Rate App',
          subtitle: 'Share your feedback',
          onTap: () => _showInfoSnackBar('Rate App - Coming Soon'),
        ),
      ],
    );
  }

  Widget _buildSection({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Container(
      decoration: AppTheme.glassDecoration(opacity: 0.05),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppTheme.spacingM),
            child: Row(
              children: [
                Icon(icon, color: AppTheme.primaryPurple, size: 20),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: GoogleFonts.poppins(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _buildSettingsTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spacingM,
            vertical: AppTheme.spacingS + 4,
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (isDestructive ? AppTheme.error : AppTheme.primaryPurple)
                      .withOpacity(0.15),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                ),
                child: Icon(
                  icon,
                  color: isDestructive ? AppTheme.error : AppTheme.primaryPurple,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: isDestructive ? AppTheme.error : AppTheme.textPrimary,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: AppTheme.textMuted,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacingM,
        vertical: AppTheme.spacingS + 4,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.primaryPurple.withOpacity(0.15),
              borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
            ),
            child: Icon(icon, color: AppTheme.primaryPurple, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textPrimary,
                  ),
                ),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: (v) {
              HapticFeedback.lightImpact();
              onChanged(v);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInfoTile({
    required IconData icon,
    required String title,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacingM,
        vertical: AppTheme.spacingS + 4,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.primaryPurple.withOpacity(0.15),
              borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
            ),
            child: Icon(icon, color: AppTheme.primaryPurple, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 14,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogoutButton() {
    return GestureDetector(
      onTap: _handleLogout,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.error.withOpacity(0.5)),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.logout, color: AppTheme.error, size: 20),
              const SizedBox(width: 8),
              Text(
                'Logout',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.error,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showInfoSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppTheme.surfaceDark,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        ),
      ),
    );
  }
}
