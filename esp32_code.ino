#include <WiFi.h>
#include <ESPAsyncWebServer.h>
#include <AsyncTCP.h>
#include <AsyncWebSocket.h>
#include <Preferences.h>    // For NVS
#include <ArduinoJson.h>    // For WebSocket messages
#include <ESPmDNS.h>        // <<< ADDED FOR mDNS
#include <MFRC522.h>        // For RFID
#include <SPI.h>            // For RFID
#include <esp_wifi.h>       // Required for ESP SmartConfig
#include <rom/rtc.h>        // Required for checking reset reason

// --- Configuration ---
const char* nvsNamespace = "wifi-creds"; // Namespace for storing credentials in NVS
const char* nvsSsidKey = "ssid";
const char* nvsPassKey = "password";
const unsigned long dataInterval = 2000; // Send data every 2 seconds (2000 ms)
const char* mdnsHostname = "clexa";      // <<< Hostname for mDNS (e.g., clexa.local)
const bool DEBUG = true;                 // Debug flag for verbose logging

// SmartConfig timeouts (in milliseconds)
#define SC_TIMEOUT_MS 90000 // SmartConfig credential timeout: 90 seconds
#define WIFI_TIMEOUT_MS 30000 // Wi-Fi connection timeout: 30 seconds

// Reset button settings
#define RESET_BUTTON_PIN 0 
#define RESET_HOLD_TIME 3000 // Time in ms to hold button to clear NVS (3 seconds)
// --- End Configuration ---

// --- Hardware Pins Configuration ---
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
#define BATTERY_PIN     34  // Battery status monitoring pin
#define SPRAYER_PIN     25
#define UV_LED_PIN      14
// --- End Hardware Pins Configuration ---

AsyncWebServer server(80); // Web server for WebSocket (port 80)
AsyncWebSocket ws("/ws"); // WebSocket server endpoint "/ws" attached to the main server
Preferences preferences;
MFRC522 rfid(SS_PIN, RST_PIN); // Initialize RFID reader

// Flag to indicate if ESP32 is connected to WiFi
bool isWifiConnected = false;
// Flag to indicate if we're in SmartConfig mode
bool isSmartConfigActive = false;
unsigned long previousMillis = 0; // For timing the data sending
String connectedSsid = ""; // Store the SSID we're connected to

// Flag to track if Clexa components are running 
bool isRunning = false; // Default to OFF when ESP starts

// Hardware sensor values
int waterLevel = 0;
int batteryStatus = 0;  // Battery status (0-100%)

// RFID tag ID that marks the end of path
byte endPathTagID[4] = {0x33, 0x81, 0xFD, 0x2C}; // Replace with your actual tag ID

// Variables for timing
unsigned long statusMillis = 0;
unsigned long lastWaterLevelCheck = 0;
unsigned long lastBatteryCheck = 0;
const long statusInterval = 5000; // 5 second interval for status updates when stopped
const long sensorCheckInterval = 5000; // 5 second interval for checking sensors

// Variables for reset button
unsigned long resetButtonPressedTime = 0;
bool resetButtonPressed = false;

