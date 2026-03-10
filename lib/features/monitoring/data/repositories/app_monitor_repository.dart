// lib/features/monitoring/data/repositories/app_monitor_repository.dart

import 'dart:io';
import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart';
import '../../../../core/models/app_info_model.dart';
import '../../../../core/services/monitoring_service.dart';
import '../../../../core/services/storage_service.dart';

class AppMonitorRepository {
  final StorageService _storage;

  AppMonitorRepository(this._storage);

  static const _ownPackage    = 'com.example.nanospark';
  static const _minAppNameLen = 2;
  // Refresh cache if older than 24 hours or on manual refresh
  static const _cacheMaxAge   = Duration(hours: 24);

  static const _blockedPrefixes = [
    'com.android',
    'android',
    'com.google.android.inputmethod',
    'com.google.android.permissioncontroller',
    'com.google.android.ext.',
    'com.samsung.android.service',
    'com.sec.android',
    'com.lge.launcher',
    'com.motorola',
    'com.miui',
    'com.xiaomi',
  ];

  // ── Public API ────────────────────────────────────────────────────────────

  /// Returns installed apps.
  /// Strategy:
  ///   1. If valid cache exists (< 24h old) → return instantly from cache.
  ///   2. Otherwise → fetch from device, save to cache, return fresh list.
  ///   [forceRefresh] = true skips cache and always fetches from device.
  Future<List<AppInfoModel>> getInstalledApps({bool forceRefresh = false}) async {
    if (!Platform.isAndroid) return MockApps.getMockApps();

    // 1 — try cache first
    if (!forceRefresh) {
      final age = _storage.getInstalledAppsCacheAge();
      if (age != null && age < _cacheMaxAge) {
        final cached = await _storage.getInstalledAppsCache();
        if (cached.isNotEmpty) return cached;
      }
    }

    // 2 — fetch fresh from device
    try {
      final List<AppInfo> raw = await InstalledApps.getInstalledApps(
        true,  // excludeSystemApps
        true,  // withIcon
        '',    // packageNamePrefix
      );

      final apps = <AppInfoModel>[];
      for (final app in raw) {
        final appName = app.name;
        if (app.packageName == _ownPackage)  continue;
        if (appName == null)                 continue;
        if (appName.length < _minAppNameLen) continue;
        if (_isBlocked(app.packageName))     continue;

        apps.add(AppInfoModel(
          name:        appName,
          packageName: app.packageName,
          icon:        app.icon,
          isSystemApp: false,
          isSelected:  false,
        ));
      }

      apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      // Save to cache for next open (fire-and-forget)
      _storage.saveInstalledAppsCache(apps);

      return apps;
    } catch (_) {
      // Fallback: try stale cache before giving up
      final stale = await _storage.getInstalledAppsCache();
      if (stale.isNotEmpty) return stale;
      return MockApps.getMockApps();
    }
  }

  Future<AppInfoModel?> getApp(String packageName) async {
    if (!Platform.isAndroid) return null;
    try {
      final AppInfo? app = await InstalledApps.getAppInfo(packageName, null);
      if (app == null) return null;
      return AppInfoModel(
        name:        app.name ?? packageName,
        packageName: app.packageName,
        icon:        app.icon,
        isSystemApp: false,
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> isInstalled(String packageName) async {
    if (!Platform.isAndroid) return false;
    try {
      final AppInfo? app = await InstalledApps.getAppInfo(packageName, null);
      return app != null;
    } catch (_) {
      return false;
    }
  }

  // ── Monitoring delegation ─────────────────────────────────────────────────

  Future<bool> startMonitoring(List<AppInfoModel> selectedApps) async {
    final packages = selectedApps.map((a) => a.packageName).toList();
    return MonitoringService.instance.start(packages);
  }

  Future<void> stopMonitoring() async =>
      MonitoringService.instance.stop();

  Future<bool> checkPermission() async =>
      MonitoringService.instance.checkUsageStatsPermission();

  Future<void> openPermissionSettings() async =>
      MonitoringService.instance.openUsageAccessSettings();

  // ── Internal ──────────────────────────────────────────────────────────────

  bool _isBlocked(String pkg) =>
      _blockedPrefixes.any((prefix) => pkg.startsWith(prefix));
}