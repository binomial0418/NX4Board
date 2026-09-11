// ─────────────────────────────────────────────────────────────────────────
// NX4Board ESP32-P4 車載儀表顯示器
//
// 硬體：Waveshare ESP32-P4-WIFI6-Touch-LCD-5
//       （ESP32-P4 + HX8394 MIPI DSI 720x1280 2-lane + GT911 觸控）
//       面板原生是直向，車上橫著裝，因此 LVGL 以 1280x720 繪圖，
//       flush 時由 PPA 做 90 度硬體旋轉寫進 DPI framebuffer。
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
#include <Preferences.h>

#include "driver/i2c_master.h"
#include "driver/ppa.h"
#include "lvgl.h"

#include "config.h"
#include "pins_config.h"
#include "src/lcd/hx8394_lcd.h"
#include "src/touch/gt911_touch.h"
#include "ui_dashboard.h"
#include "ui_settings.h"

// ── 顯示與觸控 ──────────────────────────────────────────────────────────
bsp_lcd_handles_t lcd_panels;
hx8394_lcd lcd = hx8394_lcd(LCD_RST);
gt911_touch touch = gt911_touch(TP_I2C_SDA, TP_I2C_SCL, TP_RST, TP_INT);

static lv_disp_draw_buf_t draw_buf;
static lv_color_t *buf;
static lv_color_t *buf1;

// ── 螢幕旋轉 ────────────────────────────────────────────────────────────
// 面板實體 720x1280（直向），LVGL 畫的是 1280x720（橫向）。
// 90  = 逆時針 90 度：面板的排線側朝畫面右邊
// 270 = 順時針 90 度：面板的排線側朝畫面左邊
// 實機裝上去發現上下顛倒就改成另一個值，觸控座標會跟著一起翻。
#define DISP_ROTATION 90

static ppa_client_handle_t s_ppa = NULL;
static void *s_fb = NULL;

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
// PPA（Pixel Processing Accelerator）把 LVGL 畫好的橫向區塊旋轉 90 度，
// 直接寫進 DPI 的 framebuffer。面板是 video mode、持續掃描 framebuffer，
// 所以寫進去就等於上畫面，不需要 esp_lcd_panel_draw_bitmap，也不需要
// on_color_trans_done 回呼——PPA 用 blocking 模式，回來時就已經寫完了。
//
// 座標推導（以 90 度逆時針為例，W = LCD_H_RES = 1280）：
//   面板 x = LVGL y，面板 y = W - 1 - LVGL x
// 所以輸出區塊左上角是 (y1, W - 1 - x2)。
void my_disp_flush(lv_disp_drv_t *disp, const lv_area_t *area,
                   lv_color_t *color_p) {
  const uint32_t w = area->x2 - area->x1 + 1;
  const uint32_t h = area->y2 - area->y1 + 1;

  ppa_srm_oper_config_t op = {};
  op.in.buffer = color_p;
  op.in.pic_w = w;
  op.in.pic_h = h;
  op.in.block_w = w;
  op.in.block_h = h;
  op.in.block_offset_x = 0;
  op.in.block_offset_y = 0;
  op.in.srm_cm = PPA_SRM_COLOR_MODE_RGB565;

  op.out.buffer = s_fb;
  op.out.buffer_size = (uint32_t)PANEL_H_RES * PANEL_V_RES * sizeof(uint16_t);
  op.out.pic_w = PANEL_H_RES;
  op.out.pic_h = PANEL_V_RES;
  op.out.srm_cm = PPA_SRM_COLOR_MODE_RGB565;

#if DISP_ROTATION == 90
  op.rotation_angle = PPA_SRM_ROTATION_ANGLE_90;
  op.out.block_offset_x = area->y1;
  op.out.block_offset_y = LCD_H_RES - 1 - area->x2;
#else
  op.rotation_angle = PPA_SRM_ROTATION_ANGLE_270;
  op.out.block_offset_x = PANEL_H_RES - 1 - area->y2;
  op.out.block_offset_y = area->x1;
#endif

  op.scale_x = 1.0f;
  op.scale_y = 1.0f;
  op.mode = PPA_TRANS_MODE_BLOCKING;

  esp_err_t err = ppa_do_scale_rotate_mirror(s_ppa, &op);
  if (err != ESP_OK) {
    Serial.printf("[PPA] 旋轉失敗 err=%d area=(%d,%d)-(%d,%d)\n", (int)err,
                  (int)area->x1, (int)area->y1, (int)area->x2, (int)area->y2);
  }

  g_flush_count++;
  lv_disp_flush_ready(disp);
}

