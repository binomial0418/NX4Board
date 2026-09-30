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
//   "camera": {"active": true, "limit": 90, "kind": "speed", "passed": 3},
//              kind: speed / redLight / overpass / zoneStart / zoneEnd
//   "lights": {"low": true, "high": false, "position": true, "rear_fog": false},
//   "doors": {"open": false, "unlocked": false, "trunk": false},
//   "traffic": {"active": true, "alerts": 2, "sys": "P", "ref": "61", "km": 152.3,
//               "segs": [[0, 420, 78, 0], ...],
//               "jam": {"dist": 420, "len": 1400, "speed": 22, "level": 3,
//                       "via": {"sys": "P", "ref": "61", "dir": "S"}},
//               "ramp": {"sys": "P", "ref": "61",
//                        "dirs": [{"dir": "N", "level": 0, "speed": 85}]}},
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
#include "driver/uart.h"
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
#include "nx4_obd.h"

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

// 車輛資料來源。true = 直連 OBD。
//
// 兩個來源是並存的，不是二選一：板子上沒有 GPS 元件，所以速限、替代速限、
// 測速照相、時間日期、背光這些「GPS/手機才算得出來」的欄位，**不論哪個模式
// 都走 WebSocket**。直連 OBD 只是把車輛數值（車速、轉速、水溫、電池、油量、
// 里程、增壓、節氣門、胎壓、大燈、車門、倒車）的來源換成本機解析。
static bool g_obd_direct = false;
static char g_obd_name[NX4_OBD_NAME_LEN] = NX4_OBD_NAME_DEFAULT;

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
static int g_said_passed = -1;   // 已念過「通過」的累計次數，-1 = 尚無基準
static int g_said_alerts = -1;   // 已念過「注意前方路況」的累計次數，-1 = 尚無基準
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
#define FIELD_TRAFFIC (1 << 9)

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
    if (j_has(doc, "traffic")) g_seen_fields |= FIELD_TRAFFIC;

    // 只處理本機認得的協定，其餘（例如第一通道的 BVB-7980）直接忽略
    const char *type = j_str(doc, "_type");
    if (!type || strcmp(type, "esp32_dash") != 0) {
        printf("[WS] 忽略非 esp32_dash 封包: %s\n", type ? type : "(無)");
        cJSON_Delete(doc);
        return;
    }

    // ── GPS / 手機端算出來的欄位：兩個模式都採用 ─────────────────────
    // 板子上沒有 GPS 元件，速限、替代速限、測速照相都要靠手機的定位與圖資，
    // 時間日期與背光也是手機端決定的，所以這一段不受資料來源開關影響。
    g_dash.speed_limit = j_int(doc, "speed_limit", g_dash.speed_limit);
    // 缺欄位時歸零，避免沿用上一包的舊值（判定恢復有把握後 ALT 才會消失）
    g_dash.limit_alt = j_int(doc, "limit_alt", 0);
    g_dash.limit_alt_above = j_bool(doc, "limit_alt_above", false);

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

    const cJSON *camera = cJSON_GetObjectItemCaseSensitive(doc, "camera");
    if (cJSON_IsObject(camera)) {
        g_dash.camera_active = j_bool(camera, "active", false);
        g_dash.camera_limit = j_int(camera, "limit", 0);
        const char *kind = j_str(camera, "kind");
        g_dash.camera_kind = !kind                           ? NX4_CAM_SPEED
                           : strcmp(kind, "redLight") == 0 ? NX4_CAM_RED_LIGHT
                           : strcmp(kind, "overpass") == 0 ? NX4_CAM_OVERPASS
                           : strcmp(kind, "zoneEnd") == 0  ? NX4_CAM_ZONE_END
                           : strcmp(kind, "zoneStart") == 0 ? NX4_CAM_ZONE_START
                                                           : NX4_CAM_SPEED;
        g_dash.camera_passed = j_int(camera, "passed", -1);
    }

    // 前方路況（TDX）。traffic 整個缺席是舊版 App，維持不顯示；
    // 有 traffic 但沒有 jam 就是前方順暢或不在國道／快速公路上。
    // 閘道前預知時 active 為 false（還不在主線上），但 jam 帶 via，照樣顯示。
    const cJSON *traffic = cJSON_GetObjectItemCaseSensitive(doc, "traffic");
    if (cJSON_IsObject(traffic)) {
        g_dash.traffic_alerts = j_int(traffic, "alerts", -1);
        const cJSON *jam = cJSON_GetObjectItemCaseSensitive(traffic, "jam");
        g_dash.jam_active = cJSON_IsObject(jam);
        if (g_dash.jam_active) {
            g_dash.jam_dist = j_int(jam, "dist", 0);
            g_dash.jam_len = j_int(jam, "len", 0);
            g_dash.jam_speed = j_int(jam, "speed", 0);
            g_dash.jam_level = j_int(jam, "level", 3);
            const cJSON *via = cJSON_GetObjectItemCaseSensitive(jam, "via");
            g_dash.jam_via = cJSON_IsObject(via);
            if (g_dash.jam_via) {
                const char *sys = j_str(via, "sys");
                const char *ref = j_str(via, "ref");
                const char *dir = j_str(via, "dir");
                g_dash.via_sys = (sys && sys[0]) ? sys[0] : 'P';
                strncpy(g_dash.via_ref, ref ? ref : "", sizeof(g_dash.via_ref) - 1);
                g_dash.via_ref[sizeof(g_dash.via_ref) - 1] = '\0';
                g_dash.via_dir = (dir && dir[0]) ? dir[0] : ' ';
            }
        }
        // 閘道前預知、上去之後路況正常：同樣顯示（最多兩個方向）
        const cJSON *ramp = cJSON_GetObjectItemCaseSensitive(traffic, "ramp");
        const cJSON *dirs = cJSON_IsObject(ramp) ? cJSON_GetObjectItemCaseSensitive(ramp, "dirs") : NULL;
        g_dash.ramp_active = cJSON_IsArray(dirs) && cJSON_GetArraySize(dirs) > 0;
        if (g_dash.ramp_active) {
            const char *sys = j_str(ramp, "sys");
            const char *ref = j_str(ramp, "ref");
            g_dash.ramp_sys = (sys && sys[0]) ? sys[0] : 'P';
            strncpy(g_dash.ramp_ref, ref ? ref : "", sizeof(g_dash.ramp_ref) - 1);
            g_dash.ramp_ref[sizeof(g_dash.ramp_ref) - 1] = '\0';
            int n = 0;
            const cJSON *d;
            cJSON_ArrayForEach(d, dirs) {
                if (n >= 2) break;
                const char *dir = j_str(d, "dir");
                g_dash.ramp_dir[n] = (dir && dir[0]) ? dir[0] : ' ';
                g_dash.ramp_level[n] = j_int(d, "level", 0);
                g_dash.ramp_speed[n] = j_int(d, "speed", 0);
                n++;
            }
            g_dash.ramp_n = n;
        }
    }

    // ── 車輛數值：只有 WebSocket 模式才採用 ──────────────────────────
    // 直連 OBD 時這些由本機解析供應（見 obd_apply()），若不擋掉，
    // 200ms 一次的推送會把 OBD 讀到的值蓋掉。
    if (!g_obd_direct) {
        // 缺欄位時保留上一次的值，避免畫面跳動
        g_dash.speed = j_int(doc, "speed", g_dash.speed);
        g_dash.rpm = j_int(doc, "rpm", g_dash.rpm);
        g_dash.coolant = j_int(doc, "coolant", g_dash.coolant);
        g_dash.soc = j_float(doc, "soc", g_dash.soc);
        g_dash.fuel = j_int(doc, "fuel", g_dash.fuel);
        g_dash.odo = j_int(doc, "odo", g_dash.odo);
        g_dash.turbo = j_float(doc, "turbo", g_dash.turbo);
        // 節氣門：0 是合法讀數，所以沿用上一次的值而不是 0
        g_dash.throttle = j_int(doc, "throttle", g_dash.throttle);
        // 倒車：缺欄位時視為非倒車。舊版 App 不送，沿用上次值會卡在 R。
        g_dash.reversing = j_bool(doc, "reversing", false);

        const cJSON *tires = cJSON_GetObjectItemCaseSensitive(doc, "tires");
        if (cJSON_IsObject(tires)) {
            g_dash.tire_fl = j_int(tires, "fl", g_dash.tire_fl);
            g_dash.tire_fr = j_int(tires, "fr", g_dash.tire_fr);
            g_dash.tire_rl = j_int(tires, "rl", g_dash.tire_rl);
            g_dash.tire_rr = j_int(tires, "rr", g_dash.tire_rr);
        }

        const cJSON *lights = cJSON_GetObjectItemCaseSensitive(doc, "lights");
        if (cJSON_IsObject(lights)) {
            g_dash.low_beam = j_bool(lights, "low", false);
            g_dash.high_beam = j_bool(lights, "high", false);
            // 舊版 App 不送這兩個鍵，視為沒亮——與 doors 裡缺鍵的處理一致
            g_dash.position_lamp = j_bool(lights, "position", false);
            g_dash.rear_fog = j_bool(lights, "rear_fog", false);
        }

        // 車門 / 門鎖 / 後車廂 → 右側指示燈條的後三格。
        // 整個 doors 物件缺席時沿用上一次的值（協定上合法，見 [FIELD] 診斷）；
        // 物件在但某個鍵缺席時視為 false，因為「沒送」就代表沒有該警示。
        const cJSON *doors = cJSON_GetObjectItemCaseSensitive(doc, "doors");
        if (cJSON_IsObject(doors)) {
            g_dash.door_open = j_bool(doors, "open", false);
            g_dash.door_unlocked = j_bool(doors, "unlocked", false);
            g_dash.trunk_open = j_bool(doors, "trunk", false);
        }
    }

    // 語音試聽鉤子：{"tts_say": "代號"} 直接播一段音檔（代號見 nx4_voice_clips.c），
    // {"tts_lead": 毫秒} 調開頭靜音。
    // 純粹是調音用的，儀表 App 不會送這兩個欄位。
    if (j_has(doc, "tts_lead")) nx4_tts_set_lead_in_ms(j_int(doc, "tts_lead", 400));
    const char *tts_say = j_str(doc, "tts_say");
    if (tts_say && *tts_say) nx4_tts_say(tts_say);

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

