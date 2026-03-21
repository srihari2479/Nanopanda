// lib/features/monitoring/presentation/pages/app_selection_page.dart
//
// CACHE-FIRST LOADING
// ─────────────────────────────────────────────────────────────────────────────
// Every open:
//   1. Read cached apps from StorageService → show INSTANTLY (< 50 ms).
//   2. If cache age > 24 h (or no cache) → fetch from device IN BACKGROUND,
//      update list silently. Small "Refreshing…" chip in header only.
//   3. First ever open (truly no cache) → skeleton shimmer while loading.
//   Pull-to-refresh always fetches fresh + saves to cache.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../../core/models/app_info_model.dart';
import '../../../../core/providers/monitoring_provider.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../theme/theme.dart';
import '../../data/repositories/app_monitor_repository.dart';

class AppSelectionPage extends StatefulWidget {
  const AppSelectionPage({super.key});
  @override
  State<AppSelectionPage> createState() => _AppSelectionPageState();
}

class _AppSelectionPageState extends State<AppSelectionPage> {
  static const int      _maxApps     = 10;
  static const Duration _cacheMaxAge = Duration(hours: 24);

  late AppMonitorRepository _repo;

  List<AppInfoModel> _allApps  = [];
  List<AppInfoModel> _filtered = [];

  bool _initialLoading    = false; // skeleton: no cache ever
  bool _backgroundRefresh = false; // subtle chip: cache stale

  String _searchQuery = '';
  bool   _showSearch  = false;
  final  _searchCtrl  = TextEditingController();

