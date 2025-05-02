#include "WiFi.h"
#include <esp_wifi.h> // Required for esp_wifi_get_config
#include <MFRC522.h>
#include <SPI.h>
#include <driver/adc.h>
#include <ArduinoJson.h>
#include <WiFiUDP.h>

// RFID pins
#define RST_PIN         26
#define SS_PIN          5

// Motor Driver 1 pins (Motors 1 & 2)
#define MOTOR1_EN       4
#define MOTOR1_IN1      16
#define MOTOR1_IN2      17
#define MOTOR2_EN       22
#define MOTOR2_IN1      33
#define MOTOR2_IN2      32

// Motor Driver 2 pins (Motor 3)
#define MOTOR3_EN       2
#define MOTOR3_IN1      27
#define MOTOR3_IN2      13

// Sensor pins
#define WATER_LEVEL_PIN 35
#define SENSOR_34_PIN   34
#define SPRAYER_PIN     25
#define UV_LED_PIN      14

// SmartConfig timeouts
#define SC_TIMEOUT_MS 90000 // SmartConfig credential timeout: 90 seconds
#define WIFI_TIMEOUT_MS 30000 // Wi-Fi connection timeout: 30 seconds

// RFID tag ID that marks the end of path
byte endPathTagID[4] = {0x33, 0x81, 0xFD, 0x2C}; // Replace with your actual tag ID

// System states
bool robotOn = false;
int waterLevel = 0;
int sensor34Value = 0;
bool isConnectingViaSmartConfig = false;

// Initialize RFID instance
MFRC522 rfid(SS_PIN, RST_PIN);

// UDP Communication
WiFiUDP udp;
unsigned int localUdpPort = 8888;  // Port to listen on
IPAddress clientIP;                // Client IP address to send to
unsigned int clientPort = 8889;    // Client port to send to

void setup() {
  Serial.begin(115200);
  Serial.println("\nStarting Sanitization Robot with SmartConfig");

  // Initialize RFID
  SPI.begin();
  rfid.PCD_Init();
  Serial.println("RFID reader initialized");

  // Initialize motor control pins
  pinMode(MOTOR1_EN, OUTPUT);
  pinMode(MOTOR1_IN1, OUTPUT);
  pinMode(MOTOR1_IN2, OUTPUT);
  pinMode(MOTOR2_EN, OUTPUT);
  pinMode(MOTOR2_IN1, OUTPUT);
  pinMode(MOTOR2_IN2, OUTPUT);
  pinMode(MOTOR3_EN, OUTPUT);
  pinMode(MOTOR3_IN1, OUTPUT);
  pinMode(MOTOR3_IN2, OUTPUT);

  // Initialize special GPIO2 to LOW before using it
  digitalWrite(MOTOR3_EN, LOW);

  // Initialize sanitization pins with inverted logic (HIGH = OFF)
  pinMode(SPRAYER_PIN, OUTPUT);
  pinMode(UV_LED_PIN, OUTPUT);
  digitalWrite(SPRAYER_PIN, HIGH); // OFF
  digitalWrite(UV_LED_PIN, HIGH);  // OFF

  // Sensor pins
  pinMode(WATER_LEVEL_PIN, INPUT);
  pinMode(SENSOR_34_PIN, INPUT);

  // Stop all motors
  stopAllMotors();

  // 1. Initialize WiFi & Set STA Mode
  WiFi.mode(WIFI_STA);
  WiFi.disconnect(true); // Disconnect from any previous AP
  delay(100);
  Serial.println("WiFi mode set to STA.");

  // 2. Start SmartConfig
  WiFi.beginSmartConfig();
  isConnectingViaSmartConfig = true;
  Serial.println("SmartConfig started. Waiting for configuration...");

  unsigned long startTime = millis();

  // 3. Wait for SmartConfig credentials
  while (!WiFi.smartConfigDone()) {
    delay(500);
    Serial.print(".");
    if (millis() - startTime > SC_TIMEOUT_MS) {
      Serial.println("\nSmartConfig timed out waiting for credentials.");
      WiFi.stopSmartConfig(); // Explicitly stop on timeout
      isConnectingViaSmartConfig = false;
      Serial.println("Please restart the ESP32 to try again.");
      // Halt or implement other recovery logic
      while(true) { delay(1000); }
    }
  }
  Serial.println("\nSmartConfig credentials received.");

  Serial.println("Attempting to connect to the provided AP...");
  startTime = millis(); // Reset timer for Wi-Fi connection wait

  // 5. Wait for WiFi Connection
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
    if (millis() - startTime > WIFI_TIMEOUT_MS) {
      Serial.println("\nWiFi connection timed out.");
      isConnectingViaSmartConfig = false;
      // Maybe credentials were wrong? Stop WiFi, maybe clear config?
      WiFi.disconnect(true);
      Serial.println("Connection failed. Please restart ESP32 and try SmartConfig again.");
       // Halt or implement other recovery logic
      while(true) { delay(1000); }
    }
     // It's possible smartConfigDone() becomes false again if the process fails internally
     if (!WiFi.smartConfigDone() && isConnectingViaSmartConfig) {
         Serial.println("\nSmartConfig process failed during connection attempt.");
         isConnectingViaSmartConfig = false;
         Serial.println("Please restart ESP32 and try SmartConfig again.");
         // Halt or implement other recovery logic
         while(true) { delay(1000); }
     }
  }

  // 6. Log Connection Success
  Serial.println("\nWiFi Connected to AP!"); // Matches ESP-IDF log
  isConnectingViaSmartConfig = false;

  // Log SSID and IP Address
  Serial.printf("SSID: %s\n", WiFi.SSID().c_str());
  Serial.print("IP Address: ");
  Serial.println(WiFi.localIP());

  // 7. SmartConfig Stop
  if (WiFi.smartConfigDone()) {
       WiFi.stopSmartConfig();
       Serial.println("SmartConfig process stopped.");
  }
  
  // Initial sensor readings
  readWaterLevel();
  readSensor34Value();
  
  // Setup UDP
  udp.begin(localUdpPort);
  Serial.println("UDP server started on port " + String(localUdpPort));
}

