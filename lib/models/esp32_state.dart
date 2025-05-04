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
  final String location; // Location of the robot
  final DateTime
  lastActivityTimestamp; // Timestamp of last data received from ESP32
  final DateTime
  lastStatusTimestamp; // Timestamp of last status update received

  // Use factory constructor for initial state with DateTime.now()
  factory Esp32State.initial() {
    final now = DateTime.now();
    return Esp32State(
      lastActivityTimestamp: now,
      lastStatusTimestamp: now,
      location: "Unknown",
    );
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
    required this.location,
    required this.lastActivityTimestamp,
    required this.lastStatusTimestamp,
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
    String? location,
    DateTime? lastActivityTimestamp,
    DateTime? lastStatusTimestamp,
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
      location: location ?? this.location,
      lastActivityTimestamp:
          lastActivityTimestamp ?? this.lastActivityTimestamp,
      lastStatusTimestamp: lastStatusTimestamp ?? this.lastStatusTimestamp,
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
          location == other.location &&
          lastActivityTimestamp == other.lastActivityTimestamp &&
          lastStatusTimestamp == other.lastStatusTimestamp;

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
      location.hashCode ^
      lastActivityTimestamp.hashCode ^
      lastStatusTimestamp.hashCode;

  @override
  String toString() {
    return 'Esp32State{isProvisioningNeeded: $isProvisioningNeeded, isConnectedToEsp: $isConnectedToEsp, '
        'espIpAddress: $espIpAddress, espWebSocketUrl: $espWebSocketUrl, '
        'lastRandomNumber: $lastRandomNumber, errorMessage: $errorMessage, '
        'connectedSsid: $connectedSsid, isRunning: $isRunning, '
        'waterLevel: $waterLevel, batteryStatus: $batteryStatus, '
        'location: $location, '
        'lastActivityTimestamp: $lastActivityTimestamp, '
        'lastStatusTimestamp: $lastStatusTimestamp}';
  }

  // Helper method to check if the ESP32 is considered offline
  // (no activity for more than the specified timeout)
  bool isConsideredOffline(Duration timeout) {
    final now = DateTime.now();
    return now.difference(lastActivityTimestamp) > timeout;
  }

  // New helper method to check if status updates have stopped
  bool hasStatusUpdatesStopped(Duration timeout) {
    final now = DateTime.now();
    return now.difference(lastStatusTimestamp) > timeout;
  }
}

typedef ValueGetter<T> = T Function();
