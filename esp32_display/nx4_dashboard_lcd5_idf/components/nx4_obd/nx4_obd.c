// ELM327 指令層 + PID 解析 + 輪詢排程。說明見 nx4_obd.h。
//
// 對照來源：lib/services/obd_spp_service.dart
// 各 PID 的位元對應與係數都是實車驗證過的，改動前請先看該檔的註解。

#include "nx4_obd.h"
#include "nx4_ble.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

static const char *TAG = "nx4_obd";

#define RX_MAX 512

static nx4_obd_data_t   s_data;
static SemaphoreHandle_t s_data_lock;

// ── 接收緩衝 ─────────────────────────────────────────────────────────────
// ELM327 每筆回應以 '>' 提示符結尾（見 obdlab/elm.py）。BLE 的 notify 會把
// 回應切成好幾包送來，所以要自己累積到看見 '>' 為止。
static char              s_rx[RX_MAX];
static volatile size_t   s_rx_len = 0;
static SemaphoreHandle_t s_rx_done;      // 看到 '>' 時 give

static bool s_ready = false;
static bool s_enabled = false;
static char s_ble_name[40] = "";
static char s_active_header[8] = "7DF";  // 22BC04 在不同 Header 下意義不同

static void on_ble_rx(const uint8_t *data, size_t len) {
    for (size_t i = 0; i < len; i++) {
        char c = (char)data[i];
        if (c == '>') {
            if (s_rx_len < RX_MAX) s_rx[s_rx_len] = '\0';
            else s_rx[RX_MAX - 1] = '\0';
            xSemaphoreGive(s_rx_done);
            return;
        }
        if (s_rx_len < RX_MAX - 1) s_rx[s_rx_len++] = c;
    }
}

/// 送一道指令並等回應。回傳去掉空白/換行、轉大寫後的字串（指向內部緩衝）。
/// 逾時或未連線回傳 NULL。
static const char *elm_send(const char *cmd, int timeout_ms) {
    if (!nx4_ble_ready()) return NULL;

    s_rx_len = 0;
    xSemaphoreTake(s_rx_done, 0);          // 清掉上一筆殘留的旗號

    char line[40];
    int n = snprintf(line, sizeof(line), "%s\r", cmd);
    if (!nx4_ble_write((const uint8_t *)line, n)) return NULL;

    if (xSemaphoreTake(s_rx_done, pdMS_TO_TICKS(timeout_ms)) != pdTRUE) {
        ESP_LOGW(TAG, "%s 逾時", cmd);
        return NULL;
    }

    // 就地正規化：去空白與換行、轉大寫。解析全部以這個形式進行。
    static char clean[RX_MAX];
    size_t k = 0;
    for (size_t i = 0; i < s_rx_len && k < sizeof(clean) - 1; i++) {
        char c = s_rx[i];
        if (c == ' ' || c == '\r' || c == '\n') continue;
        clean[k++] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
    }
    clean[k] = '\0';

    if (strncmp(cmd, "ATSH", 4) == 0) {
        strlcpy(s_active_header, cmd + 4, sizeof(s_active_header));
    }
    return clean;
}

// ── 小工具 ───────────────────────────────────────────────────────────────
static int hex2(const char *s) {
    int hi = s[0] <= '9' ? s[0] - '0' : s[0] - 'A' + 10;
    int lo = s[1] <= '9' ? s[1] - '0' : s[1] - 'A' + 10;
    return (hi << 4) | lo;
}

/// 在 resp 裡找 sig，回傳其後 payload 的起點；找不到回傳 NULL。
static const char *payload_after(const char *resp, const char *sig) {
    if (!resp) return NULL;
    const char *p = strstr(resp, sig);
    return p ? p + strlen(sig) : NULL;
}

// ── 增壓零點校正 ─────────────────────────────────────────────────────────
// 引擎停止（轉速 0）時 MAP 應該等於大氣壓，兩者的差就是感測器偏移。
// 連續取樣夠多次才學，且偏移離譜就不採信。對照 _maybeCalibrateBoostZero。
#define ZERO_CALIB_SAMPLES 10     // 快輪詢 300ms 一拍，約 3 秒
#define ZERO_CALIB_MAX_KPA 10.0f

static float s_baro_kpa = 101.3f;   // 沒讀到 0133 之前用標準大氣壓
static float s_map_zero_offset = 0.0f;
static int   s_engine_off_samples = 0;