void loop() {
  // Handle UDP communications
  handleUdpCommunication();
  
  // Handle WiFi Disconnection
  if (WiFi.status() != WL_CONNECTED && !isConnectingViaSmartConfig) {
    Serial.println("WiFi Disconnected. Attempting to reconnect...");
    WiFi.reconnect();
    delay(2000);
  }

  // Check sensors periodically
  static unsigned long lastWaterLevelCheck = 0;
  if (millis() - lastWaterLevelCheck > 5000) { // Check every 5 seconds
    readWaterLevel();
    lastWaterLevelCheck = millis();
  }

  static unsigned long lastSensor34Check = 0;
  if (millis() - lastSensor34Check > 5000) {
    readSensor34Value();
    lastSensor34Check = millis();
  }

  // Check for RFID tag only if robot is running
  if (robotOn) {
    if (checkRFIDEndTag()) {
      Serial.println("End tag detected - stopping robot");
      stopRobot();
    }
  }
  
  delay(10); // Smaller delay for better responsiveness
}

void handleUdpCommunication() {
  // Check for incoming commands
  int packetSize = udp.parsePacket();
  if (packetSize) {
    // Record client IP and port for sending responses back
    clientIP = udp.remoteIP();
    clientPort = udp.remotePort();
    
    Serial.print("Received UDP packet from: ");
    Serial.print(clientIP);
    Serial.print(":");
    Serial.println(clientPort);
    
    // Read the command
    char incomingPacket[255];
    int len = udp.read(incomingPacket, 255);
    if (len > 0) {
      incomingPacket[len] = 0; // Null terminate
      String command = String(incomingPacket);
      Serial.println("UDP Command: " + command);
      
      if (command == "START") {
        startRobot();
        sendUdpResponse("OK:STARTED");
      } else if (command == "STOP") {
        stopRobot();
        sendUdpResponse("OK:STOPPED");
      } else if (command == "GET_DATA") {
        sendSensorData();
      } else {
        sendUdpResponse("ERROR:UNKNOWN_COMMAND");
      }
    }
  }
  
  // Send sensor data periodically if we have a client
  static unsigned long lastSensorSend = 0;
  if (clientIP && millis() - lastSensorSend > 2000) { // Send every 2 seconds
    sendSensorData();
    lastSensorSend = millis();
  }
}

void sendSensorData() {
  if (!clientIP) return; // Only send if we have a client
  
  // Create JSON document
  StaticJsonDocument<200> doc;
  doc["water_level"] = waterLevel;
  doc["sensor_34"] = sensor34Value;
  doc["robot_status"] = robotOn ? "running" : "stopped";
  
  // Serialize JSON to string
  String jsonString;
  serializeJson(doc, jsonString);
  
  // Send UDP packet
  udp.beginPacket(clientIP, clientPort);
  udp.print(jsonString);
  udp.endPacket();
  
  Serial.println("Sent sensor data via UDP: " + jsonString);
}

