import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../../../theme/theme.dart';
import '../../../../core/models/log_entry_model.dart';
import '../../../../core/services/storage_service.dart';
import '../../data/repositories/log_repository.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late LogRepository _logRepository;

  List<LogEntryModel> _logs = [];
  bool _isLoading = true;
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    setState(() => _isLoading = true);

    try {
      final storageService = context.read<StorageService>();
      _logRepository = LogRepository(storageService);

      var logs = await _logRepository.getLogs();

      // Generate mock logs if empty
      if (logs.isEmpty) {
        logs = await _logRepository.generateMockLogs();
      }

      if (mounted) {
        setState(() {
          _logs = logs;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showErrorSnackBar('Failed to load logs');
      }
    }
  }

  Future<void> _sendToBackend() async {
    if (_logs.isEmpty) {
      _showErrorSnackBar('No logs to send');
      return;
    }

    setState(() => _isSending = true);
    HapticFeedback.mediumImpact();

    try {
      final storageService = context.read<StorageService>();
      final userId = await storageService.getUserId() ?? 'unknown_user';

      final payload = LogUploadPayload(
        userId: userId,
        logs: _logs,
      );

      final success = await _logRepository.sendLogsToBackend(payload);

      if (mounted) {
        setState(() => _isSending = false);

        if (success) {
          _showSuccessSnackBar('Logs sent successfully');
        } else {
          _showErrorSnackBar('Failed to send logs');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSending = false);
        _showErrorSnackBar('Failed to send logs');
      }
    }
  }

  Map<String, int> get _appUsageData {
    final data = <String, int>{};
    for (final log in _logs) {
      data[log.appName] = (data[log.appName] ?? 0) + log.durationInSeconds;
    }
    return data;
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
  void dispose() {
    _tabController.dispose();
    super.dispose();
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
              _buildTabBar(),
              Expanded(
                child: _isLoading
                    ? _buildLoadingState()
                    : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildTimelineView(),
                    _buildChartsView(),
                  ],
                ),
              ),
              _buildBottomActions(),
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
                  'Activity Logs',
                  style: GoogleFonts.poppins(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                Text(
                  '${_logs.length} unwanted access attempts',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          // Refresh button
          GestureDetector(
            onTap: _loadLogs,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: AppTheme.glassDecoration(opacity: 0.1),
              child: const Icon(Icons.refresh, color: AppTheme.textPrimary, size: 22),
            ),
          ),
        ],
      ),
    ).animate().fadeIn().slideY(begin: -0.2);
  }

  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppTheme.spacingM),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      child: TabBar(
        controller: _tabController,
        indicator: BoxDecoration(
          gradient: AppTheme.primaryGradient,
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: Colors.white,
        unselectedLabelColor: AppTheme.textMuted,
        labelStyle: GoogleFonts.inter(fontWeight: FontWeight.w600),
        tabs: const [
          Tab(text: 'Timeline'),
          Tab(text: 'Analytics'),
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
            'Loading logs...',
            style: GoogleFonts.inter(color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineView() {
    if (_logs.isEmpty) {
      return _buildEmptyState();
    }

    return ListView.builder(
      padding: const EdgeInsets.all(AppTheme.spacingM),
      itemCount: _logs.length,
      itemBuilder: (context, index) {
        final log = _logs[index];
        final isFirst = index == 0;
        final isLast = index == _logs.length - 1;

        return _buildTimelineItem(log, isFirst, isLast, index);
      },
    );
  }

  Widget _buildTimelineItem(LogEntryModel log, bool isFirst, bool isLast, int index) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Timeline indicator
          SizedBox(
            width: 40,
            child: Column(
              children: [
                if (!isFirst)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: AppTheme.primaryPurple.withOpacity(0.3),
                    ),
                  ),
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: AppTheme.error,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.error.withOpacity(0.4),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: AppTheme.primaryPurple.withOpacity(0.3),
                    ),
                  ),
              ],
            ),
          ),

          // Log card
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(
                left: AppTheme.spacingS,
                bottom: AppTheme.spacingM,
              ),
              padding: const EdgeInsets.all(AppTheme.spacingM),
              decoration: BoxDecoration(
                gradient: AppTheme.cardGradient,
                borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                border: Border.all(
                  color: AppTheme.error.withOpacity(0.2),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              _getAppColor(log.appName),
                              _getAppColor(log.appName).withOpacity(0.7),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Center(
                          child: Text(
                            log.appName.substring(0, 1),
                            style: GoogleFonts.poppins(
                              fontSize: 16,
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
                                fontSize: 12,
                                color: AppTheme.error,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.error.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'ALERT',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _buildInfoChip(
                        icon: Icons.access_time,
                        label: log.formattedEntryTime,
                      ),
                      const SizedBox(width: 8),
                      _buildInfoChip(
                        icon: Icons.timer,
                        label: log.duration,
                      ),
                      const SizedBox(width: 8),
                      _buildInfoChip(
                        icon: Icons.calendar_today,
                        label: log.formattedDate,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ).animate()
              .fadeIn(delay: Duration(milliseconds: 50 * index))
              .slideX(begin: 0.1),
        ],
      ),
    );
  }

  Widget _buildInfoChip({required IconData icon, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppTheme.textMuted),
          const SizedBox(width: 4),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChartsView() {
    if (_logs.isEmpty) {
      return _buildEmptyState();
    }

    final usageData = _appUsageData;
    final sortedApps = usageData.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppTheme.spacingM),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Pie chart
          Container(
            padding: const EdgeInsets.all(AppTheme.spacingM),
            decoration: AppTheme.glassDecoration(opacity: 0.05),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Time Distribution',
                  style: GoogleFonts.poppins(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: AppTheme.spacingM),
                SizedBox(
                  height: 200,
                  child: PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: 40,
                      sections: sortedApps.take(5).map((entry) {
                        return PieChartSectionData(
                          value: entry.value.toDouble(),
                          title: '${(entry.value / usageData.values.fold(0, (a, b) => a + b) * 100).toStringAsFixed(0)}%',
                          color: _getAppColor(entry.key),
                          radius: 50,
                          titleStyle: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(delay: 200.ms),

          const SizedBox(height: AppTheme.spacingM),

          // Bar chart / list
          Container(
            padding: const EdgeInsets.all(AppTheme.spacingM),
            decoration: AppTheme.glassDecoration(opacity: 0.05),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'App Usage Breakdown',
                  style: GoogleFonts.poppins(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: AppTheme.spacingM),
                ...sortedApps.map((entry) {
                  final maxValue = sortedApps.first.value;
                  final percentage = entry.value / maxValue;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              entry.key,
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            Text(
                              _formatDuration(entry.value),
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: percentage,
                            backgroundColor: AppTheme.surfaceDark,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              _getAppColor(entry.key),
                            ),
                            minHeight: 8,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ).animate().fadeIn(delay: 300.ms),

          // Legend
          Container(
            margin: const EdgeInsets.only(top: AppTheme.spacingM),
            padding: const EdgeInsets.all(AppTheme.spacingM),
            decoration: AppTheme.glassDecoration(opacity: 0.05),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Legend',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: sortedApps.take(5).map((entry) {
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: _getAppColor(entry.key),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          entry.key,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ],
            ),
          ).animate().fadeIn(delay: 400.ms),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
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
            child: const Icon(
              Icons.history,
              size: 48,
              color: AppTheme.textMuted,
            ),
          ),
          const SizedBox(height: 16),
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
            'Activity logs will appear here',
            style: GoogleFonts.inter(
              fontSize: 14,
              color: AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomActions() {
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
        child: GestureDetector(
          onTap: _logs.isNotEmpty && !_isSending ? _sendToBackend : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: double.infinity,
            height: 52,
            decoration: BoxDecoration(
              gradient: _logs.isNotEmpty && !_isSending
                  ? AppTheme.primaryGradient
                  : null,
              color: _logs.isEmpty || _isSending ? AppTheme.surfaceDark : null,
              borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
              boxShadow: _logs.isNotEmpty && !_isSending
                  ? AppTheme.glowShadow(AppTheme.primaryPurple, intensity: 0.3)
                  : null,
            ),
            child: Center(
              child: _isSending
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
                    Icons.cloud_upload,
                    color: _logs.isNotEmpty
                        ? Colors.white
                        : AppTheme.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Send Logs to Backend',
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
      ),
    ).animate().fadeIn(delay: 300.ms).slideY(begin: 0.2);
  }

  Color _getAppColor(String appName) {
    final colors = [
      const Color(0xFFE1306C),
      const Color(0xFF1877F2),
      const Color(0xFF25D366),
      const Color(0xFF1DA1F2),
      const Color(0xFFFF0000),
      const Color(0xFF000000),
      const Color(0xFFFFFC00),
      const Color(0xFFE50914),
      const Color(0xFF1DB954),
    ];
    return colors[appName.hashCode % colors.length];
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${(seconds / 60).floor()}m ${seconds % 60}s';
    return '${(seconds / 3600).floor()}h ${((seconds % 3600) / 60).floor()}m';
  }
}
