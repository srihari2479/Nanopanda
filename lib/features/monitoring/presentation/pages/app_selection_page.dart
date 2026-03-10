// lib/features/monitoring/presentation/pages/app_selection_page.dart
//
// Production-ready app selection & monitoring control page.
// Features:
//  • Real installed apps via device_apps (icons included)
//  • Usage-Stats permission banner with deep-link to settings
//  • Live search / filter
//  • Animated selection with max-limit guard
//  • Start/Stop monitoring with haptic feedback
//  • Live monitoring status indicator

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../../theme/theme.dart';
import '../../../../core/models/app_info_model.dart';
import '../../../../core/providers/monitoring_provider.dart';
import '../../../../core/services/storage_service.dart';
import '../../data/repositories/app_monitor_repository.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Max apps constant (can also come from AppConstants if you have it)
// ─────────────────────────────────────────────────────────────────────────────
const int _kMaxApps = 10;

class AppSelectionPage extends StatefulWidget {
  const AppSelectionPage({super.key});

  @override
  State<AppSelectionPage> createState() => _AppSelectionPageState();
}

class _AppSelectionPageState extends State<AppSelectionPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {

  // Declared late — injected in initState where context is available
  late final AppMonitorRepository _repo;
  final _searchCtrl    = TextEditingController();
  final _scrollCtrl    = ScrollController();