// Function to handle WebSocket events
void onEvent(AsyncWebSocket *server, AsyncWebSocketClient *client, AwsEventType type,
             void *arg, uint8_t *data, size_t len) {
  switch (type) {
    case WS_EVT_CONNECT:
      Serial.printf("WebSocket client #%u connected from %s\n", client->id(), client->remoteIP().toString().c_str());
      // Send initial status including SSID when client connects
      if (isWifiConnected) {
        StaticJsonDocument<300> jsonDoc;
        jsonDoc["type"] = "status";
        jsonDoc["connected"] = true;
        jsonDoc["ssid"] = connectedSsid;
        jsonDoc["ip"] = WiFi.localIP().toString();
        jsonDoc["running"] = isRunning; // Add running state to initial status message
        // Add sensor values to status
        jsonDoc["waterLevel"] = waterLevel;
        jsonDoc["batteryStatus"] = batteryStatus;
        
        String jsonString;
        serializeJson(jsonDoc, jsonString);
        if (DEBUG) {
          Serial.print("Sending initial status: ");
          Serial.println(jsonString);
        }
        client->text(jsonString);
      }
      break;
    case WS_EVT_DISCONNECT:
      Serial.printf("WebSocket client #%u disconnected\n", client->id());
      break;
    case WS_EVT_DATA:
      { // Added braces to create a scope for the StaticJsonDocument
        // Handle incoming data from the client
        AwsFrameInfo *info = (AwsFrameInfo*)arg;
        if (info->final && info->index == 0 && info->len == len && info->opcode == WS_TEXT) {
          // Message is text and complete
          data[len] = 0; // Null-terminate the received data
          if (DEBUG) {
            Serial.printf("WebSocket data from client #%u: %s\n", client->id(), (char*)data);
          }

          // Parse the JSON message
          StaticJsonDocument<200> jsonDoc; // Small doc for incoming commands
          DeserializationError error = deserializeJson(jsonDoc, (char*)data);

          if (error) {
            Serial.print(F("deserializeJson() failed: "));
            Serial.println(error.f_str());
            // Optionally send an error back to the client
            // client->text("{\"error\":\"Invalid JSON\"}");
            return; // Exit if JSON is invalid
          }

          // Check if it's the clear credentials command
          if (jsonDoc.containsKey("action") && strcmp(jsonDoc["action"], "clearCredentials") == 0) {
            Serial.println("Received command to clear credentials!");

            // Clear credentials from NVS
            preferences.begin(nvsNamespace, false); // Open NVS in read/write mode
            bool cleared = preferences.clear(); // Clear the entire namespace
            preferences.end();

            if (cleared) {
              Serial.println("Credentials successfully cleared from NVS.");
            } else {
              Serial.println("Failed to clear credentials, trying alternative method.");
              preferences.begin(nvsNamespace, false);
              preferences.remove(nvsSsidKey);
              preferences.remove(nvsPassKey);
              preferences.end();
              Serial.println("Attempted manual removal of credentials.");
            }

            // Force WiFi into SmartConfig mode before restart
            WiFi.disconnect(true);
            WiFi.mode(WIFI_OFF);
            delay(100);
            
            // Set an explicit flag in a different namespace to force SmartConfig mode
            preferences.begin("system", false);
            preferences.putBool("force_smartconfig", true);
            preferences.end();
            Serial.println("SmartConfig mode flag set for next boot.");

            // Send confirmation back to client
            client->text("{\"status\":\"Credentials cleared successfully. Restarting in configuration mode.\"}");
            delay(500); // Allow time for the message to be sent

            Serial.println("Restarting ESP32...");
            ESP.restart();
          } 
          // Handle start command
          else if (jsonDoc.containsKey("action") && strcmp(jsonDoc["action"], "start") == 0) {
            Serial.println("Start button pressed");
            
            // Set running state to true
            isRunning = true;
            
            // Start robot components
            startRobot();
            
            // Send confirmation back to client
            StaticJsonDocument<200> responseDoc;
            responseDoc["type"] = "status";
            responseDoc["running"] = true;
            responseDoc["message"] = "Clexa started successfully";
            
            String responseString;
            serializeJson(responseDoc, responseString);
            if (DEBUG) {
              Serial.print("Sending start confirmation: ");
              Serial.println(responseString);
            }
            client->text(responseString);
            
            // Also broadcast new status to all clients
            responseDoc["type"] = "statusUpdate";
            serializeJson(responseDoc, responseString);
            if (DEBUG) {
              Serial.print("Broadcasting start status: ");
              Serial.println(responseString);
            }
            ws.textAll(responseString);
          }
          // Handle stop command
          else if (jsonDoc.containsKey("action") && strcmp(jsonDoc["action"], "stop") == 0) {
            Serial.println("Stop button pressed");
            
            // Set running state to false
            isRunning = false;
            
            // Stop robot components
            stopRobot();
            
            // Send confirmation back to client
            StaticJsonDocument<200> responseDoc;
            responseDoc["type"] = "status";
            responseDoc["running"] = false;
            responseDoc["message"] = "Clexa stopped successfully";
            
            String responseString;
            serializeJson(responseDoc, responseString);
            if (DEBUG) {
              Serial.print("Sending stop confirmation: ");
              Serial.println(responseString);
            }
            client->text(responseString);
            
            // Also broadcast new status to all clients
            responseDoc["type"] = "statusUpdate";
            serializeJson(responseDoc, responseString);
            if (DEBUG) {
              Serial.print("Broadcasting stop status: ");
              Serial.println(responseString);
            }
            ws.textAll(responseString);
          }
          else {
            // Handle other incoming messages if needed
             Serial.println("Received unknown command or JSON structure.");
          }
        }
      } // End of scope for jsonDoc
      break;
    case WS_EVT_PONG:
    case WS_EVT_ERROR:
      break;
  }
}

