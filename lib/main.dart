import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';

import 'theme/theme.dart';
import 'core/services/storage_service.dart';
import 'core/providers/app_state_provider.dart';
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

  // Set preferred orientations
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Set system UI overlay style
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0A0E21),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Initialize services
  final storageService = StorageService();
  await storageService.init();

  runApp(
    MultiProvider(
      providers: [
        Provider<StorageService>.value(value: storageService),
        ChangeNotifierProvider(create: (_) => AppStateProvider(storageService)),
      ],
      child: const FaceGuardApp(),
    ),
  );
}

class FaceGuardApp extends StatelessWidget {
  const FaceGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppStateProvider>(
      builder: (context, appState, _) {
        return MaterialApp(
          title: 'Nanopanda',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.darkTheme,
          home: _getInitialScreen(appState),
          onGenerateRoute: _generateRoute,
        );
      },
    );
  }

  Widget _getInitialScreen(AppStateProvider appState) {
    if (!appState.isInitialized) {
      return const _SplashScreen();
    }

    if (!appState.isFaceRegistered) {
      return const FaceRegistrationPage();
    }

    if (!appState.isAuthenticated) {
      return const FaceLoginPage();
    }

    return const DashboardPage();
  }

  Route<dynamic>? _generateRoute(RouteSettings settings) {
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

  PageRouteBuilder _buildPageRoute(Widget page) {
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
    await Future.delayed(const Duration(milliseconds: 2000));
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