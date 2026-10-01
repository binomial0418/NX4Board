idf_component_register(
    SRCS
        "main.c"
        "nx4_wifi.c"
        "nx4_ws.c"
        "ui_dashboard.c"
        "ui_settings.c"
        "nx4_font_icons_40.c"
        "nx4_font_icons_64.c"
        "nx4_font_num_100.c"
        "nx4_font_num_112.c"
        "nx4_font_num_145.c"
        "nx4_font_num_310s.c"
        "nx4_font_num_58.c"
        "nx4_font_num_107s.c"
        "nx4_font_num_93s.c"
        "nx4_font_num_94.c"
        "nx4_font_num_82.c"
        "nx4_font_num_48.c"
        "nx4_font_num_64t.c"
        "nx4_font_num_70.c"
        "nx4_font_num_106.c"
        "nx4_font_num_96s.c"
        "nx4_font_tc_26.c"
        "nx4_font_tc_32.c"
        "nx4_font_tc_48.c"
    INCLUDE_DIRS "."
    REQUIRES nx4_config nx4_lcd nx4_touch nx4_audio nx4_obd
             esp_driver_i2c esp_driver_ppa esp_driver_uart esp_wifi esp_netif esp_http_server
             nvs_flash json esp_timer esp_psram
)
