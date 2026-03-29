// lib/main.dart
//
// SIMPLIFIED: No /face-overlay route needed.
// Background capture is done by BackgroundMonitorService.kt via Camera2.
// Owner sees results in Logs page after opening Nanopanda.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';

import 'theme/theme.dart';
import 'core/services/storage_service.dart';
import 'core/services/ml_face_service.dart';
import 'core/services/monitoring_service.dart';
import 'core/providers/app_state_provider.dart';
import 'core/providers/monitoring_provider.dart';
import 'features/face_auth/presentation/pages/face_registration_page.dart';
import 'features/face_auth/presentation/pages/face_login_page.dart';
import 'features/dashboard/presentation/pages/dashboard_page.dart';
import 'features/dashboard/presentation/pages/settings_page.dart';
import 'features/emotion/presentation/pages/emotion_detection_page.dart';
import 'features/emotion/presentation/pages/emotion_result_page.dart';
import 'features/monitoring/presentation/pages/app_selection_page.dart';
import 'features/monitoring/presentation/pages/logs_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterForegroundTask.initCommunicationPort();

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId:          'nanopanda_monitoring',
      channelName:        'App Protection',
      channelDescription: 'Nanopanda is protecting your apps',
      channelImportance:  NotificationChannelImportance.LOW,
      priority:           NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound:        false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction:                ForegroundTaskEventAction.repeat(5000),
      autoRunOnBoot:              true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock:              true,
      allowWifiLock:              false,
    ),
  );

  // navigatorKey not needed for background capture flow — kept for compat
  MonitoringService.navigatorKey = null;

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor:                    Colors.transparent,
      statusBarIconBrightness:           Brightness.light,
      systemNavigationBarColor:          Color(0xFF0A0E21),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  final storageService = StorageService();
  await storageService.init();

  await MlFaceService.instance.initialize();

  runApp(
    MultiProvider(
      providers: [
        Provider<StorageService>.value(value: storageService),
        ChangeNotifierProvider(
          create: (_) => AppStateProvider(storageService),
        ),
        ChangeNotifierProvider(
          create: (_) => MonitoringProvider(storageService),
        ),
      ],
      child: const FaceGuardApp(),
    ),
  );
}

class FaceGuardApp extends StatelessWidget {
  const FaceGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title:                      'Nanopanda',
      debugShowCheckedModeBanner: false,
      theme:                      AppTheme.darkTheme,
      home:                       const AppRouter(),
      onGenerateRoute:            _generateRoute,
    );
  }

  static Route<dynamic>? _generateRoute(RouteSettings settings) {
    switch (settings.name) {
      case '/registration':
        return _page(const FaceRegistrationPage());
      case '/login':
        return _page(const FaceLoginPage());
      case '/dashboard':
        return _page(const DashboardPage());
      case '/settings':
        return _page(const SettingsPage());
      case '/emotion-detection':
        return _page(const EmotionDetectionPage());
      case '/emotion-result':
        final emotion = settings.arguments as String? ?? 'neutral';
        return _page(EmotionResultPage(emotion: emotion));
      case '/app-selection':
        return _page(const AppSelectionPage());
      case '/logs':
        return _page(const LogsPage());
      default:
        return null;
    }
  }

  static PageRouteBuilder _page(Widget page) {
    return PageRouteBuilder(
      pageBuilder: (_, animation, __) => page,
      transitionsBuilder: (_, animation, __, child) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.05, 0),
              end:   Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve:  Curves.easeOutCubic,
            )),
            child: child,
          ),
        );
      },
      transitionDuration: const Duration(milliseconds: 350),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AppRouter
// ─────────────────────────────────────────────────────────────────────────────

class AppRouter extends StatefulWidget {
  const AppRouter({super.key});

  @override
  State<AppRouter> createState() => _AppRouterState();
}

class _AppRouterState extends State<AppRouter> {
  AppStateProvider? _appState;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appState = context.read<AppStateProvider>();
    if (_appState != appState) {
      _appState?.removeListener(_onStateChanged);
      _appState = appState;
      _appState!.addListener(_onStateChanged);
    }
  }

  @override
  void dispose() {
    _appState?.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    final s = _appState!;
    if (!s.isInitialized) return;
    Navigator.of(context).pushReplacementNamed(_resolveRoute(s));
  }

  String _resolveRoute(AppStateProvider s) {
    if (!s.isFaceRegistered) return '/registration';
    if (!s.isAuthenticated)  return '/login';
    return '/dashboard';
  }

  @override
  Widget build(BuildContext context) => const _SplashScreen();
}

// ─────────────────────────────────────────────────────────────────────────────
// Splash Screen
// ─────────────────────────────────────────────────────────────────────────────

class _SplashScreen extends StatefulWidget {
  const _SplashScreen();

  @override
  State<_SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<_SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double>   _scale;
  late Animation<double>   _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 1500),
    );
    _scale = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.elasticOut),
    );
    _opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve:  const Interval(0.0, 0.5, curve: Curves.easeOut),
      ),
    );
    _controller.forward();
    _init();
  }

  Future<void> _init() async {
    await Future.delayed(const Duration(milliseconds: 1500));
    if (mounted) {
      context.read<AppStateProvider>().initialize();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin:  Alignment.topLeft,
            end:    Alignment.bottomRight,
            colors: [Color(0xFF0A0E21), Color(0xFF1D1E33)],
          ),
        ),
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (_, __) => Opacity(
              opacity: _opacity.value,
              child: Transform.scale(
                scale: _scale.value,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width:  120,
                      height: 120,
                      decoration: BoxDecoration(
                        shape:    BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [Color(0xFF6C63FF), Color(0xFF9D4EDD)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color:        const Color(0xFF6C63FF).withOpacity(0.5),
                            blurRadius:   30,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.face_retouching_natural,
                        size:  60,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Nanopanda',
                      style: GoogleFonts.poppins(
                        fontSize:   32,
                        fontWeight: FontWeight.bold,
                        color:      Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Secure • Smart • Simple',
                      style: GoogleFonts.inter(
                        fontSize:      14,
                        color:         Colors.white60,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}