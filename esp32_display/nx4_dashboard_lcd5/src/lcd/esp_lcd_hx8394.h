/*
 * SPDX-FileCopyrightText: 2024 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * HX8394 MIPI-DSI 面板驅動（Waveshare ESP32-P4-WIFI6-Touch-LCD-5）
 * 結構沿用同專案 nx4_dashboard/src/lcd/esp_lcd_jd9165.*，只換面板型號、
 * 初始化序列與時序。初始化序列取自原廠 Arduino 範例的
 * examples/arduino/libraries/displays/displays_config.h。
 */

#pragma once

#include <stdint.h>
#include "soc/soc_caps.h"

#if SOC_MIPI_DSI_SUPPORTED
#include "esp_lcd_panel_vendor.h"
#include "esp_lcd_mipi_dsi.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief LCD panel initialization commands.
 */
typedef struct {
    int cmd;                /*<! The specific LCD command */
    const void *data;       /*<! Buffer that holds the command specific data */
    size_t data_bytes;      /*<! Size of `data` in memory, in bytes */
    unsigned int delay_ms;  /*<! Delay in milliseconds after this command */
} hx8394_lcd_init_cmd_t;

/**
 * @brief LCD panel vendor configuration.
 *
 * @note  This structure needs to be passed to the `vendor_config` field in `esp_lcd_panel_dev_config_t`.
 */
typedef struct {
    const hx8394_lcd_init_cmd_t *init_cmds;         /*!< Pointer to initialization commands array. Set to NULL if using default commands. */
    uint16_t init_cmds_size;                        /*<! Number of commands in above array */
    struct {
        esp_lcd_dsi_bus_handle_t dsi_bus;               /*!< MIPI-DSI bus configuration */
        const esp_lcd_dpi_panel_config_t *dpi_config;   /*!< MIPI-DPI panel configuration */
    } mipi_config;
} hx8394_vendor_config_t;

/**
 * @brief Create LCD panel for model HX8394
 */
esp_err_t esp_lcd_new_panel_hx8394(const esp_lcd_panel_io_handle_t io, const esp_lcd_panel_dev_config_t *panel_dev_config,
                                   esp_lcd_panel_handle_t *ret_panel);

/**
 * @brief MIPI-DSI bus configuration structure
 *
 * 原廠規格：2-lane，lane 速率 700 Mbit/s。
 */
#define HX8394_PANEL_BUS_DSI_2CH_CONFIG()                \
    {                                                    \
        .bus_id = 0,                                     \
        .num_data_lanes = 2,                             \
        .phy_clk_src = MIPI_DSI_PHY_CLK_SRC_DEFAULT,     \
        .lane_bit_rate_mbps = 700,                       \
    }

/**
 * @brief MIPI-DBI panel IO configuration structure
 */
#define HX8394_PANEL_IO_DBI_CONFIG()  \
    {                                 \
        .virtual_channel = 0,         \
        .lcd_cmd_bits = 8,            \
        .lcd_param_bits = 8,          \
    }

/**
 * @brief MIPI DPI configuration structure
 *
 * refresh_rate = dpi_clock_freq / (h_res + hspw + hbp + hfp) / (v_res + vspw + vbp + vfp)
 *              = 58 MHz / 800 / 1318 ≈ 55 Hz
 */
#define HX8394_720_1280_PANEL_DPI_CONFIG(px_format)      \
    {                                                    \
        .virtual_channel = 0,                                    \
        .dpi_clk_src = MIPI_DSI_DPI_CLK_SRC_DEFAULT,             \
        .dpi_clock_freq_mhz = 58,                                \
        .pixel_format = px_format,                               \
        .num_fbs = 1,                                            \
        .video_timing = {                                        \
            .h_size = 720,                                       \
            .v_size = 1280,                                      \
            .hsync_pulse_width = 20,                             \
            .hsync_back_porch = 20,                              \
            .hsync_front_porch = 40,                             \
            .vsync_pulse_width = 4,                              \
            .vsync_back_porch = 10,                              \
            .vsync_front_porch = 24,                             \
        },                                                       \
        .flags= {                                                \
            .use_dma2d = true,                                   \
        },                                                       \
    }
#endif

#ifdef __cplusplus
}
#endif