  @override
  void initState() {
    super.initState();
    _repo = AppMonitorRepository(context.read<StorageService>());
    _loadWithCache();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MonitoringProvider>().refreshPermissionStatus();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Cache-first strategy ───────────────────────────────────────────────────

  Future<void> _loadWithCache() async {
    final storage = context.read<StorageService>();

    final cached = await storage.getInstalledAppsCache();

    if (cached.isNotEmpty) {
      // Instant display from cache
      _applyList(cached);

      // Silently refresh if stale
      final age     = storage.getInstalledAppsCacheAge();
      final isStale = age == null || age > _cacheMaxAge;
      if (isStale && mounted) {
        setState(() => _backgroundRefresh = true);
        await _fetchDevice();
      }
    } else {
      // First ever open — show skeleton
      if (mounted) setState(() => _initialLoading = true);
      await _fetchDevice();
    }
  }

  Future<void> _fetchDevice() async {
    try {
      final apps = await _repo.getInstalledApps(forceRefresh: true);
      if (mounted) _applyList(apps);
    } catch (_) {
      // Silently keep whatever is already displayed
    } finally {
      if (mounted) {
        setState(() {
          _initialLoading    = false;
          _backgroundRefresh = false;
        });
      }
    }
  }

  Future<void> _onRefresh() async {
    if (mounted) setState(() => _backgroundRefresh = true);
    await _fetchDevice();
  }

  void _applyList(List<AppInfoModel> apps) {
    if (!mounted) return;
    final monitor = context.read<MonitoringProvider>();
    monitor.setApps(apps);
    setState(() {
      _allApps  = List.of(monitor.selectedApps);
      _filtered = _search(_allApps, _searchQuery);
    });
  }

  // ── Search ─────────────────────────────────────────────────────────────────

  List<AppInfoModel> _search(List<AppInfoModel> apps, String q) {
    if (q.isEmpty) return apps;
    final l = q.toLowerCase();
    return apps
        .where((a) =>
    a.name.toLowerCase().contains(l) ||
        a.packageName.toLowerCase().contains(l))
        .toList();
  }

  void _onSearch(String q) => setState(() {
    _searchQuery = q;
    _filtered    = _search(_allApps, q);
  });

  int get _selectedCount => _allApps.where((a) => a.isSelected).length;

  // ── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(children: [
            _buildHeader(),
            _buildPermissionBanner(),
            _buildSelectionBar(),
            if (_showSearch) _buildSearchBar(),
            Expanded(child: _buildBody()),
            _buildBottomBar(),
          ]),
        ),
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(AppTheme.spacingM),
      child: Row(children: [
        GestureDetector(
          onTap: () { HapticFeedback.lightImpact(); Navigator.pop(context); },
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: AppTheme.glassDecoration(opacity: 0.1),
            child: const Icon(Icons.arrow_back,
                color: AppTheme.textPrimary, size: 20),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Protect Apps',
                  style: GoogleFonts.poppins(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary)),
              if (_backgroundRefresh)
                Row(children: [
                  SizedBox(
                    width: 10, height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      valueColor:
                      AlwaysStoppedAnimation(AppTheme.textMuted),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text('Refreshing…',
                      style: GoogleFonts.inter(
                          fontSize: 11, color: AppTheme.textMuted)),
                ]),
            ],
          ),
        ),
        GestureDetector(
          onTap: () => setState(() {
            _showSearch = !_showSearch;
            if (!_showSearch) { _searchCtrl.clear(); _onSearch(''); }
          }),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: AppTheme.glassDecoration(opacity: 0.1),
            child: Icon(_showSearch ? Icons.search_off : Icons.search,
                color: AppTheme.textPrimary, size: 20),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: _backgroundRefresh ? null : _onRefresh,
          child: AnimatedOpacity(
            opacity: _backgroundRefresh ? 0.4 : 1.0,
            duration: const Duration(milliseconds: 200),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: AppTheme.glassDecoration(opacity: 0.1),
              child: const Icon(Icons.refresh,
                  color: AppTheme.textPrimary, size: 20),
            ),
          ),
        ),
      ]),
    );
  }

  // ── Permission banner ──────────────────────────────────────────────────────

  Widget _buildPermissionBanner() {
    return Consumer<MonitoringProvider>(
      builder: (_, monitor, __) {
        if (monitor.hasPermission) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.fromLTRB(
              AppTheme.spacingM, 0, AppTheme.spacingM, 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.warning.withOpacity(0.1),
            borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
            border:
            Border.all(color: AppTheme.warning.withOpacity(0.3)),
          ),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded,
                color: AppTheme.warning, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Usage Stats permission required',
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.warning)),
            ),
            GestureDetector(
              onTap: () => monitor.openUsageAccessSettings(),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                    color: AppTheme.warning,
                    borderRadius: BorderRadius.circular(8)),
                child: Text('Grant',
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.black)),
              ),
            ),
          ]),
        ).animate().fadeIn();
      },
    );
  }

  // ── Selection bar ──────────────────────────────────────────────────────────

  Widget _buildSelectionBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingM, vertical: 4),
      child: Row(children: [
        Text(
          _initialLoading
              ? 'Loading…'
              : '${_allApps.length} installed',
          style: GoogleFonts.inter(
              fontSize: 13, color: AppTheme.textSecondary),
        ),
        const Spacer(),
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(
              horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: _selectedCount >= _maxApps
                ? AppTheme.error.withOpacity(0.15)
                : AppTheme.primaryPurple.withOpacity(0.15),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text('$_selectedCount / $_maxApps',
              style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _selectedCount >= _maxApps
                      ? AppTheme.error
                      : AppTheme.primaryPurple)),
        ),
      ]),
    );
  }

  // ── Search bar ─────────────────────────────────────────────────────────────

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingM, vertical: 4),
      child: TextField(
        controller: _searchCtrl,
        onChanged:  _onSearch,
        autofocus:  true,
        style: GoogleFonts.inter(color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText:   'Search apps…',
          prefixIcon: const Icon(Icons.search, color: AppTheme.textMuted),
          suffixIcon: _searchQuery.isNotEmpty
              ? GestureDetector(
              onTap: () { _searchCtrl.clear(); _onSearch(''); },
              child: const Icon(Icons.clear,
                  color: AppTheme.textMuted))
              : null,
        ),
      ).animate().fadeIn(duration: 200.ms),
    );
  }

  // ── Body ───────────────────────────────────────────────────────────────────

  Widget _buildBody() {
    if (_initialLoading) return _buildSkeleton();

    if (_filtered.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.search_off, color: AppTheme.textMuted, size: 40),
          const SizedBox(height: 12),
          Text(
            _searchQuery.isEmpty
                ? 'No apps found'
                : 'No results for "$_searchQuery"',
            style: GoogleFonts.inter(color: AppTheme.textMuted),
          ),
        ]),
      );
    }

    return RefreshIndicator(
      onRefresh: _onRefresh,
      color:     AppTheme.primaryPurple,
      child: ListView.builder(
        padding:   const EdgeInsets.symmetric(
            horizontal: AppTheme.spacingM, vertical: 4),
        itemCount: _filtered.length,
        itemBuilder: (_, i) {
          final app = _filtered[i];
          return _AppTile(
            app:           app,
            selectedCount: _selectedCount,
            maxApps:       _maxApps,
            onToggle: () {
              HapticFeedback.selectionClick();
              context.read<MonitoringProvider>().toggleApp(app);
              setState(() {
                _allApps  = List.of(
                    context.read<MonitoringProvider>().selectedApps);
                _filtered = _search(_allApps, _searchQuery);
              });
            },
          ).animate().fadeIn(
            delay:    Duration(milliseconds: i * 12),
            duration: 200.ms,
          );
        },
      ),
    );
  }

  // ── Skeleton (first open only) ─────────────────────────────────────────────

  Widget _buildSkeleton() {
    return ListView.builder(
      padding:   const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingM, vertical: 4),
      itemCount: 12,
      itemBuilder: (_, i) => _SkeletonTile()
          .animate(onPlay: (c) => c.repeat())
          .shimmer(
        duration: 1200.ms,
        delay:    Duration(milliseconds: i * 60),
        color:    AppTheme.primaryPurple.withOpacity(0.04),
      ),
    );
  }

  // ── Bottom bar ─────────────────────────────────────────────────────────────

  Widget _buildBottomBar() {
    return Consumer<MonitoringProvider>(
      builder: (_, monitor, __) {
        final isMonitoring = monitor.isMonitoring;
        final isLoading    = monitor.isLoading;
        final canStart     = _selectedCount > 0;

        return Container(
          padding: const EdgeInsets.all(AppTheme.spacingM),
          decoration: BoxDecoration(
            color: AppTheme.secondaryDark,
            boxShadow: [
              BoxShadow(
                  color:      Colors.black.withOpacity(0.3),
                  blurRadius: 20,
                  offset:     const Offset(0, -5)),
            ],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (monitor.errorMessage != null)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: AppTheme.error.withOpacity(0.3)),
                ),
                child: Text(monitor.errorMessage!,
                    style: GoogleFonts.inter(
                        fontSize: 12, color: AppTheme.error),
                    textAlign: TextAlign.center),
              ),
            Row(children: [
              Expanded(
                child: isMonitoring
                    ? ElevatedButton.icon(
                  onPressed: isLoading
                      ? null
                      : () async {
                    HapticFeedback.mediumImpact();
                    await monitor.stopMonitoring();
                  },
                  icon: isLoading
                      ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white))
                      : const Icon(Icons.stop_circle_outlined),
                  label: Text(
                      isLoading ? 'Stopping…' : 'Stop protection'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.error,
                      padding: const EdgeInsets.symmetric(
                          vertical: 15)),
                )
                    : ElevatedButton.icon(
                  onPressed: (canStart && !isLoading)
                      ? () async {
                    HapticFeedback.mediumImpact();
                    final ok = await monitor.startMonitoring();
                    if (!ok && mounted) {
                      await monitor.refreshPermissionStatus();
                    }
                  }
                      : null,
                  icon: isLoading
                      ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white))
                      : const Icon(Icons.shield_rounded),
                  label: Text(isLoading
                      ? 'Starting…'
                      : 'Protect $_selectedCount '
                      'app${_selectedCount != 1 ? "s" : ""}'),
                  style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          vertical: 15)),
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: () => Navigator.pushNamed(context, '/logs'),
                child: Container(
                  padding: const EdgeInsets.all(13),
                  decoration: AppTheme.glassDecoration(opacity: 0.1),
                  child: Badge(
                    isLabelVisible: monitor.stats.totalAlerts > 0,
                    label: Text('${monitor.stats.totalAlerts}'),
                    child: const Icon(Icons.history_rounded,
                        color: AppTheme.textPrimary, size: 22),
                  ),
                ),
              ),
            ]),
          ]),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// App Tile