static void maybe_calibrate_zero(int map_kpa, int rpm) {
    if (rpm != 0) { s_engine_off_samples = 0; return; }
    if (++s_engine_off_samples < ZERO_CALIB_SAMPLES) return;
    s_engine_off_samples = ZERO_CALIB_SAMPLES;      // 別讓它無限增長

    float offset = map_kpa - s_baro_kpa;
    if (offset < 0) { if (-offset > ZERO_CALIB_MAX_KPA) return; }
    else if (offset > ZERO_CALIB_MAX_KPA) return;

    float d = offset - s_map_zero_offset;
    if (d < 0) d = -d;
    if (d < 0.5f) return;                            // 沒變就不寫

    s_map_zero_offset = offset;
    ESP_LOGI(TAG, "增壓零點校正：MAP=%d 大氣壓=%.1f 偏移 %.1f kPa",
             map_kpa, s_baro_kpa, offset);
}

// ── 解析 ─────────────────────────────────────────────────────────────────
/// 合併請求 010B0C0D45 的回應。ELM 會回 41 開頭，後面把各 PID 連著排。
/// 逐段走訪：讀 PID 編號 → 查它的資料長度 → 取值 → 前進。
static void parse_multi(const char *resp) {
    if (!resp) return;
    static const struct { const char *pid; int len; } kLen[] = {
        {"0B", 1}, {"0C", 2}, {"0D", 1}, {"45", 1},
    };

    char map_hex[5] = "", rpm_hex[5] = "", spd_hex[5] = "", thr_hex[5] = "";

    const char *p = resp;
    while ((p = strstr(p, "41")) != NULL) {
        const char *walk = p + 2;
        bool advanced = false;
        while (strlen(walk) >= 2) {
            int len = 0;
            const char *slot = NULL;
            for (size_t i = 0; i < sizeof(kLen) / sizeof(kLen[0]); i++) {
                if (strncmp(walk, kLen[i].pid, 2) == 0) {
                    len = kLen[i].len;
                    slot = kLen[i].pid;
                    break;
                }
            }
            if (!len) break;
            if (strlen(walk) < (size_t)(2 + len * 2)) break;

            char buf[5] = {0};
            memcpy(buf, walk + 2, len * 2);
            // 只採第一次出現的值，與 Dart 的 putIfAbsent 一致
            if (!strcmp(slot, "0B") && !map_hex[0]) strcpy(map_hex, buf);
            if (!strcmp(slot, "0C") && !rpm_hex[0]) strcpy(rpm_hex, buf);
            if (!strcmp(slot, "0D") && !spd_hex[0]) strcpy(spd_hex, buf);
            if (!strcmp(slot, "45") && !thr_hex[0]) strcpy(thr_hex, buf);
            walk += 2 + len * 2;
            advanced = true;
        }
        p = advanced ? walk : p + 2;
    }

    int rpm_val = -1;
    if (rpm_hex[0]) {
        int v = ((hex2(rpm_hex) * 256) + hex2(rpm_hex + 2)) / 4;
        if (v <= 10000) rpm_val = v;
    }

    xSemaphoreTake(s_data_lock, portMAX_DELAY);
    if (rpm_val >= 0) { s_data.rpm = rpm_val; s_data.has_rpm = true; }
    if (map_hex[0]) {
        int map_kpa = hex2(map_hex);
        maybe_calibrate_zero(map_kpa, rpm_val >= 0 ? rpm_val : -1);
        s_data.turbo = (map_kpa - s_baro_kpa - s_map_zero_offset) / 100.0f;
        s_data.has_turbo = true;
    }
    if (spd_hex[0]) {
        int v = hex2(spd_hex);
        // 車速一律以 OBD 為準（手機端同樣策略，GPS 只是後備）
        if (v <= 250) { s_data.speed = v; s_data.has_speed = true; }
    }
    if (thr_hex[0]) {
        s_data.throttle = (hex2(thr_hex) * 100 + 127) / 255;
        s_data.has_throttle = true;
    }
    xSemaphoreGive(s_data_lock);
}

/// 22 系列的共用外殼：回應簽章是 62 + PID，後面才是 payload。
/// 沒有簽章代表 ECU 沒回這個 PID（NO DATA / 負回應 / Header 不對）。
static const char *uds_payload(const char *resp, const char *pid) {
    char sig[8];
    snprintf(sig, sizeof(sig), "62%s", pid);
    return payload_after(resp, sig);
}

