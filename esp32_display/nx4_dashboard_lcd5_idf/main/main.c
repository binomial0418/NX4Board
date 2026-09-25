// ─────────────────────────────────────────────────────────────────────────
// NX4Board ESP32-P4 車載儀表顯示器（ESP-IDF 版）
//
// 硬體：Waveshare ESP32-P4-WIFI6-Touch-LCD-5
//       （ESP32-P4 + HX8394 MIPI DSI 720x1280 2-lane + GT911 觸控）
//       面板原生是直向，車上橫著裝，因此 LVGL 以 1280x720 繪圖，
//       flush 時由 PPA 做 90 度硬體旋轉寫進 DPI framebuffer。
// 角色：WiFi STA + WebSocket Server，接收 NX4Board App 第二通道推送的
//       esp32_dash JSON，以 LVGL 即時渲染車載儀表。
//
// 與 Arduino 版（../nx4_dashboard_lcd5）共用同一份 UI、驅動與字型，
// 差別只在平台層：WiFi 走 esp_wifi、WebSocket 走 esp_http_server、
// 設定走 nvs_flash、JSON 走 cJSON。改用 ESP-IDF 的理由見 main/idf_component.yml。
//
// 資料協定（手機 → 本機，見 lib/screens/dashboard_screen.dart）：
// {
//   "_type": "esp32_dash",
//   "speed": 75, "rpm": 1750, "coolant": 88, "soc": 65.5,
//   "fuel": 50, "speed_limit": 90, "limit_alt": 60, "limit_alt_above": false,
//   "odo": 33676, "turbo": 0.15, "throttle": 12, "reversing": false,
//   "time": "18:04:37", "date": "09/01 週一",
//   "tires": {"fl": 34, "fr": 34, "rl": 33, "rr": 33},
//   "camera": {"active": true, "limit": 90},
//   "lights": {"low": true, "high": false},
//   "doors": {"open": false, "unlocked": false, "trunk": false},
//   "brightness": 40
// }
//
// 執行緒模型：**所有 LVGL 呼叫都只在 app_main 這個任務裡。** httpd 有自己的
// 任務，它只負責把最新一筆封包放進單槽緩衝（見 nx4_ws.c），解析與渲染都留在
// 主迴圈，因此不需要為 LVGL 上鎖。
// ─────────────────────────────────────────────────────────────────────────

#include <stdio.h>
#include <string.h>

#include "cJSON.h"
#include "driver/i2c_master.h"
#include "driver/ppa.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lvgl.h"

#include "config.h"
#include "pins_config.h"
#include "nx4_lcd_c.h"
#include "nx4_touch_c.h"
#include "nx4_wifi.h"
#include "nx4_ws.h"
#include "ui_dashboard.h"
#include "ui_settings.h"

// 診斷用：設成 0 可編出完全不初始化音訊的版本，用來排除 I2S/ES8311
// 對網路堆疊的干擾。正常版本必須是 1。
#ifndef NX4_ENABLE_AUDIO
#define NX4_ENABLE_AUDIO 1
#endif
#include "nx4_tts.h"
#include "nx4_ble.h"

// ── 螢幕旋轉 ────────────────────────────────────────────────────────────
// 面板實體 720x1280（直向），LVGL 畫的是 1280x720（橫向）。
// 90  = 逆時針 90 度：面板的排線側朝畫面右邊
// 270 = 順時針 90 度：面板的排線側朝畫面左邊
// 實機裝上去發現上下顛倒就改成另一個值，觸控座標會跟著一起翻。
#define DISP_ROTATION 270

static ppa_client_handle_t s_ppa = NULL;
static void *s_fb = NULL;

static lv_disp_draw_buf_t s_draw_buf;
static lv_color_t *s_buf;
static lv_color_t *s_buf1;

// ── 共享狀態 ────────────────────────────────────────────────────────────
static nx4_dash_data_t g_dash;
static bool     g_dash_dirty = false;
static int64_t  g_last_data_ms = 0;
static uint32_t g_flush_count = 0;

// 背光：只有數值變動時才呼叫 LEDC，避免每筆推送都重設 duty
static int      g_brightness = 100;
static int64_t  g_brightness_hold_until = 0;
static int      g_volume = -1;

/// 取代 Arduino 的 millis()
static inline int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

