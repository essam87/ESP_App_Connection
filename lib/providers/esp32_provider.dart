import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' as flutter;
import 'package:flutter/foundation.dart' show compute;

// Adjust path based on your project structure
import '../models/esp32_state.dart';
import '../services/esp32_service.dart';

// Isolate worker function for discovery
Future<String?> _discoverEsp32Worker(Map<String, dynamic> params) async {
  final service = Esp32Service();
  final timeout = params['timeout'] as Duration?;
  return await service.discoverEsp32(
    timeout: timeout ?? const Duration(seconds: 5),
  );
}

class Esp32Provider with flutter.ChangeNotifier {
  final Esp32Service _esp32Service = Esp32Service();
  // Use factory constructor for initial state
  Esp32State _state = Esp32State.initial();
  StreamSubscription? _webSocketSubscription;
  bool _isDiscovering = false; // Prevent overlapping discovery calls

  Esp32State get state => _state;

  // Run mDNS discovery for Clexa
  Future<void> discoverEsp32() async {
    if (_isDiscovering) return;
    _isDiscovering = true;
    try {
      Future.microtask(
        () => _updateState(
          isProvisioningNeeded: false,
          isConnectedToEsp: false,
          errorMessage: null,
          lastRandomNumber: () => null,
        ),
      );

      // Use compute to move discovery to a separate isolate
      final ipAddress = await compute(_discoverEsp32Worker, {
        'timeout': const Duration(seconds: 5),
      });

      if (ipAddress != null) {
        final webSocketUrl = _esp32Service.constructWebSocketUrl(ipAddress);
        _updateState(
          isProvisioningNeeded: false,
          espIpAddress: () => ipAddress,
          espWebSocketUrl: () => webSocketUrl,
        );
        await connectToWebSocket();
      } else {
        _updateState(
          isProvisioningNeeded: true,
          isConnectedToEsp: false,
          espIpAddress: () => null,
          espWebSocketUrl: () => null,
          errorMessage:
              () =>
                  'Clexa not found. Please check connection or configure WiFi.',
        );
      }
    } catch (e) {
      _updateState(
        isConnectedToEsp: false,
        errorMessage: () => 'Discovery error: $e',
      );
    } finally {
      _isDiscovering = false;
    }
  }

