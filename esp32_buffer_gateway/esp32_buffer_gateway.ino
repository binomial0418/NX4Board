#include <PubSubClient.h>
#include <WebSocketsServer.h>
#include <WiFi.h>
#include "config.h"

// --- 常數 ---
#define BUFFER_SIZE 5
#define WS_PORT 81
#define WIFI_TIMEOUT_MS 15000

// --- 狀態機 ---
enum State {
  STATE_CONNECTING_RECV,  // 正在連接 oppoz4
  STATE_RECEIVING,        // 待命接收 WebSocket 資料
  STATE_CONNECTING_SEND,  // 正在連接 opposky
  STATE_SENDING,          // 正在透過 MQTT 發送資料
};

State currentState = STATE_CONNECTING_RECV;

// --- 資料緩衝區 ---
String dataBuffer[BUFFER_SIZE];
int bufferCount = 0;

// --- 網路物件 ---
WebSocketsServer webSocket = WebSocketsServer(WS_PORT);
WiFiClient espClient;
PubSubClient mqttClient(espClient);

// --- WebSocket 事件處理 ---
// 注意：僅在此修改狀態旗標，不做任何 WiFi/delay 操作
void webSocketEvent(uint8_t num, WStype_t type, uint8_t *payload, size_t length) {
  switch (type) {
    case WStype_DISCONNECTED:
      Serial.printf("[WS][%u] 已斷開連線\n", num);
      break;

    case WStype_CONNECTED: {
      IPAddress ip = webSocket.remoteIP(num);
      Serial.printf("[WS][%u] 已連接，來自: %d.%d.%d.%d\n", num, ip[0], ip[1], ip[2], ip[3]);
    } break;

    case WStype_TEXT: {
      if (currentState != STATE_RECEIVING) break;

      String message = String((char *)payload);
      Serial.printf("[WS][%u] 收到第 %d 筆: %s\n", num, bufferCount + 1, message.c_str());

      dataBuffer[bufferCount] = message;
      bufferCount++;

      if (bufferCount >= BUFFER_SIZE) {
        Serial.println("[緩衝] 已累積 5 筆資料，準備切換至傳送模式");
        // 僅改變狀態，實際 WiFi 切換由 loop() 處理
        currentState = STATE_CONNECTING_SEND;
      }
    } break;

    default:
      break;
  }
}

// --- 連接 WiFi（含先斷線確保乾淨切換）---
bool connectWiFi(const char *ssid, const char *pass) {
  Serial.printf("\n[WiFi] 正在連接: %s\n", ssid);
  WiFi.disconnect(true);
  delay(200);
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, pass);

  unsigned long startTime = millis();
  while (WiFi.status() != WL_CONNECTED) {
    if (millis() - startTime > WIFI_TIMEOUT_MS) {
      Serial.println("\n[WiFi] 連接逾時！");
      return false;
    }
    delay(500);
    Serial.print(".");
  }
  Serial.printf("\n[WiFi] 已連接 %s，IP: %s\n", ssid, WiFi.localIP().toString().c_str());
  return true;
}

// --- 連接 MQTT ---
static int mqttRetryCount = 0;
bool connectMqtt() {
  String clientId = "ESP32Buffer-";
  clientId += String(random(0xffff), HEX);

  Serial.println("[MQTT] 嘗試連接 Broker...");
  if (mqttClient.connect(clientId.c_str(), mqtt_user, mqtt_pass)) {
    Serial.println("[MQTT] 已連接");
    mqttRetryCount = 0;
    return true;
  }
  Serial.printf("[MQTT] 連接失敗，rc=%d (重試 %d/5)\n", mqttClient.state(), mqttRetryCount + 1);
  return false;
}