// ─────────────────────────────────────────────────────────────────────────
// LVGL 顯示驅動
// ─────────────────────────────────────────────────────────────────────────
// PPA（Pixel Processing Accelerator）把 LVGL 畫好的橫向區塊旋轉 90 度，
// 直接寫進 DPI 的 framebuffer。面板是 video mode、持續掃描 framebuffer，
// 所以寫進去就等於上畫面，不需要 esp_lcd_panel_draw_bitmap，也不需要
// on_color_trans_done 回呼——PPA 用 blocking 模式，回來時就已經寫完了。
//
// 座標推導（以 90 度逆時針為例，W = LCD_H_RES = 1280）：
//   面板 x = LVGL y，面板 y = W - 1 - LVGL x
// 所以輸出區塊左上角是 (y1, W - 1 - x2)。
static void my_disp_flush(lv_disp_drv_t *disp, const lv_area_t *area,
                          lv_color_t *color_p) {
    const uint32_t w = area->x2 - area->x1 + 1;
    const uint32_t h = area->y2 - area->y1 + 1;

    ppa_srm_oper_config_t op = {0};
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
        printf("[PPA] 旋轉失敗 err=%d area=(%d,%d)-(%d,%d)\n", (int)err,
               (int)area->x1, (int)area->y1, (int)area->x2, (int)area->y2);
    }

    g_flush_count++;
    lv_disp_flush_ready(disp);
}

// PPA 對區塊的起點與長寬有對齊要求，LVGL 預設會給任意大小的髒區域。
// 一律往外補到 4 的倍數最省事：1280 與 720 都能被 4 整除，補完不會出界。
static void my_rounder(lv_disp_drv_t *disp, lv_area_t *area) {
    (void)disp;
    area->x1 &= ~0x3;
    area->y1 &= ~0x3;
    area->x2 |= 0x3;
    area->y2 |= 0x3;
    if (area->x2 > LCD_H_RES - 1) area->x2 = LCD_H_RES - 1;
    if (area->y2 > LCD_V_RES - 1) area->y2 = LCD_V_RES - 1;
}

static void my_touchpad_read(lv_indev_drv_t *indev_driver,
                             lv_indev_data_t *data) {
    (void)indev_driver;
    static bool was_pressed = false;
    // GT911 回報的是面板原生的直向座標（0..719, 0..1279），
    // 這裡套用 my_disp_flush() 旋轉的反函數換回 LVGL 的橫向座標。
    uint16_t rawX = 0, rawY = 0;
    bool touched = nx4_touch_read(&rawX, &rawY);

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
        printf("[TOUCH] raw=(%u,%u) lvgl=(%d,%d)\n", rawX, rawY, lvX, lvY);
    }
    was_pressed = touched;
}

// ─────────────────────────────────────────────────────────────────────────
// 封包解析
// ─────────────────────────────────────────────────────────────────────────
/// 套用螢幕背光（HX8394 板以 GPIO26 的 LEDC PWM 控制，5 kHz / 10-bit）
static void applyBrightness(int percent) {
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    if (percent == g_brightness) return;

    g_brightness = percent;
    nx4_lcd_set_backlight((uint32_t)percent);
    ui_dashboard_set_brightness(percent);
    printf("[BRT] 螢幕亮度 -> %d%%\n", percent);
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
#define FIELD_DOORS (1 << 6)
#define FIELD_THROTTLE (1 << 7)
#define FIELD_REVERSING (1 << 8)

// cJSON 的取值輔助。ArduinoJson 的 `doc["x"] | fallback` 語法在 C 裡沒有
// 對應寫法，這幾個小函式就是它的替代品：欄位不存在或型別不符時回傳預設值。
static int j_int(const cJSON *o, const char *k, int dflt) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, k);
    return cJSON_IsNumber(v) ? (int)v->valuedouble : dflt;
}
static float j_float(const cJSON *o, const char *k, float dflt) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, k);
    return cJSON_IsNumber(v) ? (float)v->valuedouble : dflt;
}
static bool j_bool(const cJSON *o, const char *k, bool dflt) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, k);
    if (cJSON_IsBool(v)) return cJSON_IsTrue(v);
    if (cJSON_IsNumber(v)) return v->valuedouble != 0;
    return dflt;
}
static const char *j_str(const cJSON *o, const char *k) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, k);
    return cJSON_IsString(v) ? v->valuestring : NULL;
}
static bool j_has(const cJSON *o, const char *k) {
    return cJSON_GetObjectItemCaseSensitive(o, k) != NULL;
}

