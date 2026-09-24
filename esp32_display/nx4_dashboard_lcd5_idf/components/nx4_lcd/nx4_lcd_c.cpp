// hx8394_lcd（C++ 類別）的 C 介面包裝，說明見 nx4_lcd_c.h。

#include "nx4_lcd_c.h"
#include "hx8394_lcd.h"
#include "pins_config.h"

static hx8394_lcd s_lcd(LCD_RST);

void nx4_lcd_begin(void) { s_lcd.begin(); }
void *nx4_lcd_frame_buffer(void) { return s_lcd.get_frame_buffer(); }
void nx4_lcd_set_backlight(uint32_t percent) {
    s_lcd.example_bsp_set_lcd_backlight(percent);
}
