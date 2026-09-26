#pragma once

#include <stdbool.h>
#include "driver/i2c_master.h"

#ifdef __cplusplus
extern "C" {
#endif

// ─────────────────────────────────────────────────────────────────────────
// 中文語音提示（ES8311 + I2S，播放預錄音檔）
//
// 早期版本用 esp-sr 的 esp-tts 做即時合成，已經拿掉。那是音節拼接式合成，
// 沒有語調模型，字與字之間永遠是等長的機械停頓，調語速只是在「糊成一團」
// 和「每個字拖音」兩種難聽之間移動。本專案要念的句子是固定的幾句，
// 預錄整句才是對的做法。
//
// 音檔由 tools/gen_voice_clips.py 產生（macOS say，音色 Meijia，台灣中文），
// 16 kHz 單聲道、IMA ADPCM 4:1，全部加起來約 235 KB；
// esp-tts 光音色庫就要 3.6 MB。
//
// 解碼與播放跑在獨立的 FreeRTOS 任務，透過佇列接收，
// 不會卡住 LVGL 的 lv_timer_handler()。
// ─────────────────────────────────────────────────────────────────────────

/// 初始化編解碼器與 I2S，並啟動播放任務。
/// bus 是既有的 I2C 匯流排（與 GT911 觸控共用 GPIO 7/8）。
/// 回傳 false 代表 ES8311 沒有回應，此時所有播報呼叫都會被安全忽略。
bool nx4_tts_init(i2c_master_bus_handle_t bus);

/// 依代號播一段音檔（見 nx4_voice_clips.c）。非阻塞，佇列滿時丟棄。
/// 找不到代號只會記一筆警告。
void nx4_tts_say(const char *clip_name);

/// 遠燈開啟 / 關閉
void nx4_tts_high_beam(bool on);

/// 前有測速照相，速限 <limit>。
/// 只有整十的速限有預錄整句，其餘（含 limit <= 0）退回只念「前有測速照相」。
void nx4_tts_camera_alert(int limit);

/// 音量 0~100（預設 75）。可在 nx4_tts_init() 之前呼叫，
/// 初始化時會套用進 codec，所以開機流程可以先讀 NVS 再初始化音訊。
void nx4_tts_set_volume(int volume);
int  nx4_tts_get_volume(void);

/// 調整播放前的靜音長度（毫秒，預設 400）。
/// 第二通道送 {"tts_lead": n}，用來在不重燒韌體的情況下試聽。
void nx4_tts_set_lead_in_ms(int ms);

#ifdef __cplusplus
}
#endif
