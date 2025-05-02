import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../providers/esp32_provider.dart';

// Connection status types (matching provisioning screen)
enum ConnectionStatus { none, checking, success, noWifi, espNotFound, error }

// Discovery process states
enum DiscoveryStage { searching, found, redirectingToData, notFound, error }

class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen>
    with SingleTickerProviderStateMixin {
  // Stage tracking
  DiscoveryStage _currentStage = DiscoveryStage.searching;
  String? _networkName; // To store network name if found
  bool _discoveryComplete = false;

  // Connection checking
  final NetworkInfo _networkInfo = NetworkInfo();
  final Connectivity _connectivity = Connectivity();
  String? _currentSsid;
  bool _isCheckingConnection = false;
  String? _errorMessage;
  bool _isRedirecting = false;
  int _connectionAttempts = 0;
  ConnectionStatus _connectionStatus = ConnectionStatus.none;

  // Animation controller
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  // Add subscription
  StreamSubscription? _connectivitySubscription;

  @override
  void initState() {
    super.initState();

    // Setup animations
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    _animationController.forward();

    // Set the initial stage
    _currentStage = DiscoveryStage.searching;

    // Run automatic discovery on startup
    _checkConnection();

    // Setup connectivity listener to monitor WiFi status changes
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((
      result,
    ) {
      if (!mounted) return;

      final bool isConnectedToWifi = result.contains(ConnectivityResult.wifi);
      final bool wasConnectedToWifi =
          _connectionStatus != ConnectionStatus.noWifi;

      if (kDebugMode) {
        debugPrint(
          "Connectivity changed. WiFi connected: $isConnectedToWifi, Previous status: ${_connectionStatus.toString()}",
        );
      }

      // Only trigger discovery if there's a change in WiFi status
      if (isConnectedToWifi != wasConnectedToWifi) {
        if (kDebugMode) {
          debugPrint("WiFi status changed. Auto-discovering...");
        }

        // Add small delay to allow network to stabilize
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            _checkConnection();
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  // Animate stage transition
  void _animateToStage(DiscoveryStage newStage) async {
    await _animationController.reverse();

    if (!mounted) return;

    setState(() {
      _currentStage = newStage;
    });

    _animationController.forward();
  }

  // Get current WiFi network name
  Future<void> _checkNetworkInfo() async {
    try {
      _currentSsid = await _networkInfo.getWifiName();
      if (_currentSsid != null &&
          _currentSsid!.startsWith('"') &&
          _currentSsid!.endsWith('"')) {
        _currentSsid = _currentSsid!.substring(1, _currentSsid!.length - 1);
      }
      if (kDebugMode) {
        debugPrint("Current SSID read: $_currentSsid");
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Could not get network info: $e');
      }
      _currentSsid = 'Error reading WiFi';
    }
  }

  // Helper method for animations
  Widget _buildAnimatedContent({required Widget child, double delay = 0.0}) {
    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        // Delay animation sequentially
        final delayedAnimation = CurvedAnimation(
          parent: _animationController,
          curve: Interval(
            delay, // Start
            1.0, // End
            curve: Curves.easeOut,
          ),
        );

        return Transform.translate(
          offset: Offset(0, 20 * (1 - delayedAnimation.value)),
          child: Opacity(opacity: delayedAnimation.value, child: child),
        );
      },
      child: child,
    );
  }

  // Build animated button
  Widget _buildAnimatedButton({
    required VoidCallback onPressed,
    required Widget icon,
    required Widget label,
    Color? backgroundColor,
    Color? foregroundColor,
    bool isFullWidth = false,
  }) {
    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        return Transform.scale(
          scale: 0.9 + (0.1 * _animationController.value),
          child: Opacity(opacity: _animationController.value, child: child),
        );
      },
      child: ElevatedButton.icon(
        icon: icon,
        label: label,
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          textStyle: const TextStyle(fontSize: 16),
          minimumSize: isFullWidth ? const Size(double.infinity, 0) : null,
        ),
      ),
    );
  }

  // Reliable connection check - adapted from provisioning screen
  Future<void> _checkConnection() async {
    if (!mounted) return;

    setState(() {
      _isCheckingConnection = true;
      _discoveryComplete = false;
      _errorMessage = null;
      _connectionStatus = ConnectionStatus.checking;
      _connectionAttempts = 0; // Reset attempts when we start a new check cycle
    });
    _animateToStage(DiscoveryStage.searching);

    // STEP 1: Check if user is connected to a WiFi network
    final connectivityResult = await _connectivity.checkConnectivity();
    final bool isConnectedToWifi = connectivityResult.contains(
      ConnectivityResult.wifi,
    );

    if (!isConnectedToWifi) {
      // Not connected to WiFi
      if (mounted) {
        setState(() {
          _errorMessage = 'Not connected to WiFi';
          _isCheckingConnection = false;
          _discoveryComplete = true;
          _connectionStatus = ConnectionStatus.noWifi;
        });
        _animateToStage(DiscoveryStage.notFound);
      }
      return;
    }

    // Get current WiFi network name
    await _checkNetworkInfo();

    // Allow at least 2 seconds of visible "searching" state
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    // STEP 2: Check for ESP32
    final esp32Provider = Provider.of<Esp32Provider>(context, listen: false);

    // Check if already connected
    if (esp32Provider.state.isConnectedToEsp) {
      if (mounted) {
        setState(() {
          _networkName =
              esp32Provider.state.connectedSsid ??
              _currentSsid ??
              "Unknown Network";
          _isCheckingConnection = false;
          _connectionStatus = ConnectionStatus.success;
        });
        _animateToStage(DiscoveryStage.found);

        // Wait 2 seconds to show success
        await Future.delayed(const Duration(seconds: 2));

        // Start redirect sequence
        _startRedirectSequence();
      }
      return;
    }

    // Not already connected, try to discover
    try {
      if (kDebugMode) {
        debugPrint("Attempting to discover ESP32...");
      }

      // Try discovery and wait for connection
      await esp32Provider.discoverEsp32();

      // Wait up to 5 seconds to see if we get connected
      int attempts = 0;
      while (attempts < 5) {
        if (esp32Provider.state.isConnectedToEsp) {
          // SUCCESS - connected to ESP
          if (mounted) {
            setState(() {
              _networkName =
                  esp32Provider.state.connectedSsid ??
                  _currentSsid ??
                  "Unknown Network";
              _isCheckingConnection = false;
              _connectionStatus = ConnectionStatus.success;
            });
            _animateToStage(DiscoveryStage.found);

            // Wait 2 seconds to show success
            await Future.delayed(const Duration(seconds: 2));

            // Start redirect sequence
            _startRedirectSequence();
          }
          return;
        }

        attempts++;
        if (attempts < 5) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }

      // If we get here, we couldn't connect after 5 attempts
      if (mounted) {
        setState(() {
          _isCheckingConnection = false;
          _discoveryComplete = true;
          _connectionAttempts++;
          _connectionStatus = ConnectionStatus.espNotFound;
          _errorMessage =
              _connectionAttempts > 1
                  ? 'Still unable to find Clexa after $_connectionAttempts attempts'
                  : null;
        });
        _animateToStage(DiscoveryStage.notFound);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error checking for ESP device: $e');
      }
      if (mounted) {
        setState(() {
          _errorMessage = 'Error: $e';
          _isCheckingConnection = false;
          _discoveryComplete = true;
          _connectionStatus = ConnectionStatus.error;
        });
        _animateToStage(DiscoveryStage.error);
      }
    }
  }

  // Start redirect sequence
  void _startRedirectSequence() {
    if (!mounted) return;

    setState(() {
      _isRedirecting = true;
    });
    _animateToStage(DiscoveryStage.redirectingToData);

    // Wait 2 seconds, then redirect
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/data');
      }
    });
  }

  // Navigate to provisioning screen
  void _goToProvisioningScreen() {
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/provision');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Hero(
                tag: 'clexa_title',
                child: Text(
                  'Discovering Clexa',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 36),

              // Different UI based on discovery stage with fade animation
              FadeTransition(
                opacity: _fadeAnimation,
                child: _buildAnimatedContent(
                  child: _buildStageContent(),
                  delay: 0.1,
                ),
              ),

              // Add troubleshooting guidance if needed
              if (_connectionStatus != ConnectionStatus.none &&
                  _connectionStatus != ConnectionStatus.success &&
                  !_isRedirecting &&
                  _discoveryComplete)
                _buildAnimatedContent(
                  child: _buildConnectionGuidance(),
                  delay: 0.2,
                ),

              const SizedBox(height: 36),

              // WiFi status indicator
              if (_currentSsid != null &&
                  _connectionStatus != ConnectionStatus.noWifi)
                _buildAnimatedContent(
                  child: Text(
                    'WiFi Network: $_currentSsid',
                    style: const TextStyle(
                      fontSize: 16,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  delay: 0.3,
                ),

              const SizedBox(height: 18),

              // Different buttons based on status
              if (_connectionStatus == ConnectionStatus.none ||
                  _isCheckingConnection)
                // No buttons while checking
                const SizedBox()
              else if (_connectionStatus == ConnectionStatus.success ||
                  _isRedirecting)
                // No buttons if success or redirecting
                const SizedBox()
              else
                // Different buttons based on connection status
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Refresh button
                    if (!_isCheckingConnection)
                      _buildAnimatedButton(
                        onPressed: () => _checkConnection(),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh'),
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                    const SizedBox(width: 16),
                    // Configure button
                    if ((!_isCheckingConnection) &&
                        (_connectionStatus == ConnectionStatus.noWifi ||
                            _connectionStatus == ConnectionStatus.espNotFound))
                      _buildAnimatedButton(
                        onPressed: () => _goToProvisioningScreen(),
                        icon: const Icon(Icons.settings),
                        label: const Text('Configure Clexa'),
                        backgroundColor: Colors.deepPurple,
                        foregroundColor: Colors.white,
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  // Build different content based on the current stage
  Widget _buildStageContent() {
    switch (_currentStage) {
      case DiscoveryStage.searching:
        return Column(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            const Text(
              'Searching for Clexa device...',
              style: TextStyle(fontSize: 18),
              textAlign: TextAlign.center,
            ),
          ],
        );

      case DiscoveryStage.found:
        return Column(
          children: [
            const Icon(
              Icons.check_circle_outline,
              color: Colors.green,
              size: 64,
            ),
            const SizedBox(height: 16),
            RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.black87,
                  height: 1.5,
                ),
                children: [
                  const TextSpan(
                    text: "Clexa Found!\n",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.green,
                      fontSize: 20,
                    ),
                  ),
                  TextSpan(
                    text: "Connected to Wi-Fi: $_networkName",
                    style: const TextStyle(fontSize: 18),
                  ),
                ],
              ),
            ),
          ],
        );

      case DiscoveryStage.redirectingToData:
        return Column(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            const Text(
              'Redirecting to Data Page...',
              style: TextStyle(fontSize: 18),
              textAlign: TextAlign.center,
            ),
          ],
        );

      case DiscoveryStage.error:
        return Column(
          children: [
            const Icon(Icons.error_outline, color: Colors.orange, size: 64),
            const SizedBox(height: 16),
            Text(
              _getConnectionStatusText(),
              style: const TextStyle(
                fontSize: 18,
                color: Colors.orange,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        );

      case DiscoveryStage.notFound:
        // Use different icons based on connection status
        IconData iconData = Icons.error_outline;
        Color iconColor = Colors.red;

        // Update icon based on connection status
        if (_connectionStatus == ConnectionStatus.noWifi) {
          iconData = Icons.wifi_off;
        }

        return Column(
          children: [
            Icon(iconData, color: iconColor, size: 64),
            const SizedBox(height: 16),
            Text(
              _getConnectionStatusText(),
              style: TextStyle(
                fontSize: 18,
                color: iconColor,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        );
    }
  }

  // Get connection status text - copied from provisioning screen
  String _getConnectionStatusText() {
    switch (_connectionStatus) {
      case ConnectionStatus.noWifi:
        return 'Not connected to any WiFi network';
      case ConnectionStatus.espNotFound:
        return 'Clexa not found';
      case ConnectionStatus.error:
        return _errorMessage ?? 'Error checking connection';
      case ConnectionStatus.success:
        return 'Success! Clexa device detected on your network!';
      default:
        return _errorMessage ?? 'Connection issue detected';
    }
  }

  // Build connection guidance - adapted from provisioning screen
  Widget _buildConnectionGuidance() {
    String guidance;

    switch (_connectionStatus) {
      case ConnectionStatus.noWifi:
        guidance =
            '• Make sure your WiFi is enabled\n'
            '• Connect to a WiFi network\n'
            '• Try toggling your WiFi off and on';
        break;
      case ConnectionStatus.espNotFound:
        guidance =
            '• Make sure Clexa is powered on\n'
            '• Wait 5-10 seconds for Clexa to fully start\n'
            '• Try refreshing to discover the device\n'
            '• Make sure your phone and Clexa are on the same WiFi network';
        break;
      default:
        guidance =
            '• Please check your network settings\n'
            '• Ensure Clexa is powered on\n'
            '• Try clicking the Refresh button';
    }

    // Convert the guidance string to rich text with bold formatting
    final List<InlineSpan> textSpans = [];

    // Process each line
    final lines = guidance.split('\n');
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      // Check if the line contains "Refresh"
      if (line.contains('Refresh')) {
        // Split the line at "Refresh"
        final parts = line.split('Refresh');

        textSpans.add(TextSpan(text: parts[0]));
        textSpans.add(
          const TextSpan(
            text: 'Refresh',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        );
        textSpans.add(TextSpan(text: parts[1]));
      } else {
        textSpans.add(TextSpan(text: line));
      }

      // Add a newline if not the last line
      if (i < lines.length - 1) {
        textSpans.add(const TextSpan(text: '\n'));
      }
    }

    return Padding(
      padding: const EdgeInsets.only(top: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Troubleshooting:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          RichText(
            text: TextSpan(
              style: const TextStyle(color: Colors.black, fontSize: 16),
              children: textSpans,
            ),
          ),
        ],
      ),
    );
  }
}
