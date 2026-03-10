#include <WiFi.h>
#include <WebServer.h>
#include <WebSocketsServer.h>
#include <PubSubClient.h>
#include <Preferences.h>

// --- WiFi AP Settings (For Phone Connection & Config Portal) ---
const char* AP_SSID = "OBD_Relay_Gateway";
const char* AP_PASS = "12345678";

// --- MQTT Settings ---
const char* MQTT_BROKER = "220.132.203.243";
const int MQTT_PORT = 50883;
const char* MQTT_USER = "esp32";
const char* MQTT_PASS = "0988085240";
const char* MQTT_CLIENT_ID = "esp32_relay";
const char* MQTT_TOPIC = "owntracks/mt/NX4-327";

Preferences preferences;
WebServer server(80);
WebSocketsServer webSocket = WebSocketsServer(81);
WiFiClient espClient;
PubSubClient mqttClient(espClient);

String staSSID = "";
String staPASS = "";

// --- Config Portal HTML ---
const char* config_html = R"rawliteral(
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ESP32 Relay Config</title>
  <style>
    body { font-family: sans-serif; padding: 20px; background: #222; color: #fff; }
    input { margin: 10px 0; padding: 10px; width: 100%; max-width: 300px; box-sizing: border-box; }
    button { padding: 10px 20px; background: #007bff; color: white; border: none; cursor: pointer; }
    .card { background: #333; padding: 20px; border-radius: 8px; max-width: 400px; margin: auto; }
  </style>
</head>
<body>
  <div class="card">
    <h2>WiFi Config (STA)</h2>
    <form action="/save" method="POST">
      <label>SSID:</label><br>
      <input type="text" name="ssid" value=""><br>
      <label>Password:</label><br>
      <input type="password" name="pass" value=""><br>
      <button type="submit">Save & Reboot</button>
    </form>
  </div>
</body>
</html>
)rawliteral";

void handleRoot() {
  server.send(200, "text/html", config_html);
}

void handleSave() {
  if (server.hasArg("ssid")) {
    staSSID = server.arg("ssid");
    preferences.putString("ssid", staSSID);
  }
  if (server.hasArg("pass")) {
    staPASS = server.arg("pass");
    preferences.putString("pass", staPASS);
  }
  server.send(200, "text/plain", "Saved! Rebooting...");
  delay(1000);
  ESP.restart();
}

void setupWiFi() {
  // Start config portal on AP mode
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(AP_SSID, AP_PASS);
  Serial.print("AP IP Address: ");
  Serial.println(WiFi.softAPIP());

  // Try to connect to STA
  if (staSSID.length() > 0) {
    Serial.println("Connecting to STA: " + staSSID);
    WiFi.begin(staSSID.c_str(), staPASS.c_str());
    int attempts = 0;
    while (WiFi.status() != WL_CONNECTED && attempts < 20) {
      delay(500);
      Serial.print(".");
      attempts++;
    }
    if (WiFi.status() == WL_CONNECTED) {
      Serial.println("\nConnected to WiFi!");
    } else {
      Serial.println("\nFailed to connect to WiFi.");
    }
  }
}

void reconnectMqtt() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (!mqttClient.connected()) {
    Serial.print("Attempting MQTT connection...");
    if (mqttClient.connect(MQTT_CLIENT_ID, MQTT_USER, MQTT_PASS)) {
      Serial.println("connected");
    } else {
      Serial.print("failed, rc=");
      Serial.print(mqttClient.state());
      Serial.println(" try again later");
    }
  }
}

void onWebSocketEvent(uint8_t num, WStype_t type, uint8_t * payload, size_t length) {
  switch(type) {
    case WStype_DISCONNECTED:
      Serial.printf("[%u] Disconnected!\n", num);
      break;
    case WStype_CONNECTED: {
      IPAddress ip = webSocket.remoteIP(num);
      Serial.printf("[%u] Connected from %d.%d.%d.%d\n", num, ip[0], ip[1], ip[2], ip[3]);
      break;
    }
    case WStype_TEXT:
      Serial.printf("[%u] get Text: %s\n", num, payload);
      // Publish to MQTT
      if (mqttClient.connected()) {
        mqttClient.publish(MQTT_TOPIC, (char*)payload);
        Serial.println("Published to MQTT");
      } else {
        Serial.println("MQTT Not Connected. Dropping message.");
      }
      // Broadcast back to all clients just in case (optional)
      // webSocket.broadcastTXT(payload);
      break;
  }
}

void setup() {
  Serial.begin(115200);
  
  // Load saved credentials
  preferences.begin("wifi-config", false);
  staSSID = preferences.getString("ssid", "");
  staPASS = preferences.getString("pass", "");
  
  setupWiFi();

  // Setup Web Server for Config
  server.on("/", handleRoot);
  server.on("/save", HTTP_POST, handleSave);
  server.begin();

  // Setup WebSocket Server
  webSocket.begin();
  webSocket.onEvent(onWebSocketEvent);

  // Setup MQTT
  mqttClient.setServer(MQTT_BROKER, MQTT_PORT);
}

void loop() {
  webSocket.loop();
  server.handleClient();
  
  if (WiFi.status() == WL_CONNECTED) {
    if (!mqttClient.connected()) {
      static unsigned long lastReconnect = 0;
      if (millis() - lastReconnect > 5000) {
        lastReconnect = millis();
        reconnectMqtt();
      }
    } else {
      mqttClient.loop();
    }
  }
}