// PPA 對區塊的起點與長寬有對齊要求，LVGL 預設會給任意大小的髒區域。
// 一律往外補到 4 的倍數最省事：1280 與 720 都能被 4 整除，補完不會出界。
static void my_rounder(lv_disp_drv_t *disp, lv_area_t *area) {
  area->x1 &= ~0x3;
  area->y1 &= ~0x3;
  area->x2 |= 0x3;
  area->y2 |= 0x3;
  if (area->x2 > LCD_H_RES - 1) area->x2 = LCD_H_RES - 1;
  if (area->y2 > LCD_V_RES - 1) area->y2 = LCD_V_RES - 1;
}

void my_touchpad_read(lv_indev_drv_t *indev_driver, lv_indev_data_t *data) {
  static bool was_pressed = false;
  // GT911 回報的是面板原生的直向座標（0..719, 0..1279），
  // 這裡套用 my_disp_flush() 旋轉的反函數換回 LVGL 的橫向座標。
  uint16_t rawX, rawY;
  bool touched = touch.getTouch(&rawX, &rawY);

#if DISP_ROTATION == 90
  const int16_t lvX = (int16_t)(LCD_H_RES - 1 - rawY);
  const int16_t lvY = (int16_t)rawX;
#else
  const int16_t lvX = (int16_t)rawY;
  const int16_t lvY = (int16_t)(PANEL_H_RES - 1 - rawX);
#endif

  if (!touched) {
    data->state = LV_INDEV_STATE_REL;
  } else {
    data->state = LV_INDEV_STATE_PR;
    data->point.x = lvX;
    data->point.y = lvY;
  }

  // 只在按下的瞬間記錄一次，方便從序列埠確認觸控有沒有作用。
  // 原始與換算後的座標都印，觸控歪掉時才分得出是驅動還是旋轉的問題。
  if (touched && !was_pressed) {
    Serial.printf("[TOUCH] raw=(%u,%u) lvgl=(%d,%d)\n", rawX, rawY, lvX, lvY);
  }
  was_pressed = touched;
}

// ─────────────────────────────────────────────────────────────────────────
// WebSocket
// ─────────────────────────────────────────────────────────────────────────
/// 套用螢幕背光（HX8394 板以 GPIO26 的 LEDC PWM 控制，5 kHz / 10-bit）
static void applyBrightness(int percent) {
  if (percent < 0) percent = 0;
  if (percent > 100) percent = 100;
  if (percent == g_brightness) return;

  g_brightness = percent;
  lcd.example_bsp_set_lcd_backlight((uint32_t)percent);
  ui_dashboard_set_brightness(percent);
  Serial.printf("[BRT] 螢幕亮度 -> %d%%\n", percent);
}

// 診斷：記錄手機端「曾經送過」哪些欄位。手機 App 版本較舊時會缺欄位，
// 而缺欄位在協定上是合法的（沿用舊值），畫面上看起來就像「不會更新」。
static uint32_t g_seen_fields = 0;
static bool g_log_next_payload = false;

#define FIELD_ODO (1 << 0)
#define FIELD_TIME (1 << 1)
#define FIELD_DATE (1 << 2)
#define FIELD_TURBO (1 << 3)
#define FIELD_LIGHTS (1 << 4)
#define FIELD_BRIGHT (1 << 5)

