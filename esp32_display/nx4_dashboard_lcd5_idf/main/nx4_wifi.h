#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─────────────────────────────────────────────────────────────────────────
// WiFi STA（ESP-IDF 版）
//
// 非阻塞連線、失敗自動重試、掃描非阻塞，LVGL 的更新迴圈不會被卡住。
//
// 兩層設定：
//   * 使用者選的網路（設定頁「儲存並連線」）——開機一律先連它。NVS 沒有時
//     才回退到 config.h，所以重新燒錄韌體不會蓋掉螢幕上的設定。
//   * 已知網路清單（最多 NX4_KNOWN_MAX 組）——只有真正拿到 IP 的網路才加入，
//     各自記密碼與固定 IP。使用者選的那台連續失敗時，自動掃描並改連
//     範圍內訊號最強的已知網路；設定頁點選已知網路會自動帶出密碼。
// ─────────────────────────────────────────────────────────────────────────

#define NX4_SSID_LEN 33
#define NX4_PASS_LEN 65

/// 只把 NVS 叫起來。語音音量必須在 nx4_tts_init() 之前讀，而那時
/// nx4_wifi_start() 還沒跑到，所以拆成一支可先呼叫的函式。重複呼叫是安全的。
void nx4_nvs_init_early(void);

/// 初始化 NVS、netif、事件迴圈與 WiFi，並以儲存的憑證開始連線。
void nx4_wifi_start(void);

/// 套用新憑證：寫入 NVS 並立即重連。連上之後才會加入已知網路清單。
void nx4_wifi_apply(const char *ssid, const char *pass);

/// 目前實際在連的 SSID（自動切換時可能不是使用者選的那台）。
const char *nx4_wifi_ssid(void);

bool nx4_wifi_connected(void);
/// 已連線時回傳點分十進位字串，否則回傳 NULL。
const char *nx4_wifi_ip(void);
int nx4_wifi_rssi(void);
int nx4_wifi_channel(void);
/// 省電模式是否開著。訊號強卻大量丟包時，這是第二個要看的指標。
bool nx4_wifi_ps_on(void);

/// 每秒呼叫一次：負責斷線重連與自動切換。回傳目前是否已連線。
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

// ── 已知網路 ──────────────────────────────────────────────────────────
#define NX4_KNOWN_MAX 5

/// 查已知網路的密碼。不在清單裡回傳 false。
bool nx4_wifi_known_pass(const char *ssid, char *out, size_t n);
/// 依最近連線成功排序的第 index 筆 SSID，超出範圍回傳 NULL。
const char *nx4_wifi_known_ssid(int index);
/// 從清單移除（連同它的固定 IP）。不在清單裡回傳 false。
bool nx4_wifi_forget(const char *ssid);

// ── 其他設定（與 WiFi 憑證共用同一個 NVS namespace）────────────────────
/// 沒存過時回傳 -1。
int  nx4_nvs_load_volume(void);
void nx4_nvs_save_volume(int volume);

/// 車輛資料來源。true = 直連 OBD，false = WebSocket。沒存過時回傳 false。
bool nx4_nvs_load_obd_direct(void);
/// OBD dongle 的 BLE 廣播名稱，沒存過時填入 NX4_OBD_NAME_DEFAULT。
void nx4_nvs_load_obd_name(char *out, size_t n);
void nx4_nvs_save_source(bool direct, const char *obd_name);

#define NX4_OBD_NAME_DEFAULT "IOS-VLINK"
#define NX4_OBD_NAME_LEN 32

// ── 固定 IP ──────────────────────────────────────────────────────────────
// 把目前 DHCP 拿到的位址鎖起來，下次開機直接用，不必等 DHCP，也讓手機端
// 的設定不用每次改 IP。
//
// **固定 IP 存在各個已知網路裡。** 每台 AP 各用各的，換到沒固定過的網路
// 就用 DHCP——否則換網段之後板子會完全連不上，只能靠觸控螢幕救回來。

/// 目前連的這台是否使用固定 IP。
bool nx4_wifi_ip_pinned(void);

/// 把目前拿到的位址（IP / 閘道 / 遮罩）連同 SSID 存起來。
/// 尚未取得 IP 時回傳 false。
bool nx4_wifi_pin_current_ip(void);

/// 清掉固定 IP，退回 DHCP。下次連線生效。
void nx4_wifi_unpin_ip(void);

#ifdef __cplusplus
}
#endif
