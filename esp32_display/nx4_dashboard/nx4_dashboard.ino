// ─────────────────────────────────────────────────────────────────────────
// NX4Board ESP32-P4 車載儀表顯示器
//
// 硬體：JC1060P470C（ESP32-P4 + JD9165 MIPI DSI 1024x600 + GT911 觸控）
// 角色：WiFi STA + WebSocket Server，接收 NX4Board App 第二通道推送的
//       esp32_dash JSON，以 LVGL 即時渲染車載儀表。
//
// 資料協定（手機 → 本機，見 lib/screens/dashboard_screen.dart）：
// {
//   "_type": "esp32_dash",
//   "speed": 75, "rpm": 1750, "coolant": 88, "soc": 65.5,
//   "fuel": 50, "speed_limit": 90,
//   "odo": 33676, "turbo": 0.15, "time": "18:04:37", "date": "09/01 週一",
//   "tires": {"fl": 34, "fr": 34, "rl": 33, "rr": 33},
//   "camera": {"active": true, "limit": 90},
//   "lights": {"low": true, "high": false},
//   "brightness": 40
// }
//
// brightness 為螢幕背光百分比（0-100），由手機端依 OBD 大燈狀態決定。
// 設定頁的「測試」按鈕會額外帶 "brightness_hold_ms"，在該時間內忽略後續
// 儀表推送的 brightness，方便實機確認亮度。
//
// 編譯上傳請使用 ./build.sh（arduino-cli），詳見 README.md。
// ─────────────────────────────────────────────────────────────────────────
#pragma GCC push_options
#pragma GCC optimize("O3")

#include <Arduino.h>
#include <ArduinoJson.h>
#include <WiFi.h>
#include <WebSocketsServer.h>

#include "driver/i2c_master.h"
#include "lvgl.h"

#include "config.h"
#include "pins_config.h"
#include "src/lcd/jd9165_lcd.h"
#include "src/touch/gt911_touch.h"
#include "ui_dashboard.h"

// ── 顯示與觸控 ──────────────────────────────────────────────────────────
bsp_lcd_handles_t lcd_panels;
jd9165_lcd lcd = jd9165_lcd(LCD_RST);
gt911_touch touch = gt911_touch(TP_I2C_SDA, TP_I2C_SCL, TP_RST, TP_INT);

static lv_disp_draw_buf_t draw_buf;
static lv_color_t *buf;
static lv_color_t *buf1;

// ── WebSocket Server ────────────────────────────────────────────────────
WebSocketsServer webSocket = WebSocketsServer(WS_PORT);

// ── 共享狀態 ────────────────────────────────────────────────────────────
// webSocketEvent() 由 loop() 內的 webSocket.loop() 同步呼叫，與 LVGL 同一
// 任務，因此不需額外上鎖；仍以 dirty flag 分離「解析」與「渲染」，
// 讓多筆連續封包只觸發一次 LVGL 更新。
static nx4_dash_data_t g_dash;
static bool g_dash_dirty = false;
static uint32_t g_last_data_ms = 0;
static bool g_client_linked = false;

// 實測畫面刷新率：每次 flush 計數一次，於心跳換算成 FPS
static volatile uint32_t g_flush_count = 0;

// 背光：只有數值變動時才呼叫 LEDC，避免每筆推送都重設 duty
static int g_brightness = 100;
static uint32_t g_brightness_hold_until = 0;

// ─────────────────────────────────────────────────────────────────────────
// LVGL 顯示驅動（沿用原廠 Demo 寫法）
// ─────────────────────────────────────────────────────────────────────────
static bool lvgl_port_flush_dpi_panel_ready_callback(
    esp_lcd_panel_handle_t panel_io, esp_lcd_dpi_panel_event_data_t *edata,
    void *user_ctx) {
  lv_disp_drv_t *disp_drv = (lv_disp_drv_t *)user_ctx;
  assert(disp_drv != NULL);
  lv_disp_flush_ready(disp_drv);
  return false;
}

void my_disp_flush(lv_disp_drv_t *disp, const lv_area_t *area,
                   lv_color_t *color_p) {
  const int offsetx1 = area->x1;
  const int offsetx2 = area->x2;
  const int offsety1 = area->y1;
  const int offsety2 = area->y2;
  lcd.lcd_draw_bitmap(offsetx1, offsety1, offsetx2 + 1, offsety2 + 1,
                      &color_p->full);
  g_flush_count++;
}

