# Clexa Controller App

A Flutter application to connect to an ESP32 device, configure WiFi credentials, and display data received over WebSocket.

## Features

- Automatic Clexa device discovery using mDNS
- WiFi provisioning via Clexa captive portal
- WebSocket connection to receive real-time data from Clexa
- Beautiful UI with connection status indicators and data display

## Requirements

- Flutter SDK
- ESP32 device with WiFi capabilities and WebSocket server
- The ESP32 should be programmed to:
  - Serve a captive portal at 192.168.4.1 for WiFi configuration
  - Broadcast mDNS service with name `_clexa._tcp`
  - Serve WebSocket connection at `/ws` endpoint
  - Send JSON messages like `{"type": "randomNumber", "value": 123}`

## Dependencies

- provider: State management
- multicast_dns: For mDNS discovery
- webview_flutter: For WebView configuration portal
- web_socket_channel: For WebSocket communication
- network_info_plus: For checking WiFi connection status
- http: For potential HTTP requests

## Getting Started

1. Ensure your Clexa device is programmed with the required firmware
2. Run the Flutter app on your device
3. The app will attempt to discover the Clexa device on your network
4. If not found, follow the provisioning instructions in the app
5. Once connected, the app will display real-time data from the Clexa device

## Workflow

1. **Discovery Phase**: App tries to find Clexa via mDNS
2. **Provisioning Phase**: If Clexa not found, guide user to connect to Clexa-Config WiFi and configure home network
3. **Connection Phase**: Connect to Clexa WebSocket and receive data
4. **Display Phase**: Show real-time data received from Clexa

## ESP32 Side Implementation (TODO)

For the ESP32 side, you'll need to implement:

1. WiFi AP mode with captive portal
2. mDNS advertising
3. WebSocket server
4. Random number generation and JSON formatting

This app is designed to interact with an ESP32 that implements the required functionality for Clexa.