static void refreshIpState(void);

static void onSettingsForget(const char *ssid) {
    nx4_wifi_forget(ssid);
    refreshIpState();   // 忘記的若是目前這台，固定 IP 也跟著清掉了
}

/// 資料來源切換 / OBD 裝置名稱改變。
static void onSettingsSource(bool direct, const char *obd_name) {
    bool name_changed = obd_name && strcmp(obd_name, g_obd_name) != 0;
    if (name_changed) strlcpy(g_obd_name, obd_name, sizeof(g_obd_name));
    g_obd_direct = direct;
    nx4_nvs_save_source(direct, g_obd_name);
    printf("[來源] %s，OBD 裝置「%s」\n", direct ? "直連 OBD" : "WebSocket",
           g_obd_name);
    if (name_changed) nx4_obd_set_name(g_obd_name);
    // WebSocket 模式下完全不連藍牙，把 dongle 讓給手機端
    nx4_obd_set_enabled(direct);
}

/// 語音播報：只在狀態翻轉的那一刻念一次。
///
/// 放在主迴圈而不是 WebSocket 的解析裡——直連 OBD 模式下大燈狀態來自 OBD，
/// 不會隨著 WS 封包進來，擺在解析裡就不會觸發。
static void serviceVoice(void) {
    static bool said_high_beam = false;
    static bool said_camera = false;
    static nx4_cam_kind_t said_kind = NX4_CAM_SPEED;
    if (g_dash.high_beam != said_high_beam) {
        said_high_beam = g_dash.high_beam;
        nx4_tts_high_beam(said_high_beam);
    }
    // 警示期間換成另一種相機（例如紅燈照相後緊接測速）也要再念一次
    if (g_dash.camera_active &&
        (!said_camera || g_dash.camera_kind != said_kind)) {
        switch (g_dash.camera_kind) {
        case NX4_CAM_RED_LIGHT: nx4_tts_say("red_light"); break;
        case NX4_CAM_OVERPASS:  nx4_tts_say("overpass"); break;
        case NX4_CAM_ZONE_END:  nx4_tts_say("zone_end"); break;
        case NX4_CAM_ZONE_START: nx4_tts_say("zone_start"); break;
        default:                nx4_tts_camera_alert(g_dash.camera_limit); break;
        }
    }
    said_camera = g_dash.camera_active;
    said_kind = g_dash.camera_kind;

    // 通過相機：App 送的是累計次數而非單次旗標——200ms 一筆的狀態封包可能
    // 掉包，旗標會漏。只在數字變大時念；變小代表 App 重開、計數歸零，只記下不念。
    // 新 client 連上時歸零基準（見主迴圈的 nx4_ws_take_connected_flag），斷線期間累積的不補念。
    if (g_dash.camera_passed >= 0) {
        if (g_said_passed >= 0 && g_dash.camera_passed > g_said_passed) {
            nx4_tts_say("passed");
        }
        g_said_passed = g_dash.camera_passed;
    }

    // 前方壅塞：同樣是累計次數。要不要提醒、同一段壅塞不重複，都由 App 決定
    // （TrafficService._maybeAnnounce），這裡只負責數字變大時念。
    if (g_dash.traffic_alerts >= 0) {
        if (g_said_alerts >= 0 && g_dash.traffic_alerts > g_said_alerts) {
            nx4_tts_say("traffic");
        }
        g_said_alerts = g_dash.traffic_alerts;
    }

    // 車門沒關好就起步：車速由 0 變成大於 0 的那一刻有車門開著，念兩次。
    // 手機端 AppProvider._maybeWarnDoorOpenOnDeparture 是同一套規則。
    //
    // 資料逾時就當作沒有車速（-1），否則開機時 g_dash.speed 的初值 0
    // 會被當成「停著」，第一包資料一進來就可能誤判成起步。
    // 停車場裡時速常在 0 與 1 之間跳，兩次警告至少隔 30 秒。
    static int prev_speed = -1;
    static int64_t last_door_warn = 0;
    int64_t t = now_ms();
    bool fresh = g_last_data_ms != 0 && t - g_last_data_ms <= DATA_TIMEOUT_MS;
    int speed = fresh ? g_dash.speed : -1;
    if (prev_speed == 0 && speed > 0 && g_dash.door_open &&
        (last_door_warn == 0 || t - last_door_warn >= 30000)) {
        last_door_warn = t;
        // 佇列長度 4，兩段一起排進去；每段前面各有一段靜音，自然隔開
        nx4_tts_say("door_open");
        nx4_tts_say("door_open");
    }
    prev_speed = speed;
}

