# ES8311 codec + 預錄語音播放。與 Arduino 版逐字相同。
# nx4_voice_clips.c 是 tools/gen_voice_clips.py 產生的 IMA ADPCM 資料。
# nx4_voice_private.c 是同一支產生器從 tools/private_voice/ 產生的私有音檔（不進 git），
# 沒有時改用空清單 nx4_voice_private_stub.c。
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/nx4_voice_private.c")
    set(NX4_VOICE_PRIVATE "nx4_voice_private.c")
else()
    set(NX4_VOICE_PRIVATE "nx4_voice_private_stub.c")
endif()

idf_component_register(
    SRCS "es8311.c" "nx4_tts.cpp" "nx4_voice_clips.c" "${NX4_VOICE_PRIVATE}"
    INCLUDE_DIRS "include"
    REQUIRES esp_driver_i2c esp_driver_i2s esp_driver_gpio driver
)
