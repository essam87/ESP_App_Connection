import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:multicast_dns/multicast_dns.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

class Esp32Service {
  final String _mdnsServiceName =
      '_clexa._tcp'; // Service name Flutter searches for
  WebSocketChannel? _channel;
  StreamController<Map<String, dynamic>>? _streamController;
  bool _isConnecting = false; // Prevent multiple connection attempts
  bool _isDisconnecting = false; // Prevent multiple disconnection attempts

  Future<String?> discoverEsp32({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // Note: discovery can take time and might find multiple devices.
    // This implementation returns the first one found.

    // Use platform-safe MDnsClient initialization
    final MDnsClient client = MDnsClient(
      // Android doesn't support reusePort, which is used by default in multicast_dns
      rawDatagramSocketFactory: (
        dynamic host,
        int port, {
        bool? reuseAddress,
        bool? reusePort,
        int? ttl,
      }) {
        // On Android, we don't use reusePort parameter
        if (kDebugMode) {
          debugPrint('Creating MDnsClient with platform-safe socket options');
        }
        return RawDatagramSocket.bind(
          host,
          port,
          reuseAddress: reuseAddress ?? false,
          ttl: ttl ?? 1,
        );
      },
    );

    String? foundIpAddress;

    try {
      if (kDebugMode) {
        debugPrint('Starting mDNS discovery for $_mdnsServiceName...');
      }
      await client.start();

      // Lookup the service pointers
      await for (final PtrResourceRecord ptr in client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(_mdnsServiceName),
            timeout: timeout,
          )) {
        if (kDebugMode) {
          debugPrint('Found mDNS Ptr Record: ${ptr.domainName}');
        }
        // For each pointer, lookup the service instance details (SRV record)
        await for (final SrvResourceRecord srv in client
            .lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(ptr.domainName),
              timeout: timeout,
            )) {
          if (kDebugMode) {
            debugPrint('Found mDNS Srv Record: ${srv.target}:${srv.port}');
          }
          // And then lookup the IP address (A record for IPv4)
          await for (final IPAddressResourceRecord ip in client
              .lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target),
                timeout: timeout,
              )) {
            if (kDebugMode) {
              debugPrint(
                'Found mDNS A Record: ${ip.address.address} for ${srv.target}',
              );
            }
            foundIpAddress = ip.address.address;
            // Return the first valid IP address found
            break;
          }
          break;
        }
        break;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error during mDNS discovery: $e');
      }
    } finally {
      client.stop();
      if (kDebugMode) {
        debugPrint('mDNS discovery stopped.');
      }
    }
    if (kDebugMode) {
      debugPrint('mDNS discovery finished. Found IP: $foundIpAddress');
    }
    return foundIpAddress;
  }

  String constructWebSocketUrl(String ipAddress) {
    // Ensure ESP32 code uses port 80 and endpoint /ws
    return 'ws://$ipAddress/ws';
  }

  Stream<Map<String, dynamic>>? connectToWebSocket(String webSocketUrl) {
    if (_isConnecting || isWebSocketConnected()) {
      if (kDebugMode) {
        debugPrint(
          'WebSocket connection attempt ignored: Already connecting or connected.',
        );
      }
      return _streamController
          ?.stream; // Return existing stream if already connected
    }
    _isConnecting = true;
    _isDisconnecting = false; // Reset disconnect flag on new connection attempt

    if (kDebugMode) {
      debugPrint('Attempting WebSocket connection to: $webSocketUrl');
    }

    try {
      // Ensure previous connection resources are cleaned up
      disconnectWebSocket();

      _channel = WebSocketChannel.connect(Uri.parse(webSocketUrl));
      _streamController = StreamController<Map<String, dynamic>>.broadcast();

      _channel!.ready
          .then((_) {
            if (kDebugMode) {
              debugPrint('WebSocket handshake successful.');
            }
            _isConnecting = false; // Connection established
          })
          .catchError((error) {
            if (kDebugMode) {
              debugPrint('WebSocket handshake failed: $error');
            }
            _streamController?.addError('Handshake Error: $error');
            disconnectWebSocket(); // Clean up on handshake failure
            _isConnecting = false;
          });

      _channel!.stream.listen(
        (dynamic message) {
          if (kDebugMode) {
            debugPrint('WebSocket Received: $message');
          }
          try {
            // Ensure message is String before decoding
            if (message is String) {
              final data = jsonDecode(message) as Map<String, dynamic>;
              _streamController?.add(data);
            } else {
              if (kDebugMode) {
                debugPrint(
                  'WebSocket Received non-string message: ${message.runtimeType}',
                );
              }
              // Handle binary data if needed, otherwise ignore or report error
              // _streamController?.addError('Received non-string message');
            }
          } catch (e) {
            if (kDebugMode) {
              debugPrint('WebSocket JSON Parsing Error: $e');
            }
            _streamController?.addError('Parsing Error: $e');
          }
        },
        onError: (error) {
          if (kDebugMode) {
            debugPrint('WebSocket Stream Error: $error');
          }
          _streamController?.addError('Stream Error: $error');
          disconnectWebSocket(); // Clean up on stream error
          _isConnecting = false;
        },
        onDone: () {
          if (kDebugMode) {
            debugPrint('WebSocket Stream Done (Connection Closed).');
          }
          _streamController?.close(); // Signal stream end
          // Only call disconnect if not already initiated by disconnectWebSocket()
          if (!_isDisconnecting) {
            disconnectWebSocket();
          }
          _isConnecting = false;
        },
        cancelOnError:
            true, // Important to prevent stream staying open after error
      );

      return _streamController!.stream;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error connecting to WebSocket: $e');
      }
      _isConnecting = false;
      disconnectWebSocket(); // Ensure cleanup on immediate error
      return null;
    }
  }

  // Improved asynchronous disconnection to prevent UI freezing
  void disconnectWebSocket() {
    if (_isDisconnecting || _channel == null) {
      if (kDebugMode) {
        debugPrint(
          'WebSocket disconnect ignored: Already disconnecting or not connected',
        );
      }
      return;
    }

    _isDisconnecting = true;
    if (kDebugMode) {
      debugPrint('Starting WebSocket disconnection process...');
    }

    // Use microtask to move WebSocket operations off the UI thread
    Future.microtask(() {
      // Capture current channel and controller to avoid null issues if they change
      final currentChannel = _channel;
      final currentController = _streamController;

      // Clean up references immediately to prevent multiple close attempts
      _channel = null;
      _streamController = null;
      _isConnecting = false;

      // Safely close the WebSocket channel
      if (currentChannel != null) {
        try {
          // Use normalClosure (1000) instead of goingAway
          currentChannel.sink.close(status.normalClosure).catchError((e) {
            if (kDebugMode) {
              debugPrint('Error during WebSocket close: $e');
            }
          });
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Exception when closing WebSocket: $e');
          }
        }
      }

      // Safely close the stream controller
      if (currentController != null && !currentController.isClosed) {
        try {
          currentController.close().catchError((e) {
            if (kDebugMode) {
              debugPrint('Error closing stream controller: $e');
            }
          });
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Exception closing stream controller: $e');
          }
        }
      }

      if (kDebugMode) {
        debugPrint('WebSocket disconnection process completed');
      }

      // Reset the disconnecting flag after a delay
      Future.delayed(const Duration(milliseconds: 200), () {
        _isDisconnecting = false;
      });
    });
  }

  // --- ADDED METHOD ---
  void sendCommand(Map<String, dynamic> command) {
    if (_channel != null &&
        _streamController != null &&
        !_streamController!.isClosed) {
      try {
        final jsonString = jsonEncode(command);
        _channel!.sink.add(jsonString);
        if (kDebugMode) {
          debugPrint('WebSocket Sent command: $jsonString');
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Error sending command: $e');
        }
        _streamController?.addError('Send Error: $e');
      }
    } else {
      if (kDebugMode) {
        debugPrint('Cannot send command: WebSocket is not connected.');
      }
      // Optionally signal UI that command couldn't be sent
      // _streamController?.addError('Send Error: Not Connected');
    }
  }
  // --- END OF ADDED METHOD ---

  bool isWebSocketConnected() {
    // Check if channel exists and sink is not closed (simplistic check)
    // Note: Doesn't guarantee active PING/PONG or server responsiveness
    return _channel != null &&
        _streamController != null &&
        !_streamController!.isClosed;
  }
}
