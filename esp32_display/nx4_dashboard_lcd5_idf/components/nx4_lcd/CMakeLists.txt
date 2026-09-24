# HX8394 MIPI-DSI 面板驅動。與 Arduino 版逐字相同（只拿掉一個沒用到的
# Arduino.h include），本來就只用 esp_lcd / driver/ledc 這些 IDF API。
idf_component_register(
    SRCS "esp_lcd_hx8394.c" "hx8394_lcd.cpp" "nx4_lcd_c.cpp"
    INCLUDE_DIRS "include"
    REQUIRES nx4_config esp_lcd esp_driver_gpio esp_driver_ledc esp_mm esp_timer driver
)