/// 把 OBD 解析結果搬進畫面資料。只搬「讀到過」的欄位，沒讀到的保留 "--"。
///
/// 注意不碰 speed_limit / limit_alt / camera / clock / date——那些是 GPS 與
/// 手機端算出來的，固定由 WebSocket 供應（板子上沒有 GPS 元件）。
static void obd_apply(void) {
    nx4_obd_data_t o;
    nx4_obd_snapshot(&o);

    if (o.has_speed)    g_dash.speed = o.speed;
    if (o.has_rpm)      g_dash.rpm = o.rpm;
    if (o.has_coolant)  g_dash.coolant = o.coolant;
    if (o.has_soc)      g_dash.soc = o.soc;
    if (o.has_fuel)     g_dash.fuel = o.fuel;
    if (o.has_odo)      g_dash.odo = o.odo;
    if (o.has_turbo)    g_dash.turbo = o.turbo;
    if (o.has_throttle) g_dash.throttle = o.throttle;
    if (o.has_tpms) {
        g_dash.tire_fl = o.tire_fl; g_dash.tire_fr = o.tire_fr;
        g_dash.tire_rl = o.tire_rl; g_dash.tire_rr = o.tire_rr;
    }
    if (o.has_lights) {
        g_dash.low_beam = o.low_beam;
        g_dash.high_beam = o.high_beam;
    }
    if (o.has_position_lamp) g_dash.position_lamp = o.position_lamp;
    if (o.has_rear_fog)      g_dash.rear_fog = o.rear_fog;
    if (o.has_doors) {
        g_dash.door_open = o.door_open;
        g_dash.trunk_open = o.trunk_open;
    }
    if (o.has_lock)      g_dash.door_unlocked = o.door_unlocked;
    if (o.has_reversing) g_dash.reversing = o.reversing;

    g_dash_dirty = true;
    g_last_data_ms = now_ms();   // 有 OBD 在餵就不要讓畫面淡出
}