static void parse_bc03(const char *d) {      // 四門 + 尾門，全在 byte E
    if (!d || strlen(d) < 10) return;
    int e = hex2(d + 8);
    xSemaphoreTake(s_data_lock, portMAX_DELAY);
    // bit0 RL / bit2 RR / bit4 FR / bit5 FL / bit7 尾門
    s_data.door_open = (e & 0x01) || (e & 0x04) || (e & 0x10) || (e & 0x20);
    s_data.trunk_open = (e & 0x80) != 0;
    s_data.has_doors = true;
    xSemaphoreGive(s_data_lock);
}

static void parse_bc04(const char *d) {      // Header 770 底下 byte E 是門鎖
    if (!d || strlen(d) < 10) return;
    if (strcmp(s_active_header, "770") != 0) return;   // 302 底下意義不同，不採
    int e = hex2(d + 8);
    xSemaphoreTake(s_data_lock, portMAX_DELAY);
    // 位元設起來代表「未上鎖」，只有前兩門有訊號，任一未上鎖即視為未上鎖
    s_data.door_unlocked = (e & 0x08) || (e & 0x04);
    s_data.has_lock = true;
    xSemaphoreGive(s_data_lock);
}

static void parse_bc08(const char *d) {      // 倒車：byte F 的 bit3
    if (!d || strlen(d) < 12) return;
    int f = hex2(d + 10);
    xSemaphoreTake(s_data_lock, portMAX_DELAY);
    s_data.reversing = (f & 0x08) != 0;
    s_data.has_reversing = true;
    xSemaphoreGive(s_data_lock);
}

static void parse_bc09(const char *d) {      // 大燈：G 的 0xC0、遠燈在 H 的 0x03
    if (!d || strlen(d) < 16) return;
    int g = hex2(d + 12), h = hex2(d + 14);
    xSemaphoreTake(s_data_lock, portMAX_DELAY);
    s_data.low_beam = (g & 0xC0) != 0;
    s_data.high_beam = (h & 0x03) != 0;
    s_data.has_lights = true;
    xSemaphoreGive(s_data_lock);
}

static void parse_c00b(const char *d) {      // 胎壓，四個值各除以 5
    if (!d || strlen(d) < 42) return;
    xSemaphoreTake(s_data_lock, portMAX_DELAY);
    s_data.tire_fl = hex2(d + 8) / 5;
    s_data.tire_fr = hex2(d + 18) / 5;
    s_data.tire_rl = hex2(d + 28) / 5;
    s_data.tire_rr = hex2(d + 38) / 5;
    s_data.has_tpms = true;
    xSemaphoreGive(s_data_lock);
}

/// 油量原始值跳動大，取五筆去頭去尾後平均（與手機端同一套濾波）。
static int  s_fuel_buf[5];
static int  s_fuel_n = 0;

static void parse_b002(const char *d) {      // 里程 / 油量 / 電壓
    if (!d || strlen(d) < 18) return;

    int odo = (hex2(d + 12) << 16) | (hex2(d + 14) << 8) | hex2(d + 16);
    int raw_fuel = hex2(d + 8);
    float volt = hex2(d + 10) * 0.078125f;

    int fuel = -1;
    s_fuel_buf[s_fuel_n++] = raw_fuel;
    if (s_fuel_n >= 5) {
        int v[5];
        memcpy(v, s_fuel_buf, sizeof(v));
        for (int i = 1; i < 5; i++) {            // 插入排序，五筆而已
            int x = v[i], j = i - 1;
            while (j >= 0 && v[j] > x) { v[j + 1] = v[j]; j--; }
            v[j + 1] = x;
        }
        fuel = (v[1] + v[2] + v[3]) / 3;         // 捨棄最大與最小
        s_fuel_n = 0;
    }

    xSemaphoreTake(s_data_lock, portMAX_DELAY);
    if (odo > 0) { s_data.odo = odo; s_data.has_odo = true; }
    if (fuel >= 0) { s_data.fuel = fuel; s_data.has_fuel = true; }
    s_data.voltage = volt;
    s_data.has_voltage = true;
    xSemaphoreGive(s_data_lock);
}

// ── 輪詢 ─────────────────────────────────────────────────────────────────
// IGMP（大燈 / 車門 / 門鎖 / 倒車）共用一個 Header，一次切換全部查完。
// 兩個候選 Header 試到哪個回得出 62BC09 就鎖定，之後不再試另一個。
static const char *kIgmpHeaders[] = {"ATSH302", "ATSH770"};
static const char *s_igmp_locked = NULL;