// Function to handle SmartConfig provisioning
bool startSmartConfig() {
  Serial.println("Starting SmartConfig...");
  WiFi.mode(WIFI_STA);
  WiFi.disconnect(true); // Disconnect from any previous AP
  delay(100);
  
  // Start SmartConfig
  WiFi.beginSmartConfig();
  isSmartConfigActive = true;
  Serial.println("SmartConfig started. Waiting for configuration...");

  unsigned long startTime = millis();

  // Wait for SmartConfig to complete
  while (!WiFi.smartConfigDone()) {
    delay(500);
    Serial.print(".");
    if (millis() - startTime > SC_TIMEOUT_MS) {
      Serial.println("\nSmartConfig timed out waiting for credentials.");
      WiFi.stopSmartConfig(); // Explicitly stop on timeout
      isSmartConfigActive = false;
      return false;
    }
  }
  
  Serial.println("\nSmartConfig credentials received!");
  
  // Wait for WiFi connection
  Serial.println("Attempting to connect with the provided credentials...");
  startTime = millis(); // Reset timer for WiFi connection
  
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
    if (millis() - startTime > WIFI_TIMEOUT_MS) {
      Serial.println("\nWiFi connection timed out.");
      isSmartConfigActive = false;
      WiFi.disconnect(true);
      return false;
    }
    
    // Check if SmartConfig is still active
    if (!WiFi.smartConfigDone() && isSmartConfigActive) {
      Serial.println("\nSmartConfig process failed during connection attempt.");
      isSmartConfigActive = false;
      return false;
    }
  }
  
  // Connection successful
  Serial.println("\nWiFi Connected!");
  isSmartConfigActive = false;
  isWifiConnected = true;
  
  Serial.printf("SSID: %s\n", WiFi.SSID().c_str());
  Serial.print("IP Address: ");
  Serial.println(WiFi.localIP());
  
  // Save credentials to NVS
  preferences.begin(nvsNamespace, false);
  preferences.putString(nvsSsidKey, WiFi.SSID());
  preferences.putString(nvsPassKey, WiFi.psk());
  preferences.end();
  
  // Stop SmartConfig
  WiFi.stopSmartConfig();
  Serial.println("SmartConfig process stopped.");
  
  // Store connected SSID
  connectedSsid = WiFi.SSID();
  
  // Add auto-restart after successful SmartConfig
  ESP.restart();
  
  // This won't be reached because of restart
  return true;
}

// Function to attempt WiFi connection using saved credentials
bool connectToWifi() {
  Serial.println("Attempting to connect to WiFi...");
  preferences.begin(nvsNamespace, true);
  String savedSsid = preferences.getString(nvsSsidKey, "");
  String savedPassword = preferences.getString(nvsPassKey, "");
  preferences.end();

  if (savedSsid.length() > 0) {
    Serial.print("Connecting to: ");
    Serial.println(savedSsid);

    WiFi.mode(WIFI_STA);
    WiFi.begin(savedSsid.c_str(), savedPassword.c_str());

    unsigned long startTime = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - startTime < 20000) {
      delay(500);
      Serial.print(".");
    }
    Serial.println();

    if (WiFi.status() == WL_CONNECTED) {
      Serial.println("WiFi Connected!");
      Serial.print("IP Address: ");
      Serial.println(WiFi.localIP());
      isWifiConnected = true;
      connectedSsid = savedSsid; // Store the SSID we're connected to

      // ----- Start mDNS Setup ----- //
      Serial.print("Setting up mDNS responder with hostname: ");
      Serial.println(mdnsHostname);
      if (!MDNS.begin(mdnsHostname)) {
          Serial.println("Error setting up MDNS responder!");
          // Handle error? For now, just print message.
      } else {
          Serial.println("mDNS responder started");
          // Add service that Flutter app will look for
          // Service Name: _clexa
          // Protocol: _tcp
          // Port: 80 (where our web/websocket server runs)
          MDNS.addService("_clexa", "_tcp", 80);
          Serial.println("mDNS Service Added: _clexa._tcp on Port 80");
      }
      // ----- End mDNS Setup ----- //

      return true;
    } else {
      Serial.println("WiFi Connection Failed.");
      isWifiConnected = false;
      return false;
    }
  } else {
    Serial.println("No WiFi credentials found in NVS.");
    isWifiConnected = false;
    return false;
  }
}

