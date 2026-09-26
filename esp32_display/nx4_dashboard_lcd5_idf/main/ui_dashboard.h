#pragma once

#include "lvgl.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─────────────────────────────────────────────────────────────────────────
// NX4Board ESP32-P4 儀表 UI (LVGL v8, 邏輯 1280x720)
//
// 版面比照手機端 App 的儀表畫面（專案根目錄 rec.gif）：
//   左側兩欄帶色條的資訊卡 + 中右 0-180 圓形時速錶
//   + 最右側由上到下的四格指示燈（大燈 / 車門 / 門鎖 / 後車廂）。
//
// 設計原則：ui_dashboard_create() 只在開機時建立一次所有物件，
// 之後 ui_dashboard_update() 僅寫入 Label 文字與 Meter/Bar 數值，
// 且數值未變動時直接跳過，確保不觸發整頁重繪、維持 60 FPS。
// ─────────────────────────────────────────────────────────────────────────

/// 手機端 esp32_dash JSON 解析後的儀表資料
typedef struct {
  int speed;        // km/h
  int rpm;          // rpm
  int coolant;      // °C
  float soc;        // 混合動力電池 %
  int fuel;         // 油量 %
  int speed_limit;  // 目前路段速限 km/h，0 表示無資料
  // 高架與正下方平面道路判別不出來、且兩者速限不同時，另一條路的速限；
  // 0 表示判定有把握或兩者速限相同
  int limit_alt;
  // 另一條路在上面（高架）還是下面，決定箭頭方向
  bool limit_alt_above;
  int odo;          // 里程 km
  float turbo;      // 渦輪增壓 Bar
  int throttle;     // 相對節氣門開度 %（PID 0145），-1 表示尚未取得
  int tire_fl;      // 胎壓 psi
  int tire_fr;
  int tire_rl;
  int tire_rr;
  bool camera_active;  // 前方有測速照相
  int camera_limit;    // 該測速照相的速限 km/h
  bool camera_red_light;  // 是闖紅燈照相（沒有速限，改念「前有闖紅燈照相」）
  bool low_beam;       // 近燈（大燈）開啟
  bool high_beam;      // 遠燈開啟
  bool reversing;      // 倒車檔（時速位置改顯示 R）
  bool door_open;      // 任一車門開啟
  bool door_unlocked;  // 任一車門解鎖（22BC04 只有前兩門有訊號）
  bool trunk_open;     // 後車廂開啟
  char clock[12];      // 手機端時間 "HH:MM:SS"
  char date[24];       // 手機端日期 "09/01 週一"
} nx4_dash_data_t;

/// 以合理預設值（全部歸零 / 無警示）初始化資料結構
void nx4_dash_data_init(nx4_dash_data_t *data);

/// 建立整個儀表畫面（只呼叫一次）
void ui_dashboard_create(void);

/// 將最新資料套用至既有物件（高頻呼叫，僅更新有變動的欄位）
void ui_dashboard_update(const nx4_dash_data_t *data);

/// 更新狀態欄：WiFi 是否連上、本機 IP、手機 WebSocket 是否已連線
void ui_dashboard_set_status(bool wifi_up, const char *ip, bool client_linked);

/// 資料逾時 / 手機斷線時將主要數值淡出，避免誤讀舊值
void ui_dashboard_set_stale(bool stale);

/// 更新狀態欄上的螢幕亮度顯示（實際背光由 .ino 呼叫 LCD 驅動套用）
void ui_dashboard_set_brightness(int percent);

/// 記錄目前連線的 SSID，供點擊 IP 開啟設定面板時預填
void ui_dashboard_set_ssid(const char *ssid);

#ifdef __cplusplus
}
#endif