static void handleDashPayload(uint8_t *payload, size_t length) {
  // 連線後的第一筆原樣印出，直接看得到手機到底送了什麼
  if (g_log_next_payload) {
    g_log_next_payload = false;
    Serial.printf("[WS-RAW] (%u bytes) %.*s\n", (unsigned)length,
                  (int)(length > 400 ? 400 : length), (const char *)payload);
  }

  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, payload, length);
  if (err) {
    Serial.printf("[WS] JSON 解析失敗: %s\n", err.c_str());
    return;
  }

  if (!doc["odo"].isNull()) g_seen_fields |= FIELD_ODO;
  if (!doc["time"].isNull()) g_seen_fields |= FIELD_TIME;
  if (!doc["date"].isNull()) g_seen_fields |= FIELD_DATE;
  if (!doc["turbo"].isNull()) g_seen_fields |= FIELD_TURBO;
  if (!doc["lights"].isNull()) g_seen_fields |= FIELD_LIGHTS;
  if (!doc["brightness"].isNull()) g_seen_fields |= FIELD_BRIGHT;

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
      g_seen_fields = 0;
      g_log_next_payload = true;
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
// ─────────────────────────────────────────────────────────────────────────
// WiFi 憑證
//
// 以 NVS 儲存的為優先，沒有才回退到 config.h。這樣螢幕上設定過之後，
// 重新燒錄韌體也不會被 config.h 蓋掉。
// ─────────────────────────────────────────────────────────────────────────
static Preferences g_prefs;
static String g_ssid;
static String g_pass;
static bool g_scan_pending = false;

static void loadCredentials() {
  g_prefs.begin("nx4wifi", true);
  g_ssid = g_prefs.getString("ssid", "");
  g_pass = g_prefs.getString("pass", "");
  g_prefs.end();

  if (g_ssid.isEmpty()) {
    g_ssid = WIFI_SSID;
    g_pass = WIFI_PASS;
    Serial.printf("[WiFi] 使用 config.h 的設定: %s\n", g_ssid.c_str());
  } else {
    Serial.printf("[WiFi] 使用已儲存的設定: %s\n", g_ssid.c_str());
  }
}

static void saveCredentials(const char *ssid, const char *pass) {
  g_prefs.begin("nx4wifi", false);
  g_prefs.putString("ssid", ssid);
  g_prefs.putString("pass", pass);
  g_prefs.end();
}

/// 設定面板按下「儲存並連線」
static void onSettingsApply(const char *ssid, const char *pass) {
  Serial.printf("[WiFi] 套用新設定: %s\n", ssid);
  saveCredentials(ssid, pass);
  g_ssid = ssid;
  g_pass = pass;

  WiFi.disconnect();
  WiFi.begin(g_ssid.c_str(), g_pass.c_str());
  ui_dashboard_set_ssid(g_ssid.c_str());
}

/// 設定面板按下「掃描」。WiFi.scanNetworks(true) 為非阻塞，
/// 結果在 serviceScan() 內取回，避免卡住 LVGL 的更新迴圈。
static void onSettingsScan() {
  if (g_scan_pending) return;
  WiFi.scanDelete();
  WiFi.scanNetworks(true);
  g_scan_pending = true;
}

