#ifndef _HX8394_LCD_H
#define _HX8394_LCD_H
#include <stdio.h>
#include "esp_lcd_types.h"
#include "esp_lcd_mipi_dsi.h"

// ─────────────────────────────────────────────────────────────────────────
// Waveshare ESP32-P4-WIFI6-Touch-LCD-5
//   HX8394 MIPI-DSI 720x1280（面板原生為直向）2-lane @ 700 Mbps
//   背光 GPIO26（LEDC 5 kHz / 10-bit）、面板 RST GPIO27
//
// 介面比照同專案 nx4_dashboard/src/lcd/jd9165_lcd.h，好讓 .ino 只需換型別。
// ─────────────────────────────────────────────────────────────────────────

typedef struct {
    esp_lcd_dsi_bus_handle_t    mipi_dsi_bus;  /*!< MIPI DSI bus handle */
    esp_lcd_panel_io_handle_t   io;            /*!< ESP LCD IO handle */
    esp_lcd_panel_handle_t      panel;         /*!< ESP LCD panel (color) handle */
    esp_lcd_panel_handle_t      control;       /*!< ESP LCD panel (control) handle */
} bsp_lcd_handles_t;

class hx8394_lcd
{
public:
    hx8394_lcd(int8_t lcd_rst);

    void begin();
    void example_bsp_enable_dsi_phy_power();
    void example_bsp_init_lcd_backlight();
    void example_bsp_set_lcd_backlight(uint32_t brightness_percent);
    void lcd_draw_bitmap(uint16_t x_start, uint16_t y_start,
                         uint16_t x_end, uint16_t y_end, uint16_t *color_data);
    void draw16bitbergbbitmap(uint16_t x, uint16_t y, uint16_t w, uint16_t h, uint16_t *color_data);
    void fillScreen(uint16_t color);
    void te_on();
    void te_off();
    // 面板原生尺寸（直向）。LVGL 的邏輯尺寸是旋轉後的 1280x720，
    // 定義在 pins_config.h 的 LCD_H_RES / LCD_V_RES。
    uint16_t width();
    uint16_t height();
    // DPI 面板的實體 framebuffer。PPA 旋轉會直接寫進這裡，
    // 不經 esp_lcd_panel_draw_bitmap。
    void *get_frame_buffer();
    void get_handle(bsp_lcd_handles_t *ret_handles);

private:
    int8_t _lcd_rst;
};
#endif