  // Connect to Clexa WebSocket
  Future<void> connectToWebSocket() async {
    if (_state.espWebSocketUrl == null) {
      _updateState(errorMessage: () => 'Cannot connect: Clexa IP/URL not set.');
      return;
    }
    await _webSocketSubscription?.cancel();
    _webSocketSubscription = null;

    Future.microtask(
      () => _updateState(
        isConnectedToEsp: false,
        errorMessage: () => 'Connecting...',
      ),
    );

    try {
      // Move the actual connection to a separate microtask
      // to prevent blocking the main thread
      final webSocketUrl = _state.espWebSocketUrl!;
      Future.microtask(() async {
        try {
          final dataStream = _esp32Service.connectToWebSocket(webSocketUrl);

          if (dataStream != null) {
            _webSocketSubscription = dataStream.listen(
              (data) {
                // Handle incoming data
                if (!_state.isConnectedToEsp) {
                  _updateState(isConnectedToEsp: true, errorMessage: null);
                }

                // Update activity timestamp for any received data
                _updateActivityTimestamp();

                if (data.containsKey('type') && data['type'] == 'status') {
                  if (flutter.kDebugMode) {
                    flutter.debugPrint(
                      'Received status from Clexa: ${data.toString()}',
                    );
                  }

                  // Check for SSID in the status message
                  if (data.containsKey('ssid')) {
                    String ssid = data['ssid'];
                    if (flutter.kDebugMode) {
                      flutter.debugPrint(
                        'Received WiFi SSID from status: $ssid',
                      );
                    }
                    _updateState(connectedSsid: () => ssid);
                  }

                  // Check for running state
                  if (data.containsKey('running')) {
                    bool isRunning = data['running'];
                    _updateState(isRunning: isRunning);
                  }

                  // Check for sensor values
                  if (data.containsKey('waterLevel')) {
                    int waterLevel = data['waterLevel'];
                    if (flutter.kDebugMode) {
                      flutter.debugPrint('Received water level: $waterLevel');
                    }
                    _updateState(waterLevel: () => waterLevel);
                  }

                  if (data.containsKey('batteryStatus')) {
                    int batteryStatus = data['batteryStatus'];
                    if (flutter.kDebugMode) {
                      flutter.debugPrint(
                        'Received battery status: $batteryStatus',
                      );
                    }
                    _updateState(batteryStatus: () => batteryStatus);
                  }

                  // Check for location information
                  if (data.containsKey('location')) {
                    String location = data['location'];
                    if (flutter.kDebugMode) {
                      flutter.debugPrint('Received location: $location');
                    }
                    _updateState(location: () => location);
                  }
                } else {
                  // Handle additional data from Clexa
                  _handleEsp32Data(data);
                }
              },
              onError: (error) {
                // --- Simplified onError ---
                if (flutter.kDebugMode) {
                  flutter.debugPrint(
                    'Provider: WebSocket onError triggered: $error',
                  );
                  flutter.debugPrint(
                    'Provider: State before onError update: ${_state.toString()}',
                  );
                }
                _updateState(
                  isConnectedToEsp: false,
                  errorMessage: () => 'WebSocket error: $error',
                );
                disconnectWebSocket(); // Ensure cleanup
                // --- End Simplified onError ---
              },
              onDone: () {
                // --- Simplified onDone ---
                if (flutter.kDebugMode) {
                  flutter.debugPrint('Provider: WebSocket onDone triggered.');
                  flutter.debugPrint(
                    'Provider: State before onDone update: ${_state.toString()}',
                  );
                }
                _updateState(
                  isConnectedToEsp: false,
                  errorMessage:
                      () =>
                          (_state.errorMessage?.contains('error') ?? false)
                              ? _state
                                  .errorMessage // Keep existing error if present
                              : 'WebSocket disconnected', // Default disconnect message
                );
                disconnectWebSocket(); // Ensure cleanup
                // --- End Simplified onDone ---
              },
              cancelOnError: true,
            );
          } else {
            _updateState(
              isConnectedToEsp: false,
              errorMessage: () => 'Failed to initiate WebSocket connection',
            );
          }
        } catch (e) {
          _updateState(
            isConnectedToEsp: false,
            errorMessage: () => 'WebSocket connection error: $e',
          );
          disconnectWebSocket();
        }
      });
    } catch (e) {
      _updateState(
        isConnectedToEsp: false,
        errorMessage: () => 'WebSocket setup error: $e',
      );
      disconnectWebSocket();
    }
  }

  // Method to update activity timestamp whenever any data is received
  void _updateActivityTimestamp() {
    _updateState(lastActivityTimestamp: DateTime.now());
  }

  // Handle additional data received from Clexa
  void _handleEsp32Data(dynamic data) {
    if (flutter.kDebugMode) {
      flutter.debugPrint('Handling extra data from Clexa: $data');
    }

    if (data == null) return;

    // Update activity timestamp whenever we receive any data
    _updateActivityTimestamp();

    // Skip types we already handle directly in the WebSocket listener
    if (data is Map && data.containsKey('type')) {
      String type = data['type'].toString();
      if (type == 'status' || type == 'statusUpdate') {
        if (flutter.kDebugMode) {
          flutter.debugPrint('Skipping already processed message type: $type');
        }
        return;
      }
    }

    // Attempt to extract state from data or gracefully handle errors
    try {
      // Convert data to a usable format
      final Map<String, dynamic> stateMap;
      if (data is String) {
        stateMap = jsonDecode(data);
      } else if (data is Map) {
        stateMap = Map<String, dynamic>.from(data);
      } else {
        if (flutter.kDebugMode) {
          flutter.debugPrint(
            'Invalid data format received: ${data.runtimeType}',
          );
        }
        return;
      }

      // Log the received data for debugging
      if (flutter.kDebugMode) {
        flutter.debugPrint('Processing extra data: $stateMap');
      }

      // Check if the data contains SSID information
      if (stateMap.containsKey('ssid')) {
        String ssid = stateMap['ssid'];
        if (flutter.kDebugMode) {
          flutter.debugPrint('Received WiFi SSID in extra data: $ssid');
        }
        // Update state with the SSID
        _updateState(connectedSsid: () => ssid);
      }

      // Check if the data contains running state
      if (stateMap.containsKey('running')) {
        bool isRunning = stateMap['running'];
        if (flutter.kDebugMode) {
          flutter.debugPrint(
            'Received running state in extra data: $isRunning',
          );
        }
        // Update state with running status
        _updateState(isRunning: isRunning);
      }

      // Check for water level value
      if (stateMap.containsKey('waterLevel')) {
        int waterLevel = stateMap['waterLevel'];
        if (flutter.kDebugMode) {
          flutter.debugPrint('Received water level in extra data: $waterLevel');
        }
        _updateState(waterLevel: () => waterLevel);
      }

      // Check for battery status
      if (stateMap.containsKey('batteryStatus')) {
        int batteryStatus = stateMap['batteryStatus'];
        if (flutter.kDebugMode) {
          flutter.debugPrint(
            'Received battery status in extra data: $batteryStatus',
          );
        }
        _updateState(batteryStatus: () => batteryStatus);
      }

      // If this data contains any important field your app should handle,
      // process it here (example check for a specific field):
      if (stateMap.containsKey('command_result')) {
        if (flutter.kDebugMode) {
          flutter.debugPrint(
            'Command result in extra data: ${stateMap["command_result"]}',
          );
        }
      }
    } catch (e) {
      if (flutter.kDebugMode) {
        flutter.debugPrint('Error parsing Clexa data: $e');
      }
    }
  }

