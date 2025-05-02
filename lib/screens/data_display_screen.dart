import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart'; // Import for kDebugMode

// Adjust path based on your project structure
import '../providers/esp32_provider.dart';
import '../main.dart' show navigateTo;

// How long without activity before considering the ESP32 offline
const Duration connectionTimeoutDuration = Duration(seconds: 10);

// --- Convert to StatefulWidget ---
class DataDisplayScreen extends StatefulWidget {
  const DataDisplayScreen({super.key});

  @override
  State<DataDisplayScreen> createState() => _DataDisplayScreenState();
}

// --- Create State class ---
class _DataDisplayScreenState extends State<DataDisplayScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  Timer? _connectionCheckTimer;
  bool _isConnectionTimedOut = false;

  @override
  void initState() {
    super.initState();

    // Setup animations
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    _animationController.forward();

    // Check if provisioning is needed on init
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkProvisioningNeeded();

      // Start periodic connection check timer
      _startConnectionCheckTimer();
    });
  }

  @override
  void dispose() {
    _connectionCheckTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  // Start timer to check connection status periodically
  void _startConnectionCheckTimer() {
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = Timer.periodic(
      const Duration(seconds: 2), // Check every 2 seconds
      (_) => _checkConnectionTimeout(),
    );
  }

  // Check if connection has timed out
  void _checkConnectionTimeout() {
    if (!mounted) return;

    final espState = Provider.of<Esp32Provider>(context, listen: false).state;

    // Only check timeout if we're supposedly connected
    if (espState.isConnectedToEsp) {
      final hasTimedOut = espState.isConsideredOffline(
        connectionTimeoutDuration,
      );

      if (hasTimedOut != _isConnectionTimedOut) {
        if (hasTimedOut) {
          if (kDebugMode) {
            debugPrint(
              'Connection timed out! No activity for ${connectionTimeoutDuration.inSeconds} seconds',
            );
          }

          // If connection has timed out, force disconnect in the provider
          Provider.of<Esp32Provider>(
            context,
            listen: false,
          ).disconnectWebSocket();
        }

        setState(() {
          _isConnectionTimedOut = hasTimedOut;
        });
      }
    } else {
      // Reset timeout state if we're already disconnected
      if (_isConnectionTimedOut) {
        setState(() {
          _isConnectionTimedOut = false;
        });
      }
    }
  }

  // Simple check for provisioning needed
  void _checkProvisioningNeeded() {
    try {
      if (!mounted) return;

      final espState = Provider.of<Esp32Provider>(context, listen: false).state;

      if (kDebugMode) {
        debugPrint('DataDisplayScreen: Checking provisioning status');
        debugPrint('isProvisioningNeeded: ${espState.isProvisioningNeeded}');
      }

      if (espState.isProvisioningNeeded && mounted) {
        if (kDebugMode) {
          debugPrint('DataDisplayScreen: Provisioning needed, navigating...');
        }

        // Navigate directly using the global function
        navigateTo('/provision');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error checking provisioning status: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final espState = Provider.of<Esp32Provider>(context).state;

    // Calculate actual connection state (either from WebSocket or activity timeout)
    final bool isActuallyConnected =
        espState.isConnectedToEsp && !_isConnectionTimedOut;

    return Scaffold(
      appBar: AppBar(
        title: const Hero(tag: 'clexa_title', child: Text('Clexa Data')),
      ),
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: ListView(
            children: [
              // Connection status card
              _buildAnimatedCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Connection Status',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          isActuallyConnected
                              ? Icons.check_circle
                              : (espState.errorMessage != null &&
                                  espState.errorMessage == 'Connecting...')
                              ? Icons.sync
                              : Icons.error,
                          color:
                              isActuallyConnected
                                  ? Colors.green
                                  : (espState.errorMessage != null &&
                                      espState.errorMessage == 'Connecting...')
                                  ? Colors.orange
                                  : Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isActuallyConnected
                                ? 'Connected'
                                : _isConnectionTimedOut
                                ? 'Disconnected (Clexa Offline)'
                                : (espState.errorMessage == 'Connecting...')
                                ? 'Connecting...'
                                : 'Disconnected',
                            style: TextStyle(
                              color:
                                  isActuallyConnected
                                      ? Colors.green
                                      : (espState.errorMessage != null &&
                                          espState.errorMessage ==
                                              'Connecting...')
                                      ? Colors.orange
                                      : Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (espState.connectedSsid != null) ...[
                      Row(
                        children: [
                          const Icon(Icons.wifi, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'Network: ${espState.connectedSsid}',
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ],
                    if (espState.errorMessage != null &&
                        espState.errorMessage != 'Connecting...') ...[
                      const SizedBox(height: 8),
                      Text(
                        '${espState.errorMessage}',
                        style: const TextStyle(color: Colors.red),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Sensor readings
              _buildAnimatedCard(
                delay: const Duration(milliseconds: 100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Water Level gauge
                    SensorGauge(
                      label: 'Water Level',
                      value: espState.waterLevel ?? 0,
                      color: Colors.blue,
                      icon: Icons.water_drop,
                    ),
                    const SizedBox(height: 12),

                    // Battery Status gauge
                    SensorGauge(
                      label: 'Battery',
                      value: espState.batteryStatus ?? 0,
                      color: Colors.green,
                      icon: Icons.battery_full,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Clexa Control Panel
              _buildAnimatedCard(
                delay: const Duration(milliseconds: 100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Clexa Control Panel',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Status display
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'Clexa Status: ',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color:
                                espState.isRunning ? Colors.green : Colors.red,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            espState.isRunning ? 'Running' : 'Stopped',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Action buttons
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // Start button
                        ElevatedButton.icon(
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Start'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey.shade300,
                            minimumSize: const Size(120, 45),
                          ),
                          onPressed:
                              espState.isConnectedToEsp && !espState.isRunning
                                  ? () =>
                                      context
                                          .read<Esp32Provider>()
                                          .sendStartCommand()
                                  : null,
                        ),

                        // Stop button
                        ElevatedButton.icon(
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey.shade300,
                            minimumSize: const Size(120, 45),
                          ),
                          onPressed:
                              espState.isConnectedToEsp && espState.isRunning
                                  ? () =>
                                      context
                                          .read<Esp32Provider>()
                                          .sendStopCommand()
                                  : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (!isActuallyConnected)
                    _buildAnimatedButton(
                      onPressed:
                          (espState.errorMessage == 'Connecting...')
                              ? null
                              : () {
                                // Use context.read inside callbacks/functions outside build
                                if (espState.espWebSocketUrl != null) {
                                  context
                                      .read<Esp32Provider>()
                                      .connectToWebSocket();
                                } else {
                                  Navigator.pushReplacementNamed(context, '/');
                                }
                              },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reconnect'),
                    ),

                  // Reconfigure Button
                  Hero(
                    tag: 'action_button',
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.settings_backup_restore),
                      label: const Text('Reconfigure'),
                      onPressed:
                          !isActuallyConnected
                              ? null
                              : () {
                                // Show feedback immediately
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Telling Clexa to clear credentials and restart...',
                                    ),
                                    duration: Duration(seconds: 2),
                                  ),
                                );

                                // Use microtask to prevent UI blocking
                                Future.microtask(() {
                                  // Call provider to send command asynchronously
                                  context
                                      .read<Esp32Provider>()
                                      .sendClearCredentialsCommand();

                                  // Navigate after a reasonable delay to allow disconnect to complete
                                  Future.delayed(
                                    const Duration(seconds: 1),
                                    () {
                                      if (mounted) {
                                        // Ensure widget is still mounted
                                        Navigator.pushReplacementNamed(
                                          context,
                                          '/provision',
                                        );
                                      }
                                    },
                                  );
                                });
                              },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.grey,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // Helper widgets for animations
  Widget _buildAnimatedCard({
    required Widget child,
    Duration delay = Duration.zero,
  }) {
    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        final delayedAnimation = _animationController.drive(
          CurveTween(curve: Interval(0.2, 1.0, curve: Curves.easeOut)),
        );

        return Transform.translate(
          offset: Offset(0, 20 * (1 - delayedAnimation.value)),
          child: Opacity(
            opacity: delayedAnimation.value,
            child: Card(
              elevation: 2 * delayedAnimation.value,
              child: Padding(padding: const EdgeInsets.all(16.0), child: child),
            ),
          ),
        );
      },
      child: child,
    );
  }

  Widget _buildAnimatedButton({
    required VoidCallback? onPressed,
    required Widget icon,
    required Widget label,
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
      ),
    );
  }
}

// Add this class definition at the end of the file, outside of the existing class
class SensorGauge extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  final IconData icon;

  const SensorGauge({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 8),
            Text(
              '$label: $value%',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: value / 100.0,
          backgroundColor: Colors.grey.shade200,
          valueColor: AlwaysStoppedAnimation<Color>(color),
          minHeight: 10,
          borderRadius: BorderRadius.circular(10),
        ),
      ],
    );
  }
}
