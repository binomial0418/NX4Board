#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─────────────────────────────────────────────────────────────────────────
// WiFi STA（ESP-IDF 版）
//
// 取代 Arduino 版的 WiFi.h。行為刻意維持一致：非阻塞連線、斷線每 10 秒
// 自動重送、掃描非阻塞，這樣 LVGL 的更新迴圈不會被卡住。
//
// 憑證以 NVS 儲存的為優先，沒有才回退到 config.h——螢幕上設定過之後，
// 重新燒錄韌體也不會被 config.h 蓋掉。
// ─────────────────────────────────────────────────────────────────────────

#define NX4_SSID_LEN 33
#define NX4_PASS_LEN 65

/// 只把 NVS 叫起來。語音音量必須在 nx4_tts_init() 之前讀，而那時
/// nx4_wifi_start() 還沒跑到，所以拆成一支可先呼叫的函式。重複呼叫是安全的。
void nx4_nvs_init_early(void);

/// 初始化 NVS、netif、事件迴圈與 WiFi，並以儲存的憑證開始連線。
void nx4_wifi_start(void);

/// 套用新憑證：寫入 NVS 並立即重連。
void nx4_wifi_apply(const char *ssid, const char *pass);

/// 目前使用中的 SSID（來自 NVS 或 config.h）。
const char *nx4_wifi_ssid(void);

bool nx4_wifi_connected(void);
/// 已連線時回傳點分十進位字串，否則回傳 NULL。
const char *nx4_wifi_ip(void);
int nx4_wifi_rssi(void);
int nx4_wifi_channel(void);
/// 省電模式是否開著。訊號強卻大量丟包時，這是第二個要看的指標。
bool nx4_wifi_ps_on(void);

/// 每秒呼叫一次：負責斷線重連。回傳目前是否已連線。
bool nx4_wifi_service(void);

// ── 掃描（非阻塞）──────────────────────────────────────────────────────
typedef struct {
    char ssid[NX4_SSID_LEN];
    int  rssi;
    bool locked;
} nx4_ap_t;

/// 開始掃描。已在掃描中則忽略。
void nx4_wifi_scan_start(void);
/// 掃描是否仍在進行。
bool nx4_wifi_scan_busy(void);
/// 掃描完成時把結果填進 out 並回傳筆數；尚未完成回傳 -1，失敗回傳 -2。
/// 回傳 >= 0 之後狀態即清除，不會重複回報。
int nx4_wifi_scan_take(nx4_ap_t *out, int max);

// ── 音量（與 WiFi 憑證共用同一個 NVS namespace）────────────────────────
/// 沒存過時回傳 -1。
int  nx4_nvs_load_volume(void);
void nx4_nvs_save_volume(int volume);

#ifdef __cplusplus
}
#endif
