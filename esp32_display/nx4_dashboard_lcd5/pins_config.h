#pragma once

// ─────────────────────────────────────────────────────────────────────────
// Waveshare ESP32-P4-WIFI6-Touch-LCD-5
//   ESP32-P4（32MB PSRAM 疊封 / 32MB NOR Flash）
//   + HX8394 MIPI-DSI 720x1280 2-lane @ 700 Mbps（面板原生直向）
//   + GT911 電容觸控（板級 I2C，與 ES8311 / ES7210 共用匯流排）
//
// 腳位依原廠 docs/IO_ZH.md 與原理圖：
//   https://github.com/waveshareteam/ESP32-P4-WIFI6-Touch-LCD-5
// ─────────────────────────────────────────────────────────────────────────

// LVGL 的「邏輯」解析度：面板實體是 720x1280 直向，車上要橫著看，
// 因此 LVGL 以 1280x720 繪圖，再由 PPA 在 flush 時做 90 度硬體旋轉，
// 直接寫進 DPI framebuffer。版面座標一律用這組數字。
#define LCD_H_RES 1280
#define LCD_V_RES 720

// 面板實體尺寸（PPA 旋轉的輸出端）
#define PANEL_H_RES 720
#define PANEL_V_RES 1280

// 面板 RST。舊板 JC1060P470C 是 GPIO5。
#define LCD_RST 27
// 背光由 hx8394_lcd.cpp 內的 LEDC（GPIO26 / 5 kHz / 10-bit）管理，
// 這裡不再另外用 GPIO 控制。
#define LCD_LED -1

// 板級 I2C，與舊板巧合相同
#define TP_I2C_SDA 7
#define TP_I2C_SCL 8
// 原理圖上 TP_RST 經 0Ω R37 接 GPIO23、TP_INT 經選配的 R108 接 GPIO2，
// 是否導通視實際貼裝而定。原廠驅動一律配成 NC，改以探測兩個合法 I2C
// 位址（0x5D / 0x14）取代硬體重置。
#define TP_RST -1
#define TP_INT -1
