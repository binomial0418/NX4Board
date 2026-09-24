# GT911 觸控。與 Arduino 版逐字相同。
idf_component_register(
    SRCS "esp_lcd_touch.c" "esp_lcd_touch_gt911.c" "gt911_touch.cpp" "nx4_touch_c.cpp"
    INCLUDE_DIRS "include"
    REQUIRES nx4_config esp_lcd esp_driver_i2c esp_driver_gpio driver
)
