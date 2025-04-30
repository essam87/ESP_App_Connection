#include <WiFi.h>
#include <MFRC522.h>
#include <SPI.h>
#include <driver/adc.h>
#include <ESPAsyncWebServer.h>

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
#define SENSOR_34_PIN   34 // <<< New Pin Definition
#define SPRAYER_PIN     25
#define UV_LED_PIN      14

// WiFi credentials - replace with your network details
const char* ssid = "Net";
const char* password = "Net@5418982";

// RFID tag ID that marks the end of path
byte endPathTagID[4] = {0x33, 0x81, 0xFD, 0x2C}; // Replace with your actual tag ID

// System states
bool robotOn = false;
int waterLevel = 0;
int sensor34Value = 0; // <<< New Variable for Sensor 34

// Initialize instances
MFRC522 rfid(SS_PIN, RST_PIN);
AsyncWebServer server(80);

// HTML for web interface
const char index_html[] PROGMEM = R"rawliteral(
<!DOCTYPE HTML>
<html>
<head>
  <title>Handrail Sanitization Robot Control</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body { font-family: Arial; text-align: center; margin:0px auto; padding:20px; }
    .button { padding: 15px 50px; font-size: 24px; margin: 20px; cursor: pointer; }
    .on { background-color: #4CAF50; color: white; }
    .off { background-color: #f44336; color: white; }
    .container { margin: 20px; border: 1px solid #ccc; padding: 10px; border-radius: 8px; }
    .gauge { width: 100%; max-width: 400px; height: 30px; margin: 10px auto; background-color: #ddd; border-radius: 5px; overflow: hidden;}
    .gauge-fill { height: 100%; background-color: #2196F3; text-align: right; color: white; line-height: 30px; padding-right: 5px; transition: width 0.5s ease-in-out; }
    h1 { color: #333; }
    h2 { color: #555; margin-bottom: 5px;}
    p#status { font-weight: bold; font-size: 1.1em; }
  </style>
</head>
<body>
  <h1>Handrail Sanitization Robot</h1>

  <div class="container">
    <h2>Water Level: <span id="waterLevel">0</span>%</h2>
    <div class="gauge"><div class="gauge-fill" id="waterLevelGauge" style="width: 0%">0%</div></div>
  </div>

  <div class="container">
    <h2>Sensor 34 Value: <span id="sensor34Value">0</span>%</h2>
    <div class="gauge"><div class="gauge-fill" id="sensor34Gauge" style="width: 0%; background-color: #FF9800;">0%</div></div>
  </div>
  <div class="container">
    <button class="button on" onclick="controlRobot(true)">START</button>
    <button class="button off" onclick="controlRobot(false)">STOP</button>
  </div>
  <p id="status">Robot Status: Stopped</p>

  <script>
    function updateWaterLevel() {
      var xhr = new XMLHttpRequest();
      xhr.onreadystatechange = function() {
        if (this.readyState == 4 && this.status == 200) {
          var level = this.responseText;
          document.getElementById("waterLevel").innerHTML = level;
          document.getElementById("waterLevelGauge").style.width = level + "%";
          document.getElementById("waterLevelGauge").innerHTML = level + "%";
        }
      };
      xhr.open("GET", "/waterLevel", true);
      xhr.send();
    }

    // <<< New Function to update Sensor 34 display >>>
    function updateSensor34Value() {
      var xhr = new XMLHttpRequest();
      xhr.onreadystatechange = function() {
        if (this.readyState == 4 && this.status == 200) {
          var value = this.responseText;
          document.getElementById("sensor34Value").innerHTML = value;
          document.getElementById("sensor34Gauge").style.width = value + "%";
          document.getElementById("sensor34Gauge").innerHTML = value + "%";
        }
      };
      xhr.open("GET", "/sensor34", true); // <<< New endpoint
      xhr.send();
    }
    // <<< End New Function >>>

    function updateStatus() {
      var xhr = new XMLHttpRequest();
      xhr.onreadystatechange = function() {
        if (this.readyState == 4 && this.status == 200) {
          document.getElementById("status").innerHTML = "Robot Status: " +
            (this.responseText == "1" ? "Running" : "Stopped");
        }
      };
      xhr.open("GET", "/status", true);
      xhr.send();
    }

    function controlRobot(state) {
      var xhr = new XMLHttpRequest();
      xhr.open("GET", "/control?state=" + (state ? "1" : "0"), true);
      xhr.send();
      // Update status slightly after sending command for responsiveness
      setTimeout(updateStatus, 500);
    }

    // Set intervals to update data periodically
    setInterval(updateWaterLevel, 2000);
    setInterval(updateSensor34Value, 2000); // <<< Call new update function
    setInterval(updateStatus, 2000);

    // Initial data fetch on page load
    updateWaterLevel();
    updateSensor34Value(); // <<< Call new update function
    updateStatus();
  </script>
</body>
</html>
)rawliteral";

void setup() {
  Serial.begin(115200);

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
  pinMode(SENSOR_34_PIN, INPUT); // <<< Set pin mode for Sensor 34

  // Stop all motors
  stopAllMotors();

  // Connect to WiFi
  WiFi.begin(ssid, password);
  Serial.print("Connecting to WiFi");
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\nConnected!");
  Serial.print("IP Address: ");
  Serial.println(WiFi.localIP());

  // Web server routes
  server.on("/", HTTP_GET, [](AsyncWebServerRequest *request){
    request->send_P(200, "text/html", index_html);
  });

  server.on("/waterLevel", HTTP_GET, [](AsyncWebServerRequest *request){
    request->send(200, "text/plain", String(waterLevel));
  });

  // <<< New Endpoint for Sensor 34 >>>
  server.on("/sensor34", HTTP_GET, [](AsyncWebServerRequest *request){
    request->send(200, "text/plain", String(sensor34Value));
  });
  // <<< End New Endpoint >>>

  server.on("/status", HTTP_GET, [](AsyncWebServerRequest *request){
    request->send(200, "text/plain", robotOn ? "1" : "0");
  });

  server.on("/control", HTTP_GET, [](AsyncWebServerRequest *request){
    if (request->hasParam("state")) {
      String stateParam = request->getParam("state")->value();
      if (stateParam == "1") {
        startRobot();
        request->send(200, "text/plain", "Robot started");
      } else {
        stopRobot();
        request->send(200, "text/plain", "Robot stopped");
      }
    } else {
      request->send(400, "text/plain", "Missing state parameter");
    }
  });

  server.begin();
  Serial.println("Web server started");

  // Initial sensor readings
  readWaterLevel();
  readSensor34Value(); // <<< Initial read for Sensor 34
}

void loop() {
  // Check sensors periodically
  static unsigned long lastWaterLevelCheck = 0;
  if (millis() - lastWaterLevelCheck > 5000) { // Check every 5 seconds
    readWaterLevel();
    lastWaterLevelCheck = millis();
  }

  static unsigned long lastSensor34Check = 0; // <<< Timer for Sensor 34
  if (millis() - lastSensor34Check > 5000) { // <<< Check every 5 seconds
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

  // Note: The web server runs asynchronously, no need to handle client connections in loop()
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

// <<< New Function to Read Sensor 34 >>>
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
// <<< End New Function >>>


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