  List<AppInfoModel> _allApps      = [];
  List<AppInfoModel> _filtered     = [];
  bool               _isLoadingApps = true;
  bool               _showSearch    = false;
  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    // Inject StorageService so repo can read/write the apps cache
    _repo = AppMonitorRepository(context.read<StorageService>());
    WidgetsBinding.instance.addObserver(this);
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _loadApps();
    _searchCtrl.addListener(_onSearch);
  }

  // FIX: re-check permission whenever app comes back to foreground
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<MonitoringProvider>().refreshPermissionStatus();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseCtrl.dispose();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ── Data loading ───────────────────────────────────────────────────────────

  /// [forceRefresh] bypasses cache and fetches fresh from device.
  Future<void> _loadApps({bool forceRefresh = false}) async {
    setState(() => _isLoadingApps = true);
    try {
      // Load installed apps (from cache or device)
      final installed = await _repo.getInstalledApps(forceRefresh: forceRefresh);

      // FIX race condition: read persisted selections directly from storage
      // instead of relying on MonitoringProvider._selectedApps, which may
      // not have finished bootstrapping yet on cold start.
      final saved = await context.read<StorageService>().getSelectedApps();
      final savedPackages = {
        for (final a in saved.where((x) => x.isSelected)) a.packageName
      };

      // Merge: installed apps + restore saved selections
      final merged = installed.map((a) =>
          a.copyWith(isSelected: savedPackages.contains(a.packageName)),
      ).toList();

      final provider = context.read<MonitoringProvider>();
      provider.setApps(merged);
      _allApps  = provider.selectedApps;
      _filtered = List.from(_allApps);
    } catch (_) {
      _allApps  = MockApps.getMockApps();
      _filtered = List.from(_allApps);
    } finally {
      if (mounted) setState(() => _isLoadingApps = false);
    }
  }

  void _onSearch() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? List.from(_allApps)
          : _allApps
          .where((a) =>
      a.name.toLowerCase().contains(q) ||
          a.packageName.toLowerCase().contains(q))
          .toList();
    });
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  void _toggleApp(AppInfoModel app) {
    final provider = context.read<MonitoringProvider>();
    if (provider.isMonitoring) return;

    final selectedCount = provider.selectedApps.where((a) => a.isSelected).length;

    if (!app.isSelected && selectedCount >= _kMaxApps) {
      HapticFeedback.heavyImpact();
      _showSnack('Maximum $_kMaxApps apps can be selected', isError: true);
      return;
    }

    HapticFeedback.selectionClick();
    provider.toggleApp(app);

    // FIX: persist selection immediately so closing the app never loses it.
    // Previously only saved on "Start Protection" — toggling then closing = lost.
    provider.saveSelectedApps();

    // Sync local lists
    setState(() {
      _allApps  = provider.selectedApps;
      _filtered = _searchCtrl.text.isEmpty
          ? List.from(_allApps)
          : _allApps
          .where((a) =>
          a.name.toLowerCase().contains(_searchCtrl.text.toLowerCase()))
          .toList();
    });
  }

  Future<void> _startMonitoring() async {
    HapticFeedback.mediumImpact();
    final provider = context.read<MonitoringProvider>();

    // FIX: always do a fresh permission check before checking cached value —
    // the banner may still show even after permission was already granted
    await provider.refreshPermissionStatus();

    if (!provider.hasPermission) {
      _showPermissionDialog();
      return;
    }

    final ok = await provider.startMonitoring();
    if (!mounted) return;

    if (ok) {
      _showSnack('Monitoring started for ${provider.selectedCount} apps');
    } else if (provider.errorMessage != null &&
        provider.errorMessage!.toLowerCase().contains('permission')) {
      _showPermissionDialog();
    } else if (provider.errorMessage != null) {
      _showSnack(provider.errorMessage!, isError: true);
    }
  }

  Future<void> _stopMonitoring() async {
    HapticFeedback.mediumImpact();
    await context.read<MonitoringProvider>().stopMonitoring();
    if (mounted) _showSnack('Monitoring stopped');
  }

  void _showPermissionDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: Row(
          children: [
            const Icon(Icons.admin_panel_settings, color: AppTheme.warning),
            const SizedBox(width: 10),
            Text(
              'Permission Required',
              style: GoogleFonts.poppins(
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
          ],
        ),
        content: Text(
          'Nanopanda needs "Usage Access" permission to detect which app '
              'is in the foreground.\n\n'
              'Go to:\nSettings → Apps → Special App Access → Usage Access → '
              'Nanopanda → Allow',
          style: GoogleFonts.inter(
            fontSize: 14,
            color: AppTheme.textSecondary,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: GoogleFonts.inter(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryPurple,
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              await context.read<MonitoringProvider>().openUsageAccessSettings();
              // After returning from settings, recheck
              if (mounted) {
                await context.read<MonitoringProvider>().refreshPermissionStatus();
              }
            },
            child: Text('Open Settings',
                style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(
          isError ? Icons.error_outline : Icons.check_circle_outline,
          color: Colors.white,
          size: 18,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(msg, style: GoogleFonts.inter())),
      ]),
      backgroundColor: isError ? AppTheme.error : AppTheme.success,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
    ));
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Consumer<MonitoringProvider>(
      builder: (context, monitoring, _) {
        return Scaffold(
          body: Container(
            decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
            child: SafeArea(
              child: Column(
                children: [
                  _buildHeader(monitoring),
                  if (!monitoring.hasPermission)
                    _buildPermissionBanner(monitoring),
                  _buildStatusCard(monitoring),
                  if (_showSearch) _buildSearchBar(),
                  Expanded(
                    child: _isLoadingApps
                        ? _buildShimmerList()
                        : _filtered.isEmpty
                        ? _buildEmptySearch()
                        : _buildAppList(monitoring),
                  ),
                  _buildBottomBar(monitoring),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────────

  Widget _buildHeader(MonitoringProvider monitoring) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          _IconBtn(
            icon: Icons.arrow_back_ios_new_rounded,
            onTap: () {
              HapticFeedback.lightImpact();
              Navigator.pop(context);
            },
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'App Protection',
                  style: GoogleFonts.poppins(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                Text(
                  '${monitoring.selectedCount} / $_kMaxApps apps selected',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          _IconBtn(
            icon: Icons.search_rounded,
            onTap: () {
              HapticFeedback.lightImpact();
              setState(() {
                _showSearch = !_showSearch;
                if (!_showSearch) {
                  _searchCtrl.clear();
                  _filtered = List.from(_allApps);
                }
              });
            },
            isActive: _showSearch,
          ),
          const SizedBox(width: 8),
          _IconBtn(
            icon: Icons.refresh_rounded,
            onTap: () => _loadApps(forceRefresh: true),
          ),
        ],
      ),
    ).animate().fadeIn().slideY(begin: -0.15, duration: 300.ms);
  }

  // ── Permission banner ──────────────────────────────────────────────────────

  Widget _buildPermissionBanner(MonitoringProvider monitoring) {
    return GestureDetector(
      onTap: () async {
        await monitoring.openUsageAccessSettings();
        if (mounted) await monitoring.refreshPermissionStatus();
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(color: AppTheme.warning.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: AppTheme.warning, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Usage Access needed for real-time detection  •  Tap to open settings',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: AppTheme.warning,
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: AppTheme.warning, size: 18),
          ],
        ),
      ),
    ).animate().fadeIn(delay: 100.ms).slideY(begin: 0.1);
  }

  // ── Status card ────────────────────────────────────────────────────────────

  Widget _buildStatusCard(MonitoringProvider monitoring) {
    final isActive = monitoring.isMonitoring;
    final color    = isActive ? AppTheme.success : AppTheme.primaryPurple;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              isActive ? Icons.shield : Icons.shield_outlined,
              color: color,
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isActive ? 'Protection Active' : 'Protection Inactive',
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                if (isActive && monitoring.activeSession != null) ...[
                  Text(
                    '⚠ ${monitoring.activeSession!.appName} open '
                        '(${_elapsed(monitoring.activeSession!.elapsed)})',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: AppTheme.error,
                    ),
                  ),
                ] else
                  Text(
                    isActive
                        ? 'Monitoring ${monitoring.selectedCount} apps'
                        : 'Select apps and start protection',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: AppTheme.textMuted,
                    ),
                  ),
              ],
            ),
          ),
          if (isActive)
            AnimatedBuilder(
              animation: _pulseCtrl,
              builder: (_, __) => Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: AppTheme.success
                      .withValues(alpha: 0.5 + _pulseCtrl.value * 0.5),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.success
                          .withValues(alpha: 0.3 + _pulseCtrl.value * 0.3),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ).animate().fadeIn(delay: 150.ms);
  }

  // ── Search bar ─────────────────────────────────────────────────────────────

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.surfaceDark,
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(
            color: AppTheme.primaryPurple.withValues(alpha: 0.3),
          ),
        ),
        child: TextField(
          controller: _searchCtrl,
          autofocus: true,
          style: GoogleFonts.inter(color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: 'Search apps…',
            hintStyle: GoogleFonts.inter(color: AppTheme.textMuted),
            prefixIcon:
            const Icon(Icons.search, color: AppTheme.textMuted, size: 20),
            suffixIcon: _searchCtrl.text.isNotEmpty
                ? IconButton(
              icon: const Icon(Icons.clear,
                  color: AppTheme.textMuted, size: 18),
              onPressed: _searchCtrl.clear,
            )
                : null,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
    ).animate().fadeIn().slideY(begin: -0.1, duration: 200.ms);
  }

  // ── App list ───────────────────────────────────────────────────────────────

  Widget _buildAppList(MonitoringProvider monitoring) {
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      itemCount: _filtered.length,
      itemBuilder: (ctx, i) {
        final app = _filtered[i];
        // Sync selection state from provider
        final isSelected = monitoring.selectedApps.firstWhere(
              (a) => a.packageName == app.packageName,
          orElse: () => app,
        ).isSelected;

        return _AppTile(
          app: app,
          isSelected: isSelected,
          locked: monitoring.isMonitoring,
          onTap: () => _toggleApp(app),
          animDelay: Duration(milliseconds: (30 * i).clamp(0, 400)),
        );
      },
    );
  }

  // ── Shimmer loading ────────────────────────────────────────────────────────

  Widget _buildShimmerList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      itemCount: 10,
      itemBuilder: (_, i) => _ShimmerTile(
        delay: Duration(milliseconds: i * 60),
      ),
    );
  }

  Widget _buildEmptySearch() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.search_off_rounded,
              size: 56, color: AppTheme.textMuted),
          const SizedBox(height: 12),
          Text(
            'No apps match "${_searchCtrl.text}"',
            style: GoogleFonts.inter(
                fontSize: 15, color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  // ── Bottom bar ─────────────────────────────────────────────────────────────

  Widget _buildBottomBar(MonitoringProvider monitoring) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      decoration: BoxDecoration(
        color: AppTheme.secondaryDark,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusLarge),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Main action button ─────────────────────────────────────────────
          _MonitoringButton(
            isMonitoring: monitoring.isMonitoring,
            isLoading:    monitoring.isLoading,
            selectedCount: monitoring.selectedCount,
            onStart: _startMonitoring,
            onStop:  _stopMonitoring,
          ),
          const SizedBox(height: 10),
          // ── View logs ─────────────────────────────────────────────────────
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              Navigator.pushNamed(context, '/logs');
            },
            child: Container(
              width: double.infinity,
              height: 46,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                border: Border.all(
                  color: AppTheme.primaryPurple.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.article_outlined,
                      color: AppTheme.textSecondary, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'View Activity Logs',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  if (monitoring.stats.todayAlerts > 0) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.error,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${monitoring.stats.todayAlerts}',
                        style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.white),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(delay: 200.ms).slideY(begin: 0.2, duration: 350.ms);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _elapsed(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

class _AppTile extends StatelessWidget {
  final AppInfoModel app;
  final bool         isSelected;
  final bool         locked;
  final VoidCallback onTap;
  final Duration     animDelay;

  const _AppTile({
    required this.app,
    required this.isSelected,
    required this.locked,
    required this.onTap,
    required this.animDelay,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primaryPurple.withValues(alpha: 0.12)
              : AppTheme.surfaceDark.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(
            color: isSelected
                ? AppTheme.primaryPurple.withValues(alpha: 0.45)
                : Colors.white.withValues(alpha: 0.05),
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            _AppIcon(icon: app.icon, name: app.name),
            const SizedBox(width: 14),
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
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: isSelected
                    ? AppTheme.primaryPurple
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.primaryPurple
                      : AppTheme.textMuted.withValues(alpha: 0.4),
                  width: 2,
                ),
              ),
              child: isSelected
                  ? const Icon(Icons.check, color: Colors.white, size: 16)
                  : null,
            ),
          ],
        ),
      ),
    )
        .animate()
        .fadeIn(delay: animDelay, duration: 300.ms)
        .slideX(begin: 0.05, duration: 300.ms);
  }
}