// ─────────────────────────────────────────────────────────────────────────────

class _AppTile extends StatelessWidget {
  final AppInfoModel app;
  final int          selectedCount;
  final int          maxApps;
  final VoidCallback onToggle;
  const _AppTile({
    required this.app,
    required this.selectedCount,
    required this.maxApps,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final canSelect = app.isSelected || selectedCount < maxApps;
    return GestureDetector(
      onTap: canSelect
          ? onToggle
          : () {
        HapticFeedback.heavyImpact();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Maximum $maxApps apps allowed',
              style: GoogleFonts.inter(color: Colors.white)),
          backgroundColor: AppTheme.surfaceDark,
          behavior:        SnackBarBehavior.floating,
          duration:        const Duration(seconds: 2),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                  AppTheme.radiusMedium)),
        ));
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin:  const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: app.isSelected
              ? AppTheme.primaryPurple.withOpacity(0.12)
              : AppTheme.surfaceDark.withOpacity(0.5),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(
            color: app.isSelected
                ? AppTheme.primaryPurple.withOpacity(0.35)
                : Colors.transparent,
          ),
        ),
        child: Row(children: [
          _AppIcon(app: app),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(app.name,
                    style: GoogleFonts.inter(
                        fontSize:   14,
                        fontWeight: FontWeight.w500,
                        color:      canSelect
                            ? AppTheme.textPrimary
                            : AppTheme.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text(app.packageName,
                    style: GoogleFonts.inter(
                        fontSize: 11, color: AppTheme.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width:  22,
            height: 22,
            decoration: BoxDecoration(
              color: app.isSelected
                  ? AppTheme.primaryPurple
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: app.isSelected
                    ? AppTheme.primaryPurple
                    : AppTheme.textMuted,
                width: 1.5,
              ),
            ),
            child: app.isSelected
                ? const Icon(Icons.check, size: 13, color: Colors.white)
                : null,
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// App Icon
// ─────────────────────────────────────────────────────────────────────────────

class _AppIcon extends StatelessWidget {
  final AppInfoModel app;
  const _AppIcon({required this.app});

  @override
  Widget build(BuildContext context) {
    final icon = app.icon;
    if (icon != null && icon.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(icon,
            width: 38, height: 38, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _fallback()),
      );
    }
    return _fallback();
  }

  Widget _fallback() => Container(
    width:  38,
    height: 38,
    decoration: BoxDecoration(
      color:        AppTheme.primaryPurple.withOpacity(0.18),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Center(
      child: Text(
        app.name.isNotEmpty ? app.name[0].toUpperCase() : '?',
        style: GoogleFonts.poppins(
            fontSize:   16,
            fontWeight: FontWeight.bold,
            color:      AppTheme.primaryPurple),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Skeleton tile
// ─────────────────────────────────────────────────────────────────────────────

class _SkeletonTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin:  const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color:        AppTheme.surfaceDark.withOpacity(0.5),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color:        AppTheme.primaryPurple.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 13, width: 120,
                decoration: BoxDecoration(
                  color:        AppTheme.primaryPurple.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 5),
              Container(
                height: 10, width: 180,
                decoration: BoxDecoration(
                  color:        AppTheme.primaryPurple.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ],
          ),
        ),
        Container(
          width: 22, height: 22,
          decoration: BoxDecoration(
            color:        AppTheme.primaryPurple.withOpacity(0.06),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ]),
    );
  }
}