void sendUdpResponse(String response) {
  if (!clientIP) return;
  
  udp.beginPacket(clientIP, clientPort);
  udp.print(response);
  udp.endPacket();
  
  Serial.println("Sent UDP response: " + response);
}

void readWaterLevel() {
  int rawValue = analogRead(WATER_LEVEL_PIN);
  waterLevel = map(rawValue, 0, 3050, 0, 100); // Adjust 3050 if needed based on calibration
  // Constrain the value just in case rawValue goes slightly out of expected range
  waterLevel = constrain(waterLevel, 0, 100);
  Serial.print("Raw ADC (Water Lvl): ");
  Serial.print(rawValue);
  Serial.print(" -> Water level: ");
  Serial.print(waterLevel);
  Serial.println("%");
}

void readSensor34Value() {
  int rawValue = analogRead(SENSOR_34_PIN);
  // Map raw ADC value (0-4095 for 12-bit ESP32) to 0-100 range
  // Adjust 4095 if your sensor doesn't use the full 0-3.3V range
  sensor34Value = map(rawValue, 0, 3753, 0, 100);
  // Constrain the value to ensure it's within 0-100
  sensor34Value = constrain(sensor34Value, 0, 100);

  Serial.print("Raw ADC (Sensor 34): ");
  Serial.print(rawValue);
  Serial.print(" -> Sensor 34 value: ");
  Serial.print(sensor34Value);
  Serial.println("%");
}

bool checkRFIDEndTag() {
  if (!rfid.PICC_IsNewCardPresent() || !rfid.PICC_ReadCardSerial()) {
    return false;
  }

  // Compare the read UID byte-by-byte with the endPathTagID
  bool isEndTag = true;
  for (byte i = 0; i < rfid.uid.size; i++) { // Use rfid.uid.size for safety
     if (i >= 4 || rfid.uid.uidByte[i] != endPathTagID[i]) { // Compare only first 4 bytes
        isEndTag = false;
        break;
     }
  }

  // Halt PICC and stop crypto to allow reading another tag
  rfid.PICC_HaltA();
  rfid.PCD_StopCrypto1();

  if (isEndTag) {
    Serial.print("Detected End Tag ID: ");
    for (byte i = 0; i < 4; i++) {
       Serial.print(endPathTagID[i] < 0x10 ? " 0" : " ");
       Serial.print(endPathTagID[i], HEX);
    }
     Serial.println();
  }

  return isEndTag;
}

void startRobot() {
  if (robotOn) return; // Already running
  Serial.println("Starting robot...");
  robotOn = true;

  // Start moving motors forward
  startMotorsForward();

  // Activate sanitizer (LOW = ON due to inverted logic mentioned in setup comment)
  digitalWrite(SPRAYER_PIN, LOW);
  digitalWrite(UV_LED_PIN, LOW);
  Serial.println("Motors, Sprayer, and UV LED activated.");
}

void stopRobot() {
  if (!robotOn) return; // Already stopped
  Serial.println("Stopping robot...");
  robotOn = false;

  // Stop all motors
  stopAllMotors();

  // Deactivate sanitizer (HIGH = OFF)
  digitalWrite(SPRAYER_PIN, HIGH);
  digitalWrite(UV_LED_PIN, HIGH);
  Serial.println("Motors, Sprayer, and UV LED deactivated.");
}

void startMotorsForward() {
  Serial.println("Setting motors forward");
  // Set direction for all motors
  digitalWrite(MOTOR1_IN1, HIGH);
  digitalWrite(MOTOR1_IN2, LOW);
  digitalWrite(MOTOR2_IN1, HIGH);
  digitalWrite(MOTOR2_IN2, LOW);
  digitalWrite(MOTOR3_IN1, HIGH);
  digitalWrite(MOTOR3_IN2, LOW);

  // Set speed for all motors (adjust 150 as needed for desired speed)
  analogWrite(MOTOR1_EN, 150);
  analogWrite(MOTOR2_EN, 150);
  analogWrite(MOTOR3_EN, 150);
}

void stopAllMotors() {
  Serial.println("Stopping all motors");
  // Disable motor enable pins (stops power regardless of IN pins)
  analogWrite(MOTOR1_EN, 0);
  analogWrite(MOTOR2_EN, 0);
  analogWrite(MOTOR3_EN, 0);

  // Set IN pins to LOW (good practice)
  digitalWrite(MOTOR1_IN1, LOW);
  digitalWrite(MOTOR1_IN2, LOW);
  digitalWrite(MOTOR2_IN1, LOW);
  digitalWrite(MOTOR2_IN2, LOW);
  digitalWrite(MOTOR3_IN1, LOW);
  digitalWrite(MOTOR3_IN2, LOW);
}