#pragma once

#include "lvgl.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─────────────────────────────────────────────────────────────────────────
// NX4Board ESP32-P4 儀表 UI (LVGL v8, 1024x600)
//
// 設計原則：ui_dashboard_create() 只在開機時建立一次所有物件，
// 之後 ui_dashboard_update() 僅寫入 Label 文字與 Bar/Arc 數值，
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
  int tire_fl;      // 胎壓 psi
  int tire_fr;
  int tire_rl;
  int tire_rr;
  bool camera_active;  // 前方有測速照相
  int camera_limit;    // 該測速照相的速限 km/h
} nx4_dash_data_t;

/// 以合理預設值（全部歸零 / 無警示）初始化資料結構
void nx4_dash_data_init(nx4_dash_data_t *data);

/// 建立整個儀表畫面（只呼叫一次）
void ui_dashboard_create(void);

/// 將最新資料套用至既有物件（高頻呼叫，僅更新有變動的欄位）
void ui_dashboard_update(const nx4_dash_data_t *data);

/// 更新上方狀態列：WiFi 是否連上、本機 IP、手機 WebSocket 是否已連線
void ui_dashboard_set_status(bool wifi_up, const char *ip, bool client_linked);

/// 資料逾時 / 手機斷線時將主要數值淡出，避免誤讀舊值
void ui_dashboard_set_stale(bool stale);

#ifdef __cplusplus
}
#endif