static void handleDashPayload(const char *payload, size_t length) {
    // 連線後的第一筆原樣印出，直接看得到手機到底送了什麼
    if (g_log_next_payload) {
        g_log_next_payload = false;
        printf("[WS-RAW] (%u bytes) %.*s\n", (unsigned)length,
               (int)(length > 400 ? 400 : length), payload);
    }

    cJSON *doc = cJSON_ParseWithLength(payload, length);
    if (!doc) {
        printf("[WS] JSON 解析失敗\n");
        return;
    }

    if (j_has(doc, "odo")) g_seen_fields |= FIELD_ODO;
    if (j_has(doc, "time")) g_seen_fields |= FIELD_TIME;
    if (j_has(doc, "date")) g_seen_fields |= FIELD_DATE;
    if (j_has(doc, "turbo")) g_seen_fields |= FIELD_TURBO;
    if (j_has(doc, "lights")) g_seen_fields |= FIELD_LIGHTS;
    if (j_has(doc, "brightness")) g_seen_fields |= FIELD_BRIGHT;
    if (j_has(doc, "doors")) g_seen_fields |= FIELD_DOORS;
    if (j_has(doc, "throttle")) g_seen_fields |= FIELD_THROTTLE;
    if (j_has(doc, "reversing")) g_seen_fields |= FIELD_REVERSING;

    // 只處理本機認得的協定，其餘（例如第一通道的 BVB-7980）直接忽略
    const char *type = j_str(doc, "_type");
    if (!type || strcmp(type, "esp32_dash") != 0) {
        printf("[WS] 忽略非 esp32_dash 封包: %s\n", type ? type : "(無)");
        cJSON_Delete(doc);
        return;
    }

    // 缺欄位時保留上一次的值，避免畫面跳動
    g_dash.speed = j_int(doc, "speed", g_dash.speed);
    g_dash.rpm = j_int(doc, "rpm", g_dash.rpm);
    g_dash.coolant = j_int(doc, "coolant", g_dash.coolant);
    g_dash.soc = j_float(doc, "soc", g_dash.soc);
    g_dash.fuel = j_int(doc, "fuel", g_dash.fuel);
    g_dash.speed_limit = j_int(doc, "speed_limit", g_dash.speed_limit);
    // 缺欄位時歸零，避免沿用上一包的舊值（判定恢復有把握後 ALT 才會消失）
    g_dash.limit_alt = j_int(doc, "limit_alt", 0);
    g_dash.limit_alt_above = j_bool(doc, "limit_alt_above", false);
    g_dash.odo = j_int(doc, "odo", g_dash.odo);
    g_dash.turbo = j_float(doc, "turbo", g_dash.turbo);
    // 節氣門：0 是合法讀數，所以沿用上一次的值而不是 0
    g_dash.throttle = j_int(doc, "throttle", g_dash.throttle);

    const char *clock = j_str(doc, "time");
    if (clock && clock[0]) {
        strncpy(g_dash.clock, clock, sizeof(g_dash.clock) - 1);
        g_dash.clock[sizeof(g_dash.clock) - 1] = '\0';
    }
    const char *date = j_str(doc, "date");
    if (date && date[0]) {
        strncpy(g_dash.date, date, sizeof(g_dash.date) - 1);
        g_dash.date[sizeof(g_dash.date) - 1] = '\0';
    }

    const cJSON *tires = cJSON_GetObjectItemCaseSensitive(doc, "tires");
    if (cJSON_IsObject(tires)) {
        g_dash.tire_fl = j_int(tires, "fl", g_dash.tire_fl);
        g_dash.tire_fr = j_int(tires, "fr", g_dash.tire_fr);
        g_dash.tire_rl = j_int(tires, "rl", g_dash.tire_rl);
        g_dash.tire_rr = j_int(tires, "rr", g_dash.tire_rr);
    }

    const cJSON *camera = cJSON_GetObjectItemCaseSensitive(doc, "camera");
    if (cJSON_IsObject(camera)) {
        g_dash.camera_active = j_bool(camera, "active", false);
        g_dash.camera_limit = j_int(camera, "limit", 0);
    }

    // 倒車：缺欄位時視為非倒車。舊版 App 不送這個欄位，沿用上次值會卡在 R。
    g_dash.reversing = j_bool(doc, "reversing", false);

    const cJSON *lights = cJSON_GetObjectItemCaseSensitive(doc, "lights");
    if (cJSON_IsObject(lights)) {
        g_dash.low_beam = j_bool(lights, "low", false);
        g_dash.high_beam = j_bool(lights, "high", false);
    }

    // 語音試聽鉤子：{"tts_say": "代號"} 直接播一段音檔（代號見 nx4_voice_clips.c），
    // {"tts_lead": 毫秒} 調開頭靜音。
    // 純粹是調音用的，儀表 App 不會送這兩個欄位。
    if (j_has(doc, "tts_lead")) nx4_tts_set_lead_in_ms(j_int(doc, "tts_lead", 400));
    const char *tts_say = j_str(doc, "tts_say");
    if (tts_say && *tts_say) nx4_tts_say(tts_say);

    // 語音播報：只在狀態翻轉的那一刻念一次。第二通道每 200ms 推一次，
    // 若照 g_dash 現值判斷會變成每包都念。
    static bool s_said_high_beam = false;
    static bool s_said_camera = false;
    if (g_dash.high_beam != s_said_high_beam) {
        s_said_high_beam = g_dash.high_beam;
        nx4_tts_high_beam(s_said_high_beam);
    }
    if (g_dash.camera_active && !s_said_camera) {
        nx4_tts_camera_alert(g_dash.camera_limit);
    }
    s_said_camera = g_dash.camera_active;

    // 車門 / 門鎖 / 後車廂 → 右側指示燈條的後三格。
    // 整個 doors 物件缺席時沿用上一次的值（協定上合法，見 [FIELD] 診斷）；
    // 物件在但某個鍵缺席時視為 false，因為「沒送」就代表沒有該警示。
    const cJSON *doors = cJSON_GetObjectItemCaseSensitive(doc, "doors");
    if (cJSON_IsObject(doors)) {
        g_dash.door_open = j_bool(doors, "open", false);
        g_dash.door_unlocked = j_bool(doors, "unlocked", false);
        g_dash.trunk_open = j_bool(doors, "trunk", false);
    }

    // 亮度：帶 brightness_hold_ms 的（設定頁測試按鈕）優先，並在該期間
    // 忽略儀表推送的亮度，否則 200ms 一次的推送會馬上把測試值蓋掉
    if (j_has(doc, "brightness")) {
        int hold = j_int(doc, "brightness_hold_ms", 0);
        if (hold > 0) {
            g_brightness_hold_until = now_ms() + hold;
            applyBrightness(j_int(doc, "brightness", g_brightness));
        } else if (now_ms() >= g_brightness_hold_until) {
            applyBrightness(j_int(doc, "brightness", g_brightness));
        }
    }

    cJSON_Delete(doc);
    g_dash_dirty = true;
    g_last_data_ms = now_ms();
}