static void serviceScan() {
  if (!g_scan_pending) return;
  int n = WiFi.scanComplete();
  if (n == WIFI_SCAN_RUNNING) return;

  g_scan_pending = false;
  if (n < 0) {
    ui_settings_set_status("掃描失敗");
    return;
  }
  if (n == 0) {
    ui_settings_set_status("找不到網路");
    return;
  }

  ui_settings_clear_networks();
  if (n > 20) n = 20; // 清單塞得下就好
  for (int i = 0; i < n; i++) {
    ui_settings_add_network(WiFi.SSID(i).c_str(), WiFi.RSSI(i),
                            WiFi.encryptionType(i) != WIFI_AUTH_OPEN);
  }
  char buf[32];
  snprintf(buf, sizeof(buf), "%d", n);
  ui_settings_set_status(buf);
  WiFi.scanDelete();
}

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
      if (ui_settings_is_open()) ui_settings_set_status("連線失敗");
      break;
    case ARDUINO_EVENT_WIFI_STA_GOT_IP:
      Serial.printf("[WiFi] 取得 IP: %s\n", WiFi.localIP().toString().c_str());
      if (ui_settings_is_open()) ui_settings_set_status("已連線");
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

  WiFi.begin(g_ssid.c_str(), g_pass.c_str());
  Serial.printf("[WiFi] 連線中: %s\n", g_ssid.c_str());
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
    // 掃描進行中則跳過，重連會中斷掃描。
    if (!g_scan_pending && now - last_retry >= 10000) {
      last_retry = now;
      Serial.printf("[WiFi] 未連線 (status=%d)，重試 %s\n", (int)WiFi.status(),
                    g_ssid.c_str());
      WiFi.disconnect();
      WiFi.begin(g_ssid.c_str(), g_pass.c_str());
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

    // 只要有 client 就檢查欄位齊不齊，缺哪個直接點名
    if (webSocket.connectedClients() > 0) {
      Serial.printf("[FIELD] odo=%c time=%c date=%c turbo=%c lights=%c bright=%c",
                    (g_seen_fields & FIELD_ODO) ? 'Y' : 'N',
                    (g_seen_fields & FIELD_TIME) ? 'Y' : 'N',
                    (g_seen_fields & FIELD_DATE) ? 'Y' : 'N',
                    (g_seen_fields & FIELD_TURBO) ? 'Y' : 'N',
                    (g_seen_fields & FIELD_LIGHTS) ? 'Y' : 'N',
                    (g_seen_fields & FIELD_BRIGHT) ? 'Y' : 'N');
      if ((g_seen_fields & (FIELD_ODO | FIELD_TIME | FIELD_DATE)) !=
          (FIELD_ODO | FIELD_TIME | FIELD_DATE)) {
        Serial.print("   <- 手機 App 版本可能過舊，缺少的欄位不會更新");
      }
      Serial.println();
    }
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

  s_fb = lcd.get_frame_buffer();
  assert(s_fb);

  // PPA：負責把橫向的 LVGL 區塊旋轉 90 度貼進直向的 framebuffer。
  // 沒有它就只能靠 LVGL 的 sw_rotate 用 CPU 搬，FPS 會掉很多。
  ppa_client_config_t ppa_cfg = {};
  ppa_cfg.oper_type = PPA_OPERATION_SRM;
  ppa_cfg.max_pending_trans_num = 1;
  ESP_ERROR_CHECK(ppa_register_client(&ppa_cfg, &s_ppa));

  // LVGL 初始化：雙緩衝置於 PSRAM。
  // PPA 的來源緩衝要對齊到快取行，所以用 aligned_alloc 而非 malloc。
  lv_init();
  size_t buffer_size = sizeof(int16_t) * LCD_H_RES * LCD_V_RES;
  buf = (lv_color_t *)heap_caps_aligned_alloc(64, buffer_size, MALLOC_CAP_SPIRAM);
  buf1 = (lv_color_t *)heap_caps_aligned_alloc(64, buffer_size, MALLOC_CAP_SPIRAM);
  assert(buf);
  assert(buf1);
  lv_disp_draw_buf_init(&draw_buf, buf, buf1, LCD_H_RES * LCD_V_RES);

  static lv_disp_drv_t disp_drv;
  lv_disp_drv_init(&disp_drv);
  disp_drv.hor_res = LCD_H_RES;
  disp_drv.ver_res = LCD_V_RES;
  disp_drv.flush_cb = my_disp_flush;
  disp_drv.rounder_cb = my_rounder;
  disp_drv.draw_buf = &draw_buf;
  // 局部刷新：只送出有變動的區域，配合「僅更新物件數值」達成 60 FPS
  disp_drv.full_refresh = false;
  lv_disp_drv_register(&disp_drv);

  static lv_indev_drv_t indev_drv;
  lv_indev_drv_init(&indev_drv);
  indev_drv.type = LV_INDEV_TYPE_POINTER;
  indev_drv.read_cb = my_touchpad_read;
  lv_indev_drv_register(&indev_drv);

  ui_dashboard_create();
  // 不在此呼叫 ui_dashboard_update()：那會把全 0 的初始結構畫上去，
  // 讓畫面在還沒收到任何資料時就顯示 0 km/h、EV 等看似真實的狀態。
  // 保留各 label 建立時的 "--"，第一筆資料抵達時自然會 force 全面更新。
  ui_settings_set_callbacks(onSettingsApply, onSettingsScan);
  loadCredentials();
  ui_dashboard_set_ssid(g_ssid.c_str());

  char geo[160];
  ui_settings_debug_geometry(geo, sizeof(geo));
  Serial.printf("[UI] 設定面板 %s\n", geo);
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
  serviceScan();

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
