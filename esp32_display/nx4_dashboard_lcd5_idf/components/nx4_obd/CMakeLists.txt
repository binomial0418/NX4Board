# 直連 OBD：BLE 傳輸 + ELM327 指令層 + PID 解析。
# 手機端對應的是 lib/services/obd_spp_service.dart。
idf_component_register(
    SRCS "nx4_ble.c"
    INCLUDE_DIRS "include"
    REQUIRES nx4_config bt esp_timer
)
