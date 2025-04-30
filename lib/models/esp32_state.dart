import 'package:flutter/foundation.dart' show immutable;

@immutable
class Esp32State {
  final bool isProvisioningNeeded;
  final bool isConnectedToEsp;
  final String? espIpAddress;
  final String? espWebSocketUrl;
  final int? lastRandomNumber;
  final String? errorMessage;
  final String? connectedSsid;
  final bool isRunning;
  final int? waterLevel;
  final int? batteryStatus;
  final DateTime
  lastActivityTimestamp; // Timestamp of last data received from ESP32

  // Use factory constructor for initial state with DateTime.now()
  factory Esp32State.initial() {
    return Esp32State(lastActivityTimestamp: DateTime.now());
  }

  const Esp32State({
    this.isProvisioningNeeded = false,
    this.isConnectedToEsp = false,
    this.espIpAddress,
    this.espWebSocketUrl,
    this.lastRandomNumber,
    this.errorMessage,
    this.connectedSsid,
    this.isRunning = false,
    this.waterLevel,
    this.batteryStatus,
    required this.lastActivityTimestamp,
  });

  Esp32State copyWith({
    bool? isProvisioningNeeded,
    bool? isConnectedToEsp,
    ValueGetter<String?>? espIpAddress,
    ValueGetter<String?>? espWebSocketUrl,
    ValueGetter<int?>? lastRandomNumber,
    ValueGetter<String?>? errorMessage,
    ValueGetter<String?>? connectedSsid,
    bool? isRunning,
    ValueGetter<int?>? waterLevel,
    ValueGetter<int?>? batteryStatus,
    DateTime? lastActivityTimestamp,
  }) {
    return Esp32State(
      isProvisioningNeeded: isProvisioningNeeded ?? this.isProvisioningNeeded,
      isConnectedToEsp: isConnectedToEsp ?? this.isConnectedToEsp,
      espIpAddress: espIpAddress != null ? espIpAddress() : this.espIpAddress,
      espWebSocketUrl:
          espWebSocketUrl != null ? espWebSocketUrl() : this.espWebSocketUrl,
      lastRandomNumber:
          lastRandomNumber != null ? lastRandomNumber() : this.lastRandomNumber,
      errorMessage: errorMessage != null ? errorMessage() : this.errorMessage,
      connectedSsid:
          connectedSsid != null ? connectedSsid() : this.connectedSsid,
      isRunning: isRunning ?? this.isRunning,
      waterLevel: waterLevel != null ? waterLevel() : this.waterLevel,
      batteryStatus:
          batteryStatus != null ? batteryStatus() : this.batteryStatus,
      lastActivityTimestamp:
          lastActivityTimestamp ?? this.lastActivityTimestamp,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Esp32State &&
          runtimeType == other.runtimeType &&
          isProvisioningNeeded == other.isProvisioningNeeded &&
          isConnectedToEsp == other.isConnectedToEsp &&
          espIpAddress == other.espIpAddress &&
          espWebSocketUrl == other.espWebSocketUrl &&
          lastRandomNumber == other.lastRandomNumber &&
          connectedSsid == other.connectedSsid &&
          errorMessage == other.errorMessage &&
          isRunning == other.isRunning &&
          waterLevel == other.waterLevel &&
          batteryStatus == other.batteryStatus &&
          lastActivityTimestamp == other.lastActivityTimestamp;

  @override
  int get hashCode =>
      isProvisioningNeeded.hashCode ^
      isConnectedToEsp.hashCode ^
      espIpAddress.hashCode ^
      espWebSocketUrl.hashCode ^
      lastRandomNumber.hashCode ^
      connectedSsid.hashCode ^
      errorMessage.hashCode ^
      isRunning.hashCode ^
      waterLevel.hashCode ^
      batteryStatus.hashCode ^
      lastActivityTimestamp.hashCode;

  @override
  String toString() {
    return 'Esp32State{isProvisioningNeeded: $isProvisioningNeeded, isConnectedToEsp: $isConnectedToEsp, '
        'espIpAddress: $espIpAddress, espWebSocketUrl: $espWebSocketUrl, '
        'lastRandomNumber: $lastRandomNumber, errorMessage: $errorMessage, '
        'connectedSsid: $connectedSsid, isRunning: $isRunning, '
        'waterLevel: $waterLevel, batteryStatus: $batteryStatus, '
        'lastActivityTimestamp: $lastActivityTimestamp}';
  }

  // Helper method to check if the ESP32 is considered offline
  // (no activity for more than the specified timeout)
  bool isConsideredOffline(Duration timeout) {
    final now = DateTime.now();
    return now.difference(lastActivityTimestamp) > timeout;
  }
}

typedef ValueGetter<T> = T Function();