// ─────────────────────────────────────────────────────────────────────────
// 設定面板的 callback（都在 LVGL 任務裡執行）
// ─────────────────────────────────────────────────────────────────────────
static void onSettingsApply(const char *ssid, const char *pass) {
    nx4_wifi_apply(ssid, pass);
    ui_dashboard_set_ssid(nx4_wifi_ssid());
}

static void onSettingsScan(void) { nx4_wifi_scan_start(); }

/// 音量滑桿放開：套用、存檔、播一段測試音讓使用者當場聽到。
static void onSettingsVolume(int volume) {
    nx4_tts_set_volume(volume);
    nx4_nvs_save_volume(volume);
    printf("[語音] 音量 %d%%\n", volume);
    nx4_tts_say("boot");   // 「系統啟動」，長度適中，拿來當試聽音
}

static void serviceScan(void) {
    if (!nx4_wifi_scan_busy()) return;
    static nx4_ap_t aps[20];
    int n = nx4_wifi_scan_take(aps, 20);
    if (n == -1) return;            // 還在掃
    if (n == -2) { ui_settings_set_status("掃描失敗"); return; }
    if (n == 0) { ui_settings_set_status("找不到網路"); return; }

    ui_settings_clear_networks();
    for (int i = 0; i < n; i++) {
        ui_settings_add_network(aps[i].ssid, aps[i].rssi, aps[i].locked);
    }
    char buf[32];
    snprintf(buf, sizeof(buf), "%d", n);
    ui_settings_set_status(buf);
}