void clearNvsAndRestart() {
  Serial.println("Clearing all NVS and restarting...");
  
  // Clear credentials from NVS
  preferences.begin(nvsNamespace, false); // Open NVS in read/write mode
  bool cleared = preferences.clear(); // Clear the entire namespace
  preferences.end();
  
  if (cleared) {
    Serial.println("Credentials successfully cleared from NVS.");
  } else {
    Serial.println("Failed to clear credentials, trying alternative method.");
    preferences.begin(nvsNamespace, false);
    preferences.remove(nvsSsidKey);
    preferences.remove(nvsPassKey);
    preferences.end();
    Serial.println("Attempted manual removal of credentials.");
  }
  
  // Force WiFi into SmartConfig mode before restart
  WiFi.disconnect(true);
  WiFi.mode(WIFI_OFF);
  delay(100);
  
  // Set an explicit flag in a different namespace to force SmartConfig mode
  preferences.begin("system", false);
  preferences.putBool("force_smartconfig", true);
  preferences.end();
  Serial.println("SmartConfig mode flag set for next boot.");
  
  delay(500); // Allow time for NVS operations to complete
  
  Serial.println("Restarting ESP32...");
  ESP.restart();
}

void setup() {
  Serial.begin(115200);
  Serial.println("\nESP32 Booting...");
  delay(500); // Brief delay to ensure serial monitor is ready

  // Check if we've had a reset caused by the reset button
  Serial.print("Reset reason: ");
  Serial.println(rtc_get_reset_reason(0)); // Get the reset reason for CPU0
  
  // Setup the reset button pin as input with pullup
  pinMode(RESET_BUTTON_PIN, INPUT_PULLUP);
  
  // Initialize hardware
  initializeHardware();

  // Check if we should force SmartConfig mode (set during credential clearing)
  Serial.println("Checking for forced SmartConfig mode flag...");
  preferences.begin("system", true);
  bool shouldForceSmartConfig = preferences.getBool("force_smartconfig", false);
  preferences.end();
  
  if (shouldForceSmartConfig) {
    Serial.println("FORCE SMARTCONFIG MODE FLAG DETECTED!");
    
    // Clear the flag immediately
    preferences.begin("system", false);
    preferences.remove("force_smartconfig");
    preferences.end();
    Serial.println("Force SmartConfig mode flag cleared.");
    
    // Skip WiFi connection attempt and go straight to SmartConfig mode
    if (startSmartConfig()) {
      // Initialize WebSocket server if SmartConfig was successful
      ws.onEvent(onEvent);
      server.addHandler(&ws);
      server.begin();
      Serial.println("HTTP and WebSocket server started.");
      Serial.println("WebSocket ready on ws://" + WiFi.localIP().toString() + "/ws");
    } else {
      Serial.println("SmartConfig failed. Will try again on next boot.");
    }
    return;
  }

  // Initialize NVS for WiFi credentials
  Serial.println("Checking for WiFi credentials...");
  if (!preferences.begin(nvsNamespace, true)) {
    Serial.println("Failed to initialize NVS! Trying read/write mode.");
     if (!preferences.begin(nvsNamespace, false)) {
      Serial.println("Failed to initialize NVS even in read/write mode. Halting.");
        while(1) delay(1000);
     } else {
        preferences.end();
     }
  } else {
    // Check if SSID exists as a quick test
    String savedSsid = preferences.getString(nvsSsidKey, "");
    preferences.end();
    
    if (savedSsid.isEmpty()) {
      Serial.println("No WiFi credentials found in NVS.");
      // Start SmartConfig instead of SoftAP
      if (startSmartConfig()) {
        // Initialize WebSocket server if SmartConfig was successful
        ws.onEvent(onEvent);
        server.addHandler(&ws);
        server.begin();
        Serial.println("HTTP and WebSocket server started.");
        Serial.println("WebSocket ready on ws://" + WiFi.localIP().toString() + "/ws");
      } else {
        Serial.println("SmartConfig failed. Will try again on next boot.");
      }
      return;
    }
  }

  // If we reach here, we should attempt to connect to WiFi with saved credentials
  if (connectToWifi()) {
    // Initialize WebSocket server
    ws.onEvent(onEvent);
    server.addHandler(&ws); // Add WebSocket handler to the server
    
    // Start the web server (which now also handles WebSocket requests on /ws)
    server.begin();
    Serial.println("HTTP and WebSocket server started.");
    Serial.println("WebSocket ready on ws://" + WiFi.localIP().toString() + "/ws");
  } else {
    // If WiFi connection failed, start SmartConfig
    Serial.println("WiFi connection failed, starting SmartConfig.");
    if (startSmartConfig()) {
      // Initialize WebSocket server if SmartConfig was successful
      ws.onEvent(onEvent);
      server.addHandler(&ws);
      server.begin();
      Serial.println("HTTP and WebSocket server started.");
      Serial.println("WebSocket ready on ws://" + WiFi.localIP().toString() + "/ws");
    } else {
      Serial.println("SmartConfig failed. Will try again on next boot.");
    }
  }
  Serial.setDebugOutput(false);
}