  // Improved asynchronous WebSocket disconnection
  void disconnectWebSocket() {
    if (flutter.kDebugMode) {
      flutter.debugPrint('Provider: disconnectWebSocket called.');
    }

    // Cancel the subscription asynchronously to prevent UI blocking
    Future.microtask(() {
      if (_webSocketSubscription != null) {
        _webSocketSubscription!.cancel().catchError((e) {
          if (flutter.kDebugMode) {
            flutter.debugPrint('Error canceling WebSocket subscription: $e');
          }
        });
        _webSocketSubscription = null;
      }

      // Disconnect the WebSocket service
      _esp32Service.disconnectWebSocket();

      // Update the state
      if (_state.isConnectedToEsp || _state.errorMessage == 'Connecting...') {
        _updateState(isConnectedToEsp: false, errorMessage: () => null);
      }
    });
  }

  // Manually set Clexa IP address
  void setEspIpAddress(String ipAddress) {
    final webSocketUrl = _esp32Service.constructWebSocketUrl(ipAddress);
    _updateState(
      espIpAddress: () => ipAddress,
      espWebSocketUrl: () => webSocketUrl,
      isProvisioningNeeded: false,
      isConnectedToEsp: false,
      errorMessage: null,
    );
  }

  // Improved asynchronous clear credentials command
  void sendClearCredentialsCommand() {
    // First, immediately update the UI to show feedback
    _updateState(errorMessage: () => 'Sending clear credentials command...');

    // Use microtask to move operations off the UI thread
    Future.microtask(() async {
      try {
        if (!_state.isConnectedToEsp) {
          if (flutter.kDebugMode) {
            flutter.debugPrint("Cannot clear credentials: Not connected.");
          }
          _updateState(
            errorMessage: () => 'Connect to Clexa first to clear credentials',
          );
          return;
        }

        if (flutter.kDebugMode) {
          flutter.debugPrint("Provider: Sending clearCredentials command.");
        }

        // 1. Send the command to Clexa
        _esp32Service.sendCommand({"action": "clearCredentials"});

        // Give the ESP a moment to process the command before disconnecting
        await Future.delayed(const Duration(milliseconds: 300));

        if (flutter.kDebugMode) {
          flutter.debugPrint(
            "Provider: Command sent successfully, now disconnecting.",
          );
        }

        // 2. Update state before disconnecting WebSocket
        _updateState(
          isConnectedToEsp: false,
          espIpAddress: () => null,
          espWebSocketUrl: () => null,
          errorMessage: () => 'Sent clear command to Clexa...',
        );

        // 3. Cleanup WebSocket after a slight delay
        disconnectWebSocket();
      } catch (e) {
        if (flutter.kDebugMode) {
          flutter.debugPrint(
            "Provider: Error in sendClearCredentialsCommand: $e",
          );
        }
        _updateState(errorMessage: () => 'Error: $e');
      }
    });
  }