static void poll_igmp(void) {
    const char *hdrs[2];
    int n;
    if (s_igmp_locked) { hdrs[0] = s_igmp_locked; n = 1; }
    else { hdrs[0] = kIgmpHeaders[0]; hdrs[1] = kIgmpHeaders[1]; n = 2; }

    for (int i = 0; i < n; i++) {
        elm_send(hdrs[i], 1000);
        const char *r9 = elm_send("22BC09", 1500);
        bool ok = r9 && strstr(r9, "62BC09");
        if (ok) {
            parse_bc09(uds_payload(r9, "BC09"));
            parse_bc03(uds_payload(elm_send("22BC03", 1500), "BC03"));
            parse_bc04(uds_payload(elm_send("22BC04", 1500), "BC04"));
            parse_bc08(uds_payload(elm_send("22BC08", 1500), "BC08"));
            elm_send("ATSH7DF", 1000);
            if (!s_igmp_locked) {
                s_igmp_locked = hdrs[i];
                ESP_LOGI(TAG, "IGMP Header %s 有效，已鎖定", hdrs[i]);
            }
            return;
        }
        elm_send("ATSH7DF", 1000);
        if (!s_igmp_locked) ESP_LOGW(TAG, "%s 取不到 62BC09，改試下一個", hdrs[i]);
    }
}

/// ELM 初始化。ATAL 很關鍵：沒有它長回應會被截斷（TPMS、里程都會壞）。
/// ATSP6 直接鎖 ISO 15765-4 CAN 11-bit 500K，省掉自動偵測。
/// ATZ 重試三次——BLE 剛連上時第一道指令常常沒有回應。
static bool elm_init(void) {
    static const char *kInit[] = {"ATE0", "ATL0", "ATH0", "ATS0", "ATAL",
                                  "ATST32", "ATAT1", "ATSP6", "ATSH7DF"};
    for (int i = 0; i < 3; i++) {
        const char *r = elm_send("ATZ", 6000);
        if (r && r[0]) goto ok;
        ESP_LOGW(TAG, "ATZ 第 %d 次沒回應，重試", i + 1);
        vTaskDelay(pdMS_TO_TICKS(500));
    }
    ESP_LOGE(TAG, "ATZ 連續三次沒有回應，dongle 可能睡著了");
    return false;
ok:
    for (size_t i = 0; i < sizeof(kInit) / sizeof(kInit[0]); i++) {
        elm_send(kInit[i], 3000);
    }
    // 大氣壓只在連線時讀一次，增壓的零點校正要用
    const char *r = elm_send("0133", 2000);
    const char *p = payload_after(r, "4133");
    if (p && strlen(p) >= 2) {
        s_baro_kpa = hex2(p);
        ESP_LOGI(TAG, "大氣壓 %.0f kPa", s_baro_kpa);
    }
    ESP_LOGI(TAG, "ELM 初始化完成");
    return true;
}