void my_touchpad_read(lv_indev_drv_t *indev_driver, lv_indev_data_t *data) {
  uint16_t touchX, touchY;
  bool touched = touch.getTouch(&touchX, &touchY);

  if (!touched) {
    data->state = LV_INDEV_STATE_REL;
  } else {
    data->state = LV_INDEV_STATE_PR;
    data->point.x = touchX;
    data->point.y = touchY;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// WebSocket
// ─────────────────────────────────────────────────────────────────────────
/// 套用螢幕背光（JD9165 驅動以 GPIO23 的 LEDC PWM 控制，10-bit）
static void applyBrightness(int percent) {
  if (percent < 0) percent = 0;
  if (percent > 100) percent = 100;
  if (percent == g_brightness) return;

  g_brightness = percent;
  lcd.example_bsp_set_lcd_backlight((uint32_t)percent);
  ui_dashboard_set_brightness(percent);
  Serial.printf("[BRT] 螢幕亮度 -> %d%%\n", percent);
}

static void handleDashPayload(uint8_t *payload, size_t length) {
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, payload, length);
  if (err) {
    Serial.printf("[WS] JSON 解析失敗: %s\n", err.c_str());
    return;
  }

  // 只處理本機認得的協定，其餘（例如第一通道的 BVB-7980）直接忽略
  const char *type = doc["_type"] | "";
  if (strcmp(type, "esp32_dash") != 0) {
    Serial.printf("[WS] 忽略非 esp32_dash 封包: %s\n", type);
    return;
  }

  // 缺欄位時保留上一次的值，避免畫面跳動
  g_dash.speed = doc["speed"] | g_dash.speed;
  g_dash.rpm = doc["rpm"] | g_dash.rpm;
  g_dash.coolant = doc["coolant"] | g_dash.coolant;
  g_dash.soc = doc["soc"] | g_dash.soc;
  g_dash.fuel = doc["fuel"] | g_dash.fuel;
  g_dash.speed_limit = doc["speed_limit"] | g_dash.speed_limit;
  g_dash.odo = doc["odo"] | g_dash.odo;
  g_dash.turbo = doc["turbo"] | g_dash.turbo;

  const char *clock = doc["time"] | "";
  if (clock[0] != '\0') {
    strncpy(g_dash.clock, clock, sizeof(g_dash.clock) - 1);
    g_dash.clock[sizeof(g_dash.clock) - 1] = '\0';
  }

  const char *date = doc["date"] | "";
  if (date[0] != '\0') {
    strncpy(g_dash.date, date, sizeof(g_dash.date) - 1);
    g_dash.date[sizeof(g_dash.date) - 1] = '\0';
  }

  JsonObjectConst tires = doc["tires"];
  if (!tires.isNull()) {
    g_dash.tire_fl = tires["fl"] | g_dash.tire_fl;
    g_dash.tire_fr = tires["fr"] | g_dash.tire_fr;
    g_dash.tire_rl = tires["rl"] | g_dash.tire_rl;
    g_dash.tire_rr = tires["rr"] | g_dash.tire_rr;
  }

  JsonObjectConst camera = doc["camera"];
  if (!camera.isNull()) {
    g_dash.camera_active = camera["active"] | false;
    g_dash.camera_limit = camera["limit"] | 0;
  }

  JsonObjectConst lights = doc["lights"];
  if (!lights.isNull()) {
    g_dash.low_beam = lights["low"] | false;
    g_dash.high_beam = lights["high"] | false;
  }

  // 亮度：帶 brightness_hold_ms 的（設定頁測試按鈕）優先，並在該期間
  // 忽略儀表推送的亮度，否則 200ms 一次的推送會馬上把測試值蓋掉
  if (doc["brightness"].is<int>()) {
    uint32_t hold = doc["brightness_hold_ms"] | 0;
    if (hold > 0) {
      g_brightness_hold_until = millis() + hold;
      applyBrightness(doc["brightness"].as<int>());
    } else if (millis() >= g_brightness_hold_until) {
      applyBrightness(doc["brightness"].as<int>());
    }
  }

  g_dash_dirty = true;
  g_last_data_ms = millis();
}

static void webSocketEvent(uint8_t num, WStype_t type, uint8_t *payload,
                           size_t length) {
  switch (type) {
    case WStype_DISCONNECTED:
      Serial.printf("[WS] [%u] 已斷開\n", num);
      g_client_linked = webSocket.connectedClients() > 0;
      break;

    case WStype_CONNECTED: {
      IPAddress ip = webSocket.remoteIP(num);
      Serial.printf("[WS] [%u] 已連接，來自: %s\n", num, ip.toString().c_str());
      g_client_linked = true;
    } break;

    case WStype_TEXT:
      handleDashPayload(payload, length);
      break;

    default:
      break;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// WiFi（非阻塞：連線期間畫面仍持續更新）
// ─────────────────────────────────────────────────────────────────────────
/// WiFi 事件：記錄斷線原因碼，是診斷連不上的唯一可靠依據
/// （常見：15=4WAY_HANDSHAKE_TIMEOUT 密碼錯誤、201=NO_AP_FOUND、
///   202=AUTH_FAIL、203=ASSOC_FAIL）
static void onWifiEvent(WiFiEvent_t event, WiFiEventInfo_t info) {
  switch (event) {
    case ARDUINO_EVENT_WIFI_STA_START:
      Serial.println("[WiFi] STA start");
      break;
    case ARDUINO_EVENT_WIFI_STA_CONNECTED:
      Serial.println("[WiFi] 已與 AP 關聯");
      break;
    case ARDUINO_EVENT_WIFI_STA_DISCONNECTED:
      Serial.printf("[WiFi] 斷線, reason=%d\n",
                    info.wifi_sta_disconnected.reason);
      break;
    case ARDUINO_EVENT_WIFI_STA_GOT_IP:
      Serial.printf("[WiFi] 取得 IP: %s\n", WiFi.localIP().toString().c_str());
      // 關聯完成後才關省電模式：在 begin() 之前呼叫會讓 ESP-Hosted
      // 重新初始化，導致剛送出的連線請求被以 reason=8 (ASSOC_LEAVE) 中止
      WiFi.setSleep(false);
      break;
    default:
      break;
  }
}

static void startWifi() {
  WiFi.onEvent(onWifiEvent);
  WiFi.mode(WIFI_STA);

#if USE_STATIC_IP
  IPAddress ip(STATIC_IP);
  IPAddress gateway(STATIC_GATEWAY);
  IPAddress subnet(STATIC_SUBNET);
  IPAddress dns(STATIC_DNS);
  if (!WiFi.config(ip, gateway, subnet, dns)) {
    Serial.println("[WiFi] 靜態 IP 設定失敗，改用 DHCP");
  }
#endif

  WiFi.begin(WIFI_SSID, WIFI_PASS);
  Serial.printf("[WiFi] 連線中: %s\n", WIFI_SSID);
}

/// 每秒檢查一次 WiFi/連線狀態並更新狀態列，斷線時自動重連
static void serviceWifi() {
  static uint32_t last_check = 0;
  static bool was_connected = false;

  uint32_t now = millis();
  if (now - last_check < 1000) return;
  last_check = now;

  bool connected = (WiFi.status() == WL_CONNECTED);

  static uint32_t last_retry = 0;

  if (connected && !was_connected) {
    Serial.printf("[WiFi] 已連線，IP: %s\n", WiFi.localIP().toString().c_str());
    Serial.printf("[WS] Server 啟動於 port %d\n", WS_PORT);
    last_retry = 0;
  } else if (!connected) {
    // 不論是初次連線失敗還是中途斷線，都每 10 秒重送一次 begin()。
    // 只在「已連線 → 斷線」時重連的話，開機第一次就失敗會永遠卡住。
    if (now - last_retry >= 10000) {
      last_retry = now;
      Serial.printf("[WiFi] 未連線 (status=%d)，重試 %s\n", (int)WiFi.status(),
                    WIFI_SSID);
      WiFi.disconnect();
      WiFi.begin(WIFI_SSID, WIFI_PASS);
    }
  }
  was_connected = connected;

  ui_dashboard_set_status(connected,
                          connected ? WiFi.localIP().toString().c_str() : NULL,
                          g_client_linked);

  // 心跳：每 10 秒印一次現況，方便在車上以序列埠確認裝置是否還活著
  static uint32_t last_beat = 0;
  if (now - last_beat >= 10000) {
    last_beat = now;
    uint32_t age = (g_last_data_ms == 0) ? 0 : (now - g_last_data_ms);
    uint32_t fps = (g_flush_count * 1000) / (now - (last_beat - 10000));
    g_flush_count = 0;
    Serial.printf(
        "[HB] WiFi=%s(st=%d) IP=%s clients=%u lastData=%lums BRT=%d%% "
        "fps=%lu speed=%d rpm=%d low=%d high=%d\n",
        connected ? "up" : "down", (int)WiFi.status(),
        connected ? WiFi.localIP().toString().c_str() : "-",
        webSocket.connectedClients(), (unsigned long)age, g_brightness,
        (unsigned long)fps, g_dash.speed, g_dash.rpm, g_dash.low_beam,
        g_dash.high_beam);
  }
}

// ─────────────────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  Serial.println("\nNX4Board ESP32-P4 Dashboard");

  nx4_dash_data_init(&g_dash);

  // 觸控 I2C 匯流排
  i2c_master_bus_handle_t i2c_handle = NULL;
  i2c_master_bus_config_t i2c_bus_conf = {
      .i2c_port = I2C_NUM_1,
      .sda_io_num = (gpio_num_t)TP_I2C_SDA,
      .scl_io_num = (gpio_num_t)TP_I2C_SCL,
      .clk_source = I2C_CLK_SRC_DEFAULT,
      .glitch_ignore_cnt = 7,
      .intr_priority = 0,
      .trans_queue_depth = 0,
      .flags = {
          .enable_internal_pullup = 1,
      },
  };
  i2c_new_master_bus(&i2c_bus_conf, &i2c_handle);

  lcd.begin();
  touch.begin();
  lcd.get_handle(&lcd_panels);

  // LVGL 初始化：雙緩衝置於 PSRAM
  lv_init();
  size_t buffer_size = sizeof(int16_t) * LCD_H_RES * LCD_V_RES;
  buf = (lv_color_t *)heap_caps_malloc(buffer_size, MALLOC_CAP_SPIRAM);
  buf1 = (lv_color_t *)heap_caps_malloc(buffer_size, MALLOC_CAP_SPIRAM);
  assert(buf);
  assert(buf1);
  lv_disp_draw_buf_init(&draw_buf, buf, buf1, LCD_H_RES * LCD_V_RES);

  static lv_disp_drv_t disp_drv;
  lv_disp_drv_init(&disp_drv);
  disp_drv.hor_res = LCD_H_RES;
  disp_drv.ver_res = LCD_V_RES;
  disp_drv.flush_cb = my_disp_flush;
  disp_drv.draw_buf = &draw_buf;
  // 局部刷新：只送出有變動的區域，配合「僅更新物件數值」達成 60 FPS
  disp_drv.full_refresh = false;
  lv_disp_drv_register(&disp_drv);

  static lv_indev_drv_t indev_drv;
  lv_indev_drv_init(&indev_drv);
  indev_drv.type = LV_INDEV_TYPE_POINTER;
  indev_drv.read_cb = my_touchpad_read;
  lv_indev_drv_register(&indev_drv);

  esp_lcd_dpi_panel_event_callbacks_t cbs = {0};
  cbs.on_color_trans_done = lvgl_port_flush_dpi_panel_ready_callback;
  esp_lcd_dpi_panel_register_event_callbacks(lcd_panels.panel, &cbs, &disp_drv);

  ui_dashboard_create();
  ui_dashboard_update(&g_dash);
  ui_dashboard_set_brightness(g_brightness);
  ui_dashboard_set_stale(true);

  startWifi();

  webSocket.begin();
  webSocket.onEvent(webSocketEvent);

  Serial.println("Setup done");
}

void loop() {
  webSocket.loop();
  serviceWifi();

  // 僅在有新資料時套用（只寫入 Label/Bar/Arc 數值，不重建物件）
  if (g_dash_dirty) {
    g_dash_dirty = false;
    ui_dashboard_update(&g_dash);
  }

  // 逾時未收到手機資料 → 淡化數值，避免誤讀舊值
  if (g_last_data_ms != 0 && millis() - g_last_data_ms > DATA_TIMEOUT_MS) {
    ui_dashboard_set_stale(true);
  }

  lv_timer_handler();
  delay(2);
}
