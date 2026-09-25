#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─────────────────────────────────────────────────────────────────────────
// 直連 OBD：ELM327 指令層 + PID 解析 + 輪詢排程
//
// 移植自 lib/services/obd_spp_service.dart。那支 2,789 行裡約 2,000 行是
// 檔位探測、模組點名、日誌那些診斷工具，儀表用不到；這裡只帶走跑儀表需要的
// 解析與輪詢，各 PID 的位元對應與係數逐項對照過，註解標了來源。
//
// 傳輸走 BLE（見 nx4_ble.h）。指令是序列的：送出後要讀到 '>' 提示符才算一筆
// 結束，所以整個流程跑在自己的任務裡，以旗號等待回應。
// ─────────────────────────────────────────────────────────────────────────

/// 解析出來的車輛狀態。欄位名稱對齊 nx4_dash_data_t，方便直接搬。
/// has_* 為 false 代表「還沒讀到過」，呼叫端應保留畫面上的 "--"。
typedef struct {
    int   speed;        bool has_speed;
    int   rpm;          bool has_rpm;
    int   coolant;      bool has_coolant;
    float soc;          bool has_soc;
    int   fuel;         bool has_fuel;
    int   odo;          bool has_odo;
    float turbo;        bool has_turbo;
    int   throttle;     bool has_throttle;

    int   tire_fl, tire_fr, tire_rl, tire_rr;
    bool  has_tpms;

    bool  low_beam, high_beam;      bool has_lights;
    bool  door_open, door_unlocked, trunk_open;
    bool  has_doors, has_lock;
    bool  reversing;    bool has_reversing;

    float voltage;      bool has_voltage;
} nx4_obd_data_t;

/// 啟動 BLE 連線與輪詢任務。name 是 dongle 的 BLE 廣播名稱。
void nx4_obd_start(const char *ble_name);

/// 改連另一個 dongle 名稱（設定頁改了之後呼叫）。
void nx4_obd_set_name(const char *ble_name);

/// dongle 是否已連線且 ELM 初始化完成。
bool nx4_obd_ready(void);

/// 取一份目前的解析結果。內部有鎖，可以從 LVGL 任務安全呼叫。
void nx4_obd_snapshot(nx4_obd_data_t *out);

#ifdef __cplusplus
}
#endif