static void obd_task(void *arg) {
    int64_t last_slow = 0, last_min = 0, last_igmp = 0;

    for (;;) {
        if (!s_enabled) {
            s_ready = false;
            s_igmp_locked = NULL;
            vTaskDelay(pdMS_TO_TICKS(500));
            continue;
        }
        if (!nx4_ble_ready()) {
            s_ready = false;
            s_igmp_locked = NULL;
            vTaskDelay(pdMS_TO_TICKS(500));
            continue;
        }
        if (!s_ready) {
            if (!elm_init()) { vTaskDelay(pdMS_TO_TICKS(2000)); continue; }
            s_ready = true;
        }

        int64_t now = esp_timer_get_time() / 1000;

        // 快輪詢 300ms：MAP / 轉速 / 車速 / 節氣門，一道指令拿四個值
        parse_multi(elm_send("010B0C0D45", 2000));

        if (now - last_slow >= 5000) {          // HEV 電池 SoC
            last_slow = now;
            const char *p = payload_after(elm_send("015B", 2000), "415B");
            if (p && strlen(p) >= 2) {
                xSemaphoreTake(s_data_lock, portMAX_DELAY);
                s_data.soc = hex2(p) * 100.0f / 255.0f;
                s_data.has_soc = true;
                xSemaphoreGive(s_data_lock);
            }
        }

        if (now - last_min >= 30000) {          // 水溫 / 里程油量 / 胎壓
            last_min = now;
            // 4167 的格式是 4167 CC AA，水溫在第二個 byte
            const char *p = payload_after(elm_send("0167", 2000), "4167");
            if (p && strlen(p) >= 4) {
                int c = hex2(p + 2) - 40;
                if (c >= -40 && c <= 150) {
                    xSemaphoreTake(s_data_lock, portMAX_DELAY);
                    s_data.coolant = c;
                    s_data.has_coolant = true;
                    xSemaphoreGive(s_data_lock);
                }
            }
            elm_send("ATSH7C6", 1000);
            parse_b002(uds_payload(elm_send("22B002", 2500), "B002"));
            elm_send("ATSH7A0", 1000);
            parse_c00b(uds_payload(elm_send("22C00B", 2500), "C00B"));
            elm_send("ATSH7DF", 1000);
        }

        // 大燈 / 車門 / 門鎖 / 倒車。間隔依車速調整（照搬手機端 _pollIgmp）：
        // 車門與門鎖幾乎只在靜止時變動，行進間查得再勤也不會有事情發生，
        // 不如把匯流排讓給 300ms 的時速/轉速快輪詢。
        //
        // 這一批是 6 道指令（Header + 四個 PID + 還原 Header），在 BLE 上
        // 單道來回大約 100ms 起跳，行進間若還是每秒一批，光這批就吃掉大半
        // 秒的匯流排時間，快輪詢會被推到 1 秒以上。
        xSemaphoreTake(s_data_lock, portMAX_DELAY);
        bool moving = s_data.has_speed && s_data.speed > 5;
        xSemaphoreGive(s_data_lock);
        if (now - last_igmp >= (moving ? 3000 : 1000)) {
            last_igmp = now;
            poll_igmp();
        }

        // 手機端還會輪詢 22E000 判斷 D 檔，但這個畫面沒有檔位顯示
        // （倒車的 R 來自 22BC08），所以不送——每秒三道指令在 BLE 上不便宜。

        // 快輪詢的目標節奏是 300ms。上面那些指令花掉的時間要扣掉，
        // 否則實際間隔會變成「300ms + 本圈所有指令的來回時間」，
        // 慢輪詢那幾批一跑，時速與轉速就會明顯頓一下。
        int64_t spent = (esp_timer_get_time() / 1000) - now;
        if (spent < 300) vTaskDelay(pdMS_TO_TICKS(300 - spent));
        else taskYIELD();
    }
}

// ── 對外 ─────────────────────────────────────────────────────────────────
void nx4_obd_start(const char *ble_name, bool enabled) {
    s_data_lock = xSemaphoreCreateMutex();
    s_rx_done = xSemaphoreCreateBinary();
    memset(&s_data, 0, sizeof(s_data));
    s_enabled = enabled;
    if (ble_name) strlcpy(s_ble_name, ble_name, sizeof(s_ble_name));

    // 只有真的要用才去碰藍牙。WebSocket 模式下連 NimBLE 都不初始化，
    // dongle 完全不會被佔用。
    if (enabled) nx4_ble_start(s_ble_name, on_ble_rx);
    xTaskCreatePinnedToCore(obd_task, "nx4_obd", 5120, NULL, 4, NULL, 0);
}

void nx4_obd_set_enabled(bool on) {
    if (s_enabled == on) return;
    s_enabled = on;
    if (!on) {
        s_ready = false;
        s_igmp_locked = NULL;
    }
    if (on) {
        // nx4_ble_start() 同時處理兩種情況：NimBLE 還沒初始化就初始化，
        // 已經初始化過（之前停用）就只是重新開始掃描。
        nx4_ble_start(s_ble_name, on_ble_rx);
    } else {
        nx4_ble_set_enabled(false);
    }
}

void nx4_obd_set_name(const char *ble_name) {
    if (ble_name) strlcpy(s_ble_name, ble_name, sizeof(s_ble_name));
    if (s_enabled) nx4_ble_set_name(s_ble_name);   // 停用中就等下次啟用再套用
}
bool nx4_obd_ready(void) { return s_ready; }

void nx4_obd_snapshot(nx4_obd_data_t *out) {
    xSemaphoreTake(s_data_lock, portMAX_DELAY);
    *out = s_data;
    xSemaphoreGive(s_data_lock);
}
