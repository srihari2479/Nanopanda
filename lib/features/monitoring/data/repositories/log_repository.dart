// lib/features/monitoring/data/log_repository.dart
//
// Log repository — persists, queries, and exports monitoring logs.
// All writes go through StorageService (SharedPreferences).
// No mocks in production paths; mock generation is opt-in and dev-only.

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/models/log_entry_model.dart';
import '../../../../core/services/storage_service.dart';

class LogRepository {
  final StorageService _storage;

  LogRepository(this._storage);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<List<LogEntryModel>> getLogs() async {
    final all = await _storage.getLogs();
    // Always return newest first
    all.sort((a, b) => b.entryTime.compareTo(a.entryTime));
    return all;
  }

  Future<List<LogEntryModel>> getLogsForApp(String packageName) async {
    final all = await getLogs();
    return all.where((l) => l.appPackageName == packageName).toList();
  }

  Future<List<LogEntryModel>> getLogsForDateRange(
      DateTime from,
      DateTime to,
      ) async {
    final all = await getLogs();
    return all.where((l) =>
    l.entryTime.isAfter(from) && l.entryTime.isBefore(to),
    ).toList();
  }

  Future<List<LogEntryModel>> getTodaysLogs() async {
    final now   = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end   = start.add(const Duration(days: 1));
    return getLogsForDateRange(start, end);
  }

  // ── Write ─────────────────────────────────────────────────────────────────

  Future<void> addLog(LogEntryModel log) async {
    await _storage.addLog(log);
    debugPrint('[LogRepository] added log: ${log.appName} @ ${log.formattedEntryTime}');
  }

  Future<void> saveLogs(List<LogEntryModel> logs) async {
    await _storage.saveLogs(logs);
  }

  Future<void> deleteLog(String id) async {
    final logs = await getLogs();
    logs.removeWhere((l) => l.id == id);
    await _storage.saveLogs(logs);
  }

  Future<void> clearLogs() async {
    await _storage.clearLogs();
    debugPrint('[LogRepository] all logs cleared');
  }

  // ── Export ────────────────────────────────────────────────────────────────

  /// Exports all logs to a JSON file in the app documents directory.
  /// Returns the file path on success, null on failure.
  Future<String?> exportLogsToJson() async {
    try {
      final logs    = await getLogs();
      final payload = {
        'exportedAt': DateTime.now().toIso8601String(),
        'totalEntries': logs.length,
        'logs': logs.map((l) => l.toJson()).toList(),
      };

      final dir  = await getApplicationDocumentsDirectory();
      final ts   = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/nanopanda_logs_$ts.json');
      await file.writeAsString(jsonEncode(payload));

      debugPrint('[LogRepository] exported to ${file.path}');
      return file.path;
    } catch (e) {
      debugPrint('[LogRepository] export failed: $e');
      return null;
    }
  }

  // ── Stats helpers ─────────────────────────────────────────────────────────

  Future<Map<String, int>> getAlertCountByApp() async {
    final logs   = await getLogs();
    final counts = <String, int>{};
    for (final l in logs.where((l) => l.isUnwantedPerson)) {
      counts[l.appName] = (counts[l.appName] ?? 0) + 1;
    }
    return counts;
  }

  Future<int> getTotalAlerts() async {
    final logs = await getLogs();
    return logs.where((l) => l.isUnwantedPerson).length;
  }

  // ── Demo / placeholder generation ─────────────────────────────────────────

  /// Returns demo logs for display when no real logs exist yet.
  /// Does NOT persist to storage — they disappear once real logs are recorded.
  Future<List<LogEntryModel>> generateDemoLogs() async {
    final mock = <LogEntryModel>[];
    final now  = DateTime.now();

    final data = [
      ('Instagram',  'com.instagram.android',  'Face mismatch detected'),
      ('WhatsApp',   'com.whatsapp',            'No face detected'),
      ('TikTok',     'com.zhiliaoapp.musically','Unknown person'),
      ('YouTube',    'com.google.android.youtube', 'Blur detected'),
      ('Facebook',   'com.facebook.katana',     'Face mismatch detected'),
      ('Snapchat',   'com.snapchat.android',    'No face detected'),
    ];

    for (var i = 0; i < 12; i++) {
      final d          = data[i % data.length];
      final entryTime  = now.subtract(Duration(hours: i * 2, minutes: i * 7));
      final duration   = Duration(minutes: 5 + (i * 3 % 20));

      mock.add(LogEntryModel(
        id:               'demo_${now.millisecondsSinceEpoch}_$i',
        appName:          d.$1,
        appPackageName:   d.$2,
        entryTime:        entryTime,
        exitTime:         entryTime.add(duration),
        detectionReason:  d.$3,
        isUnwantedPerson: true,
      ));
    }

    mock.sort((a, b) => b.entryTime.compareTo(a.entryTime));
    // Do NOT persist demo logs — return in-memory only so real log
    // entries are not polluted. The page will show real data once it exists.
    return mock;
  }
}