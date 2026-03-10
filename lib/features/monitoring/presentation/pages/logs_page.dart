// lib/features/monitoring/presentation/pages/logs_page.dart
//
// Production logs page — Timeline + Analytics tabs.
// Shows real-time active session card, full log timeline,
// per-app usage breakdown, pie chart, and export.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';

import '../../../../theme/theme.dart';
import '../../../../core/models/log_entry_model.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../core/providers/monitoring_provider.dart';
import '../../data/repositories/log_repository.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage>
    with TickerProviderStateMixin {

  late TabController  _tabCtrl;
  late LogRepository  _repo;
  late AnimationController _pulseCtrl;

  List<LogEntryModel> _logs          = [];
  bool                _isLoading     = true;
  bool                _isExporting   = false;
  bool                _isDemoData    = false; // true when showing placeholder demo logs

  // Filter state
  String? _filterPackage;
  DateTimeRange? _filterRange;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _repo = LogRepository(context.read<StorageService>());
      _loadLogs();
      // Live: whenever MonitoringProvider logs a new unauthorized access,
      // this page auto-refreshes — no manual pull needed
      context.read<MonitoringProvider>().addListener(_onMonitoringUpdate);
    });
  }

  void _onMonitoringUpdate() {
    if (mounted) _loadLogs();
  }

  @override
  void dispose() {
    // Safe unsubscribe — provider may outlive this page
    try {
      context.read<MonitoringProvider>().removeListener(_onMonitoringUpdate);
    } catch (_) {}
    _tabCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ── Data ───────────────────────────────────────────────────────────────────

  Future<void> _loadLogs() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      var all = await _repo.getLogs();
      bool isDemo = false;
      // If no real logs yet, seed demo data so the UI always shows something
      // useful — user can clear them once real logs are recorded.
      if (all.isEmpty) {
        all = await _repo.generateDemoLogs();
        isDemo = true;
      }
      if (mounted) setState(() { _logs = all; _isDemoData = isDemo; _isLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<LogEntryModel> get _filteredLogs {
    var result = List<LogEntryModel>.from(_logs);
    if (_filterPackage != null) {
      result = result.where((l) => l.appPackageName == _filterPackage).toList();
    }
    if (_filterRange != null) {
      result = result.where((l) =>
      l.entryTime.isAfter(_filterRange!.start) &&
          l.entryTime.isBefore(_filterRange!.end.add(const Duration(days: 1))),
      ).toList();
    }
    return result;
  }

  Future<void> _deleteLog(String id) async {
    await _repo.deleteLog(id);
    setState(() => _logs.removeWhere((l) => l.id == id));
    _showSnack('Log deleted');
  }

  Future<void> _clearAll() async {
    final confirmed = await _showConfirmDialog(
      title: 'Clear All Logs',
      body: 'This will permanently delete all ${_logs.length} log entries.',
      action: 'Clear',
    );
    if (!confirmed) return;

    await _repo.clearLogs();
    if (mounted) {
      setState(() => _logs = []);
      _showSnack('All logs cleared');
    }
  }

  Future<void> _exportLogs() async {
    if (_logs.isEmpty) { _showSnack('No logs to export', isError: true); return; }
    setState(() => _isExporting = true);
    HapticFeedback.mediumImpact();

    try {
      final path = await _repo.exportLogsToJson();
      if (path != null && mounted) {
        await SharePlus.instance.share(
          ShareParams(files: [XFile(path)], subject: 'Nanopanda Activity Logs'),
        );
      } else {
        _showSnack('Export failed', isError: true);
      }
    } catch (e) {
      _showSnack('Export failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
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
                  if (monitoring.activeSession != null)
                    _buildLiveSessionBanner(monitoring),
                  _buildTabBar(),
                  Expanded(
                    child: _isLoading
                        ? _buildLoading()
                        : TabBarView(
                      controller: _tabCtrl,
                      children: [
                        _buildTimeline(monitoring),
                        _buildAnalytics(),
                      ],
                    ),
                  ),
                  _buildBottomBar(),
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
            onTap: () { HapticFeedback.lightImpact(); Navigator.pop(context); },
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Activity Logs',
                  style: GoogleFonts.poppins(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                Text(
                  '${_filteredLogs.length} intrusion${_filteredLogs.length != 1 ? 's' : ''} recorded',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          _IconBtn(icon: Icons.refresh_rounded, onTap: _loadLogs),
          const SizedBox(width: 8),
          _IconBtn(
            icon: Icons.more_vert_rounded,
            onTap: () => _showOptionsSheet(monitoring),
          ),
        ],
      ),
    ).animate().fadeIn().slideY(begin: -0.15, duration: 300.ms);
  }

  // ── Live session banner ────────────────────────────────────────────────────

  Widget _buildLiveSessionBanner(MonitoringProvider monitoring) {
    final session = monitoring.activeSession!;
    return AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (_, __) => Container(
        margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppTheme.error.withValues(alpha: 0.1 + _pulseCtrl.value * 0.05),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(
            color: AppTheme.error.withValues(alpha: 0.4 + _pulseCtrl.value * 0.2),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: AppTheme.error
                    .withValues(alpha: 0.6 + _pulseCtrl.value * 0.4),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.error.withValues(alpha: 0.5),
                    blurRadius: 6,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '⚠ LIVE: ${session.appName} is open',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.error,
                    ),
                  ),
                  Text(
                    'Unauthorized access  •  ${_elapsed(session.elapsed)}',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: AppTheme.error.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ).animate().fadeIn(delay: 100.ms);
  }

  // ── Tab bar ────────────────────────────────────────────────────────────────

  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      child: TabBar(
        controller: _tabCtrl,
        indicator: BoxDecoration(
          gradient: AppTheme.primaryGradient,
          borderRadius: BorderRadius.circular(10),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: Colors.white,
        unselectedLabelColor: AppTheme.textMuted,
        labelStyle: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 14),
        tabs: const [Tab(text: 'Timeline'), Tab(text: 'Analytics')],
      ),
    ).animate().fadeIn(delay: 100.ms);
  }

  // ── Timeline ───────────────────────────────────────────────────────────────

  Widget _buildTimeline(MonitoringProvider monitoring) {
    final logs = _filteredLogs;
    if (logs.isEmpty) return _buildEmptyState(monitoring);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      itemCount: logs.length + (_isDemoData ? 1 : 0),
      itemBuilder: (_, i) {
        if (_isDemoData && i == 0) return _buildDemoBanner();
        final logIndex = _isDemoData ? i - 1 : i;
        return _buildTimelineItem(
          logs[logIndex],
          isFirst: logIndex == 0,
          isLast:  logIndex == logs.length - 1,
          index:   logIndex,
        );
      },
    );
  }

  Widget _buildDemoBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.primaryPurple.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: AppTheme.primaryPurple.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded,
              color: AppTheme.primaryPurple, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Demo data — start monitoring and protect apps to see real alerts here.',
              style: GoogleFonts.inter(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms);
  }

  Widget _buildTimelineItem(
      LogEntryModel log, {
        required bool isFirst,
        required bool isLast,
        required int  index,
      }) {
    final dotColor = log.exitTime == null ? AppTheme.error : AppTheme.error;

    return Dismissible(
      key: Key(log.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: AppTheme.error.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        ),
        child: const Icon(Icons.delete_outline, color: AppTheme.error, size: 24),
      ),
      confirmDismiss: (_) async {
        return _showConfirmDialog(
          title: 'Delete Log',
          body: 'Remove this entry for ${log.appName}?',
          action: 'Delete',
        );
      },
      onDismissed: (_) => _deleteLog(log.id),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Timeline rail
            SizedBox(
              width: 28,
              child: Column(
                children: [
                  if (!isFirst)
                    Expanded(
                      child: Center(
                        child: Container(
                          width: 2,
                          color: AppTheme.primaryPurple.withValues(alpha: 0.2),
                        ),
                      ),
                    ),
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: dotColor.withValues(alpha: 0.5),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  if (!isLast)
                    Expanded(
                      child: Center(
                        child: Container(
                          width: 2,
                          color: AppTheme.primaryPurple.withValues(alpha: 0.2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Card
            Expanded(
              child: Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  gradient: AppTheme.cardGradient,
                  borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                  border: Border.all(
                    color: AppTheme.error.withValues(alpha:
                    log.exitTime == null ? 0.45 : 0.15,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // App row
                    Row(
                      children: [
                        _AppAvatar(name: log.appName),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                log.appName,
                                style: GoogleFonts.inter(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textPrimary,
                                ),
                              ),
                              Text(
                                log.detectionReason ?? 'Unauthorized access',
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  color: AppTheme.error,
                                ),
                              ),
                            ],
                          ),
                        ),
                        _StatusBadge(isOngoing: log.exitTime == null),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // Chips row
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _InfoChip(
                          icon: Icons.access_time_rounded,
                          label: log.formattedEntryTime,
                        ),
                        _InfoChip(
                          icon: Icons.timer_outlined,
                          label: log.duration,
                          color: log.exitTime == null
                              ? AppTheme.error
                              : null,
                        ),
                        _InfoChip(
                          icon: Icons.calendar_today_rounded,
                          label: _formatDate(log.entryTime),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      )
          .animate()
          .fadeIn(delay: Duration(milliseconds: (index * 40).clamp(0, 500)))
          .slideX(begin: 0.04, duration: 300.ms),
    );
  }

  // ── Analytics ──────────────────────────────────────────────────────────────

  Widget _buildAnalytics() {
    if (_logs.isEmpty) {
      return _buildEmptyState(null);
    }

    final byApp     = <String, int>{};
    final bySeconds = <String, int>{};

    for (final l in _filteredLogs) {
      byApp[l.appName]     = (byApp[l.appName] ?? 0) + 1;
      bySeconds[l.appName] = (bySeconds[l.appName] ?? 0) + l.durationInSeconds;
    }

    final sortedApps = byApp.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final totalAlerts = sortedApps.fold(0, (s, e) => s + e.value);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Summary cards ────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  label: 'Total Alerts',
                  value: '$totalAlerts',
                  icon: Icons.warning_amber_rounded,
                  color: AppTheme.error,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  label: 'Apps Targeted',
                  value: '${byApp.length}',
                  icon: Icons.apps_rounded,
                  color: AppTheme.primaryPurple,
                ),
              ),
            ],
          ).animate().fadeIn(delay: 100.ms),

          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: _StatCard(
                  label: 'Most Targeted',
                  value: sortedApps.isNotEmpty ? sortedApps.first.key : '—',
                  icon: Icons.trending_up_rounded,
                  color: AppTheme.warning,
                  small: true,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  label: 'Total Duration',
                  value: _formatDuration(
                    bySeconds.values.fold(0, (s, v) => s + v),
                  ),
                  icon: Icons.timer_rounded,
                  color: AppTheme.accentCyan,
                ),
              ),
            ],
          ).animate().fadeIn(delay: 150.ms),

          const SizedBox(height: 20),

          // ── Pie chart ────────────────────────────────────────────────────
          _SectionTitle('Intrusions by App'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: AppTheme.glassDecoration(opacity: 0.04),
            child: Row(
              children: [
                SizedBox(
                  width: 160,
                  height: 160,
                  child: PieChart(
                    PieChartData(
                      sectionsSpace: 3,
                      centerSpaceRadius: 36,
                      sections: sortedApps.take(6).map((e) {
                        final pct = totalAlerts > 0
                            ? (e.value / totalAlerts * 100)
                            : 0.0;
                        return PieChartSectionData(
                          value:  e.value.toDouble(),
                          title:  '${pct.toStringAsFixed(0)}%',
                          color:  _appColor(e.key),
                          radius: 48,
                          titleStyle: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: sortedApps.take(6).map((e) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: _appColor(e.key),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                e.key,
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: AppTheme.textSecondary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '${e.value}',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(delay: 200.ms),

          const SizedBox(height: 20),

          // ── Duration breakdown ────────────────────────────────────────────
          _SectionTitle('Time Spent per App'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: AppTheme.glassDecoration(opacity: 0.04),
            child: Column(
              children: sortedApps.map((entry) {
                final secs   = bySeconds[entry.key] ?? 0;
                final maxSec = bySeconds.values
                    .fold(0, (m, v) => v > m ? v : m);
                final ratio  = maxSec > 0 ? secs / maxSec : 0.0;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: _appColor(entry.key),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                entry.key,
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: AppTheme.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            _formatDuration(secs),
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: AppTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: ratio.toDouble(),
                          minHeight: 7,
                          backgroundColor:
                          AppTheme.surfaceDark.withValues(alpha: 0.6),
                          valueColor: AlwaysStoppedAnimation(
                            _appColor(entry.key),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ).animate().fadeIn(delay: 300.ms),
        ],
      ),
    );
  }

  // ── Empty state ────────────────────────────────────────────────────────────

  Widget _buildEmptyState(MonitoringProvider? monitoring) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppTheme.surfaceDark,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.history_rounded,
                size: 48, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 20),
          Text(
            'No logs yet',
            style: GoogleFonts.poppins(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            monitoring != null && !monitoring.isMonitoring
                ? 'Start monitoring to detect intrusions'
                : 'Logs will appear when protected apps are opened',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: AppTheme.textMuted,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation(AppTheme.primaryPurple),
        ),
        const SizedBox(height: 16),
        Text('Loading logs…',
            style: GoogleFonts.inter(color: AppTheme.textSecondary)),
      ],
    ),
  );

  // ── Bottom bar ─────────────────────────────────────────────────────────────

  Widget _buildBottomBar() {
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
      child: GestureDetector(
        onTap: _logs.isNotEmpty && !_isExporting ? _exportLogs : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 52,
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: _logs.isNotEmpty && !_isExporting
                ? AppTheme.primaryGradient
                : null,
            color: (_logs.isEmpty || _isExporting) ? AppTheme.surfaceDark : null,
            borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
            boxShadow: _logs.isNotEmpty && !_isExporting
                ? AppTheme.glowShadow(AppTheme.primaryPurple, intensity: 0.25)
                : null,
          ),
          child: Center(
            child: _isExporting
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
                  Icons.ios_share_rounded,
                  color: _logs.isNotEmpty
                      ? Colors.white
                      : AppTheme.textMuted,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Export Logs',
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _logs.isNotEmpty
                        ? Colors.white
                        : AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ).animate().fadeIn(delay: 250.ms).slideY(begin: 0.2);
  }

  // ── Options sheet ──────────────────────────────────────────────────────────

  void _showOptionsSheet(MonitoringProvider monitoring) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.secondaryDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusXL),
        ),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: AppTheme.textMuted.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            _OptionTile(
              icon: Icons.filter_list_rounded,
              label: 'Filter by App',
              onTap: () {
                Navigator.pop(context);
                _showFilterSheet();
              },
            ),
            _OptionTile(
              icon: Icons.date_range_rounded,
              label: 'Filter by Date',
              onTap: () async {
                Navigator.pop(context);
                final range = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2024),
                  lastDate: DateTime.now(),
                  builder: (ctx, child) => Theme(
                    data: ThemeData.dark().copyWith(
                      colorScheme: const ColorScheme.dark(
                        primary: AppTheme.primaryPurple,
                      ),
                    ),
                    child: child!,
                  ),
                );
                if (range != null) setState(() => _filterRange = range);
              },
            ),
            if (_filterPackage != null || _filterRange != null)
              _OptionTile(
                icon: Icons.clear_rounded,
                label: 'Clear Filters',
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _filterPackage = null;
                    _filterRange   = null;
                  });
                },
              ),
            _OptionTile(
              icon: Icons.delete_sweep_rounded,
              label: 'Clear All Logs',
              color: AppTheme.error,
              onTap: () { Navigator.pop(context); _clearAll(); },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showFilterSheet() {
    final uniquePackages = _logs.map((l) => (l.appPackageName, l.appName))
        .toSet().toList();

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.secondaryDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusXL),
        ),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(horizontal: 180, vertical: 12),
              decoration: BoxDecoration(
                color: AppTheme.textMuted.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Filter by App',
                style: GoogleFonts.poppins(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
            ...uniquePackages.map(
                  (entry) => ListTile(
                leading: _AppAvatar(name: entry.$2, size: 36),
                title: Text(
                  entry.$2,
                  style: GoogleFonts.inter(color: AppTheme.textPrimary),
                ),
                trailing: _filterPackage == entry.$1
                    ? const Icon(Icons.check_circle, color: AppTheme.primaryPurple)
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _filterPackage =
                    _filterPackage == entry.$1 ? null : entry.$1;
                  });
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.inter()),
      backgroundColor: isError ? AppTheme.error : AppTheme.success,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
    ));
  }

  Future<bool> _showConfirmDialog({
    required String title,
    required String body,
    required String action,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: Text(title,
            style: GoogleFonts.poppins(
                fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        content: Text(body,
            style: GoogleFonts.inter(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: GoogleFonts.inter(color: AppTheme.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action,
                style: GoogleFonts.inter(color: AppTheme.error)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Color _appColor(String name) {
    const palette = [
      Color(0xFFE1306C), Color(0xFF1877F2), Color(0xFF25D366),
      Color(0xFF6C63FF), Color(0xFFFF0000), Color(0xFF1DB954),
      Color(0xFF1DA1F2), Color(0xFFFF6900), Color(0xFFE50914),
      Color(0xFFFFFC00), Color(0xFFBD081C), Color(0xFF00BCD4),
    ];
    return palette[name.hashCode.abs() % palette.length];
  }

  String _elapsed(Duration d) {
    if (d.inHours > 0)   return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }

  String _formatDate(DateTime dt) {
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date  = DateTime(dt.year, dt.month, dt.day);
    if (date == today)
      return 'Today';
    if (date == today.subtract(const Duration(days: 1)))
      return 'Yesterday';
    return DateFormat('MMM d').format(dt);
  }

  String _formatDuration(int secs) {
    if (secs < 60)   return '${secs}s';
    if (secs < 3600) return '${(secs / 60).floor()}m ${secs % 60}s';
    return '${(secs / 3600).floor()}h ${((secs % 3600) / 60).floor()}m';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

class _AppAvatar extends StatelessWidget {
  final String name;
  final double size;

  const _AppAvatar({required this.name, this.size = 40});

  @override
  Widget build(BuildContext context) {
    const palette = [
      Color(0xFFE1306C), Color(0xFF1877F2), Color(0xFF25D366),
      Color(0xFF6C63FF), Color(0xFFFF0000), Color(0xFF1DB954),
    ];
    final color = palette[name.hashCode.abs() % palette.length];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color, color.withValues(alpha: 0.65)],
        ),
        borderRadius: BorderRadius.circular(size * 0.25),
      ),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: GoogleFonts.poppins(
            fontSize: size * 0.4,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final bool isOngoing;
  const _StatusBadge({required this.isOngoing});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: (isOngoing ? AppTheme.error : AppTheme.error).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isOngoing ? 'LIVE' : 'ALERT',
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: AppTheme.error,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color?   color;

  const _InfoChip({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: BorderRadius.circular(6),
        border: color != null
            ? Border.all(color: c.withValues(alpha: 0.3))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: c),
          const SizedBox(width: 4),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              color: color ?? AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String  label;
  final String  value;
  final IconData icon;
  final Color   color;
  final bool    small;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 6),
          Text(
            value,
            style: GoogleFonts.poppins(
              fontSize: small ? 13 : 20,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 10,
              color: AppTheme.textMuted,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: GoogleFonts.poppins(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: AppTheme.textPrimary,
    ),
  );
}

class _IconBtn extends StatelessWidget {
  final IconData     icon;
  final VoidCallback onTap;

  const _IconBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Icon(icon, size: 20, color: AppTheme.textPrimary),
    ),
  );
}

class _OptionTile extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final VoidCallback onTap;
  final Color?       color;

  const _OptionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.textPrimary;
    return ListTile(
      leading: Icon(icon, color: c, size: 22),
      title: Text(
        label,
        style: GoogleFonts.inter(color: c, fontSize: 15),
      ),
      onTap: onTap,
    );
  }
}