/// 音量滑桿放開：套用、存檔、播一段測試音讓使用者當場聽到。
static void onSettingsVolume(int volume) {
    nx4_tts_set_volume(volume);
    nx4_nvs_save_volume(volume);
    printf("[語音] 音量 %d%%\n", volume);
    nx4_tts_say("boot");   // 「系統啟動」，長度適中，拿來當試聽音
}

/// 更新設定頁上固定 IP 的按鈕與說明。
static void refreshIpState(void) {
    bool pinned = nx4_wifi_ip_pinned();
    const char *ip = nx4_wifi_ip();
    char detail[48];
    if (pinned) snprintf(detail, sizeof(detail), "%s", ip ? ip : "");
    else if (ip) snprintf(detail, sizeof(detail), "DHCP %s", ip);
    else snprintf(detail, sizeof(detail), "尚未連線");
    ui_settings_set_ip_state(pinned, detail);
}

/// 按下「固定目前 IP」/「改用 DHCP」。
static void onSettingsIpToggle(void) {
    if (nx4_wifi_ip_pinned()) {
        nx4_wifi_unpin_ip();
    } else if (!nx4_wifi_pin_current_ip()) {
        ui_settings_set_status("尚未取得 IP，無法固定");
        return;
    }
    refreshIpState();
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
    if (connected != was_connected) {
        if (connected) {
            // 自動切換到其他已知網路時，右下角的 SSID 要跟著換
            ui_dashboard_set_ssid(nx4_wifi_ssid());
            printf("[WiFi] 已連線，IP: %s\n", nx4_wifi_ip());
            printf("[WS] Server 啟動於 port %d\n", WS_PORT);
        }
        refreshIpState();       // 連上/斷線都更新設定頁的 IP 顯示
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
                   "doors=%c thr=%c rev=%c traffic=%c",
                   (g_seen_fields & FIELD_ODO) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_TIME) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_DATE) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_TURBO) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_LIGHTS) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_BRIGHT) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_DOORS) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_THROTTLE) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_REVERSING) ? 'Y' : 'N',
                   (g_seen_fields & FIELD_TRAFFIC) ? 'Y' : 'N');
            if ((g_seen_fields & (FIELD_ODO | FIELD_TIME | FIELD_DATE)) !=
                (FIELD_ODO | FIELD_TIME | FIELD_DATE)) {
                printf("   <- 手機 App 版本可能過舊，缺少的欄位不會更新");
            }
            printf("\n");
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
/// 序列埠注入：UART0（console）收到以 '{' 開頭的一整行，就當成 WebSocket
/// 封包處理。沒有 WiFi 時可以在桌上直接送 esp32_dash 測試畫面與語音。
/// 只裝 RX 緩衝，printf 照舊直接寫 FIFO，不受影響。
static void serial_inject_task(void *arg) {
    (void)arg;
    static char line[NX4_WS_BUF_SIZE];
    size_t len = 0;
    bool overflow = false;
    uint8_t ch;
    for (;;) {
        if (uart_read_bytes(UART_NUM_0, &ch, 1, portMAX_DELAY) != 1) continue;
        if (ch == '\n' || ch == '\r') {
            if (!overflow && len > 0 && line[0] == '{') nx4_ws_inject(line, len);
            len = 0;
            overflow = false;
        } else if (len < sizeof(line) - 1) {
            line[len++] = (char)ch;
        } else {
            overflow = true;
        }
    }
}

