import 'dart:convert';
import 'dart:typed_data';

/// App Info Model
/// Represents an installed application on the device
class AppInfoModel {
  final String name;
  final String packageName;
  final Uint8List? icon;
  final bool isSystemApp;
  final bool isSelected;

  AppInfoModel({
    required this.name,
    required this.packageName,
    this.icon,
    this.isSystemApp = false,
    this.isSelected = false,
  });

  /// Create copy with selection toggle
  AppInfoModel copyWith({bool? isSelected}) {
    return AppInfoModel(
      name: name,
      packageName: packageName,
      icon: icon,
      isSystemApp: isSystemApp,
      isSelected: isSelected ?? this.isSelected,
    );
  }

  /// Create from JSON (for storage)
  factory AppInfoModel.fromJson(Map<String, dynamic> json) {
    return AppInfoModel(
      name: json['name'] as String,
      packageName: json['packageName'] as String,
      isSystemApp: json['isSystemApp'] as bool? ?? false,
      isSelected: json['isSelected'] as bool? ?? false,
    );
  }

  /// Convert to JSON (for storage)
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'packageName': packageName,
      'isSystemApp': isSystemApp,
      'isSelected': isSelected,
    };
  }

  /// Serialize list to string
  static String serializeList(List<AppInfoModel> apps) {
    final selectedApps = apps.where((a) => a.isSelected).toList();
    return jsonEncode(selectedApps.map((e) => e.toJson()).toList());
  }

  /// Deserialize list from string
  static List<AppInfoModel> deserializeList(String? data) {
    if (data == null || data.isEmpty) return [];
    try {
      final list = jsonDecode(data) as List;
      return list.map((e) => AppInfoModel.fromJson(e)).toList();
    } catch (e) {
      return [];
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppInfoModel && other.packageName == packageName;
  }

  @override
  int get hashCode => packageName.hashCode;

  @override
  String toString() => 'AppInfo(name: $name, package: $packageName)';
}

/// Mock app data for development/testing
class MockApps {
  static List<AppInfoModel> getMockApps() {
    return [
      AppInfoModel(
        name: 'Instagram',
        packageName: 'com.instagram.android',
      ),
      AppInfoModel(
        name: 'Facebook',
        packageName: 'com.facebook.katana',
      ),
      AppInfoModel(
        name: 'WhatsApp',
        packageName: 'com.whatsapp',
      ),
      AppInfoModel(
        name: 'Twitter',
        packageName: 'com.twitter.android',
      ),
      AppInfoModel(
        name: 'YouTube',
        packageName: 'com.google.android.youtube',
      ),
      AppInfoModel(
        name: 'TikTok',
        packageName: 'com.zhiliaoapp.musically',
      ),
      AppInfoModel(
        name: 'Snapchat',
        packageName: 'com.snapchat.android',
      ),
      AppInfoModel(
        name: 'Netflix',
        packageName: 'com.netflix.mediaclient',
      ),
      AppInfoModel(
        name: 'Spotify',
        packageName: 'com.spotify.music',
      ),
      AppInfoModel(
        name: 'Chrome',
        packageName: 'com.android.chrome',
      ),
      AppInfoModel(
        name: 'Gmail',
        packageName: 'com.google.android.gm',
      ),
      AppInfoModel(
        name: 'Telegram',
        packageName: 'org.telegram.messenger',
      ),
      AppInfoModel(
        name: 'Discord',
        packageName: 'com.discord',
      ),
      AppInfoModel(
        name: 'Reddit',
        packageName: 'com.reddit.frontpage',
      ),
      AppInfoModel(
        name: 'Pinterest',
        packageName: 'com.pinterest',
      ),
    ];
  }
}
