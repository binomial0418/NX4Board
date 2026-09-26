#pragma once

#include "lvgl.h"
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─────────────────────────────────────────────────────────────────────────
// WiFi 設定面板（點右下角 IP 開啟）
//
// 本檔只負責畫面與輸入，實際的掃描、連線與 NVS 儲存都由
// nx4_dashboard.ino 透過下列 callback 完成 —— UI 層不碰 Arduino API，
// 才能維持 ui_*.c 是純 LVGL 的 C 檔。
// ─────────────────────────────────────────────────────────────────────────

/// 使用者按下「儲存並連線」
typedef void (*nx4_settings_apply_cb_t)(const char *ssid, const char *pass);
/// 使用者按下「掃描」（實作端應以非阻塞方式掃描，完成後回填結果）
typedef void (*nx4_settings_scan_cb_t)(void);
/// 使用者放開音量滑桿（0~100）。實作端應套用音量、播一段測試音、寫入 NVS。
typedef void (*nx4_settings_volume_cb_t)(int volume);
/// 使用者切換車輛資料來源，或改了 OBD 裝置名稱。實作端應寫入 NVS 並套用。
/// direct 為 true 代表「直連 OBD」，false 代表「WebSocket」。
/// GPS 相關資料（速限、測速照相、時間）一律走 WebSocket，不受這個開關影響。
typedef void (*nx4_settings_source_cb_t)(bool direct, const char *obd_name);
/// 使用者按下「固定目前 IP」/「改用 DHCP」。實作端切換狀態後，
/// 要回頭呼叫 ui_settings_set_ip_state() 更新按鈕與說明文字。
typedef void (*nx4_settings_ip_cb_t)(void);

void ui_settings_set_callbacks(nx4_settings_apply_cb_t apply,
                               nx4_settings_scan_cb_t scan,
                               nx4_settings_volume_cb_t volume,
                               nx4_settings_source_cb_t source,
                               nx4_settings_ip_cb_t ip_toggle);

/// 已知網路（連線成功過、存有密碼的 AP）
/// 查密碼：找得到就填進 out 並回傳 true
typedef bool (*nx4_settings_known_pass_cb_t)(const char *ssid, char *out, size_t n);
/// 依最近使用排序的第 index 筆 SSID，超出範圍回傳 NULL
typedef const char *(*nx4_settings_known_at_cb_t)(int index);
/// 使用者按下「忘記」
typedef void (*nx4_settings_forget_cb_t)(const char *ssid);

void ui_settings_set_known_callbacks(nx4_settings_known_pass_cb_t pass,
                                     nx4_settings_known_at_cb_t at,
                                     nx4_settings_forget_cb_t forget);

/// 建立面板（開機時呼叫一次，預設隱藏）
void ui_settings_create(void);

/// 開啟面板，並以目前的 SSID 預填欄位（已知網路會連密碼一起帶出）。
/// 清單是空的就先列出已知網路，不必先掃描也能直接點選切換。
void ui_settings_open(const char *current_ssid);
void ui_settings_close(void);
bool ui_settings_is_open(void);

/// 掃描結果：先 clear 再逐筆 add
void ui_settings_clear_networks(void);
void ui_settings_add_network(const char *ssid, int rssi, bool locked);

/// 預填音量滑桿（開機讀完 NVS 後呼叫一次）。不會觸發 volume callback。
void ui_settings_set_volume(int volume);

/// 預填資料來源與 OBD 裝置名稱（開機讀完 NVS 後呼叫一次）。不會觸發 callback。
void ui_settings_set_source(bool direct, const char *obd_name);

/// 更新固定 IP 的按鈕與說明。pinned 決定按鈕顯示「固定目前 IP」或
/// 「改用 DHCP」，detail 是旁邊的小字（例如目前位址）。
void ui_settings_set_ip_state(bool pinned, const char *detail);

/// 面板下方的狀態列文字（掃描中、連線中、連線失敗…）
void ui_settings_set_status(const char *text);

/// 把面板內主要元件的實際座標寫入 buf，供序列埠診斷版面
void ui_settings_debug_geometry(char *buf, size_t n);

#ifdef __cplusplus
}
#endif
