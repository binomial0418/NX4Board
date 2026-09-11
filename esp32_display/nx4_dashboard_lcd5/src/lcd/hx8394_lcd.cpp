#include "sdkconfig.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_timer.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_mipi_dsi.h"
#include "esp_lcd_panel_io.h"
#include "esp_ldo_regulator.h"
#include "driver/gpio.h"
#include "driver/ledc.h"
#include "esp_err.h"
#include "esp_log.h"
#include "Arduino.h"

#include "esp_lcd_hx8394.h"
#include "hx8394_lcd.h"

// 面板原生尺寸（直向）。旋轉由 .ino 的 PPA flush 處理。
#define PANEL_H_RES 720
#define PANEL_V_RES 1280

#define MIPI_DPI_PX_FORMAT (LCD_COLOR_PIXEL_FORMAT_RGB565)
#define LCD_BIT_PER_PIXEL (16)

// “VDD_MIPI_DPHY”应供电 2.5V，可从内部 LDO 稳压器或外部 LDO 芯片获取电源
#define EXAMPLE_MIPI_DSI_PHY_PWR_LDO_CHAN 3 // LDO_VO3 连接至 VDD_MIPI_DPHY
#define EXAMPLE_MIPI_DSI_PHY_PWR_LDO_VOLTAGE_MV 2500
#define EXAMPLE_LCD_BK_LIGHT_ON_LEVEL 100
#define EXAMPLE_LCD_BK_LIGHT_OFF_LEVEL 0
// LCD-5 的背光接 GPIO26（舊板 JC1060P470C 是 GPIO23）
#define EXAMPLE_PIN_NUM_BK_LIGHT GPIO_NUM_26
// 原廠 BSP 的背光 PWM 是 5 kHz / 10-bit，與舊板的 20 kHz 不同
#define EXAMPLE_LCD_BK_LIGHT_FREQ_HZ 5000

#define LCD_LEDC_CH           LEDC_CHANNEL_0

static const char *TAG = "hx8394_lcd";
static esp_lcd_panel_handle_t panel_handle = NULL;
static esp_lcd_panel_io_handle_t io_handle = NULL;
static void *fb0 = NULL;

hx8394_lcd::hx8394_lcd(int8_t lcd_rst)
{
    _lcd_rst = lcd_rst;
}

void hx8394_lcd::example_bsp_enable_dsi_phy_power()
{
    // 打开 MIPI DSI PHY 的电源，使其从“无电”状态进入“关机”状态
    esp_ldo_channel_handle_t ldo_mipi_phy = NULL;
#ifdef EXAMPLE_MIPI_DSI_PHY_PWR_LDO_CHAN
    esp_ldo_channel_config_t ldo_mipi_phy_config = {
        .chan_id = EXAMPLE_MIPI_DSI_PHY_PWR_LDO_CHAN,
        .voltage_mv = EXAMPLE_MIPI_DSI_PHY_PWR_LDO_VOLTAGE_MV,
    };
    ESP_ERROR_CHECK(esp_ldo_acquire_channel(&ldo_mipi_phy_config, &ldo_mipi_phy));
    ESP_LOGI(TAG, "MIPI DSI PHY Powered on");
#endif
}

void hx8394_lcd::example_bsp_init_lcd_backlight()
{
#if EXAMPLE_PIN_NUM_BK_LIGHT >= 0
    const ledc_channel_config_t LCD_backlight_channel = {
        .gpio_num = EXAMPLE_PIN_NUM_BK_LIGHT,
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel = LCD_LEDC_CH,
        .intr_type = LEDC_INTR_DISABLE,
        .timer_sel = LEDC_TIMER_1,
        .duty = 0,
        .hpoint = 0
    };
    const ledc_timer_config_t LCD_backlight_timer = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .duty_resolution = LEDC_TIMER_10_BIT,
        .timer_num = LEDC_TIMER_1,
        .freq_hz = EXAMPLE_LCD_BK_LIGHT_FREQ_HZ,
        .clk_cfg = LEDC_AUTO_CLK
    };

    ledc_timer_config(&LCD_backlight_timer);
    ledc_channel_config(&LCD_backlight_channel);
#endif
}

void hx8394_lcd::example_bsp_set_lcd_backlight(uint32_t brightness_percent)
{
#if EXAMPLE_PIN_NUM_BK_LIGHT >= 0
    if (brightness_percent > 100) {
        brightness_percent = 100;
    }

    ESP_LOGI(TAG, "Setting LCD backlight: %d%%", (int)brightness_percent);
    uint32_t duty_cycle = (1023 * brightness_percent) / 100; // 10-bit: 100% = 1023
    ledc_set_duty(LEDC_LOW_SPEED_MODE, LCD_LEDC_CH, duty_cycle);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, LCD_LEDC_CH);
