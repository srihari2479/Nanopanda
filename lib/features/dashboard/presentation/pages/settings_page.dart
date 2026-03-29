// lib/features/dashboard/presentation/pages/settings_page.dart
//
// Production Settings page — all options fully wired.
//
// BUG FIXES vs old version:
//
// BUG 1 — _notificationsEnabled fake toggle:
//   Old: only setState(), never persisted, always resets to true on open.
//   Fix: persisted via StorageService.saveSetting('notifications_enabled').
//        Loaded in _loadSettings() on init.
//
// BUG 2 — _backgroundMonitoring desync:
//   Old: reads appState.isMonitoringEnabled (just a bool flag), ignores
//        MonitoringProvider.isMonitoring (the real state). Out of sync
//        whenever monitoring is started/stopped from app_selection_page.
//   Fix: reads from MonitoringProvider.isMonitoring directly. Uses Consumer
//        so it rebuilds when external changes happen.
//
// BUG 3 — Reset All Data doesn't stop monitoring first:
//   Old: called resetAllData() directly. Foreground service kept running
//        after reset — monitoring a cleared profile with no face vector.
//   Fix: _handleResetData() calls monitor.stopMonitoring() before reset.
//
// BUG 4 — No loading state on destructive actions:
//   Old: no disabled state. Double-tap during async caused duplicate dialogs.
//   Fix: _isBusy flag disables all tappable tiles while any async op runs.
//
// BUG 5 — Version hardcoded:
//   Old: AppConstants.appVersion (static string).
//   Fix: PackageInfo.fromPlatform() loads real version from build.gradle.
//
// BUG 6 — Missing mounted guard after await:
//   Old: context.read() called after await without mounted check.
//   Fix: every async handler checks mounted before touching context.
//
// BUG 7 — Monitoring toggle silent fail when no apps selected:
//   Old: startMonitoring() returns false, nothing shown.
//   Fix: shows snackbar "Select apps to monitor first" with shortcut button.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../../../theme/theme.dart';
import '../../../../core/providers/app_state_provider.dart';
import '../../../../core/providers/monitoring_provider.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../core/utils/constants.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // ── Persisted settings ────────────────────────────────────────────────────
  bool _logsEnabled          = true;
  bool _notificationsEnabled = true;

  // ── UI state ──────────────────────────────────────────────────────────────
  bool   _isBusy  = false;   // disables all tiles during any async op
  String _version = '';
  String _build   = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadVersion();
  }

  Future<void> _loadSettings() async {
    final storage  = context.read<StorageService>();
    final appState = context.read<AppStateProvider>();
    if (!mounted) return;
    setState(() {
      _logsEnabled          = appState.isLogsEnabled;
      _notificationsEnabled =
          storage.getSetting<bool>('notifications_enabled') ?? true;
    });
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _version = info.version;
        _build   = info.buildNumber;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _version = AppConstants.appVersion;
        _build   = '';
      });
    }
  }

  // ── Handlers ──────────────────────────────────────────────────────────────

  Future<void> _handleReRegisterFace() async {
    if (_isBusy) return;
    final confirmed = await _confirm(
      title:   'Re-register face',
      message: 'This deletes your current face data and starts '
          'a fresh registration. Continue?',
    );
    if (!confirmed || !mounted) return;

    setState(() => _isBusy = true);
    try {
      final storage  = context.read<StorageService>();
      final appState = context.read<AppStateProvider>();
      // deleteFaceVector() also clears the embedding version tag,
      // so the new registration will write the correct 'float32_v1' tag.
      await storage.deleteFaceVector();
      await appState.setFaceRegistered(false);
      if (!mounted) return;
      Navigator.of(context)
          .pushNamedAndRemoveUntil('/registration', (_) => false);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _handleResetData() async {
    if (_isBusy) return;
    final confirmed = await _confirm(
      title:         'Reset all data',
      message:       'Deletes face registration, all logs, and stops '
          'monitoring. This cannot be undone.',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _isBusy = true);
    try {
      final monitor  = context.read<MonitoringProvider>();
      final appState = context.read<AppStateProvider>();

      // BUG 3 FIX: stop foreground service before clearing storage
      if (monitor.isMonitoring) {
        await monitor.stopMonitoring();
      }
      if (!mounted) return;

      await appState.resetAllData();
      if (!mounted) return;
      Navigator.of(context)
          .pushNamedAndRemoveUntil('/registration', (_) => false);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _handleLogout() async {
    if (_isBusy) return;
    final confirmed = await _confirm(
      title:   'Lock app',
      message: 'You will need face verification to re-enter.',
    );
    if (!confirmed || !mounted) return;
    context.read<AppStateProvider>().logout();
    Navigator.of(context)
        .pushNamedAndRemoveUntil('/login', (_) => false);
  }

  Future<void> _handleMonitoringToggle(bool value) async {
    if (_isBusy) return;
    final monitor = context.read<MonitoringProvider>();

    if (value && monitor.selectedCount == 0) {
      // BUG 7 FIX: no apps selected → explain and offer shortcut
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Select apps to monitor first',
            style: GoogleFonts.inter(color: Colors.white),
          ),
          backgroundColor: AppTheme.warning,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          ),
          action: SnackBarAction(
            label:     'Select Apps',
            textColor: Colors.white,
            onPressed: () =>
                Navigator.pushNamed(context, '/app-selection'),
          ),
        ),
      );
      return;
    }

    setState(() => _isBusy = true);
    try {
      await monitor.setMonitoringEnabledFromSettings(value);
      if (!mounted) return;
      if (!value) return; // stopped — nothing more to do

      if (monitor.status == MonitoringStatus.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              monitor.errorMessage ?? 'Permission required',
              style: GoogleFonts.inter(color: Colors.white),
            ),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius:
              BorderRadius.circular(AppTheme.radiusMedium),
            ),
            action: SnackBarAction(
              label:     'Grant',
              textColor: Colors.white,
              onPressed: () => monitor.openUsageAccessSettings(),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _handleClearLogs() async {
    if (_isBusy) return;
    final confirmed = await _confirm(
      title:         'Clear all logs',
      message:       'All monitoring history will be deleted permanently.',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _isBusy = true);
    try {
      await context.read<MonitoringProvider>().clearLogs();
      if (!mounted) return;
      _showSnack('Logs cleared', color: AppTheme.success);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  // ── Confirm dialog ─────────────────────────────────────────────────────────

  Future<bool> _confirm({
    required String title,
    required String message,
    bool isDestructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
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
            child: Text('Cancel',
                style: GoogleFonts.inter(color: AppTheme.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              isDestructive ? 'Delete' : 'Confirm',
              style: GoogleFonts.inter(
                color: isDestructive
                    ? AppTheme.error
                    : AppTheme.primaryPurple,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showSnack(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg,
          style: GoogleFonts.inter(color: Colors.white)),
      backgroundColor: color ?? AppTheme.surfaceDark,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
    ));
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────

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
              SliverToBoxAdapter(child: _buildHeader()),
              SliverPadding(
                padding: const EdgeInsets.all(AppTheme.spacingM),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    _buildFaceSection()
                        .animate().fadeIn(delay: 100.ms),
                    const SizedBox(height: AppTheme.spacingM),
                    _buildMonitoringSection()
                        .animate().fadeIn(delay: 180.ms),
                    const SizedBox(height: AppTheme.spacingM),
                    _buildPrivacySection()
                        .animate().fadeIn(delay: 260.ms),
                    const SizedBox(height: AppTheme.spacingM),
                    _buildAboutSection()
                        .animate().fadeIn(delay: 340.ms),
                    const SizedBox(height: AppTheme.spacingL),
                    _buildLogoutButton()
                        .animate().fadeIn(delay: 420.ms),
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

  // ── Header ─────────────────────────────────────────────────────────────────

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
              child: const Icon(Icons.arrow_back,
                  color: AppTheme.textPrimary),
            ),
          ),
          const SizedBox(width: AppTheme.spacingM),
          Text(
            'Settings',
            style: GoogleFonts.poppins(
              fontSize:   24,
              fontWeight: FontWeight.bold,
              color:      AppTheme.textPrimary,
            ),
          ),
        ],
      ),
    ).animate().fadeIn().slideX(begin: -0.1);
  }

  // ── Face Recognition section ───────────────────────────────────────────────

  Widget _buildFaceSection() {
    return Consumer<AppStateProvider>(
      builder: (_, appState, __) {
        return _buildSection(
          title: 'Face recognition',
          icon:  Icons.face_retouching_natural,
          children: [
            // Face registered status chip
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.spacingM, 0, AppTheme.spacingM, 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: appState.isFaceRegistered
                          ? AppTheme.success.withOpacity(0.15)
                          : AppTheme.warning.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          appState.isFaceRegistered
                              ? Icons.verified_user
                              : Icons.warning_amber_rounded,
                          size: 14,
                          color: appState.isFaceRegistered
                              ? AppTheme.success
                              : AppTheme.warning,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          appState.isFaceRegistered
                              ? 'Face registered'
                              : 'Not registered',
                          style: GoogleFonts.inter(
                            fontSize:   12,
                            fontWeight: FontWeight.w500,
                            color: appState.isFaceRegistered
                                ? AppTheme.success
                                : AppTheme.warning,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            _buildTile(
              icon:     Icons.refresh_rounded,
              title:    'Re-register face',
              subtitle: 'Replace current face data',
              onTap:    _isBusy ? null : _handleReRegisterFace,
            ),
            _buildTile(
              icon:          Icons.delete_forever_outlined,
              title:         'Delete face data',
              subtitle:      'Remove stored biometric data',
              onTap:         _isBusy ? null : _handleResetData,
              isDestructive: true,
            ),
          ],
        );
      },
    );
  }

  // ── Monitoring section ─────────────────────────────────────────────────────

  Widget _buildMonitoringSection() {
    return Consumer<MonitoringProvider>(
      builder: (_, monitor, __) {
        // BUG 2 FIX: read from MonitoringProvider.isMonitoring (real state),
        // not AppStateProvider.isMonitoringEnabled (stale flag).
        final isOn = monitor.isMonitoring;

        return _buildSection(
          title: 'Monitoring',
          icon:  Icons.monitor_heart_outlined,
          children: [
            // Live status indicator
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.spacingM, 0, AppTheme.spacingM, 8),
              child: Row(
                children: [
                  _StatusDot(active: isOn),
                  const SizedBox(width: 6),
                  Text(
                    isOn
                        ? 'Watching ${monitor.selectedCount} app${monitor.selectedCount != 1 ? "s" : ""}'
                        : 'Protection off',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: isOn
                          ? AppTheme.success
                          : AppTheme.textMuted,
                    ),
                  ),
                  if (monitor.stats.totalAlerts > 0) ...[
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.error.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${monitor.stats.totalAlerts} alert${monitor.stats.totalAlerts != 1 ? "s" : ""}',
                        style: GoogleFonts.inter(
                            fontSize: 11, color: AppTheme.error),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            _buildSwitch(
              icon:    isOn ? Icons.shield : Icons.shield_outlined,
              title:   'App protection',
              subtitle: isOn
                  ? 'Actively monitoring'
                  : 'Tap to start protecting',
              value:    isOn,
              loading:  monitor.isLoading,
              onChanged: _isBusy || monitor.isLoading
                  ? null
                  : _handleMonitoringToggle,
            ),

            _buildTile(
              icon:     Icons.app_settings_alt_outlined,
              title:    'Manage protected apps',
              subtitle: monitor.selectedCount == 0
                  ? 'No apps selected'
                  : '${monitor.selectedCount} app${monitor.selectedCount != 1 ? "s" : ""} selected',
              onTap: _isBusy
                  ? null
                  : () => Navigator.pushNamed(context, '/app-selection'),
            ),

            _buildTile(
              icon:     Icons.history_rounded,
              title:    'View access logs',
              subtitle: monitor.logs.isEmpty
                  ? 'No activity yet'
                  : '${monitor.logs.length} entries',
              onTap: _isBusy
                  ? null
                  : () => Navigator.pushNamed(context, '/logs'),
            ),

            if (monitor.logs.isNotEmpty)
              _buildTile(
                icon:          Icons.delete_sweep_outlined,
                title:         'Clear all logs',
                subtitle:      '${monitor.logs.length} entries will be deleted',
                onTap:         _isBusy ? null : _handleClearLogs,
                isDestructive: true,
              ),
          ],
        );
      },
    );
  }

  // ── Privacy & Security section ─────────────────────────────────────────────

  Widget _buildPrivacySection() {
    return _buildSection(
      title: 'Privacy & security',
      icon:  Icons.shield_outlined,
      children: [
        // BUG 1 FIX: notifications toggle now persists via StorageService
        _buildSwitch(
          icon:     Icons.notifications_outlined,
          title:    'Security notifications',
          subtitle: 'Alerts when unauthorized access detected',
          value:    _notificationsEnabled,
          onChanged: _isBusy
              ? null
              : (value) async {
            setState(() => _notificationsEnabled = value);
            await context
                .read<StorageService>()
                .saveSetting('notifications_enabled', value);
          },
        ),
        _buildSwitch(
          icon:     Icons.article_outlined,
          title:    'Enable logs',
          subtitle: 'Record unauthorized access sessions',
          value:    _logsEnabled,
          onChanged: _isBusy
              ? null
              : (value) async {
            setState(() => _logsEnabled = value);
            await context
                .read<AppStateProvider>()
                .setLogsEnabled(value);
          },
        ),
        _buildTile(
          icon:     Icons.privacy_tip_outlined,
          title:    'Privacy policy',
          subtitle: 'How we handle your data',
          onTap:    () =>
              _showSnack('All data stored locally on your device'),
        ),
      ],
    );
  }

  // ── About section ──────────────────────────────────────────────────────────

  Widget _buildAboutSection() {
    // BUG 5 FIX: version loaded from PackageInfo.fromPlatform()
    final versionStr = _version.isEmpty
        ? '…'
        : (_build.isEmpty ? _version : '$_version (build $_build)');

    return _buildSection(
      title: 'About',
      icon:  Icons.info_outline_rounded,
      children: [
        _buildInfoRow(
          icon:  Icons.apps_rounded,
          title: 'App name',
          value: AppConstants.appName,
        ),
        _buildInfoRow(
          icon:  Icons.new_releases_outlined,
          title: 'Version',
          value: versionStr,
        ),
        _buildInfoRow(
          icon:  Icons.security_rounded,
          title: 'Face model',
          value: 'FaceNet-128 INT8',
        ),
        _buildInfoRow(
          icon:  Icons.storage_rounded,
          title: 'Storage',
          value: 'On-device only',
        ),
      ],
    );
  }

  // ── Logout button ──────────────────────────────────────────────────────────

  Widget _buildLogoutButton() {
    return GestureDetector(
      onTap: _isBusy ? null : _handleLogout,
      child: AnimatedOpacity(
        opacity:  _isBusy ? 0.4 : 1.0,
        duration: const Duration(milliseconds: 200),
        child: Container(
          width:   double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border.all(
              color: AppTheme.error.withOpacity(0.4),
            ),
            borderRadius:
            BorderRadius.circular(AppTheme.radiusMedium),
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline_rounded,
                    color: AppTheme.error, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Lock app',
                  style: GoogleFonts.inter(
                    fontSize:   16,
                    fontWeight: FontWeight.w600,
                    color:      AppTheme.error,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Section wrapper ────────────────────────────────────────────────────────

  Widget _buildSection({
    required String       title,
    required IconData     icon,
    required List<Widget> children,
  }) {
    return Container(
      decoration: AppTheme.glassDecoration(opacity: 0.05),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.spacingM, AppTheme.spacingM,
                AppTheme.spacingM, 4),
            child: Row(
              children: [
                Icon(icon, color: AppTheme.primaryPurple, size: 18),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: GoogleFonts.poppins(
                    fontSize:   15,
                    fontWeight: FontWeight.w600,
                    color:      AppTheme.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          ...children,
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ── Tile widgets ───────────────────────────────────────────────────────────

  Widget _buildTile({
    required IconData icon,
    required String   title,
    required String   subtitle,
    VoidCallback?     onTap,
    bool              isDestructive = false,
  }) {
    final color    = isDestructive ? AppTheme.error : AppTheme.primaryPurple;
    final disabled = onTap == null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: disabled
            ? null
            : () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: AnimatedOpacity(
          opacity:  disabled ? 0.4 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.spacingM,
              vertical:   AppTheme.spacingS + 4,
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.13),
                    borderRadius:
                    BorderRadius.circular(AppTheme.radiusSmall),
                  ),
                  child: Icon(icon, color: color, size: 19),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.inter(
                          fontSize:   15,
                          fontWeight: FontWeight.w500,
                          color: isDestructive
                              ? AppTheme.error
                              : AppTheme.textPrimary,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color:    AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    color: AppTheme.textMuted, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSwitch({
    required IconData       icon,
    required String         title,
    required String         subtitle,
    required bool           value,
    bool                    loading  = false,
    ValueChanged<bool>?     onChanged,
  }) {
    final disabled = onChanged == null;

    return AnimatedOpacity(
      opacity:  disabled ? 0.4 : 1.0,
      duration: const Duration(milliseconds: 200),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingM,
          vertical:   AppTheme.spacingS + 4,
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: AppTheme.primaryPurple.withOpacity(0.13),
                borderRadius:
                BorderRadius.circular(AppTheme.radiusSmall),
              ),
              child: Icon(icon,
                  color: AppTheme.primaryPurple, size: 19),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.inter(
                      fontSize:   15,
                      fontWeight: FontWeight.w500,
                      color:      AppTheme.textPrimary,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color:    AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            if (loading)
              const SizedBox(
                width:  22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation(
                      AppTheme.primaryPurple),
                ),
              )
            else
              Switch(
                value:     value,
                onChanged: disabled
                    ? null
                    : (v) {
                  HapticFeedback.lightImpact();
                  onChanged(v);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow({
    required IconData icon,
    required String   title,
    required String   value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacingM,
        vertical:   AppTheme.spacingS + 2,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: AppTheme.primaryPurple.withOpacity(0.13),
              borderRadius:
              BorderRadius.circular(AppTheme.radiusSmall),
            ),
            child: Icon(icon,
                color: AppTheme.primaryPurple, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: GoogleFonts.inter(
                fontSize:   15,
                fontWeight: FontWeight.w500,
                color:      AppTheme.textPrimary,
              ),
            ),
          ),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 13,
              color:    AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Animated status dot (pulsing green = active)
// ─────────────────────────────────────────────────────────────────────────────

class _StatusDot extends StatefulWidget {
  final bool active;
  const _StatusDot({required this.active});

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.active) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_StatusDot old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.active && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.active ? AppTheme.success : AppTheme.textMuted;

    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Container(
        width:  10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withOpacity(
            widget.active ? 0.5 + _c.value * 0.5 : 0.5,
          ),
        ),
      ),
    );
  }
}