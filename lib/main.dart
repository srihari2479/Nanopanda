import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';

import 'theme/theme.dart';
import 'core/services/storage_service.dart';
import 'core/services/ml_face_service.dart';
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

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0A0E21),
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
        ChangeNotifierProvider(create: (_) => AppStateProvider(storageService)),
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
      title: 'Nanopanda',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      // BUG FIX: Do NOT wrap MaterialApp in Consumer and change home: based
      // on state. MaterialApp.home is only read ONCE on the first build.
      // Any subsequent rebuild of MaterialApp.home is silently ignored by
      // Flutter's Navigator — the screen never changes.
      //
      // CORRECT PATTERN: home: is always the static AppRouter widget.
      // AppRouter listens to AppStateProvider and imperatively calls
      // Navigator.pushReplacementNamed() so the correct screen always shows.
      home: const AppRouter(),
      onGenerateRoute: _generateRoute,
    );
  }

  static Route<dynamic>? _generateRoute(RouteSettings settings) {
    switch (settings.name) {
      case '/registration':
        return _buildPageRoute(const FaceRegistrationPage());
      case '/login':
        return _buildPageRoute(const FaceLoginPage());
      case '/dashboard':
        return _buildPageRoute(const DashboardPage());
      case '/settings':
        return _buildPageRoute(const SettingsPage());
      case '/emotion-detection':
        return _buildPageRoute(const EmotionDetectionPage());
      case '/emotion-result':
        final emotion = settings.arguments as String? ?? 'neutral';
        return _buildPageRoute(EmotionResultPage(emotion: emotion));
      case '/app-selection':
        return _buildPageRoute(const AppSelectionPage());
      case '/logs':
        return _buildPageRoute(const LogsPage());
      default:
        return null;
    }
  }

  static PageRouteBuilder _buildPageRoute(Widget page) {
    return PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.05, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            )),
            child: child,
          ),
        );
      },
      transitionDuration: const Duration(milliseconds: 350),
    );
  }
}

/// AppRouter
///
/// BUG FIX — Why this widget exists:
/// The original code wrapped MaterialApp in a Consumer<AppStateProvider> and
/// changed `home:` based on state. This does NOT work because Flutter's
/// Navigator only reads `home:` once on the very first build. After that,
/// rebuilding MaterialApp with a different `home:` is completely ignored —
/// the navigator stack stays unchanged and the screen never switches.
///
/// CORRECT PATTERN used here:
///   1. AppRouter is always the static home: of MaterialApp.
///   2. It subscribes to AppStateProvider via addListener.
///   3. When state changes it calls Navigator.pushReplacementNamed() which
///      correctly replaces whatever is on the stack.
///
/// Screen decision logic:
///
///   Fresh install (friend's new phone):
///     → splash → initialize() finds no face vector
///     → isFaceRegistered=false → /registration  ✅
///
///   Returning user (cold start):
///     → splash → initialize() finds face vector
///     → isFaceRegistered=true, isAuthenticated=false → /login  ✅
///
///   Authenticated user (resume from recents, process still alive):
///     → isAuthenticated stays true in memory → /dashboard  ✅
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
    // didChangeDependencies is the correct place to read Provider
    // (not initState, where Provider is not yet available).
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
    final appState = _appState!;
    if (!appState.isInitialized) return; // still loading, wait

    final target = _resolveRoute(appState);
    Navigator.of(context).pushReplacementNamed(target);
  }

  String _resolveRoute(AppStateProvider s) {
    if (!s.isFaceRegistered) return '/registration';
    if (!s.isAuthenticated) return '/login';
    return '/dashboard';
  }

  @override
  Widget build(BuildContext context) {
    // AppRouter always renders the splash screen.
    // The real navigation happens in _onStateChanged once initialize() fires.
    return const _SplashScreen();
  }
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
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.elasticOut),
    );

    _opacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
      ),
    );

    _controller.forward();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Show splash for at least 1.5s, then kick off initialize().
    // AppRouter._onStateChanged handles navigation once done.
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
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0A0E21), Color(0xFF1D1E33)],
          ),
        ),
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Opacity(
                opacity: _opacityAnimation.value,
                child: Transform.scale(
                  scale: _scaleAnimation.value,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            colors: [Color(0xFF6C63FF), Color(0xFF9D4EDD)],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF6C63FF).withOpacity(0.5),
                              blurRadius: 30,
                              spreadRadius: 5,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.face_retouching_natural,
                          size: 60,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Nanopanda',
                        style: GoogleFonts.poppins(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Secure • Smart • Simple',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          color: Colors.white60,
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}