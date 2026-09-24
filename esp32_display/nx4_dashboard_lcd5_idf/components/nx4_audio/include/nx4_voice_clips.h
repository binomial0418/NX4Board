// 由 tools/gen_voice_clips.py 產生，請勿手動編輯。
// 音色 Meijia（台灣中文），16000 Hz 單聲道，IMA ADPCM 4-bit。
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NX4_VOICE_SAMPLE_RATE 16000

typedef struct {
    const char    *name;     // 查找用的代號
    const uint8_t *data;     // IMA ADPCM，每個 byte 兩個取樣（低位 nibble 在前）
    uint32_t       samples;  // 解碼後的取樣數
} nx4_voice_clip_t;

extern const nx4_voice_clip_t nx4_voice_clips[];
extern const int              nx4_voice_clip_count;

#ifdef __cplusplus
}
#endif
