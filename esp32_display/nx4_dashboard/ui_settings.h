#pragma once

#include "lvgl.h"
#include <stdbool.h>

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

void ui_settings_set_callbacks(nx4_settings_apply_cb_t apply,
                               nx4_settings_scan_cb_t scan);

/// 建立面板（開機時呼叫一次，預設隱藏）
void ui_settings_create(void);

/// 開啟面板，並以目前的 SSID 預填欄位
void ui_settings_open(const char *current_ssid);
void ui_settings_close(void);
bool ui_settings_is_open(void);

/// 掃描結果：先 clear 再逐筆 add
void ui_settings_clear_networks(void);
void ui_settings_add_network(const char *ssid, int rssi, bool locked);

/// 面板下方的狀態列文字（掃描中、連線中、連線失敗…）
void ui_settings_set_status(const char *text);

#ifdef __cplusplus
}
#endif