// Send status updates to connected clients
void sendStatusUpdate() {
  if (DEBUG) {
    Serial.println("Sending periodic status update");
  }
  
  // Create status document
  StaticJsonDocument<300> statusDoc;
  statusDoc["type"] = "status";
  statusDoc["running"] = isRunning;
  statusDoc["ssid"] = connectedSsid;
  statusDoc["ip"] = WiFi.localIP().toString();
  statusDoc["waterLevel"] = waterLevel;
  statusDoc["batteryStatus"] = batteryStatus;
  
  // Serialize to string
  String statusString;
  serializeJson(statusDoc, statusString);
  
  if (DEBUG) {
    Serial.print("Status update: ");
    Serial.println(statusString);
  }
  
  // Send to all connected clients
  ws.textAll(statusString);
}

void loop() {
  // Check reset button
  if (digitalRead(RESET_BUTTON_PIN) == LOW) { // Button is pressed (active LOW)
    if (!resetButtonPressed) {
      // Button was just pressed
      resetButtonPressed = true;
      resetButtonPressedTime = millis();
      Serial.println("Reset button pressed, hold for 3+ seconds to clear all settings");
    } else {
      // Button is being held
      if (millis() - resetButtonPressedTime >= RESET_HOLD_TIME) {
        // Button has been held for the required time
        Serial.println("Reset button held for 3+ seconds");
        clearNvsAndRestart();
      }
    }
  } else {
    // Button not pressed
    resetButtonPressed = false;
  }

  if (isWifiConnected) {
    // If connected to WiFi, handle WebSockets
    ws.cleanupClients();

    // Read sensor values regularly
    unsigned long currentMillis = millis();
    if (currentMillis - lastWaterLevelCheck >= sensorCheckInterval) {
      lastWaterLevelCheck = currentMillis;
      readWaterLevel();
    }
    
    if (currentMillis - lastBatteryCheck >= sensorCheckInterval) {
      lastBatteryCheck = currentMillis;
      readBatteryStatus();
    }
    
    // Check for RFID tag only if robot is running
    if (isRunning) {
      if (checkRFIDEndTag()) {
        Serial.println("End tag detected - stopping robot");
        stopRobot();
        isRunning = false;
        
        // Broadcast status update
        StaticJsonDocument<200> statusDoc;
        statusDoc["type"] = "statusUpdate";
        statusDoc["running"] = false;
        statusDoc["message"] = "Robot automatically stopped: End tag detected";
        
        String statusString;
        serializeJson(statusDoc, statusString);
        ws.textAll(statusString);
      }
    }
    
    // Send periodic status updates
    if (currentMillis - statusMillis >= statusInterval) {
      statusMillis = currentMillis;
      
      // Only broadcast if we have clients
      if (ws.count() > 0) {
        sendStatusUpdate();
      }
    }
  } else if (!isSmartConfigActive) {
    // If we lost WiFi connection and are not in SmartConfig mode, try to reconnect
    Serial.println("WiFi disconnected. Attempting to reconnect...");
    if (!connectToWifi()) {
      // If reconnection fails, try SmartConfig
      Serial.println("Reconnection failed, starting SmartConfig.");
      if (startSmartConfig()) {
        // Initialize WebSocket server if SmartConfig was successful
        ws.onEvent(onEvent);
        server.addHandler(&ws);
        server.begin();
        Serial.println("HTTP and WebSocket server started.");
        Serial.println("WebSocket ready on ws://" + WiFi.localIP().toString() + "/ws");
      }
    }
    
    // Add delay before next attempt
    delay(5000);
  }
}

