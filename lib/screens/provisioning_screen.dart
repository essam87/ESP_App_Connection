import 'package:flutter/material.dart';
import 'package:esp_smartconfig/esp_smartconfig.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:network_info_plus/network_info_plus.dart';

// Provisioning process states
enum ProvisioningStage { input, provisioning, success, failure }

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

  // Timing information
  DateTime? _provisioningStartTime;
  String? _provisioningDuration;

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
  }

  @override
  void dispose() {
    _animationController.dispose();
    _ssidController.dispose();
    _passwordController.dispose();
    _ssidFocusNode.dispose();
    _passwordFocusNode.dispose();
    _provisioner?.stop();
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

    // Clear screen and show provisioning UI
    _animateToStage(ProvisioningStage.provisioning);

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
          // Calculate duration
          _provisioningDuration = _calculateDuration();

          setState(() {
            _isSubmitting = false;
          });

          // Show success stage
          _animateToStage(ProvisioningStage.success);
        }

        // Stop provisioning process
        _provisioner!.stop();
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

      // Wait for 90 seconds max, then show error if no response
      Future.delayed(const Duration(seconds: 90), () {
        if (_currentStage == ProvisioningStage.provisioning && mounted) {
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
          _errorMessage = 'Error starting provisioning: $e';
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

  // Builder for provisioning stage
  Widget _buildProvisioningStageContent() {
    switch (_currentStage) {
      case ProvisioningStage.input:
        return _buildInputForm();

      case ProvisioningStage.provisioning:
        return _buildProvisioningInProgressUI();

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
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Before you begin:',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '1. Make sure Clexa is powered on',
                      style: TextStyle(color: Colors.blue),
                    ),
                    Text(
                      '2. Your phone must be connected to a WiFi network',
                      style: TextStyle(color: Colors.blue),
                    ),
                    Text(
                      '3. Enter the WiFi credentials below and start provisioning',
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
                    // Password can be empty for open networks
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
                        _isSubmitting ? () {} : () => _startProvisioning(),
                    icon: const Icon(Icons.send),
                    label: const Text('Start Provisioning'),
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

  // Provisioning in progress UI
  Widget _buildProvisioningInProgressUI() {
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
                'Sending credentials to Clexa...',
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
                          "Wait a moment for Clexa to restart before discovering.",
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
          '• Make sure Clexa is in provisioning mode\n'
          '• Ensure Clexa is powered on and the LED is blinking\n'
          '• Try moving your phone closer to the device\n'
          '• Check that your phone is connected to a 2.4GHz WiFi network (not 5GHz)';
    } else {
      troubleshootingTips =
          '• Verify your WiFi network name and password\n'
          '• Ensure your WiFi network is 2.4GHz (not 5GHz)\n'
          '• Restart the Clexa device and try again\n'
          '• Make sure your phone has location permissions enabled';
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
