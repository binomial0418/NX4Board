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
//   "tires": {"fl": 34, "fr": 34, "rl": 33, "rr": 33},
//   "camera": {"active": true, "limit": 90}
// }
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
static void startWifi() {
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);  // 關閉省電模式，降低推送延遲

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

  if (connected && !was_connected) {
    Serial.printf("[WiFi] 已連線，IP: %s\n", WiFi.localIP().toString().c_str());
    Serial.printf("[WS] Server 啟動於 port %d\n", WS_PORT);
  } else if (!connected && was_connected) {
    Serial.println("[WiFi] 連線中斷，嘗試重連");
    WiFi.reconnect();
  }
  was_connected = connected;

  ui_dashboard_set_status(connected,
                          connected ? WiFi.localIP().toString().c_str() : NULL,
                          g_client_linked);
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
