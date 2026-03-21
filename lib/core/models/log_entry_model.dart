// lib/core/models/log_entry_model.dart
//
// Extended with:
//   faceImagePath  — absolute path to saved JPEG of the intruder's face
//   matchScore     — cosine similarity ×100 (0–100). null = no face detected
//   attemptCount   — how many capture attempts were made (1–3)

import 'dart:convert';

class LogEntryModel {
  final String   id;
  final String   appName;
  final String   appPackageName;
  final DateTime entryTime;
  final DateTime exitTime;
  final String   detectionReason;
  final bool     isUnwantedPerson;

  // ── New fields ──────────────────────────────────────────────────────────────
  final String? faceImagePath; // null = no face captured
  final double? matchScore;    // 0.0–100.0, null = no face detected
  final int     attemptCount;  // 1–3

  const LogEntryModel({
    required this.id,
    required this.appName,
    required this.appPackageName,
    required this.entryTime,
    required this.exitTime,
    required this.detectionReason,
    required this.isUnwantedPerson,
    this.faceImagePath,
    this.matchScore,
    this.attemptCount = 1,
  });

  int get durationInSeconds => exitTime.difference(entryTime).inSeconds;

  String get formattedDuration {
    final s = durationInSeconds;
    if (s >= 3600) return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
    if (s >= 60)   return '${s ~/ 60}m ${s % 60}s';
    return '${s}s';
  }

  /// e.g. "14 Mar 2026  15:45" — used by LogRepository debug prints.
  String get formattedEntryTime {
    final d = entryTime;
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month]} ${d.year}  $h:$m';
  }

  // ── Serialisation ──────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
    'id':               id,
    'appName':          appName,
    'appPackageName':   appPackageName,
    'entryTime':        entryTime.toIso8601String(),
    'exitTime':         exitTime.toIso8601String(),
    'detectionReason':  detectionReason,
    'isUnwantedPerson': isUnwantedPerson,
    'faceImagePath':    faceImagePath,
    'matchScore':       matchScore,
    'attemptCount':     attemptCount,
  };

  factory LogEntryModel.fromJson(Map<String, dynamic> json) => LogEntryModel(
    id:               json['id']             as String,
    appName:          json['appName']         as String,
    appPackageName:   json['appPackageName']  as String,
    entryTime:        DateTime.parse(json['entryTime']  as String),
    exitTime:         DateTime.parse(json['exitTime']   as String),
    detectionReason:  json['detectionReason'] as String,
    isUnwantedPerson: json['isUnwantedPerson'] as bool,
    faceImagePath:    json['faceImagePath']   as String?,
    matchScore:       (json['matchScore'] as num?)?.toDouble(),
    attemptCount:     (json['attemptCount'] as num?)?.toInt() ?? 1,
  );

  static String serializeList(List<LogEntryModel> logs) =>
      jsonEncode(logs.map((l) => l.toJson()).toList());

  static List<LogEntryModel> deserializeList(String? data) {
    if (data == null || data.isEmpty) return [];
    try {
      final list = jsonDecode(data) as List<dynamic>;
      return list
          .map((e) => LogEntryModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}