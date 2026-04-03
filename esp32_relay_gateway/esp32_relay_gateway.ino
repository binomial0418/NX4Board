#include <PubSubClient.h>
#include <WebSocketsServer.h>
#include <WiFi.h>
#include "config.h"

// --- 全域變數 ---
WebSocketsServer webSocket = WebSocketsServer(81);
WiFiClient espClient;
PubSubClient mqttClient(espClient);

unsigned long lastMqttRetry = 0;
const unsigned long mqttRetryInterval = 5000; // 5秒重試一次

// --- MQTT 重連邏輯 (Non-blocking) ---
void reconnectMqtt() {
  if (!mqttClient.connected()) {
    unsigned long now = millis();
    if (now - lastMqttRetry > mqttRetryInterval) {
      lastMqttRetry = now;
      Serial.println("[MQTT] 嘗試連接至 Broker...");

      String clientId = "ESP32Relay-";
      clientId += String(random(0xffff), HEX);

      if (mqttClient.connect(clientId.c_str(), mqtt_user, mqtt_pass)) {
        Serial.println("[MQTT] 已連接");
      } else {
        Serial.print("[MQTT] 連接失敗, rc=");
        Serial.print(mqttClient.state());
        Serial.println(" 到下次重試前將繼續運作區域網路模式");
      }
    }
  }
}

// --- WebSocket 事件處理 ---
void webSocketEvent(uint8_t num, WStype_t type, uint8_t *payload,
                    size_t length) {
  switch (type) {
  case WStype_DISCONNECTED:
    Serial.printf("[%u] WebSocket 已斷開\n", num);
    break;
  case WStype_CONNECTED: {
    IPAddress ip = webSocket.remoteIP(num);
    Serial.printf("[%u] WebSocket 已連接，來自: %d.%d.%d.%d\n", num, ip[0],
                  ip[1], ip[2], ip[3]);
  } break;
  case WStype_TEXT: {
    // 收到數據，立即轉發至 MQTT
    String message = String((char *)payload);
    Serial.printf("[%u] 收到數據: %s\n", num, message.c_str());

    if (mqttClient.connected()) {
      if (mqttClient.publish(mqtt_topic, message.c_str())) {
        Serial.println("[轉發] MQTT 發送成功");
      } else {
        Serial.println("[轉發] MQTT 發送失敗");
      }
    } else {
      Serial.println("[轉發] MQTT 未連接，數據已丟棄");
    }
  } break;
  default:
    break;
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println("\n--- ESP32 數據轉發網關啟動 ---");

  // 1. 設定 WiFi 雙模 (AP + STA)
  WiFi.mode(WIFI_AP_STA);

  // 設定 AP
  WiFi.softAP(ssid_ap, pass_ap);
  Serial.print("[WiFi] AP 模式啟動, SSID: ");
  Serial.println(ssid_ap);
  Serial.print("[WiFi] AP IP 位址: ");
  Serial.println(WiFi.softAPIP());

  // 連接 STA
  WiFi.begin(ssid_sta, pass_sta);
  Serial.print("[WiFi] 正在連接至外部 WiFi: ");
  Serial.println(ssid_sta);

  // 2. 初始化 MQTT
  mqttClient.setServer(mqtt_server, mqtt_port);

  // 3. 啟動 WebSocket Server
  webSocket.begin();
  webSocket.onEvent(webSocketEvent);
  Serial.println("[WS] WebSocket Server 已啟動於端口 81");
}

void loop() {
  // 處理 WebSocket 任務
  webSocket.loop();

  // 處理 MQTT 任務與重連
  if (WiFi.status() == WL_CONNECTED) {
    if (!mqttClient.connected()) {
      reconnectMqtt();
    }
    mqttClient.loop();
  }

  // 檢查 STA 狀態變化（供 Debug）
  static wl_status_t lastStatus = WL_IDLE_STATUS;
  wl_status_t currentStatus = WiFi.status();
  if (currentStatus != lastStatus) {
    if (currentStatus == WL_CONNECTED) {
      Serial.print("[WiFi] STA 已連接, IP: ");
      Serial.println(WiFi.localIP());
    } else if (currentStatus == WL_DISCONNECTED) {
      Serial.println("[WiFi] STA 連線中斷");
    }
    lastStatus = currentStatus;
  }
}