void app_main(void) {
    g_dash.camera_passed = -1;   // 還沒收到 App 的計數，不能把 0 當基準
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
    ui_settings_set_callbacks(onSettingsApply, onSettingsScan, onSettingsVolume,
                              onSettingsSource, onSettingsIpToggle);
    ui_settings_set_known_callbacks(nx4_wifi_known_pass, nx4_wifi_known_ssid,
                                    onSettingsForget);
    ui_settings_set_volume(g_volume);

    g_obd_direct = nx4_nvs_load_obd_direct();
    nx4_nvs_load_obd_name(g_obd_name, sizeof(g_obd_name));
    ui_settings_set_source(g_obd_direct, g_obd_name);
    printf("[來源] %s，OBD 裝置「%s」\n",
           g_obd_direct ? "直連 OBD" : "WebSocket", g_obd_name);

    // 只有選「直連 OBD」才去連藍牙。WebSocket 模式下連 NimBLE 都不初始化，
    // dongle 完全不被佔用——手機端要用同一顆，不能兩邊搶。
    nx4_obd_start(g_obd_name, g_obd_direct);

    nx4_wifi_start();
    ui_dashboard_set_ssid(nx4_wifi_ssid());

    char geo[160];
    ui_settings_debug_geometry(geo, sizeof(geo));
    refreshIpState();
    printf("[UI] 設定面板 %s\n", geo);
    ui_dashboard_set_brightness(g_brightness);
    ui_dashboard_set_stale(true);

    ESP_ERROR_CHECK(nx4_ws_start(WS_PORT));

    if (uart_driver_install(UART_NUM_0, 4096, 0, 0, NULL, 0) == ESP_OK) {
        xTaskCreate(serial_inject_task, "serial_inject", 4096, NULL, 3, NULL);
    }

    // 開機提示音。放在最後，這時畫面與網路都已就緒，
    // 使用者聽到「系統啟動」時看到的也是可用的儀表。
    nx4_tts_say("boot");

    printf("Setup done\n");

    static char rx[NX4_WS_BUF_SIZE];
    for (;;) {
        if (nx4_ws_take_connected_flag()) {
            g_seen_fields = 0;
            g_log_next_payload = true;
            g_said_passed = -1;
            g_dash.camera_passed = -1;
            g_said_alerts = -1;
            g_dash.traffic_alerts = -1;
        }
        size_t n = nx4_ws_take(rx, sizeof(rx));
        if (n > 0) handleDashPayload(rx, n);

        // 直連 OBD：每 100ms 把最新解析結果搬進畫面。OBD 任務是獨立跑的，
        // 這裡只是取快照，不會被藍牙的延遲拖住。
        if (g_obd_direct) {
            static int64_t last_obd = 0;
            int64_t t = now_ms();
            if (t - last_obd >= 100) { last_obd = t; obd_apply(); }
        }

        serviceVoice();
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
