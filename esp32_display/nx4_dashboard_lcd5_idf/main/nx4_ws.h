#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─────────────────────────────────────────────────────────────────────────
// WebSocket Server（esp_http_server）
//
// 取代 Arduino 版的 WebSocketsServer。手機端（NX4Board App 第二通道）連進來
// 之後每 200ms 推一筆 esp32_dash JSON。
//
// **收到的文字不會在這裡解析。** httpd 有自己的任務，而 LVGL 不是執行緒安全的，
// 所以 handler 只把最新一筆複製進單槽緩衝，交由 LVGL 任務取走處理。單槽
// 「後到覆蓋先到」正好符合原本 dirty flag 的語意：連續多筆只需渲染最後一筆。
// ─────────────────────────────────────────────────────────────────────────

#define NX4_WS_BUF_SIZE 2048

/// 啟動伺服器。
esp_err_t nx4_ws_start(uint16_t port);

/// 目前連線中的 client 數。
int nx4_ws_clients(void);

/// 取走最新一筆封包。有資料時複製進 out（結尾補 '\0'）並回傳長度，
/// 沒有新資料回傳 0。由 LVGL 任務呼叫。
size_t nx4_ws_take(char *out, size_t max);

/// 是否剛有新的 client 連上（取走後清除）。用來重置欄位診斷。
bool nx4_ws_take_connected_flag(void);

#ifdef __cplusplus
}
#endif
