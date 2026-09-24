# NX4Board ESP32-P4 車載儀表（ESP-IDF 版）
#
# 與 Arduino 版（../nx4_dashboard_lcd5）同一份 UI、驅動與字型，差別只在
# 平台層：WiFi 走 esp_wifi、WebSocket 走 esp_http_server、設定走 nvs_flash。
#
# 改用 ESP-IDF 的原因是 esp_hosted 的版本可以自己指定。Arduino core 綁死
# 主機端 2.11.6，而本板 ESP32-C6 的出廠韌體對應的是 1.4.x，版本不符會
# 造成封包大量遺失（詳見 main/idf_component.yml 與 README）。
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(nx4_dashboard_lcd5_idf)

# 沿用 Arduino 版那份手寫的 lv_conf.h，而不是 LVGL 元件的 Kconfig。
# 版面、字型、LV_USE_FONT_COMPRESSED=0 這些設定都在裡面，兩版共用同一份
# 才不會在移植時悄悄跑掉。搭配 sdkconfig.defaults 的 CONFIG_LV_CONF_SKIP=n。
idf_build_set_property(COMPILE_DEFINITIONS
    "LV_CONF_PATH=${CMAKE_CURRENT_LIST_DIR}/main/lv_conf.h" APPEND)