class _AppIcon extends StatelessWidget {
  final Uint8List? icon;
  final String     name;

  const _AppIcon({required this.icon, required this.name});

  @override
  Widget build(BuildContext context) {
    if (icon != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.memory(icon!, width: 46, height: 46, fit: BoxFit.cover),
      );
    }
    // Fallback: colour avatar
    final color = _colorForName(name);
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [color, color.withValues(alpha: 0.6)]),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: GoogleFonts.poppins(
              fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ),
    );
  }

  Color _colorForName(String s) {
    const palette = [
      Color(0xFFE1306C), Color(0xFF1877F2), Color(0xFF25D366),
      Color(0xFF6C63FF), Color(0xFFFF0000), Color(0xFF1DB954),
      Color(0xFF1DA1F2), Color(0xFFFF6900), Color(0xFFE50914),
    ];
    return palette[s.hashCode.abs() % palette.length];
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isActive;

  const _IconBtn({required this.icon, required this.onTap, this.isActive = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isActive
              ? AppTheme.primaryPurple.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isActive
                ? AppTheme.primaryPurple.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Icon(
          icon,
          size: 20,
          color: isActive ? AppTheme.primaryPurple : AppTheme.textPrimary,
        ),
      ),
    );
  }
}

class _MonitoringButton extends StatelessWidget {
  final bool isMonitoring;
  final bool isLoading;
  final int  selectedCount;
  final VoidCallback onStart;
  final VoidCallback onStop;