// Initialize all hardware components
void initializeHardware() {
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
  pinMode(BATTERY_PIN, INPUT);

  // Stop all motors
  stopAllMotors();
  
  // Initial sensor readings
  readWaterLevel();
  readBatteryStatus();
}

// Read water level sensor
void readWaterLevel() {
  int rawValue = analogRead(WATER_LEVEL_PIN);
  waterLevel = map(rawValue, 0, 3050, 0, 100); // Adjust 3050 if needed based on calibration
  // Constrain the value just in case rawValue goes slightly out of expected range
  waterLevel = constrain(waterLevel, 0, 100);
  if (DEBUG) {
    Serial.print("Raw ADC (Water Lvl): ");
    Serial.print(rawValue);
    Serial.print(" -> Water level: ");
    Serial.print(waterLevel);
    Serial.println("%");
  }
}

// Read battery status
void readBatteryStatus() {
  int rawValue = analogRead(BATTERY_PIN);
  // Map raw ADC value (0-4095 for 12-bit ESP32) to 0-100 range
  // Adjust 3753 if your battery voltage range is different
  batteryStatus = map(rawValue, 0, 3753, 0, 100);
  // Constrain the value to ensure it's within 0-100
  batteryStatus = constrain(batteryStatus, 0, 100);

  if (DEBUG) {
    Serial.print("Raw ADC (Battery): ");
    Serial.print(rawValue);
    Serial.print(" -> Battery status: ");
    Serial.print(batteryStatus);
    Serial.println("%");
  }
}

// Check for RFID end tag
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

  if (isEndTag && DEBUG) {
    Serial.print("Detected End Tag ID: ");
    for (byte i = 0; i < 4; i++) {
       Serial.print(endPathTagID[i] < 0x10 ? " 0" : " ");
       Serial.print(endPathTagID[i], HEX);
    }
    Serial.println();
  }

  return isEndTag;
}

// Start robot hardware
void startRobot() {
  Serial.println("Starting robot...");

  // Start moving motors forward
  startMotorsForward();

  // Activate sanitizer (LOW = ON due to inverted logic)
  digitalWrite(SPRAYER_PIN, LOW);
  digitalWrite(UV_LED_PIN, LOW);
  Serial.println("Motors, Sprayer, and UV LED activated.");
}

// Stop robot hardware
void stopRobot() {
  Serial.println("Stopping robot...");

  // Stop all motors
  stopAllMotors();

  // Deactivate sanitizer (HIGH = OFF)
  digitalWrite(SPRAYER_PIN, HIGH);
  digitalWrite(UV_LED_PIN, HIGH);
  Serial.println("Motors, Sprayer, and UV LED deactivated.");
}

// Start all motors in forward direction
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

// Stop all motors
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