#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─────────────────────────────────────────────────────────────────────────
// BLE 傳輸層：連上 ELM327 相容的 OBD dongle
//
// 手機端走的是 Bluetooth Classic SPP（lib/services/obd_spp_service.dart 的
// classic_bt channel），但這塊板子做不到——ESP32-P4 沒有射頻，唯一的無線
// 晶片是 ESP32-C6，而 C6 的 soc_caps.h 只有 SOC_BLE_SUPPORTED，沒有
// SOC_BT_CLASSIC_SUPPORTED。這是矽層級的限制。
//
// 所以這裡走 BLE GATT。UUID 取自 obdlab/ble.py（同一顆 dongle 實測過）：
//
//   Service 18F0    序列橋接
//   2AF0  (notify)  ELM → 我們
//   2AF1  (write)   我們 → ELM
//
// NimBLE 的 host 跑在 P4，controller 在 C6，中間走 ESP-Hosted 的 VHCI，
// 相關 sdkconfig 見 sdkconfig.defaults 的「BLE」區塊。
// ─────────────────────────────────────────────────────────────────────────

/// 收到 dongle 回傳的位元組。在 NimBLE 的 host 任務裡呼叫，
/// 實作端請只做「丟進緩衝」這類短工作，不要阻塞。
typedef void (*nx4_ble_rx_cb_t)(const uint8_t *data, size_t len);

/// 啟動 BLE：初始化 NimBLE、掃描指定名稱的裝置、連線、找到上面那組
/// characteristic 並訂閱 notify。斷線後會自動重新掃描。
/// name 會被複製一份，呼叫端不必保留。
void nx4_ble_start(const char *name, nx4_ble_rx_cb_t on_rx);

/// 改連另一個名稱（設定頁改了裝置名稱時用）。會先斷線再重新掃描。
void nx4_ble_set_name(const char *name);

/// 是否已連線且 characteristic 都就緒。
bool nx4_ble_ready(void);

/// 寫一段資料給 dongle。BLE 預設 MTU 只有 23（可用 20 bytes），
/// 超過會自動切段。未就緒時回傳 false。
bool nx4_ble_write(const uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif
