#include "sdkconfig.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_err.h"
#include "esp_log.h"
#include "driver/i2c_master.h"
#include "esp_lcd_touch_gt911.h"
#include "gt911_touch.h"

// GT911 回報的是「面板原生」座標，也就是直向的 720x1280。
// 轉成 LVGL 的橫向 1280x720 是在 .ino 的 my_touchpad_read() 做的，
// 這裡不動 swap_xy / mirror，好讓序列埠印出的原始座標保持可讀。
#define CONFIG_LCD_HRES 720
#define CONFIG_LCD_VRES 1280

static const char *TAG = "gt911";

esp_lcd_touch_handle_t tp = NULL;
esp_lcd_panel_io_handle_t tp_io_handle = NULL;

uint16_t touch_strength[1];
uint8_t touch_cnt = 0;

gt911_touch::gt911_touch(int8_t sda_pin, int8_t scl_pin, int8_t rst_pin, int8_t int_pin)
{
    _sda = sda_pin;
    _scl = scl_pin;
    _rst = rst_pin;
    _int = int_pin;
}

void gt911_touch::begin()
{
    i2c_master_bus_handle_t i2c_handle = NULL;
    i2c_master_get_bus_handle(1, &i2c_handle);

    esp_lcd_panel_io_i2c_config_t tp_io_config = ESP_LCD_TOUCH_IO_I2C_GT911_CONFIG();
    tp_io_config.scl_speed_hz = 100000;

    // LCD-5 不主動控制 TP_RST/TP_INT，所以 GT911 醒來時用哪個位址是不確定的。
    // 先探測 0x5D，沒回應再退到 0x14；兩個都不在就放棄觸控但繼續開機，
    // 儀表本身不需要觸控也能用（設定改用 config.h）。
    if (i2c_master_probe(i2c_handle, ESP_LCD_TOUCH_IO_I2C_GT911_ADDRESS, 100) == ESP_OK) {
        tp_io_config.dev_addr = ESP_LCD_TOUCH_IO_I2C_GT911_ADDRESS;
    } else if (i2c_master_probe(i2c_handle, ESP_LCD_TOUCH_IO_I2C_GT911_ADDRESS_BACKUP, 100) == ESP_OK) {
        tp_io_config.dev_addr = ESP_LCD_TOUCH_IO_I2C_GT911_ADDRESS_BACKUP;
    } else {
        ESP_LOGE(TAG, "GT911 在 0x5D 與 0x14 都沒有回應，停用觸控");
        return;
    }
    ESP_LOGI(TAG, "GT911 位址 0x%02X", (unsigned)tp_io_config.dev_addr);

    esp_lcd_new_panel_io_i2c(i2c_handle, &tp_io_config, &tp_io_handle);

    esp_lcd_touch_config_t tp_cfg = {
        .x_max = CONFIG_LCD_HRES,
        .y_max = CONFIG_LCD_VRES,
        .rst_gpio_num = (gpio_num_t)_rst,
        .int_gpio_num = (gpio_num_t)_int,
        .levels = {
            .reset = 0,
            .interrupt = 0,
        },
        .flags = {
            .swap_xy = 0,
            .mirror_x = 0,
            .mirror_y = 0,
        },
    };

    ESP_LOGI(TAG, "Initialize touch controller gt911");
    ESP_ERROR_CHECK(esp_lcd_touch_new_i2c_gt911(tp_io_handle, &tp_cfg, &tp));
}

bool gt911_touch::getTouch(uint16_t *x, uint16_t *y)
{
    if (tp == NULL) {
        return false;
    }
    esp_lcd_touch_read_data(tp);
    return esp_lcd_touch_get_coordinates(tp, x, y, touch_strength, &touch_cnt, 1);
}

void gt911_touch::set_rotation(uint8_t r)
{
    if (tp == NULL) {
        return;
    }
    switch (r) {
    case 0:
    case 2:
        esp_lcd_touch_set_swap_xy(tp, false);
        esp_lcd_touch_set_mirror_x(tp, false);
        esp_lcd_touch_set_mirror_y(tp, false);
        break;
    case 1:
    case 3:
        esp_lcd_touch_set_swap_xy(tp, false);
        esp_lcd_touch_set_mirror_x(tp, true);
        esp_lcd_touch_set_mirror_y(tp, true);
        break;
    }
}
