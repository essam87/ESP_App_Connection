import 'package:flutter/material.dart';
import 'package:esp_smartconfig/esp_smartconfig.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:async';

// Provisioning process states
enum ProvisioningStage {
  input,
  sendingCredentials,
  credentialsSent,
  credentialsFailed,
  connecting,
  success,
  failure,
}

class ProvisioningScreen extends StatefulWidget {
  const ProvisioningScreen({super.key});

  @override
  State<ProvisioningScreen> createState() => _ProvisioningScreenState();
}

class _ProvisioningScreenState extends State<ProvisioningScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _ssidController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _ssidFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();

  // Form state
  bool _showPassword = false;
  final _formKey = GlobalKey<FormState>();
  bool _isSubmitting = false;
  String? _errorMessage;

  // Animation controllers
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  // Provisioner instance
  Provisioner? _provisioner;

  // Current stage
  ProvisioningStage _currentStage = ProvisioningStage.input;
  String? _currentSsid;

  // Timing information
  DateTime? _provisioningStartTime;
  String? _provisioningDuration;
  Timer? _provisioningTimer;

  // Connectivity state
  bool _isConnectedToWifi = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  @override
  void initState() {
    super.initState();

    // Initialize animations
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    _animationController.forward();

    // Initialize connectivity monitoring
    _checkConnectivity();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      _updateConnectionStatus,
    );
  }

  // Check current connectivity status
  Future<void> _checkConnectivity() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    _updateConnectionStatus(connectivityResult);
  }

  // Update connection status based on connectivity result
  void _updateConnectionStatus(List<ConnectivityResult> results) {
    setState(() {
      _isConnectedToWifi = results.contains(ConnectivityResult.wifi);
      // Clear error message if now connected to WiFi
      if (_isConnectedToWifi &&
          _errorMessage?.contains('WiFi network') == true) {
        _errorMessage = null;
      }
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    _ssidController.dispose();
    _passwordController.dispose();
    _ssidFocusNode.dispose();
    _passwordFocusNode.dispose();
    _provisioner?.stop();
    _connectivitySubscription?.cancel();
    _provisioningTimer?.cancel();
    super.dispose();
  }

  // Animate stage transition
  void _animateToStage(ProvisioningStage newStage) async {
    await _animationController.reverse();

    if (!mounted) return;

    setState(() {
      _currentStage = newStage;
    });

    _animationController.forward();
  }

  Future<void> _startProvisioning() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // Store SSID for displaying in messages
    _currentSsid = _ssidController.text.trim();

    // Clear screen and show provisioning UI
    _animateToStage(ProvisioningStage.sendingCredentials);

    // Start timing
    _provisioningStartTime = DateTime.now();
    _provisioningDuration = null;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final ssid = _ssidController.text.trim();
    final password = _passwordController.text.trim();

    try {
      // Get actual WiFi info
      final networkInfo = NetworkInfo();

      String? bssid;
      try {
        bssid = await networkInfo.getWifiBSSID();
        if (kDebugMode) {
          debugPrint('Current BSSID: $bssid');
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Error getting BSSID: $e');
        }
        // Will use default if getting BSSID fails
      }

      // Create the provisioner with correct parameters
      _provisioner = Provisioner.espTouch();

      // Set up listener for provisioning responses
      _provisioner!.listen((response) {
        if (kDebugMode) {
          debugPrint(
            'Provisioning response received: ${response.ipAddressText}',
          );
        }

        if (mounted) {
          // Show credentials sent message for 1 second
          _animateToStage(ProvisioningStage.credentialsSent);

          // Then show connecting message
          Future.delayed(const Duration(seconds: 1), () {
            if (mounted) {
              _animateToStage(ProvisioningStage.connecting);
            }
          });

          // Calculate duration
          _provisioningDuration = _calculateDuration();

          // Show success after a short delay (simulating connection process)
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) {
              setState(() {
                _isSubmitting = false;
              });

              // Show success stage
              _animateToStage(ProvisioningStage.success);
            }
          });
        }

        // Stop provisioning process
        _provisioner!.stop();
        _provisioningTimer?.cancel();
      });

      // Start the provisioning process with the correct parameters
      if (kDebugMode) {
        debugPrint(
          'Starting provisioning with SSID: $ssid, BSSID: ${bssid ?? "empty"}, Password length: ${password.length}',
        );
      }

      // Create request
      final request = ProvisioningRequest.fromStrings(
        ssid: ssid,
        bssid: bssid ?? '',
        password: password,
      );

      _provisioner!.start(request);

      // Cancel any existing timer
      _provisioningTimer?.cancel();

      // First, check for credential sending timeout after 90 seconds
      _provisioningTimer = Timer(const Duration(seconds: 90), () {
        if (_currentStage == ProvisioningStage.sendingCredentials && mounted) {
          // If still in sending credentials stage, show failure
          _provisioner?.stop();
          _animateToStage(ProvisioningStage.credentialsFailed);
          setState(() {
            _isSubmitting = false;
            _errorMessage = 'Could not send credentials to Clexa';
          });
        }
      });

      // Then, check for full provisioning timeout after 90 seconds total
      Future.delayed(const Duration(seconds: 90), () {
        // Cancel previous timer if it's still active
        _provisioningTimer?.cancel();

        // Set new timer for overall process timeout
        if ((_currentStage == ProvisioningStage.sendingCredentials ||
                _currentStage == ProvisioningStage.credentialsSent ||
                _currentStage == ProvisioningStage.connecting) &&
            mounted) {
          // Calculate duration
          _provisioningDuration = _calculateDuration();

          // If still in provisioning after timeout, show failure
          _provisioner?.stop();
          _animateToStage(ProvisioningStage.failure);
          setState(() {
            _isSubmitting = false;
            _errorMessage = 'Provisioning timed out';
          });
        }
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Provisioning error: $e');
      }

      if (mounted) {
        setState(() {
          // Check for the specific FormatException that occurs when not connected to WiFi
          if (e.toString().contains(
            'FormatException: Invalid radix-16 number',
          )) {
            _errorMessage =
                'Please connect your phone to a WiFi network before provisioning';
          } else if (e.toString().contains('Minimum length of password is 8')) {
            _errorMessage = null;
          } else {
            _errorMessage = 'Error starting provisioning: $e';
          }
          _isSubmitting = false;
        });
        _animateToStage(ProvisioningStage.failure);
      }
    }
  }

  // Calculate provisioning duration
  String _calculateDuration() {
    if (_provisioningStartTime == null) return '';

    final duration = DateTime.now().difference(_provisioningStartTime!);
    final seconds = duration.inSeconds;

    if (seconds < 60) {
      return 'Time elapsed: $seconds seconds';
    } else {
      final minutes = duration.inMinutes;
      final remainingSeconds = seconds - (minutes * 60);
      return 'Time elapsed: $minutes min $remainingSeconds sec';
    }
  }

  // Helper widgets for animations
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

  // Build animated card
  Widget _buildAnimatedCard({required Widget child, double delay = 0.0}) {
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

        return FadeTransition(
          opacity: delayedAnimation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.05),
              end: Offset.zero,
            ).animate(delayedAnimation),
            child: child,
          ),
        );
      },
      child: Card(
        elevation: 4,
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: Padding(padding: const EdgeInsets.all(16.0), child: child),
      ),
    );
  }

  // Build animated button
  Widget _buildAnimatedButton({
    required VoidCallback? onPressed,
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

  // Builder for provisioning stage
  Widget _buildProvisioningStageContent() {
    switch (_currentStage) {
      case ProvisioningStage.input:
        return _buildInputForm();

      case ProvisioningStage.sendingCredentials:
        return _buildSendingCredentialsUI();

      case ProvisioningStage.credentialsSent:
        return _buildCredentialsSentUI();

      case ProvisioningStage.credentialsFailed:
        return _buildCredentialsFailedUI();

      case ProvisioningStage.connecting:
        return _buildConnectingUI();

      case ProvisioningStage.success:
        return _buildProvisioningSuccessUI();

      case ProvisioningStage.failure:
        return _buildProvisioningFailureUI();
    }
  }

  // Input form UI
  Widget _buildInputForm() {
    return ListView(
      children: [
        const Text(
          'Connect Clexa to WiFi',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),

        // SmartConfig Info Card
        _buildAnimatedCard(
          delay: 0.1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Before you begin:',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '1. Make sure Clexa is powered on',
                      style: TextStyle(color: Colors.blue),
                    ),
                    const Text(
                      '2. Your phone must be connected to a WiFi network',
                      style: TextStyle(color: Colors.blue),
                    ),
                    const Text(
                      '3. Enter the WiFi credentials below and start configuring',
                      style: TextStyle(color: Colors.blue),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // WiFi Credentials Form
        _buildAnimatedCard(
          delay: 0.2,
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'WiFi Credentials',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _ssidController,
                  focusNode: _ssidFocusNode,
                  decoration: const InputDecoration(
                    labelText: 'WiFi Network Name (SSID)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.wifi),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter your WiFi network name';
                    }
                    return null;
                  },
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passwordController,
                  focusNode: _passwordFocusNode,
                  decoration: const InputDecoration(
                    labelText: 'WiFi Password',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                  obscureText: !_showPassword,
                  validator: (value) {
                    // Password validation for minimum length
                    if (value == null || value.isEmpty || value.length < 8) {
                      return 'Password must be at least 8 characters';
                    }
                    return null;
                  },
                  textInputAction: TextInputAction.done,
                ),
                // Add show password checkbox
                Row(
                  children: [
                    Checkbox(
                      value: _showPassword,
                      onChanged: (bool? value) {
                        setState(() {
                          _showPassword = value ?? false;
                        });
                      },
                    ),
                    // Make text clickable too
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _showPassword = !_showPassword;
                        });
                      },
                      child: const Text('Show password'),
                    ),
                  ],
                ),

                if (_errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: Colors.red),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(color: Colors.red.shade800),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: _buildAnimatedButton(
                    onPressed:
                        (_isSubmitting || !_isConnectedToWifi)
                            ? null // Disable button if submitting or not connected to WiFi
                            : () => _startProvisioning(),
                    icon: const Icon(Icons.send),
                    label: Text(
                      _isConnectedToWifi
                          ? 'Start Provisioning'
                          : 'Connect to WiFi First',
                    ),
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    isFullWidth: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Sending credentials UI
  Widget _buildSendingCredentialsUI() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildAnimatedContent(
              child: const Text(
                'Provisioning Clexa',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 36),

            _buildAnimatedContent(
              delay: 0.1,
              child: const CircularProgressIndicator(),
            ),

            const SizedBox(height: 24),

            _buildAnimatedContent(
              delay: 0.2,
              child: const Text(
                'Sending credentials...',
                style: TextStyle(fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 48),

            _buildAnimatedContent(
              delay: 0.3,
              child: _buildAnimatedButton(
                icon: const Icon(Icons.cancel),
                label: const Text('Cancel'),
                onPressed: () {
                  _provisioner?.stop();
                  _provisioningTimer?.cancel();
                  setState(() {
                    _isSubmitting = false;
                  });
                  _animateToStage(ProvisioningStage.input);
                },
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Credentials sent UI
  Widget _buildCredentialsSentUI() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildAnimatedContent(
              child: const Text(
                'Provisioning Clexa',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 36),

            _buildAnimatedContent(
              delay: 0.1,
              child: const CircularProgressIndicator(),
            ),

            const SizedBox(height: 24),

            _buildAnimatedContent(
              delay: 0.2,
              child: const Text(
                'Credentials sent!',
                style: TextStyle(fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 48),

            _buildAnimatedContent(
              delay: 0.3,
              child: _buildAnimatedButton(
                icon: const Icon(Icons.cancel),
                label: const Text('Cancel'),
                onPressed: () {
                  _provisioner?.stop();
                  _provisioningTimer?.cancel();
                  setState(() {
                    _isSubmitting = false;
                  });
                  _animateToStage(ProvisioningStage.input);
                },
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Credentials failed UI
  Widget _buildCredentialsFailedUI() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildAnimatedContent(
              child: const Text(
                'Provisioning Clexa',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 36),

            _buildAnimatedContent(
              delay: 0.1,
              child: const Icon(Icons.info, color: Colors.red, size: 64),
            ),

            const SizedBox(height: 24),

            _buildAnimatedContent(
              delay: 0.2,
              child: Column(
                children: [
                  const Text(
                    'Credentials not sent!',
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (_provisioningDuration != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _provisioningDuration!,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                        fontStyle: FontStyle.italic,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],

                  // Add troubleshooting section
                  const SizedBox(height: 24),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.amber.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Troubleshooting Tips:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.amber,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Ensure Clexa is powered on and the LED is on and not blinking (configuring mode)',
                          style: TextStyle(color: Colors.amber),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            _buildAnimatedContent(
              delay: 0.3,
              child: _buildAnimatedButton(
                icon: const Icon(Icons.wifi),
                label: const Text('Configure Again'),
                onPressed: () {
                  _animateToStage(ProvisioningStage.input);
                },
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Connecting UI
  Widget _buildConnectingUI() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildAnimatedContent(
              child: const Text(
                'Provisioning Clexa',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 36),

            _buildAnimatedContent(
              delay: 0.1,
              child: const CircularProgressIndicator(),
            ),

            const SizedBox(height: 24),

            _buildAnimatedContent(
              delay: 0.2,
              child: Text(
                'Clexa is trying to connect to WiFi: $_currentSsid',
                style: const TextStyle(fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 48),

            _buildAnimatedContent(
              delay: 0.3,
              child: _buildAnimatedButton(
                icon: const Icon(Icons.cancel),
                label: const Text('Cancel'),
                onPressed: () {
                  _provisioner?.stop();
                  _provisioningTimer?.cancel();
                  setState(() {
                    _isSubmitting = false;
                  });
                  _animateToStage(ProvisioningStage.input);
                },
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Provisioning success UI
  Widget _buildProvisioningSuccessUI() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildAnimatedContent(
              child: const Text(
                'Provisioning Clexa',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 36),

            _buildAnimatedContent(
              delay: 0.1,
              child: const Icon(
                Icons.check_circle_outline,
                color: Colors.green,
                size: 64,
              ),
            ),

            const SizedBox(height: 24),

            _buildAnimatedContent(
              delay: 0.2,
              child: RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.black87,
                    height: 1.5,
                  ),
                  children: [
                    const TextSpan(
                      text: "Clexa connected successfully!\n",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.green,
                        fontSize: 20,
                      ),
                    ),
                    const TextSpan(
                      text:
                          "Wait 5-10 seconds for Clexa to fully restart before discovering.",
                      style: TextStyle(fontSize: 18),
                    ),
                    if (_provisioningDuration != null) ...[
                      const TextSpan(text: "\n\n"),
                      TextSpan(
                        text: _provisioningDuration,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.grey,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 48),

            _buildAnimatedContent(
              delay: 0.3,
              child: _buildAnimatedButton(
                icon: const Icon(Icons.search),
                label: const Text('Discover Clexa'),
                onPressed: () {
                  Navigator.pushReplacementNamed(context, '/');
                },
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                isFullWidth: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Provisioning failure UI
  Widget _buildProvisioningFailureUI() {
    // Different troubleshooting tips based on error
    String troubleshootingTips = '';

    if (_errorMessage?.toLowerCase().contains('timeout') ?? false) {
      troubleshootingTips =
          '• Verify your WiFi network name and password\n'
          '• Ensure your WiFi network is 2.4GHz (not 5GHz)\n'
          '• Ensure Clexa is powered on and the LED is on and not blinking (configuring mode)\n'
          '• Try moving your phone closer to Clexa';
    } else {
      troubleshootingTips =
          '• Verify your WiFi network name and password\n'
          '• Ensure your WiFi network is 2.4GHz (not 5GHz)\n'
          '• Ensure Clexa is powered on and the LED is on and not blinking (configuring mode)\n'
          '• Try moving your phone closer to Clexa';
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildAnimatedContent(
              child: const Text(
                'Provisioning Clexa',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 36),

            _buildAnimatedContent(
              delay: 0.1,
              child: const Icon(
                Icons.error_outline,
                color: Colors.red,
                size: 64,
              ),
            ),

            const SizedBox(height: 24),

            _buildAnimatedContent(
              delay: 0.2,
              child: Column(
                children: [
                  const Text(
                    'Clexa could not connect to WiFi network.',
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (_provisioningDuration != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _provisioningDuration!,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                        fontStyle: FontStyle.italic,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],

                  // Add troubleshooting section
                  const SizedBox(height: 24),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.amber.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Troubleshooting Tips:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.amber,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          troubleshootingTips,
                          style: TextStyle(color: Colors.amber.shade900),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            _buildAnimatedContent(
              delay: 0.3,
              child: _buildAnimatedButton(
                icon: const Icon(Icons.wifi),
                label: const Text('Configure Again'),
                onPressed: () {
                  _animateToStage(ProvisioningStage.input);
                },
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        // Unfocus any text fields when tapping anywhere on the screen
        FocusScope.of(context).unfocus();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Hero(
            tag: 'clexa_title',
            child: Text('Clexa Configuration'),
          ),
          leading:
              _currentStage == ProvisioningStage.input
                  ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed:
                        () => Navigator.pushReplacementNamed(context, '/'),
                  )
                  : null,
        ),
        body: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: _buildProvisioningStageContent(),
            ),
          ),
        ),
      ),
    );
  }
}