/// 每秒檢查一次連線狀態並更新狀態列，斷線時自動重連
static void serviceWifi(void) {
    static int64_t last_check = 0;
    static bool was_connected = false;

    int64_t now = now_ms();
    if (now - last_check < 1000) return;
    last_check = now;

    bool connected = nx4_wifi_service();
    if (connected && !was_connected) {
        printf("[WiFi] 已連線，IP: %s\n", nx4_wifi_ip());
        printf("[WS] Server 啟動於 port %d\n", WS_PORT);
    }
    was_connected = connected;

    ui_dashboard_set_status(connected, nx4_wifi_ip(), nx4_ws_clients() > 0);

    // 心跳：每 10 秒印一次現況，方便在車上以序列埠確認裝置是否還活著
    static int64_t last_beat = 0;
    if (now - last_beat >= 10000) {
        int64_t span = now - last_beat;
        last_beat = now;
        int64_t age = (g_last_data_ms == 0) ? 0 : (now - g_last_data_ms);
        uint32_t fps = (uint32_t)((g_flush_count * 1000) / (span > 0 ? span : 1));
        g_flush_count = 0;
        printf("[HB] WiFi=%s IP=%s rssi=%ddBm ps=%s clients=%d lastData=%lldms "
               "BRT=%d%% fps=%lu speed=%d rpm=%d low=%d high=%d\n",
               connected ? "up" : "down", connected ? nx4_wifi_ip() : "-",
               // 訊號強度：收不到資料時第一個要看的就是這個。P4 本身沒有射頻，
               // 網路全部經由 ESP32-C6 副處理器轉送，鏈路品質差會表現成
               // 「連線還在、但 lastData 一路累積」而不是斷線。
               connected ? nx4_wifi_rssi() : 0,
               (connected && nx4_wifi_ps_on()) ? "on" : "off",
               nx4_ws_clients(), (long long)age, g_brightness,
               (unsigned long)fps, g_dash.speed, g_dash.rpm,
               g_dash.low_beam, g_dash.high_beam);

        // 只要有 client 就檢查欄位齊不齊，缺哪個直接點名
        if (nx4_ws_clients() > 0) {
            printf("[FIELD] odo=%c time=%c date=%c turbo=%c lights=%c bright=%c "
                   "doors=%c thr=%c rev=%c",
                   (g_seen_fields & FIELD_ODO) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_TIME) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_DATE) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_TURBO) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_LIGHTS) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_BRIGHT) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_DOORS) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_THROTTLE) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_REVERSING) ? 'Y' : 'N');
            if ((g_seen_fields & (FIELD_ODO | FIELD_TIME | FIELD_DATE)) !=
                (FIELD_ODO | FIELD_TIME | FIELD_DATE)) {
                printf("   <- 手機 App 版本可能過舊，缺少的欄位不會更新");
            }
            printf("\n");
        }
    }
}

/// 暫時的 BLE 收包探針，只把 dongle 吐回來的東西印出來。
static void ble_rx_probe(const uint8_t *data, size_t len) {
    printf("[BLE-RX] %.*s\n", (int)len, (const char *)data);
}

