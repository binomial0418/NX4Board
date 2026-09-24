#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// hx8394_lcd 是 C++ 類別（與 Arduino 版逐字相同，不改它），
// 而 ESP-IDF 版的 main 是純 C，這一層只是把它包成 C 介面。

/// 初始化 DSI 匯流排、面板與背光。
void nx4_lcd_begin(void);

/// DPI 面板的實體 framebuffer。PPA 旋轉會直接寫進這裡。
void *nx4_lcd_frame_buffer(void);

/// 背光百分比 0-100。
void nx4_lcd_set_backlight(uint32_t percent);

#ifdef __cplusplus
}
#endif