  const _MonitoringButton({
    required this.isMonitoring,
    required this.isLoading,
    required this.selectedCount,
    required this.onStart,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final canStart = selectedCount > 0 && !isLoading;

    return GestureDetector(
      onTap: isLoading ? null : (isMonitoring ? onStop : onStart),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        height: 54,
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: isMonitoring
              ? const LinearGradient(
            colors: [Color(0xFFEF5350), Color(0xFFE53935)],
          )
              : canStart
              ? const LinearGradient(
            colors: [Color(0xFF11998E), Color(0xFF38EF7D)],
          )
              : null,
          color: (!isMonitoring && !canStart)
              ? AppTheme.surfaceDark
              : null,
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          boxShadow: isMonitoring || canStart
              ? [
            BoxShadow(
              color: (isMonitoring
                  ? AppTheme.error
                  : const Color(0xFF11998E))
                  .withValues(alpha: 0.35),
              blurRadius: 16,
              spreadRadius: 2,
              offset: const Offset(0, 4),
            ),
          ]
              : null,
        ),
        child: Center(
          child: isLoading
              ? const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: Colors.white,
            ),
          )
              : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isMonitoring
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline,
                color: canStart || isMonitoring
                    ? Colors.white
                    : AppTheme.textMuted,
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(
                isMonitoring
                    ? 'Stop Protection'
                    : 'Start Protection',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: canStart || isMonitoring
                      ? Colors.white
                      : AppTheme.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShimmerTile extends StatefulWidget {
  final Duration delay;
  const _ShimmerTile({required this.delay});

  @override
  State<_ShimmerTile> createState() => _ShimmerTileState();
}

class _ShimmerTileState extends State<_ShimmerTile>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Color.lerp(
              AppTheme.surfaceDark, AppTheme.surfaceDark.withValues(alpha: 0.4),
              _anim.value),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 13,
                    width: 120,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 10,
                    width: 180,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ).animate().fadeIn(delay: widget.delay, duration: 250.ms);
  }
}