#endif
}

void hx8394_lcd::begin()
{
    example_bsp_enable_dsi_phy_power();
    example_bsp_init_lcd_backlight();
    example_bsp_set_lcd_backlight(EXAMPLE_LCD_BK_LIGHT_OFF_LEVEL);

    // 首先创建 MIPI DSI 总线，它还将初始化 DSI PHY
    esp_lcd_dsi_bus_handle_t mipi_dsi_bus;
    esp_lcd_dsi_bus_config_t bus_config = HX8394_PANEL_BUS_DSI_2CH_CONFIG();
    ESP_ERROR_CHECK(esp_lcd_new_dsi_bus(&bus_config, &mipi_dsi_bus));

    ESP_LOGI(TAG, "Install MIPI DSI LCD control panel");
    // 我们使用 DBI 接口发送 LCD 命令和参数
    esp_lcd_dbi_io_config_t dbi_config = HX8394_PANEL_IO_DBI_CONFIG();
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_dbi(mipi_dsi_bus, &dbi_config, &io_handle));

    // 创建 HX8394 控制面板
    esp_lcd_dpi_panel_config_t dpi_config = HX8394_720_1280_PANEL_DPI_CONFIG(MIPI_DPI_PX_FORMAT);

    hx8394_vendor_config_t vendor_config = {
        .mipi_config = {
            .dsi_bus = mipi_dsi_bus,
            .dpi_config = &dpi_config,
        },
    };
    const esp_lcd_panel_dev_config_t panel_config = {
        .reset_gpio_num = _lcd_rst,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = LCD_BIT_PER_PIXEL,
        .vendor_config = &vendor_config,
    };
    ESP_ERROR_CHECK(esp_lcd_new_panel_hx8394(io_handle, &panel_config, &panel_handle));
    ESP_ERROR_CHECK(esp_lcd_panel_reset(panel_handle));
    ESP_ERROR_CHECK(esp_lcd_panel_init(panel_handle));

    // 取得 DPI framebuffer，供 PPA 旋轉直接寫入
    ESP_ERROR_CHECK(esp_lcd_dpi_panel_get_frame_buffer(panel_handle, 1, &fb0));
    ESP_LOGI(TAG, "DPI frame buffer @%p (%dx%d)", fb0, PANEL_H_RES, PANEL_V_RES);

    // 打开背光
    example_bsp_set_lcd_backlight(EXAMPLE_LCD_BK_LIGHT_ON_LEVEL);
}

void hx8394_lcd::lcd_draw_bitmap(uint16_t x_start, uint16_t y_start, uint16_t x_end, uint16_t y_end, uint16_t *color_data)
{
    esp_lcd_panel_draw_bitmap(panel_handle, x_start, y_start, x_end, y_end, color_data);
}

void hx8394_lcd::draw16bitbergbbitmap(uint16_t x, uint16_t y, uint16_t w, uint16_t h, uint16_t *color_data)
{
    esp_lcd_panel_draw_bitmap(panel_handle, x, y, x + w, y + h, color_data);
}

void hx8394_lcd::fillScreen(uint16_t color)
{
    if (!fb0) {
        return;
    }
    uint16_t *p = (uint16_t *)fb0;
    for (size_t i = 0; i < (size_t)PANEL_H_RES * PANEL_V_RES; i++) {
        p[i] = color;
    }
}

void hx8394_lcd::te_on()
{
    esp_lcd_panel_io_tx_param(io_handle, 0x35, new (uint8_t[]){0x00}, 1);
}

void hx8394_lcd::te_off()
{
    esp_lcd_panel_io_tx_param(io_handle, 0x34, new (uint8_t[]){0x00}, 0);
}

uint16_t hx8394_lcd::width()
{
    return PANEL_H_RES;
}

uint16_t hx8394_lcd::height()
{
    return PANEL_V_RES;
}

void *hx8394_lcd::get_frame_buffer()
{
    return fb0;
}

void hx8394_lcd::get_handle(bsp_lcd_handles_t *ret_handles)
{
    ret_handles->io = io_handle;
    ret_handles->mipi_dsi_bus = NULL;
    ret_handles->panel = panel_handle;
    ret_handles->control = NULL;
}
