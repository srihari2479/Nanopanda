import 'dart:convert';

/// Log Entry Model
/// Represents a monitoring log entry for unwanted person detection
class LogEntryModel {
  final String id;
  final String appName;
  final String appPackageName;
  final DateTime entryTime;
  final DateTime? exitTime;
  final String? detectionReason;
  final String? capturedImageBase64;
  final bool isUnwantedPerson;

  LogEntryModel({
    required this.id,
    required this.appName,
    required this.appPackageName,
    required this.entryTime,
    this.exitTime,
    this.detectionReason,
    this.capturedImageBase64,
    this.isUnwantedPerson = false,
  });

  /// Calculate duration in minutes
  String get duration {
    if (exitTime == null) return 'Ongoing';
    final diff = exitTime!.difference(entryTime);
    if (diff.inHours > 0) {
      return '${diff.inHours}h ${diff.inMinutes % 60}m';
    } else if (diff.inMinutes > 0) {
      return '${diff.inMinutes} minutes';
    } else {
      return '${diff.inSeconds} seconds';
    }
  }

  /// Get duration in seconds
  int get durationInSeconds {
    if (exitTime == null) return 0;
    return exitTime!.difference(entryTime).inSeconds;
  }

  /// Format entry time
  String get formattedEntryTime {
    return '${entryTime.hour.toString().padLeft(2, '0')}:'
        '${entryTime.minute.toString().padLeft(2, '0')}';
  }

  /// Format date
  String get formattedDate {
    return '${entryTime.year}-${entryTime.month.toString().padLeft(2, '0')}-'
        '${entryTime.day.toString().padLeft(2, '0')}';
  }

  /// Create from JSON
  factory LogEntryModel.fromJson(Map<String, dynamic> json) {
    return LogEntryModel(
      id: json['id'] as String,
      appName: json['appName'] as String,
      appPackageName: json['appPackageName'] as String,
      entryTime: DateTime.parse(json['entryTime'] as String),
      exitTime: json['exitTime'] != null
          ? DateTime.parse(json['exitTime'] as String)
          : null,
      detectionReason: json['detectionReason'] as String?,
      capturedImageBase64: json['capturedImageBase64'] as String?,
      isUnwantedPerson: json['isUnwantedPerson'] as bool? ?? false,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'appName': appName,
      'appPackageName': appPackageName,
      'entryTime': entryTime.toIso8601String(),
      'exitTime': exitTime?.toIso8601String(),
      'detectionReason': detectionReason,
      'capturedImageBase64': capturedImageBase64,
      'isUnwantedPerson': isUnwantedPerson,
    };
  }

  /// Create copy with exit time
  LogEntryModel copyWithExit(DateTime exitTime) {
    return LogEntryModel(
      id: id,
      appName: appName,
      appPackageName: appPackageName,
      entryTime: entryTime,
      exitTime: exitTime,
      detectionReason: detectionReason,
      capturedImageBase64: capturedImageBase64,
      isUnwantedPerson: isUnwantedPerson,
    );
  }

  /// Serialize to string
  String serialize() => jsonEncode(toJson());

  /// Deserialize from string
  static LogEntryModel? deserialize(String? data) {
    if (data == null || data.isEmpty) return null;
    try {
      return LogEntryModel.fromJson(jsonDecode(data));
    } catch (e) {
      return null;
    }
  }

  /// Serialize list
  static String serializeList(List<LogEntryModel> logs) {
    return jsonEncode(logs.map((e) => e.toJson()).toList());
  }

  /// Deserialize list
  static List<LogEntryModel> deserializeList(String? data) {
    if (data == null || data.isEmpty) return [];
    try {
      final list = jsonDecode(data) as List;
      return list.map((e) => LogEntryModel.fromJson(e)).toList();
    } catch (e) {
      return [];
    }
  }

  @override
  String toString() => 'LogEntry(app: $appName, time: $formattedEntryTime)';
}

/// Log upload payload for backend
class LogUploadPayload {
  final String userId;
  final String? unwantedPersonVector;
  final List<LogEntryModel> logs;

  LogUploadPayload({
    required this.userId,
    this.unwantedPersonVector,
    required this.logs,
  });

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'unwantedPersonVector': unwantedPersonVector,
      'logs': logs.map((log) => {
        'appName': log.appName,
        'entryTime': log.entryTime.toIso8601String(),
        'exitTime': log.exitTime?.toIso8601String(),
        'duration': log.duration,
      }).toList(),
    };
  }
}
