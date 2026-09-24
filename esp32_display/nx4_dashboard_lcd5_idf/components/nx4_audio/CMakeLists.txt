# ES8311 codec + 預錄語音播放。與 Arduino 版逐字相同。
# nx4_voice_clips.c 是 tools/gen_voice_clips.py 產生的 IMA ADPCM 資料。
idf_component_register(
    SRCS "es8311.c" "nx4_tts.cpp" "nx4_voice_clips.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_driver_i2c esp_driver_i2s esp_driver_gpio driver
)
