import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:wifi_scan/wifi_scan.dart';

import '../providers/esp32_provider.dart';

// Connection status types
enum ConnectionStatus { none, checking, success, noWifi, espNotFound, error }

// Discovery process states
enum DiscoveryStage {
  checkingWifi,
  connectedToWifi,
  lookingForClexa,
  found,
  foundOnDifferentNetwork,
  redirectingToData,
  notFound,
  error,
}

class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen>
    with SingleTickerProviderStateMixin {
  // Stage tracking
  DiscoveryStage _currentStage = DiscoveryStage.checkingWifi;
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

    // Set the initial stage with empty status
    _currentStage = DiscoveryStage.checkingWifi;
    _connectionStatus = ConnectionStatus.none;
    _errorMessage = null;

    // Run automatic discovery on startup
    _checkConnection();
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  // Animate stage transition
  void _animateToStage(DiscoveryStage newStage) async {
    // Don't animate if it's the same stage
    if (newStage == _currentStage) return;

    // Start by fading out current content
    await _animationController.reverse();

    if (!mounted) return;

    // Update the stage while content is invisible
    setState(() {
      _currentStage = newStage;
    });

    // Then fade in new content
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

  // Scan for WiFi networks to find the ESP's network
  Future<String?> _findClexaNetwork() async {
    try {
      // Check if WiFi scanning is available
      final canScan = await WiFiScan.instance.canStartScan();
      if (canScan != CanStartScan.yes) {
        if (kDebugMode) {
          debugPrint('Cannot scan for WiFi networks: $canScan');
        }
        return null;
      }

      // Start the scan
      final result = await WiFiScan.instance.startScan();
      if (!result) {
        if (kDebugMode) {
          debugPrint('Failed to start WiFi scan');
        }
        return null;
      }

      // Get scan results
      await Future.delayed(
        const Duration(seconds: 2),
      ); // Wait for scan to complete
      final accessPoints = await WiFiScan.instance.getScannedResults();

      if (kDebugMode) {
        debugPrint('Found ${accessPoints.length} WiFi networks');
      }

      // Look for any network starting with "Clexa-On-"
      for (var ap in accessPoints) {
        final ssid = ap.ssid;
        if (ssid.startsWith('Clexa-On-')) {
          // Extract the network name from "Clexa-On-{NetworkName}"
          final espNetwork = ssid.substring(9); // "Clexa-On-".length
          if (kDebugMode) {
            debugPrint('Found Clexa on network: $espNetwork');
          }
          return espNetwork;
        }
      }

      return null; // No Clexa broadcast network found
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error scanning WiFi networks: $e');
      }
      return null;
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

  // Reliable connection check with improved flow
  Future<void> _checkConnection() async {
    if (!mounted) return;

    // Immediately update all UI state to avoid any flashing
    setState(() {
      // Reset all state variables
      _currentStage = DiscoveryStage.checkingWifi;
      _isCheckingConnection = true;
      _discoveryComplete = false;
      _errorMessage = null;
      _connectionStatus = ConnectionStatus.checking;
      _isRedirecting = false;
    });

    // Make sure animation is complete before proceeding
    if (_animationController.status != AnimationStatus.completed) {
      await _animationController.forward();
    }

    // STAGE 1: Allow 2 seconds for the "Checking WiFi Connection..." UI
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    // Check if user is connected to a WiFi network
    final connectivityResult = await _connectivity.checkConnectivity();
    final bool isConnectedToWifi = connectivityResult.contains(
      ConnectivityResult.wifi,
    );

    if (!isConnectedToWifi) {
      // STAGE 1B: Not connected to WiFi
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

    // STAGE 1A: Show "Connected to WiFi 'ssid'" for 1 second
    if (mounted) {
      setState(() {
        _networkName = _currentSsid ?? "Unknown Network";
      });
      _updateStageWithoutAnimation(DiscoveryStage.connectedToWifi);

      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
    }

    // STAGE 2: Show "Looking for Clexa on the same network..." for 5 seconds
    _updateStageWithoutAnimation(DiscoveryStage.lookingForClexa);

    // Check for ESP32 during these 5 seconds
    final esp32Provider = Provider.of<Esp32Provider>(context, listen: false);

    // First try WiFi scanning to find broadcast information
    String? espNetworkFromBroadcast = await _findClexaNetwork();

    // If we found a broadcast, and it's on a different network
    if (espNetworkFromBroadcast != null &&
        espNetworkFromBroadcast != _currentSsid) {
      if (mounted) {
        setState(() {
          _isCheckingConnection = false;
          _discoveryComplete = true;
          _networkName = espNetworkFromBroadcast;
        });
        _animateToStage(DiscoveryStage.foundOnDifferentNetwork);
        return;
      }
    }

    // Check if already connected
    if (esp32Provider.state.isConnectedToEsp) {
      // STAGE 2A: ESP already connected
      if (mounted) {
        // Check if connected to same network
        String? espSsid = esp32Provider.state.connectedSsid;

        if (espSsid != null && espSsid != _currentSsid) {
          // STAGE 2C: ESP found but on different network
          if (mounted) {
            setState(() {
              _isCheckingConnection = false;
              _discoveryComplete = true;
              _networkName = espSsid;
            });
            _animateToStage(DiscoveryStage.foundOnDifferentNetwork);
          }
          return;
        }

        // Same network - show success with animation
        setState(() {
          _networkName = espSsid ?? _currentSsid ?? "Unknown Network";
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

      // Try discovery within the 5-second window
      await esp32Provider.discoverEsp32();

      // Total search time of 5 seconds (including animation)
      int startTime = DateTime.now().millisecondsSinceEpoch;
      int remainingTime = 5000; // 5 seconds in milliseconds

      // Wait for the connection or timeout
      while (remainingTime > 0) {
        if (esp32Provider.state.isConnectedToEsp) {
          // STAGE 2A: SUCCESS - connected to ESP
          if (mounted) {
            // Check if connected to same network
            String? espSsid = esp32Provider.state.connectedSsid;

            if (espSsid != null && espSsid != _currentSsid) {
              // STAGE 2C: ESP found but on different network
              if (mounted) {
                setState(() {
                  _isCheckingConnection = false;
                  _discoveryComplete = true;
                  _networkName = espSsid;
                });
                _animateToStage(DiscoveryStage.foundOnDifferentNetwork);
              }
              return;
            }

            // Same network - show success with animation
            setState(() {
              _networkName = espSsid ?? _currentSsid ?? "Unknown Network";
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

        // Calculate remaining time
        int now = DateTime.now().millisecondsSinceEpoch;
        remainingTime = 5000 - (now - startTime);

        // Wait a bit before checking again
        if (remainingTime > 0) {
          await Future.delayed(
            Duration(milliseconds: remainingTime > 500 ? 500 : remainingTime),
          );
        }
      }

      // STAGE 2B: If we get here, we couldn't find ESP after 5 seconds
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
        // Use animation for transition to error state
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

  // Update text-only stages without animations (for early stages with spinner)
  void _updateStageWithoutAnimation(DiscoveryStage newStage) {
    if (mounted) {
      setState(() {
        _currentStage = newStage;
      });
    }
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
                  _discoveryComplete &&
                  _currentStage != DiscoveryStage.foundOnDifferentNetwork)
                _buildAnimatedContent(
                  child: _buildConnectionGuidance(),
                  delay: 0.2,
                ),

              const SizedBox(height: 36),

              // "Configure Network" button only shown when discovery complete with "not found"
              if (_currentStage == DiscoveryStage.notFound &&
                  _discoveryComplete)
                Column(
                  children: [
                    _buildAnimatedButton(
                      icon: const Icon(Icons.wifi),
                      label: const Text('Configure Clexa Network'),
                      onPressed: () => _goToProvisioningScreen(),
                    ),
                    const SizedBox(height: 12), // Space between buttons
                    _buildAnimatedButton(
                      icon:
                          _isCheckingConnection
                              ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                              : const Icon(Icons.search),
                      label: Text(
                        _isCheckingConnection
                            ? 'Checking Connection...'
                            : 'Discover Clexa',
                      ),
                      onPressed:
                          _isCheckingConnection
                              ? () {}
                              : () => _checkConnection(),
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      isFullWidth: true,
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
      case DiscoveryStage.checkingWifi:
        return Column(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              'Checking WiFi connection...',
              style: const TextStyle(fontSize: 18),
              textAlign: TextAlign.center,
            ),
          ],
        );

      case DiscoveryStage.connectedToWifi:
        return Column(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              "Connected to WiFi: $_currentSsid",
              style: const TextStyle(fontSize: 18),
              textAlign: TextAlign.center,
            ),
          ],
        );

      case DiscoveryStage.lookingForClexa:
        return Column(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              'Looking for Clexa on the same network...',
              style: const TextStyle(fontSize: 18),
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

      case DiscoveryStage.foundOnDifferentNetwork:
        return Column(
          children: [
            const Icon(
              Icons.warning_amber_outlined,
              color: Colors.orange,
              size: 64,
            ),
            const SizedBox(height: 16),
            Text(
              'Clexa found on a different network',
              style: const TextStyle(
                fontSize: 18,
                color: Colors.orange,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              'Your device is on network: $_currentSsid\nClexa is on network: $_networkName',
              style: const TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Troubleshooting:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '• Connect your device to the same WiFi network as Clexa\n'
                    '• Try holding the physical reset button on Clexa for 3 seconds\n'
                    '• Wait a moment, then try the Discover Clexa button',
                    style: const TextStyle(fontSize: 16),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _buildAnimatedButton(
              icon:
                  _isCheckingConnection
                      ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                      : const Icon(Icons.search),
              label: Text(
                _isCheckingConnection
                    ? 'Checking Connection...'
                    : 'Discover Clexa',
              ),
              onPressed:
                  _isCheckingConnection ? () {} : () => _checkConnection(),
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              isFullWidth: true,
            ),
          ],
        );

      case DiscoveryStage.redirectingToData:
        return Column(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              'Redirecting to Data Page...',
              style: const TextStyle(fontSize: 18),
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
        } else if (_connectionStatus == ConnectionStatus.none) {
          // Don't show any error icon for the initial state
          return const SizedBox(); // Return empty widget
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
        return _errorMessage ?? '';
    }
  }

  // Build connection guidance - adapted from provisioning screen
  Widget _buildConnectionGuidance() {
    String guidance;

    switch (_connectionStatus) {
      case ConnectionStatus.noWifi:
        guidance =
            '• Make sure your WiFi is enabled\n'
            '• Connect to a WiFi network';
        break;
      case ConnectionStatus.espNotFound:
        guidance =
            '• Make sure Clexa is powered on\n'
            '• Wait 5-10 seconds for Clexa to fully start\n'
            '• If it is not being discovered, try the Configure Clexa Network button to set up WiFi Network';
        break;
      default:
        guidance = '';
    }

    // Convert the guidance string to rich text with bold formatting for "Discover Clexa"
    final List<InlineSpan> textSpans = [];

    // Process each line
    final lines = guidance.split('\n');
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      // Check if the line contains "Discover Clexa"
      if (line.contains('Discover Clexa')) {
        // Split the line at "Discover Clexa"
        final parts = line.split('Discover Clexa');

        textSpans.add(TextSpan(text: parts[0]));
        textSpans.add(
          const TextSpan(
            text: 'Discover Clexa',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        );
        textSpans.add(TextSpan(text: parts[1]));
      }
      // Check if the line contains "Configure Clexa Network"
      else if (line.contains('Configure Clexa Network')) {
        // Split the line at "Configure Clexa Network"
        final parts = line.split('Configure Clexa Network');

        textSpans.add(TextSpan(text: parts[0]));
        textSpans.add(
          const TextSpan(
            text: 'Configure Clexa Network',
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