  // Send start command to ESP32
  void sendStartCommand() {
    try {
      if (!_state.isConnectedToEsp) {
        if (flutter.kDebugMode) {
          flutter.debugPrint("Cannot start: Not connected to Clexa.");
        }
        _updateState(errorMessage: () => 'Connect to Clexa first to start');
        return;
      }

      if (flutter.kDebugMode) {
        flutter.debugPrint("Provider: Sending start command.");
      }

      // Send the command to Clexa
      _esp32Service.sendCommand({"action": "start"});

      if (flutter.kDebugMode) {
        flutter.debugPrint("Provider: Start command sent successfully.");
      }

      // Update local state (actual confirmation will come from ESP)
      _updateState(isRunning: true, errorMessage: () => null);
    } catch (e) {
      if (flutter.kDebugMode) {
        flutter.debugPrint("Provider: Error in sendStartCommand: $e");
      }
      _updateState(errorMessage: () => 'Error: $e');
    }
  }

  // Send stop command to ESP32
  void sendStopCommand() {
    try {
      if (!_state.isConnectedToEsp) {
        if (flutter.kDebugMode) {
          flutter.debugPrint("Cannot stop: Not connected to Clexa.");
        }
        _updateState(errorMessage: () => 'Connect to Clexa first to stop');
        return;
      }

      if (flutter.kDebugMode) {
        flutter.debugPrint("Provider: Sending stop command.");
      }

      // Send the command to Clexa
      _esp32Service.sendCommand({"action": "stop"});

      if (flutter.kDebugMode) {
        flutter.debugPrint("Provider: Stop command sent successfully.");
      }

      // Update local state (actual confirmation will come from ESP)
      _updateState(isRunning: false, errorMessage: () => null);
    } catch (e) {
      if (flutter.kDebugMode) {
        flutter.debugPrint("Provider: Error in sendStopCommand: $e");
      }
      _updateState(errorMessage: () => 'Error: $e');
    }
  }

  // --- _updateState (Remove isReconfiguring parameter) ---
  void _updateState({
    bool? isProvisioningNeeded,
    bool? isConnectedToEsp,
    flutter.ValueGetter<String?>? espIpAddress,
    flutter.ValueGetter<String?>? espWebSocketUrl,
    flutter.ValueGetter<String?>? connectedSsid,
    flutter.ValueGetter<int?>? lastRandomNumber,
    flutter.ValueGetter<String?>? errorMessage,
    bool? isRunning,
    flutter.ValueGetter<int?>? waterLevel,
    flutter.ValueGetter<int?>? batteryStatus,
    DateTime? lastActivityTimestamp,
    flutter.ValueGetter<String?>? location,
  }) {
    final String? newErrorMessage =
        errorMessage != null ? errorMessage() : _state.errorMessage;

    if (flutter.kDebugMode) {
      flutter.debugPrint(
        'Provider: Updating state: isConnectedToEsp=$isConnectedToEsp, '
        'isProvisioningNeeded=$isProvisioningNeeded, '
        'espIpAddress=${espIpAddress != null ? espIpAddress() : 'unchanged'}, '
        'espWebSocketUrl=${espWebSocketUrl != null ? espWebSocketUrl() : 'unchanged'}, '
        'lastRandomNumber=${lastRandomNumber != null ? lastRandomNumber() : 'unchanged'}, '
        'errorMessage=$newErrorMessage '
        'connectedSsid=${connectedSsid != null ? connectedSsid() : 'unchanged'} '
        'isRunning=$isRunning '
        'waterLevel=${waterLevel != null ? waterLevel() : 'unchanged'} '
        'batteryStatus=${batteryStatus != null ? batteryStatus() : 'unchanged'} '
        'lastActivityTimestamp=${lastActivityTimestamp?.toString() ?? 'unchanged'} '
        'location=${location != null ? location() : 'unchanged'}',
      );
    }

    _state = _state.copyWith(
      isProvisioningNeeded: isProvisioningNeeded,
      isConnectedToEsp: isConnectedToEsp,
      espIpAddress: espIpAddress,
      espWebSocketUrl: espWebSocketUrl,
      lastRandomNumber: lastRandomNumber,
      connectedSsid: connectedSsid,
      errorMessage: () => newErrorMessage,
      isRunning: isRunning,
      waterLevel: waterLevel,
      batteryStatus: batteryStatus,
      lastActivityTimestamp: lastActivityTimestamp,
      location: location,
    );

    notifyListeners();
  }
  // --- END OF MODIFIED HELPER ---

  // --- dispose (No changes) ---
  @override
  void dispose() {
    if (flutter.kDebugMode) {
      flutter.debugPrint('Esp32Provider disposed.');
    }
    disconnectWebSocket();
    super.dispose();
  }
}
