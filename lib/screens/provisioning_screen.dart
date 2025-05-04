import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart'; // Keep connectivity for wifi detection

// Adjust path based on your project structure
import '../providers/esp32_provider.dart';

class ProvisioningScreen extends StatefulWidget {
  const ProvisioningScreen({super.key});

  @override
  State<ProvisioningScreen> createState() => _ProvisioningScreenState();
}

class _ProvisioningScreenState extends State<ProvisioningScreen>
    with SingleTickerProviderStateMixin {
  final NetworkInfo _networkInfo = NetworkInfo();
  final Connectivity _connectivity = Connectivity();
  String? _currentSsid;
  bool _isLoadingNetworkInfo = true;
  bool _locationPermissionGranted = false;
  final TextEditingController _ssidController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  // Focus nodes for text fields
  final FocusNode _ssidFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();

  // Form state
  bool _showPassword = false;
  final _formKey = GlobalKey<FormState>();
  bool _isSubmitting = false;
  bool _showConfigForm = false;

  // Connection check states
  bool _credentialsSubmitted = false;
  String? _connectionStatus;
  final bool _isRedirecting = false;

  // Track Clexa's connected SSID
  String? _clexaConnectedSsid;

  // Animation controller
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  // Timers
  Timer? _redirectTimer;
  StreamSubscription? _connectivitySubscription;

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

    // Request location permission for WiFi info
    _requestPermissionAndSetupMonitoring();
  }

  @override
  void dispose() {
    _redirectTimer?.cancel();
    _connectivitySubscription?.cancel();
    _animationController.dispose();
    _ssidController.dispose();
    _passwordController.dispose();
    _ssidFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  // Request permission for WiFi info
  Future<void> _requestPermissionAndSetupMonitoring() async {
    if (!mounted) return;
    setState(() => _isLoadingNetworkInfo = true);

    // Request location permission
    var status = await Permission.location.request();
    _locationPermissionGranted = status.isGranted;

    if (kDebugMode) {
      debugPrint("Location permission status: $status");
    }

    if (_locationPermissionGranted) {
      // If granted, check network info and setup monitoring
      await _checkNetworkInfo();
      _setupConnectivityMonitoring();
    } else {
      // If denied, update state
      setState(() {
        _currentSsid = "Permission denied";
        _isLoadingNetworkInfo = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Location permission is required to read WiFi SSID.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // Setup connectivity monitoring
  void _setupConnectivityMonitoring() {
    _connectivitySubscription?.cancel();
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((
      results,
    ) {
      bool hasWifi = results.contains(ConnectivityResult.wifi);

      if (hasWifi) {
        if (kDebugMode) {
          debugPrint("WiFi connectivity changed, updating network info");
        }
        _checkNetworkInfo();
      } else {
        if (mounted) {
          setState(() {
            _currentSsid = "Not connected to WiFi";
            _isLoadingNetworkInfo = false;
          });
        }
      }
    });
  }

  // Check current WiFi network
  Future<void> _checkNetworkInfo() async {
    if (!_locationPermissionGranted) {
      setState(() {
        _currentSsid = "Permission needed";
        _isLoadingNetworkInfo = false;
      });
      return;
    }

    if (!mounted) return;
    setState(() => _isLoadingNetworkInfo = true);

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
    } finally {
      if (mounted) {
        setState(() => _isLoadingNetworkInfo = false);
      }
    }
  }

  // Handle credentials submitted
  void _handleCredentialsSubmitted() {
    if (mounted) {
      setState(() {
        _credentialsSubmitted = true;
        _showConfigForm = false;
        _connectionStatus = null;
        _clexaConnectedSsid =
            _ssidController.text; // Set the SSID that Clexa will connect to
      });
    }
  }

  // Navigate back to discovery screen to find Clexa
  void _goToDiscoveryScreen() {
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/');
  }

  // Check connection - simplified version that works reliably
  Future<void> _checkConnection() async {
    if (!mounted) return;

    setState(() {
      _connectionStatus = null;
    });

    // STEP 1: Check if user is connected to a WiFi network
    final connectivityResult = await _connectivity.checkConnectivity();
    final bool isConnectedToWifi = connectivityResult.contains(
      ConnectivityResult.wifi,
    );

    if (!isConnectedToWifi) {
      // Not connected to WiFi
      if (mounted) {
        setState(() {
          _connectionStatus = 'no_wifi';
        });
      }
      return;
    }

    // Get current WiFi network name
    await _checkNetworkInfo();

    if (_currentSsid == 'Clexa-Config') {
      // Still connected to config network
      if (mounted) {
        setState(() {
          _connectionStatus = 'still_in_config';
        });
      }
      return;
    }

    // STEP 2: Check for ESP32
    final esp32Provider = Provider.of<Esp32Provider>(context, listen: false);

    // Check if already connected
    if (esp32Provider.state.isConnectedToEsp) {
      if (mounted) {
        setState(() {
          _connectionStatus = 'success';
        });

        // Wait 2 seconds to show success
        Future.delayed(const Duration(seconds: 2), () {
          _startRedirectSequence();
        });
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
              _connectionStatus = 'success';
            });

            // Wait 2 seconds to show success
            Future.delayed(const Duration(seconds: 2), () {
              _startRedirectSequence();
            });
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
          _connectionStatus = 'esp_not_found';
        });
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error checking for ESP device: $e');
      }
      if (mounted) {
        setState(() {
          _connectionStatus = 'error';
        });
      }
    }
  }

  // Start redirect sequence
  void _startRedirectSequence() {
    if (!mounted) return;

    // Wait 2 seconds, then redirect
    _redirectTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/data');
      }
    });
  }

  // Submit WiFi credentials
  Future<void> _submitWifiCredentials() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    final String ssid = _ssidController.text.trim();
    final String password = _passwordController.text.trim();

    try {
      // Send credentials via HTTP POST
      final response = await http
          .post(
            Uri.parse('http://192.168.4.1/save'),
            headers: <String, String>{
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: {'ssid': ssid, 'password': password},
          )
          .timeout(const Duration(seconds: 10));

      if (kDebugMode) {
        debugPrint('Response status: ${response.statusCode}');
        debugPrint('Response body: ${response.body}');
      }

      if (response.statusCode == 200 || response.statusCode == 302) {
        _handleCredentialsSubmitted();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Failed to send credentials: ${response.statusCode}',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error sending credentials: $e');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isConnectedToEspConfig = _currentSsid == 'Clexa-Config';

    // Add back the ESP Provider to monitor connection state
    final esp32Provider = Provider.of<Esp32Provider>(context, listen: true);

    // Check if already connected to ESP32 and we're not in config mode, but only if we're in connection checking mode
    if (esp32Provider.state.isConnectedToEsp &&
        !isConnectedToEspConfig &&
        _credentialsSubmitted &&
        !_isRedirecting &&
        _connectionStatus != null) {
      // Only auto-redirect if already in connection check mode
      // We're already connected! Set success state
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          _connectionStatus = 'success';
        });

        // Give a moment to show success state, then redirect
        Future.delayed(const Duration(seconds: 2), () {
          _startRedirectSequence();
        });
      });
    }

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
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pushReplacementNamed(context, '/'),
          ),
        ),
        body: FadeTransition(
          opacity: _fadeAnimation,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: ListView(
              children: [
                const Text(
                  'Setup Clexa WiFi',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),

                // Network Status Card - Always show this now
                _buildAnimatedCard(
                  delay: 0.1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Current Network Status:',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _isLoadingNetworkInfo
                          ? const Center(child: CircularProgressIndicator())
                          : Center(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _getNetworkStatusIcon(isConnectedToEspConfig),
                                  color: _getNetworkStatusColor(
                                    isConnectedToEspConfig,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _currentSsid ?? 'Unknown',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: _getNetworkStatusColor(
                                      isConnectedToEspConfig,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      // Remove all additional text when credentials are submitted
                      if (!_credentialsSubmitted) ...[
                        const SizedBox(height: 8),
                        if (isConnectedToEspConfig)
                          const Text(
                            'Connected to Clexa\'s setup network. You can configure WiFi credentials below.',
                            style: TextStyle(color: Colors.green),
                            textAlign: TextAlign.center,
                          )
                        else if (_currentSsid == "Not connected to WiFi")
                          const Text(
                            'Not connected to any WiFi network.',
                            style: TextStyle(color: Colors.red),
                            textAlign: TextAlign.center,
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Instructions Card - Only show before credentials submitted
                if (!_credentialsSubmitted)
                  _buildAnimatedCard(
                    delay: 0.0,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Instructions:',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 10,
                            horizontal: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.blue.shade200),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.wifi, color: Colors.blue),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Connect your phone to the "Clexa-Config" WiFi network',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),

                // Only show connection check UI when credentials are submitted
                if (_credentialsSubmitted)
                  _buildAnimatedCard(
                    delay: 0.2,
                    child: Column(
                      children: [
                        const Text(
                          'Credentials Saved!',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.green,
                          ),
                        ),
                        const SizedBox(height: 24),
                        // Show different content based on network status
                        if (_currentSsid == _clexaConnectedSsid)
                          // User is on the same network as Clexa - show Discover button
                          Column(
                            children: [
                              const Text(
                                'You are connected to the same network as Clexa!',
                                style: TextStyle(
                                  color: Colors.green,
                                  fontWeight: FontWeight.bold,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'You can now discover and connect to your device.',
                                style: TextStyle(fontSize: 16),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 32),
                              // Discover Clexa button
                              _buildAnimatedButton(
                                onPressed: () => _goToDiscoveryScreen(),
                                icon: const Icon(Icons.search),
                                label: const Text('Discover Clexa'),
                                backgroundColor: Colors.blue,
                                foregroundColor: Colors.white,
                                isFullWidth: true,
                              ),
                            ],
                          )
                        else if (_currentSsid == "Clexa-Config")
                          // User is still on config network - suggest reconnecting
                          Column(
                            children: [
                              const Text(
                                'You need to connect to the WiFi network that Clexa is using.',
                                style: TextStyle(
                                  color: Colors.orange,
                                  fontWeight: FontWeight.bold,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Please connect to "$_clexaConnectedSsid" WiFi network that Clexa is using.',
                                style: const TextStyle(fontSize: 16),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 32),
                              // Add check connection button
                              _buildAnimatedButton(
                                onPressed: () => _checkConnection(),
                                icon: const Icon(Icons.refresh),
                                label: const Text('Check Connection'),
                                backgroundColor: Colors.blue,
                                foregroundColor: Colors.white,
                                isFullWidth: true,
                              ),
                            ],
                          )
                        else if (_currentSsid == "Not connected to WiFi")
                          // User is not connected to WiFi
                          Column(
                            children: [
                              const Text(
                                'You are not connected to any WiFi network',
                                style: TextStyle(
                                  color: Colors.red,
                                  fontWeight: FontWeight.bold,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Please connect to "$_clexaConnectedSsid" WiFi network that Clexa is using.',
                                style: const TextStyle(fontSize: 16),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 32),
                              // Add check connection button
                              _buildAnimatedButton(
                                onPressed: () => _checkConnection(),
                                icon: const Icon(Icons.refresh),
                                label: const Text('Check Connection'),
                                backgroundColor: Colors.blue,
                                foregroundColor: Colors.white,
                                isFullWidth: true,
                              ),
                            ],
                          )
                        else
                          // User is on a different network than Clexa
                          Column(
                            children: [
                              const Text(
                                'You are on a different network than Clexa',
                                style: TextStyle(
                                  color: Colors.blue,
                                  fontWeight: FontWeight.bold,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Please connect to "$_clexaConnectedSsid" WiFi network that Clexa is using.',
                                style: const TextStyle(fontSize: 16),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 32),
                              // Add check connection button
                              _buildAnimatedButton(
                                onPressed: () => _checkConnection(),
                                icon: const Icon(Icons.refresh),
                                label: const Text('Check Connection'),
                                backgroundColor: Colors.blue,
                                foregroundColor: Colors.white,
                                isFullWidth: true,
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),

                // Show custom WiFi Form if connected to Clexa-Config and credentials not submitted
                if (isConnectedToEspConfig && !_credentialsSubmitted)
                  _buildAnimatedCard(
                    delay: 0.2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Configure WiFi Credentials:',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),

                        // Show form button if not showing form yet
                        if (!_showConfigForm)
                          _buildAnimatedButton(
                            onPressed: () {
                              setState(() {
                                _showConfigForm = true;
                              });
                            },
                            icon: const Icon(Icons.wifi),
                            label: const Text('Open WiFi Configuration Form'),
                          ),

                        // Show custom WiFi form when requested
                        if (_showConfigForm)
                          Form(
                            key: _formKey,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
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
                                  enableInteractiveSelection: true,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  keyboardType: TextInputType.text,
                                  textInputAction: TextInputAction.next,
                                  contextMenuBuilder: (
                                    context,
                                    editableTextState,
                                  ) {
                                    // Only show context menu if there's text in the field
                                    final String selectedText =
                                        editableTextState
                                            .textEditingValue
                                            .selection
                                            .textInside(
                                              editableTextState
                                                  .textEditingValue
                                                  .text,
                                            );
                                    if (selectedText.isEmpty &&
                                        editableTextState
                                            .textEditingValue
                                            .text
                                            .isEmpty) {
                                      // When field is empty, show only paste option
                                      return AdaptiveTextSelectionToolbar.buttonItems(
                                        anchors:
                                            editableTextState
                                                .contextMenuAnchors,
                                        buttonItems: <ContextMenuButtonItem>[
                                          // Add just the paste button
                                          ContextMenuButtonItem(
                                            onPressed: () {
                                              Clipboard.getData(
                                                'text/plain',
                                              ).then((data) {
                                                if (data?.text != null) {
                                                  editableTextState
                                                      .performAction(
                                                        TextInputAction.newline,
                                                      );
                                                  editableTextState
                                                      .updateEditingValue(
                                                        TextEditingValue(
                                                          text: data!.text!,
                                                          selection:
                                                              TextSelection.collapsed(
                                                                offset:
                                                                    data
                                                                        .text!
                                                                        .length,
                                                              ),
                                                        ),
                                                      );
                                                  // Request focus explicitly to prevent it from being lost
                                                  if (_ssidController.text ==
                                                      data.text) {
                                                    _ssidFocusNode
                                                        .requestFocus();
                                                  } else if (_passwordController
                                                          .text ==
                                                      data.text) {
                                                    _passwordFocusNode
                                                        .requestFocus();
                                                  }
                                                }
                                              });
                                            },
                                            type: ContextMenuButtonType.paste,
                                          ),
                                        ],
                                      );
                                    } else if (selectedText.isEmpty) {
                                      return Container();
                                    }
                                    return AdaptiveTextSelectionToolbar.editableText(
                                      editableTextState: editableTextState,
                                    );
                                  },
                                  onTap: () async {
                                    FocusScope.of(context).requestFocus();
                                    await Clipboard.getData('text/plain');
                                  },
                                ),
                                const SizedBox(height: 16),
                                // Updated Password TextFormField with paste support
                                TextFormField(
                                  controller: _passwordController,
                                  focusNode: _passwordFocusNode,
                                  decoration: const InputDecoration(
                                    labelText: 'WiFi Password',
                                    border: OutlineInputBorder(),
                                    prefixIcon: Icon(Icons.lock),
                                  ),
                                  obscureText: !_showPassword,
                                  enableInteractiveSelection: true,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  keyboardType: TextInputType.visiblePassword,
                                  textInputAction: TextInputAction.done,
                                  contextMenuBuilder: (
                                    context,
                                    editableTextState,
                                  ) {
                                    // Only show context menu if there's text in the field
                                    final String selectedText =
                                        editableTextState
                                            .textEditingValue
                                            .selection
                                            .textInside(
                                              editableTextState
                                                  .textEditingValue
                                                  .text,
                                            );
                                    if (selectedText.isEmpty &&
                                        editableTextState
                                            .textEditingValue
                                            .text
                                            .isEmpty) {
                                      // When field is empty, show only paste option
                                      return AdaptiveTextSelectionToolbar.buttonItems(
                                        anchors:
                                            editableTextState
                                                .contextMenuAnchors,
                                        buttonItems: <ContextMenuButtonItem>[
                                          // Add just the paste button
                                          ContextMenuButtonItem(
                                            onPressed: () {
                                              Clipboard.getData(
                                                'text/plain',
                                              ).then((data) {
                                                if (data?.text != null) {
                                                  editableTextState
                                                      .performAction(
                                                        TextInputAction.newline,
                                                      );
                                                  editableTextState
                                                      .updateEditingValue(
                                                        TextEditingValue(
                                                          text: data!.text!,
                                                          selection:
                                                              TextSelection.collapsed(
                                                                offset:
                                                                    data
                                                                        .text!
                                                                        .length,
                                                              ),
                                                        ),
                                                      );
                                                  // Request focus explicitly to prevent it from being lost
                                                  if (_ssidController.text ==
                                                      data.text) {
                                                    _ssidFocusNode
                                                        .requestFocus();
                                                  } else if (_passwordController
                                                          .text ==
                                                      data.text) {
                                                    _passwordFocusNode
                                                        .requestFocus();
                                                  }
                                                }
                                              });
                                            },
                                            type: ContextMenuButtonType.paste,
                                          ),
                                        ],
                                      );
                                    } else if (selectedText.isEmpty) {
                                      return Container();
                                    }
                                    return AdaptiveTextSelectionToolbar.editableText(
                                      editableTextState: editableTextState,
                                    );
                                  },
                                  onTap: () async {
                                    FocusScope.of(context).requestFocus();
                                    await Clipboard.getData('text/plain');
                                  },
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
                                    const Spacer(), // Push the checkbox to the left
                                  ],
                                ),
                                const SizedBox(height: 16),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed:
                                        _isSubmitting
                                            ? null
                                            : _submitWifiCredentials,
                                    style: ElevatedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                    ),
                                    child:
                                        _isSubmitting
                                            ? const Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                SizedBox(
                                                  width: 20,
                                                  height: 20,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                ),
                                                SizedBox(width: 12),
                                                Text('Submitting...'),
                                              ],
                                            )
                                            : const Text('Save Credentials'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Helper widgets for animations
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

  // Helper method to get appropriate network status icon
  IconData _getNetworkStatusIcon(bool isConnectedToEspConfig) {
    // Before credentials are submitted, use the original icon scheme
    if (!_credentialsSubmitted) {
      if (isConnectedToEspConfig) {
        return Icons.wifi; // WiFi icon for config network (pre-submission)
      } else if (_currentSsid == "Not connected to WiFi") {
        return Icons.wifi_off; // WiFi off icon for no connection
      } else {
        return Icons.info; // Info icon for other networks (pre-submission)
      }
    }
    // After credentials are submitted, use the new icon scheme
    else {
      if (isConnectedToEspConfig) {
        return Icons.info; // Info icon for config network (post-submission)
      } else if (_currentSsid == "Not connected to WiFi") {
        return Icons.wifi_off; // WiFi off icon for no connection
      } else if (_clexaConnectedSsid != null &&
          _currentSsid == _clexaConnectedSsid) {
        return Icons.wifi; // WiFi icon for connected to same network as Clexa
      } else {
        return Icons.wifi; // WiFi icon for other networks
      }
    }
  }

  // Helper method to get appropriate network status color
  Color _getNetworkStatusColor(bool isConnectedToEspConfig) {
    // Before credentials are submitted, use the original color scheme
    if (!_credentialsSubmitted) {
      if (isConnectedToEspConfig) {
        return Colors.green; // Green for config network (pre-submission)
      } else if (_currentSsid == "Not connected to WiFi") {
        return Colors.red; // Red for no connection
      } else {
        return Colors.orange; // Orange for other networks (pre-submission)
      }
    }
    // After credentials are submitted, use the new color scheme
    else {
      if (isConnectedToEspConfig) {
        return Colors.orange; // Orange for config network (post-submission)
      } else if (_currentSsid == "Not connected to WiFi") {
        return Colors.red; // Red for no connection
      } else if (_clexaConnectedSsid != null &&
          _currentSsid == _clexaConnectedSsid) {
        return Colors.green; // Green for connected to same network as Clexa
      } else {
        return Colors.blue; // Blue for different networks
      }
    }
  }
}