// --- 發送所有緩衝資料 ---
void sendBufferedData() {
  Serial.printf("[MQTT] 開始發送 %d 筆資料...\n", bufferCount);
  int successCount = 0;
  for (int i = 0; i < bufferCount; i++) {
    if (mqttClient.publish(mqtt_topic, dataBuffer[i].c_str())) {
      Serial.printf("[MQTT] 第 %d 筆發送成功: %s\n", i + 1, dataBuffer[i].c_str());
      successCount++;
    } else {
      Serial.printf("[MQTT] 第 %d 筆發送失敗，保留以供重試\n", i + 1);
      // 將失敗的資料移到陣列前端
      if (i != successCount) {
        dataBuffer[successCount] = dataBuffer[i];
      }
    }
    mqttClient.loop();
    delay(100);
  }
  bufferCount = bufferCount - successCount;  // 只清除成功發送的筆數
  if (bufferCount > 0) {
    Serial.printf("[MQTT] %d 筆發送失敗，保留於緩衝區以供下次重試\n", bufferCount);
  } else {
    Serial.println("[MQTT] 所有資料發送完畢，清除緩衝區");
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("\n--- ESP32 緩衝轉發器啟動 ---");
  Serial.printf("[設定] 接收 WiFi: %s | 傳送 WiFi: %s\n", ssid_recv, ssid_send);
  Serial.printf("[設定] 緩衝筆數: %d | MQTT: %s:%d\n", BUFFER_SIZE, mqtt_server, mqtt_port);

  // 初始化亂數種子，避免 MQTT Client ID 衝突
  randomSeed(esp_random());

  // setServer 只需呼叫一次
  mqttClient.setServer(mqtt_server, mqtt_port);

  // onEvent 只需設定一次
  webSocket.onEvent(webSocketEvent);

  // 初始狀態由 loop() 狀態機處理
}

void loop() {
  switch (currentState) {

    // --- 連接接收用 WiFi (oppoz4) ---
    case STATE_CONNECTING_RECV:
      if (connectWiFi(ssid_recv, pass_recv)) {
        // WiFi 重連後重新啟動 WebSocket Server（綁定新 IP）
        webSocket.begin();
        Serial.printf("[WS] WebSocket Server 啟動於端口 %d，等待資料...\n", WS_PORT);
        currentState = STATE_RECEIVING;
      } else {
        Serial.println("[WiFi] 重試連接...");
        delay(3000);
      }
      break;

    // --- 待命接收 WebSocket 資料 ---
    case STATE_RECEIVING:
      webSocket.loop();

      if (WiFi.status() != WL_CONNECTED) {
        Serial.println("[WiFi] 連線中斷，重新連接...");
        currentState = STATE_CONNECTING_RECV;
      }
      break;

    // --- 連接傳送用 WiFi (opposky) ---
    // connectWiFi 內部已先 disconnect，無需額外處理
    case STATE_CONNECTING_SEND:
      webSocket.close();  // 先關閉 WebSocket，避免 port 占用或記憶體洩漏
      if (connectWiFi(ssid_send, pass_send)) {
        currentState = STATE_SENDING;
      } else {
        Serial.println("[WiFi] opposky 連接失敗，重試...");
        delay(3000);
      }
      break;

    // --- 透過 MQTT 發送緩衝資料 ---
    case STATE_SENDING:
      if (connectMqtt()) {
        sendBufferedData();
        mqttClient.disconnect();
        Serial.println("[狀態] 發送完畢，切換回接收模式 (oppoz4)");
        currentState = STATE_CONNECTING_RECV;
        mqttRetryCount = 0;
      } else {
        // MQTT 連接失敗時，最多重試 5 次，超過則清空緩衝區並回到接收模式
        if (++mqttRetryCount > 5) {
          Serial.printf("[MQTT] 連接失敗達 5 次，清空緩衝區 (%d 筆資料) 並回到接收模式\n", bufferCount);
          bufferCount = 0;
          currentState = STATE_CONNECTING_RECV;
          mqttRetryCount = 0;
        } else {
          Serial.println("[MQTT] 連接失敗，資料保留，重試...");
          delay(3000);
        }
      }
      break;
  }
}
