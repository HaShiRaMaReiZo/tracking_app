import 'package:flutter/material.dart';

import 'screens/login_screen.dart';
import 'screens/sessions_screen.dart';
import 'services/auth_service.dart';
import 'services/background_tracking_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeBackgroundTrackingService();
  runApp(const TrackingApp());
}

class TrackingApp extends StatelessWidget {
  const TrackingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tracking',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: FutureBuilder<AuthService>(
        future: _initAuth(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final authService = snapshot.data ?? AuthService();
          if (authService.isLoggedIn) {
            return SessionsScreen(authService: authService);
          }
          return LoginScreen(authService: authService);
        },
      ),
    );
  }

  Future<AuthService> _initAuth() async {
    final authService = AuthService();
    await authService.init();
    return authService;
  }
}