// ─────────────────────────────────────────────────────────────────────────
void app_main(void) {
    printf("\nNX4Board ESP32-P4 Dashboard (ESP-IDF)\n");

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
    ESP_ERROR_CHECK(i2c_new_master_bus(&i2c_bus_conf, &i2c_handle));

    // 語音（ES8311）。與觸控共用同一條 I2C 匯流排，
    // 所以必須在 i2c_new_master_bus() 之後、且不另開 I2C。
    // 失敗不影響儀表本身，播報呼叫會被安全忽略。
#if NX4_ENABLE_AUDIO
    // NVS 由 nx4_wifi_start() 初始化，但音量必須在 nx4_tts_init() 之前讀，
    // 所以這裡先把 NVS 叫起來（重複呼叫是安全的）。
    nx4_nvs_init_early();
    g_volume = nx4_nvs_load_volume();
    if (g_volume >= 0) nx4_tts_set_volume(g_volume);   // 必須在 init 之前
    nx4_tts_init(i2c_handle);
    if (g_volume < 0) g_volume = nx4_tts_get_volume(); // 沒存過就沿用預設
#endif

    nx4_lcd_begin();
    nx4_touch_begin();

    s_fb = nx4_lcd_frame_buffer();
    assert(s_fb);

    // PPA：負責把橫向的 LVGL 區塊旋轉 90 度貼進直向的 framebuffer。
    // 沒有它就只能靠 LVGL 的 sw_rotate 用 CPU 搬，FPS 會掉很多。
    ppa_client_config_t ppa_cfg = {0};
    ppa_cfg.oper_type = PPA_OPERATION_SRM;
    ppa_cfg.max_pending_trans_num = 1;
    ESP_ERROR_CHECK(ppa_register_client(&ppa_cfg, &s_ppa));

    // LVGL 初始化：雙緩衝置於 PSRAM。
    // PPA 的來源緩衝要對齊到快取行，所以用 aligned_alloc 而非 malloc。
    lv_init();
    size_t buffer_size = sizeof(int16_t) * LCD_H_RES * LCD_V_RES;
    s_buf = heap_caps_aligned_alloc(64, buffer_size, MALLOC_CAP_SPIRAM);
    s_buf1 = heap_caps_aligned_alloc(64, buffer_size, MALLOC_CAP_SPIRAM);
    assert(s_buf);
    assert(s_buf1);
    lv_disp_draw_buf_init(&s_draw_buf, s_buf, s_buf1, LCD_H_RES * LCD_V_RES);

    static lv_disp_drv_t disp_drv;
    lv_disp_drv_init(&disp_drv);
    disp_drv.hor_res = LCD_H_RES;
    disp_drv.ver_res = LCD_V_RES;
    disp_drv.flush_cb = my_disp_flush;
    disp_drv.rounder_cb = my_rounder;
    disp_drv.draw_buf = &s_draw_buf;
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
    ui_settings_set_callbacks(onSettingsApply, onSettingsScan, onSettingsVolume);
    ui_settings_set_volume(g_volume);

    nx4_wifi_start();
    ui_dashboard_set_ssid(nx4_wifi_ssid());

    char geo[160];
    ui_settings_debug_geometry(geo, sizeof(geo));
    printf("[UI] 設定面板 %s\n", geo);
    ui_dashboard_set_brightness(g_brightness);
    ui_dashboard_set_stale(true);

    ESP_ERROR_CHECK(nx4_ws_start(WS_PORT));

    // 開機提示音。放在最後，這時畫面與網路都已就緒，
    // 使用者聽到「系統啟動」時看到的也是可用的儀表。
    nx4_tts_say("boot");

    // TODO(直連OBD)：目前只是把 BLE 拉起來、把 dongle 回傳的位元組原樣印出，
    // 用來驗證 C6 的 BLE controller 走 ESP-Hosted VHCI 可用、且 18F0/2AF0/2AF1
    // 這組 UUID 在這顆 dongle 上正確。ELM 指令層與 PID 解析還沒接上。
    nx4_ble_start("IOS-VLINK", ble_rx_probe);

    printf("Setup done\n");

    static char rx[NX4_WS_BUF_SIZE];
    for (;;) {
        if (nx4_ws_take_connected_flag()) {
            g_seen_fields = 0;
            g_log_next_payload = true;
        }
        size_t n = nx4_ws_take(rx, sizeof(rx));
        if (n > 0) handleDashPayload(rx, n);

        serviceWifi();
        serviceScan();

        // 僅在有新資料時套用（只寫入 Label/Bar 數值，不重建物件）
        if (g_dash_dirty) {
            g_dash_dirty = false;
            ui_dashboard_update(&g_dash);
        }

        // 逾時未收到手機資料 → 淡化數值，避免誤讀舊值
        if (g_last_data_ms != 0 && now_ms() - g_last_data_ms > DATA_TIMEOUT_MS) {
            ui_dashboard_set_stale(true);
        }

        lv_timer_handler();
        vTaskDelay(pdMS_TO_TICKS(2));
    }
}
