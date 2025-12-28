import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../../theme/theme.dart';
import '../../../../core/models/app_info_model.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../core/providers/app_state_provider.dart';
import '../../../../core/utils/constants.dart';
import '../../data/repositories/app_monitor_repository.dart';

class AppSelectionPage extends StatefulWidget {
  const AppSelectionPage({super.key});

  @override
  State<AppSelectionPage> createState() => _AppSelectionPageState();
}

class _AppSelectionPageState extends State<AppSelectionPage> {
  final AppMonitorRepository _repository = AppMonitorRepository();

  List<AppInfoModel> _apps = [];
  bool _isLoading = true;
  bool _isMonitoring = false;
  bool _isStartingMonitoring = false;

  @override
  void initState() {
    super.initState();
    _loadApps();
  }

  Future<void> _loadApps() async {
    setState(() => _isLoading = true);

    try {
      final apps = await _repository.getInstalledApps();
      final storageService = context.read<StorageService>();
      final savedApps = await storageService.getSelectedApps();
      final appState = context.read<AppStateProvider>();

      // Mark previously selected apps
      final updatedApps = apps.map((app) {
        final isSelected = savedApps.any((s) => s.packageName == app.packageName);
        return app.copyWith(isSelected: isSelected);
      }).toList();

      if (mounted) {
        setState(() {
          _apps = updatedApps;
          _isLoading = false;
          _isMonitoring = appState.isMonitoringEnabled;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showErrorSnackBar('Failed to load apps');
      }
    }
  }

  int get _selectedCount => _apps.where((a) => a.isSelected).length;

  void _toggleAppSelection(int index) {
    if (_isMonitoring) return; // Can't change while monitoring

    final app = _apps[index];
    final currentCount = _selectedCount;

    if (!app.isSelected && currentCount >= AppConstants.maxAppsToMonitor) {
      _showErrorSnackBar('Maximum ${AppConstants.maxAppsToMonitor} apps can be selected');
      return;
    }

    HapticFeedback.lightImpact();
    setState(() {
      _apps[index] = app.copyWith(isSelected: !app.isSelected);
    });
  }

  Future<void> _startMonitoring() async {
    if (_selectedCount == 0) {
      _showErrorSnackBar('Please select at least one app');
      return;
    }

    setState(() => _isStartingMonitoring = true);
    HapticFeedback.mediumImpact();

    try {
      final selectedApps = _apps.where((a) => a.isSelected).toList();

      // Save selected apps
      final storageService = context.read<StorageService>();
      await storageService.saveSelectedApps(selectedApps);

      // Start monitoring
      final success = await _repository.startMonitoring(selectedApps);

      if (success && mounted) {
        await context.read<AppStateProvider>().setMonitoringEnabled(true);
        setState(() {
          _isMonitoring = true;
          _isStartingMonitoring = false;
        });
        _showSuccessSnackBar('Monitoring started for $_selectedCount apps');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isStartingMonitoring = false);
        _showErrorSnackBar('Failed to start monitoring');
      }
    }
  }

  Future<void> _stopMonitoring() async {
    HapticFeedback.mediumImpact();

    try {
      await _repository.stopMonitoring();
      await context.read<AppStateProvider>().setMonitoringEnabled(false);

      if (mounted) {
        setState(() => _isMonitoring = false);
        _showSuccessSnackBar('Monitoring stopped');
      }
    } catch (e) {
      _showErrorSnackBar('Failed to stop monitoring');
    }
  }

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 8),
            Text(message),
          ],
        ),
        backgroundColor: AppTheme.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        ),
      ),
    );
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
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _buildStatusBar(),
              Expanded(
                child: _isLoading
                    ? _buildLoadingState()
                    : _buildAppsList(),
              ),
              _buildBottomControls(),
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
              child: const Icon(Icons.arrow_back, color: AppTheme.textPrimary),
            ),
          ),
          const SizedBox(width: AppTheme.spacingM),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Monitor Apps',
                  style: GoogleFonts.poppins(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                Text(
                  'Select up to ${AppConstants.maxAppsToMonitor} apps to monitor',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn().slideY(begin: -0.2);
  }

  Widget _buildStatusBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppTheme.spacingM),
      padding: const EdgeInsets.all(AppTheme.spacingM),
      decoration: AppTheme.glassDecoration(
        opacity: _isMonitoring ? 0.15 : 0.05,
        borderColor: _isMonitoring
            ? AppTheme.success.withOpacity(0.3)
            : null,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: (_isMonitoring ? AppTheme.success : AppTheme.primaryPurple)
                  .withOpacity(0.2),
              borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
            ),
            child: Icon(
              _isMonitoring ? Icons.shield : Icons.apps,
              color: _isMonitoring ? AppTheme.success : AppTheme.primaryPurple,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isMonitoring ? 'Monitoring Active' : 'Monitoring Inactive',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _isMonitoring ? AppTheme.success : AppTheme.textPrimary,
                  ),
                ),
                Text(
                  '$_selectedCount / ${AppConstants.maxAppsToMonitor} apps selected',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (_isMonitoring)
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: AppTheme.success,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.success.withOpacity(0.5),
                    blurRadius: 8,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ).animate(onPlay: (c) => c.repeat(reverse: true))
                .fadeIn(duration: 800.ms)
                .fadeOut(duration: 800.ms),
        ],
      ),
    ).animate().fadeIn(delay: 100.ms);
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryPurple),
          ),
          const SizedBox(height: 16),
          Text(
            'Loading installed apps...',
            style: GoogleFonts.inter(color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildAppsList() {
    return ListView.builder(
      padding: const EdgeInsets.all(AppTheme.spacingM),
      itemCount: _apps.length,
      itemBuilder: (context, index) {
        final app = _apps[index];
        return _buildAppTile(app, index)
            .animate()
            .fadeIn(delay: Duration(milliseconds: 50 * index))
            .slideX(begin: 0.1);
      },
    );
  }

  Widget _buildAppTile(AppInfoModel app, int index) {
    final isSelected = app.isSelected;

    return GestureDetector(
      onTap: () => _toggleAppSelection(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: AppTheme.spacingS),
        padding: const EdgeInsets.all(AppTheme.spacingM),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primaryPurple.withOpacity(0.15)
              : AppTheme.surfaceDark.withOpacity(0.5),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(
            color: isSelected
                ? AppTheme.primaryPurple.withOpacity(0.5)
                : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            // App icon placeholder
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    _getAppColor(app.name),
                    _getAppColor(app.name).withOpacity(0.7),
                  ],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  app.name.substring(0, 1).toUpperCase(),
                  style: GoogleFonts.poppins(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    app.name,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  Text(
                    app.packageName,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: AppTheme.textMuted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: isSelected
                    ? AppTheme.primaryPurple
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.primaryPurple
                      : AppTheme.textMuted,
                  width: 2,
                ),
              ),
              child: isSelected
                  ? const Icon(Icons.check, color: Colors.white, size: 18)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Color _getAppColor(String appName) {
    final colors = [
      const Color(0xFFE1306C), // Instagram pink
      const Color(0xFF1877F2), // Facebook blue
      const Color(0xFF25D366), // WhatsApp green
      const Color(0xFF1DA1F2), // Twitter blue
      const Color(0xFFFF0000), // YouTube red
      const Color(0xFF000000), // TikTok black
      const Color(0xFFFFFC00), // Snapchat yellow
      const Color(0xFFE50914), // Netflix red
      const Color(0xFF1DB954), // Spotify green
    ];
    return colors[appName.hashCode % colors.length];
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.all(AppTheme.spacingM),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark.withOpacity(0.5),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusLarge),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // Start/Stop Monitoring buttons
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: _isMonitoring ? _stopMonitoring : _startMonitoring,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      height: 52,
                      decoration: BoxDecoration(
                        gradient: _isMonitoring
                            ? null
                            : (_selectedCount > 0
                            ? const LinearGradient(
                          colors: [Color(0xFF11998E), Color(0xFF38EF7D)],
                        )
                            : null),
                        color: _isMonitoring
                            ? AppTheme.error
                            : (_selectedCount == 0 ? AppTheme.surfaceDark : null),
                        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                        boxShadow: _selectedCount > 0 && !_isMonitoring
                            ? AppTheme.glowShadow(const Color(0xFF11998E), intensity: 0.3)
                            : null,
                      ),
                      child: Center(
                        child: _isStartingMonitoring
                            ? SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        )
                            : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _isMonitoring ? Icons.stop : Icons.play_arrow,
                              color: _selectedCount > 0 || _isMonitoring
                                  ? Colors.white
                                  : AppTheme.textMuted,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _isMonitoring ? 'Stop Monitoring' : 'Start Monitoring',
                              style: GoogleFonts.inter(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: _selectedCount > 0 || _isMonitoring
                                    ? Colors.white
                                    : AppTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: AppTheme.spacingS),

            // Show Logs button
            GestureDetector(
              onTap: () {
                HapticFeedback.lightImpact();
                Navigator.pushNamed(context, '/logs');
              },
              child: Container(
                width: double.infinity,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                  border: Border.all(
                    color: AppTheme.textMuted.withOpacity(0.3),
                  ),
                ),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.article_outlined,
                        color: AppTheme.textSecondary,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Show Logs',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ).animate().fadeIn(delay: 300.ms).slideY(begin: 0.2);
  }
}
