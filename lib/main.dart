import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/esp32_provider.dart';
import 'screens/discovery_screen.dart';
import 'screens/provisioning_screen.dart';
import 'screens/data_display_screen.dart';

// Custom page route for smooth transitions
class FadePageRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  FadePageRoute({required this.page})
    : super(
        pageBuilder: (context, animation, secondaryAnimation) => page,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = 0.0;
          const end = 1.0;
          const curve = Curves.easeInOut;

          var tween = Tween(
            begin: begin,
            end: end,
          ).chain(CurveTween(curve: curve));
          var opacityAnimation = animation.drive(tween);

          return FadeTransition(opacity: opacityAnimation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      );
}

// Global navigator key for navigation from anywhere
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Helper function to navigate from anywhere
void navigateTo(String routeName, {Object? arguments}) {
  navigatorKey.currentState?.pushReplacementNamed(
    routeName,
    arguments: arguments,
  );
}

void main() {
  // Add error handling for Flutter framework errors
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrint('Flutter error: ${details.exception}');
    debugPrint('Stack trace: ${details.stack}');
    FlutterError.presentError(details);
  };

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<Esp32Provider>(
      create: (ctx) => Esp32Provider(),
      child: MaterialApp(
        title: 'Clexa',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          useMaterial3: true,
        ),
        navigatorKey: navigatorKey, // Use our global navigator key
        onGenerateRoute: (settings) {
          // Handle routes with smooth transitions
          switch (settings.name) {
            case '/':
              return FadePageRoute(page: const DiscoveryScreen());
            case '/data':
              return FadePageRoute(page: const DataDisplayScreen());
            case '/provision':
              return FadePageRoute(page: const ProvisioningScreen());
            default:
              return FadePageRoute(page: const DiscoveryScreen());
          }
        },
        home: const DiscoveryScreen(),
      ),
    );
  }
}
