#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// gt911_touch 是 C++ 類別（與 Arduino 版逐字相同，不改它），
// 而 ESP-IDF 版的 main 是純 C，這一層只是把它包成 C 介面。

/// 初始化觸控。必須在 i2c_new_master_bus(I2C_NUM_1, ...) 之後呼叫——
/// 驅動內部是用 i2c_master_get_bus_handle(1, ...) 取既有匯流排，不另開。
void nx4_touch_begin(void);

/// 讀一次觸控。回傳面板原生的直向座標（0..719, 0..1279）。
bool nx4_touch_read(uint16_t *x, uint16_t *y);

#ifdef __cplusplus
}
#endif
