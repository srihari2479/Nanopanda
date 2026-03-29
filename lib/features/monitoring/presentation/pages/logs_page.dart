// lib/features/monitoring/presentation/pages/logs_page.dart
//
// Updated log card shows:
//   • Intruder face photo (if captured) — tappable for full view
//   • Match score badge (e.g. "23% match")
//   • Attempt count
//   • App name, entry/exit time, duration
//   • Detection reason
// Stats tab and heatmap unchanged.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../../../../theme/theme.dart';
import '../../../../core/providers/monitoring_provider.dart';
import '../../../../core/models/log_entry_model.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MonitoringProvider>().reloadLogs();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _buildTabBar(),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _TimelineTab(),
                    _StatsTab(),
                  ],
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
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: AppTheme.glassDecoration(opacity: 0.1),
              child: const Icon(Icons.arrow_back,
                  color: AppTheme.textPrimary, size: 20),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Access Logs',
              style: GoogleFonts.poppins(
                fontSize:   22,
                fontWeight: FontWeight.bold,
                color:      AppTheme.textPrimary,
              ),
            ),
          ),
          Consumer<MonitoringProvider>(
            builder: (context, monitor, _) {
              if (monitor.logs.isEmpty) return const SizedBox.shrink();
              return GestureDetector(
                onTap: () => _confirmClearAll(context, monitor),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: AppTheme.glassDecoration(opacity: 0.1),
                  child: Row(children: [
                    const Icon(Icons.delete_outline,
                        color: AppTheme.error, size: 16),
                    const SizedBox(width: 4),
                    Text('Clear',
                        style: GoogleFonts.inter(
                            fontSize: 13, color: AppTheme.error)),
                  ]),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppTheme.spacingM),
      decoration: AppTheme.glassDecoration(opacity: 0.05),
      child: TabBar(
        controller:               _tabController,
        labelColor:               AppTheme.primaryPurple,
        unselectedLabelColor:     AppTheme.textMuted,
        indicatorColor:           AppTheme.primaryPurple,
        indicatorSize:            TabBarIndicatorSize.tab,
        tabs: [
          Tab(child: Text('Timeline',
              style: GoogleFonts.inter(
                  fontSize: 14, fontWeight: FontWeight.w500))),
          Tab(child: Text('Statistics',
              style: GoogleFonts.inter(
                  fontSize: 14, fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }

  Future<void> _confirmClearAll(
      BuildContext ctx, MonitoringProvider monitor) async {
    HapticFeedback.mediumImpact();
    final confirm = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: Text('Clear All Logs?',
            style: GoogleFonts.poppins(color: AppTheme.textPrimary)),
        content: Text('This cannot be undone.',
            style: GoogleFonts.inter(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('Cancel',
                style: GoogleFonts.inter(color: AppTheme.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('Clear',
                style: GoogleFonts.inter(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (confirm == true) await monitor.clearLogs();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Timeline Tab
// ─────────────────────────────────────────────────────────────────────────────

class _TimelineTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<MonitoringProvider>(
      builder: (context, monitor, _) {
        final logs = monitor.logs;
        if (logs.isEmpty) return _EmptyLogs();

        // Group by date
        final grouped = <String, List<LogEntryModel>>{};
        for (final log in logs) {
          final key = DateFormat('MMMM d, yyyy').format(log.entryTime);
          grouped.putIfAbsent(key, () => []).add(log);
        }

        return ListView.builder(
          padding:   const EdgeInsets.all(AppTheme.spacingM),
          itemCount: grouped.length,
          itemBuilder: (ctx, groupIdx) {
            final dateKey = grouped.keys.elementAt(groupIdx);
            final dayLogs = grouped[dateKey]!;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Date header
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(children: [
                    Container(
                      width: 4, height: 16,
                      decoration: BoxDecoration(
                        color:        AppTheme.primaryPurple,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(dateKey,
                        style: GoogleFonts.poppins(
                            fontSize:   13,
                            fontWeight: FontWeight.w600,
                            color:      AppTheme.textSecondary)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color:        AppTheme.error.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${dayLogs.length} alert${dayLogs.length > 1 ? "s" : ""}',
                        style: GoogleFonts.inter(
                            fontSize: 11, color: AppTheme.error),
                      ),
                    ),
                  ]),
                ),

                // Log entries for this date
                ...dayLogs.asMap().entries.map((e) => _LogCard(
                  log:   e.value,
                  index: e.key,
                  onDelete: () =>
                      monitor.deleteLog(e.value.id),
                )),
              ],
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Log Card — rich with face photo, score, duration
// ─────────────────────────────────────────────────────────────────────────────

class _LogCard extends StatelessWidget {
  final LogEntryModel log;
  final int           index;
  final VoidCallback  onDelete;

  const _LogCard({
    required this.log,
    required this.index,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = log.faceImagePath != null &&
        File(log.faceImagePath!).existsSync();

    return Dismissible(
      key:             Key(log.id),
      direction:       DismissDirection.endToStart,
      onDismissed:     (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding:   const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color:        AppTheme.error.withOpacity(0.15),
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        child: const Icon(Icons.delete_outline, color: AppTheme.error),
      ),
      child: Container(
        margin:     const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
          color: log.isUnwantedPerson
              ? AppTheme.error.withOpacity(0.06)
              : AppTheme.success.withOpacity(0.06),
          border: Border(
            left: BorderSide(
              color: log.isUnwantedPerson ? AppTheme.error : AppTheme.success,
              width: 3,
            ),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
          child: Column(
            children: [
              // ── Top row: face photo + core info ──────────────────────────
              Padding(
                padding: const EdgeInsets.all(AppTheme.spacingM),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Face photo or placeholder
                    _FacePhotoWidget(
                        imagePath: hasPhoto ? log.faceImagePath : null),
                    const SizedBox(width: 12),

                    // Core info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // App name + AUTH/UNAUTH badge
                          Row(children: [
                            Expanded(
                              child: Text(
                                log.appName,
                                style: GoogleFonts.poppins(
                                  fontSize:   15,
                                  fontWeight: FontWeight.w600,
                                  color:      AppTheme.textPrimary,
                                ),
                                maxLines:  1,
                                overflow:  TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            log.isUnwantedPerson
                                ? _UnauthorizedBadge()
                                : _AuthorizedBadge(),
                          ]),

                          const SizedBox(height: 4),

                          // Entry time
                          Text(
                            DateFormat('hh:mm a').format(log.entryTime),
                            style: GoogleFonts.inter(
                                fontSize: 13,
                                color:    AppTheme.textSecondary),
                          ),

                          const SizedBox(height: 6),

                          // Stats row: duration · match score · attempts
                          Wrap(
                            spacing:   6,
                            runSpacing: 4,
                            children: [
                              _Chip(
                                icon:  Icons.timer_outlined,
                                label: log.formattedDuration,
                                color: AppTheme.primaryPurple,
                              ),
                              if (log.matchScore != null)
                                _Chip(
                                  icon:  Icons.face_outlined,
                                  label: '${log.matchScore!.toStringAsFixed(0)}% match',
                                  color: _scoreColor(log.matchScore!),
                                ),
                              _Chip(
                                icon:  Icons.refresh,
                                label: '${log.attemptCount} attempt${log.attemptCount > 1 ? "s" : ""}',
                                color: AppTheme.textMuted,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // ── Bottom: detection reason ──────────────────────────────────
              Container(
                width:   double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.spacingM, vertical: 10),
                decoration: BoxDecoration(
                  color: log.isUnwantedPerson
                      ? AppTheme.error.withOpacity(0.06)
                      : AppTheme.success.withOpacity(0.06),
                  border: Border(
                    top: BorderSide(
                      color: log.isUnwantedPerson
                          ? AppTheme.error.withOpacity(0.12)
                          : AppTheme.success.withOpacity(0.12),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      log.isUnwantedPerson
                          ? Icons.warning_amber_rounded
                          : Icons.verified_user_outlined,
                      size: 14,
                      color: log.isUnwantedPerson
                          ? AppTheme.error.withOpacity(0.7)
                          : AppTheme.success.withOpacity(0.7),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        log.detectionReason,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color:    AppTheme.textSecondary,
                        ),
                      ),
                    ),
                    // Exit time
                    Text(
                      '→ ${DateFormat('hh:mm a').format(log.exitTime)}',
                      style: GoogleFonts.inter(
                          fontSize: 11, color: AppTheme.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ).animate().fadeIn(delay: Duration(milliseconds: index * 60)).slideY(
        begin: 0.05, end: 0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      ),
    );
  }

  Color _scoreColor(double score) {
    if (score < 30) return AppTheme.error;
    if (score < 60) return AppTheme.warning;
    return AppTheme.error; // still unauthorized even at 60–74%
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Face photo widget — tappable for full screen view
// ─────────────────────────────────────────────────────────────────────────────

class _FacePhotoWidget extends StatelessWidget {
  final String? imagePath;
  const _FacePhotoWidget({this.imagePath});

  @override
  Widget build(BuildContext context) {
    final size = 72.0;

    Widget image;
    if (imagePath != null) {
      image = GestureDetector(
        onTap: () => _showFullScreen(context, imagePath!),
        child: Hero(
          tag: imagePath!,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              File(imagePath!),
              width:  size,
              height: size,
              fit:    BoxFit.cover,
              errorBuilder: (_, __, ___) => _placeholder(size),
            ),
          ),
        ),
      );
    } else {
      image = _placeholder(size);
    }

    return Stack(
      children: [
        image,
        // Red corner indicator
        Positioned(
          right: 0, top: 0,
          child: Container(
            width: 14, height: 14,
            decoration: BoxDecoration(
              color:  AppTheme.error,
              shape:  BoxShape.circle,
              border: Border.all(color: AppTheme.surfaceDark, width: 1.5),
            ),
            child: const Icon(Icons.close, size: 8, color: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _placeholder(double size) {
    return Container(
      width:  size,
      height: size,
      decoration: BoxDecoration(
        color:        AppTheme.error.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(
            color: AppTheme.error.withOpacity(0.2)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.no_photography_outlined,
              size: 24, color: AppTheme.textMuted),
          const SizedBox(height: 2),
          Text('No photo',
              style: GoogleFonts.inter(
                  fontSize: 8, color: AppTheme.textMuted)),
        ],
      ),
    );
  }

  void _showFullScreen(BuildContext context, String path) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque:           false,
        barrierColor:     Colors.black87,
        barrierDismissible: true,
        pageBuilder: (_, __, ___) => _FullScreenPhoto(path: path),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Full screen photo viewer
// ─────────────────────────────────────────────────────────────────────────────

class _FullScreenPhoto extends StatelessWidget {
  final String path;
  const _FullScreenPhoto({required this.path});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Center(
          child: Hero(
            tag: path,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.file(
                File(path),
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small chip widget
// ─────────────────────────────────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;

  const _Chip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color:        color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: GoogleFonts.inter(fontSize: 11, color: color)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unauthorized badge
// ─────────────────────────────────────────────────────────────────────────────

class _UnauthorizedBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color:        AppTheme.error.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border:       Border.all(color: AppTheme.error.withOpacity(0.3)),
      ),
      child: Text(
        'UNAUTH',
        style: GoogleFonts.inter(
          fontSize:   9,
          fontWeight: FontWeight.w700,
          color:      AppTheme.error,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _AuthorizedBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color:        AppTheme.success.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border:       Border.all(color: AppTheme.success.withOpacity(0.3)),
      ),
      child: Text(
        'AUTH',
        style: GoogleFonts.inter(
          fontSize:   9,
          fontWeight: FontWeight.w700,
          color:      AppTheme.success,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stats Tab
// ─────────────────────────────────────────────────────────────────────────────

class _StatsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<MonitoringProvider>(
      builder: (context, monitor, _) {
        final stats = monitor.stats;
        final logs  = monitor.logs;

        if (logs.isEmpty) return _EmptyLogs();

        return ListView(
          padding: const EdgeInsets.all(AppTheme.spacingM),
          children: [
            _StatsSummary(stats: stats),
            const SizedBox(height: AppTheme.spacingM),
            _AppBreakdown(stats: stats),
            const SizedBox(height: AppTheme.spacingM),
            _HourlyHeatmap(logs: logs),
            const SizedBox(height: 40),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stats summary cards
// ─────────────────────────────────────────────────────────────────────────────

class _StatsSummary extends StatelessWidget {
  final MonitoringStats stats;
  const _StatsSummary({required this.stats});

  @override
  Widget build(BuildContext context) {
    String fmtDuration(Duration d) {
      if (d.inHours > 0)   return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
      if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
      return '${d.inSeconds}s';
    }

    return GridView.count(
      crossAxisCount:   2,
      shrinkWrap:       true,
      physics:          const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing:  12,
      childAspectRatio: 1.5,
      children: [
        _StatCard(
          label: 'Total Alerts',
          value: '${stats.totalAlerts}',
          icon:  Icons.warning_amber_rounded,
          color: AppTheme.error,
        ),
        _StatCard(
          label: 'Today',
          value: '${stats.todayAlerts}',
          icon:  Icons.today,
          color: AppTheme.warning,
        ),
        _StatCard(
          label: 'Most Targeted',
          value: stats.mostTargetedApp,
          icon:  Icons.apps,
          color: AppTheme.primaryPurple,
          small: true,
        ),
        _StatCard(
          label: 'Total Unauth Time',
          value: fmtDuration(stats.totalUnauthorizedTime),
          icon:  Icons.timer_outlined,
          color: AppTheme.success,
        ),
      ],
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
      padding:    const EdgeInsets.all(AppTheme.spacingM),
      decoration: AppTheme.glassDecoration(opacity: 0.07),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:  MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: color, size: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: GoogleFonts.poppins(
                  fontSize:   small ? 13 : 22,
                  fontWeight: FontWeight.bold,
                  color:      AppTheme.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                label,
                style: GoogleFonts.inter(
                    fontSize: 11, color: AppTheme.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// App breakdown
// ─────────────────────────────────────────────────────────────────────────────

class _AppBreakdown extends StatelessWidget {
  final MonitoringStats stats;
  const _AppBreakdown({required this.stats});

  @override
  Widget build(BuildContext context) {
    if (stats.alertsByApp.isEmpty) return const SizedBox.shrink();

    final maxAlerts = stats.alertsByApp.values.reduce((a, b) => a > b ? a : b);
    final sorted    = stats.alertsByApp.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('By App',
            style: GoogleFonts.poppins(
                fontSize:   16,
                fontWeight: FontWeight.w600,
                color:      AppTheme.textPrimary)),
        const SizedBox(height: AppTheme.spacingM),
        ...sorted.map((entry) {
          final pct     = entry.value / maxAlerts;
          final durSecs = stats.durationByApp[entry.key] ?? 0;

          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding:    const EdgeInsets.all(AppTheme.spacingM),
              decoration: AppTheme.glassDecoration(opacity: 0.07),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(entry.key,
                          style: GoogleFonts.inter(
                              fontSize:   14,
                              fontWeight: FontWeight.w500,
                              color:      AppTheme.textPrimary)),
                    ),
                    Text('${entry.value} alert${entry.value > 1 ? "s" : ""}',
                        style: GoogleFonts.inter(
                            fontSize: 12, color: AppTheme.error)),
                  ]),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value:           pct,
                      backgroundColor: AppTheme.textMuted.withOpacity(0.15),
                      valueColor: const AlwaysStoppedAnimation(AppTheme.error),
                      minHeight:       6,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Total time: ${_fmtSecs(durSecs)}',
                          style: GoogleFonts.inter(
                              fontSize: 11, color: AppTheme.textMuted)),
                      Text(
                        entry.key == stats.mostTargetedApp
                            ? '🎯 Most targeted' : '',
                        style: GoogleFonts.inter(
                            fontSize: 11, color: AppTheme.warning),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  String _fmtSecs(int s) {
    if (s >= 3600) return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
    if (s >= 60)   return '${s ~/ 60}m ${s % 60}s';
    return '${s}s';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hourly heatmap
// ─────────────────────────────────────────────────────────────────────────────

class _HourlyHeatmap extends StatelessWidget {
  final List<LogEntryModel> logs;
  const _HourlyHeatmap({required this.logs});

  @override
  Widget build(BuildContext context) {
    final hourCounts = List.filled(24, 0);
    for (final log in logs.where((l) => l.isUnwantedPerson)) {
      hourCounts[log.entryTime.hour]++;
    }
    final maxCount = hourCounts.reduce((a, b) => a > b ? a : b);
    if (maxCount == 0) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Hourly Pattern',
            style: GoogleFonts.poppins(
                fontSize:   16,
                fontWeight: FontWeight.w600,
                color:      AppTheme.textPrimary)),
        const SizedBox(height: AppTheme.spacingM),
        Container(
          padding:    const EdgeInsets.all(AppTheme.spacingM),
          decoration: AppTheme.glassDecoration(opacity: 0.07),
          child: Column(children: [
            GridView.builder(
              shrinkWrap: true,
              physics:    const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount:  6,
                childAspectRatio: 1.5,
                crossAxisSpacing: 4,
                mainAxisSpacing:  4,
              ),
              itemCount: 24,
              itemBuilder: (ctx, hour) {
                final count = hourCounts[hour];
                final pct   = maxCount > 0 ? count / maxCount : 0.0;
                final color = Color.lerp(
                  AppTheme.primaryPurple.withOpacity(0.1),
                  AppTheme.error,
                  pct,
                )!;
                return Tooltip(
                  message: '${hour.toString().padLeft(2, '0')}:00 '
                      '— $count alert${count != 1 ? "s" : ""}',
                  child: Container(
                    decoration: BoxDecoration(
                      color:        color,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Center(
                      child: Text(
                        hour.toString().padLeft(2, '0'),
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color:    pct > 0.4
                              ? Colors.white
                              : AppTheme.textMuted,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Low',
                    style: GoogleFonts.inter(
                        fontSize: 10, color: AppTheme.textMuted)),
                Row(children: List.generate(5, (i) => Container(
                  width:  16,
                  height: 8,
                  margin: const EdgeInsets.only(left: 2),
                  decoration: BoxDecoration(
                    color: Color.lerp(
                        AppTheme.primaryPurple.withOpacity(0.1),
                        AppTheme.error, i / 4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ))),
                Text('High',
                    style: GoogleFonts.inter(
                        fontSize: 10, color: AppTheme.textMuted)),
              ],
            ),
          ]),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty state
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyLogs extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width:  80,
            height: 80,
            decoration: BoxDecoration(
              color:  AppTheme.success.withOpacity(0.1),
              shape:  BoxShape.circle,
            ),
            child: const Icon(Icons.verified_user_outlined,
                color: AppTheme.success, size: 40),
          ),
          const SizedBox(height: 16),
          Text('All Clear!',
              style: GoogleFonts.poppins(
                  fontSize:   20,
                  fontWeight: FontWeight.w600,
                  color:      AppTheme.textPrimary)),
          const SizedBox(height: 8),
          Text(
            'No unauthorized access detected.\nYour apps are secure.',
            style:     GoogleFonts.inter(
                fontSize: 14, color: AppTheme.textMuted),
            textAlign: TextAlign.center,
          ),
        ],
      ).animate().fadeIn().scale(),
    );
  }
}