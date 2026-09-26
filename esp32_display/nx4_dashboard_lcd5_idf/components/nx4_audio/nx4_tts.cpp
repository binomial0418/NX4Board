// 中文語音提示：ES8311 codec + I2S，播放預錄的 IMA ADPCM 音檔。
// 介面與設計說明見 nx4_tts.h。

#include "nx4_tts.h"

#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "driver/i2s.h"
#include "driver/gpio.h"
#include "esp_log.h"

#include "es8311.h"
#include "nx4_voice_clips.h"

static const char *TAG = "nx4_tts";

// 板上音訊接腳（Waveshare ESP32-P4-WIFI6-Touch-LCD-5，取自官方 09_Audio_Playback 範例）
#define PIN_AMP_EN   53   // 功放致能，低電位靜音
#define PIN_I2S_MCLK 13
#define PIN_I2S_BCLK 12
#define PIN_I2S_LRCK 10
#define PIN_I2S_DOUT 9

#define I2S_PORT     I2S_NUM_0
#define ES8311_ADDR  0x18
#define TTS_VOLUME_DEFAULT 75   // ES8311 音量 0~100

#define NAME_LEN     24
#define QUEUE_LEN    4

// 一次送進 I2S 的立體聲影格數。音檔是單聲道，
// 但 ES8311 走標準 I2S 兩聲道，所以每個取樣要複製成左右各一份。
#define CHUNK_FRAMES 256

// 拉高功放致能之後先送這麼久的靜音再開始播音檔。
// 功放從 shutdown 醒來、ES8311 的 DAC 解除靜音都需要時間，
// 沒有這段墊底的話第一個字會被吃掉一半。實測要 400ms 才完整。
#define LEAD_IN_MS   400

typedef struct {
    char name[NAME_LEN];
} tts_msg_t;

static es8311_handle_t         s_codec   = NULL;
static QueueHandle_t           s_queue   = NULL;
static i2c_master_dev_handle_t s_i2c_dev = NULL;
static bool                    s_ready   = false;
static int16_t                 s_stereo[CHUNK_FRAMES * 2];
static int                     s_lead_in_ms = LEAD_IN_MS;
static int                     s_volume = TTS_VOLUME_DEFAULT;

// ── IMA ADPCM 解碼 ───────────────────────────────────────────────────────
// 必須與 tools/gen_voice_clips.py 的編碼器逐位元一致，改一邊就要改另一邊。
static const int16_t kStepTab[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
    253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
    1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024,
    3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493,
    10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
    27086, 29794, 32767,
};
static const int8_t kIndexTab[16] = {
    -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8,
};

typedef struct {
    int32_t pred;
    int32_t idx;
} adpcm_state_t;

static inline int16_t adpcm_step(adpcm_state_t *st, uint8_t code) {
    int32_t step = kStepTab[st->idx];
    int32_t delta = step >> 3;
    if (code & 4) delta += step;
    if (code & 2) delta += step >> 1;
    if (code & 1) delta += step >> 2;

    int32_t pred = (code & 8) ? st->pred - delta : st->pred + delta;
    if (pred < -32768) pred = -32768;
    if (pred > 32767) pred = 32767;
    st->pred = pred;

    int32_t idx = st->idx + kIndexTab[code];
    if (idx < 0) idx = 0;
    if (idx > 88) idx = 88;
    st->idx = idx;

    return (int16_t) pred;
}

// ── 播放 ─────────────────────────────────────────────────────────────────
static const nx4_voice_clip_t *find_clip(const char *name) {
    for (int i = 0; i < nx4_voice_clip_count; i++) {
        if (strcmp(nx4_voice_clips[i].name, name) == 0) return &nx4_voice_clips[i];
    }
    return NULL;
}

static void write_silence(int ms) {
    memset(s_stereo, 0, sizeof(s_stereo));
    int frames = NX4_VOICE_SAMPLE_RATE * ms / 1000;
    while (frames > 0) {
        int n = frames > CHUNK_FRAMES ? CHUNK_FRAMES : frames;
        size_t written = 0;
        i2s_write(I2S_PORT, s_stereo, (size_t) n * 2 * sizeof(int16_t), &written, portMAX_DELAY);
        frames -= n;
    }
}

static void play_clip(const char *name) {
    const nx4_voice_clip_t *clip = find_clip(name);
    if (!clip) {
        ESP_LOGW(TAG, "沒有這段音檔: %s", name);
        return;
    }

    adpcm_state_t st = {0, 0};
    uint32_t done = 0;

    gpio_set_level((gpio_num_t) PIN_AMP_EN, 1);
    write_silence(s_lead_in_ms);

    while (done < clip->samples) {
        uint32_t n = clip->samples - done;
        if (n > CHUNK_FRAMES) n = CHUNK_FRAMES;
        for (uint32_t i = 0; i < n; i++) {
            uint32_t s = done + i;
            uint8_t byte = clip->data[s >> 1];
            // 編碼端低位 nibble 先寫，這裡要照同樣順序取
            uint8_t code = (s & 1) ? (byte >> 4) : (byte & 0x0F);
            int16_t v = adpcm_step(&st, code);
            s_stereo[i * 2] = v;
            s_stereo[i * 2 + 1] = v;
        }
        size_t written = 0;
        i2s_write(I2S_PORT, s_stereo, (size_t) n * 2 * sizeof(int16_t), &written, portMAX_DELAY);
        done += n;
    }

    // 等 DMA 把尾巴吐完再靜音，否則最後一個字會被切掉。
    vTaskDelay(pdMS_TO_TICKS(120));
    i2s_zero_dma_buffer(I2S_PORT);
    gpio_set_level((gpio_num_t) PIN_AMP_EN, 0);
}

static void tts_task(void *arg) {
    tts_msg_t msg;
    for (;;) {
        if (xQueueReceive(s_queue, &msg, portMAX_DELAY) == pdTRUE) {
            play_clip(msg.name);
        }
    }
}

// ── 初始化 ───────────────────────────────────────────────────────────────
static bool codec_begin(i2c_master_bus_handle_t bus) {
    i2c_device_config_t dev_cfg = {};
    dev_cfg.dev_addr_length = I2C_ADDR_BIT_LEN_7;
    dev_cfg.device_address = ES8311_ADDR;
    dev_cfg.scl_speed_hz = 100000;
    if (i2c_master_bus_add_device(bus, &dev_cfg, &s_i2c_dev) != ESP_OK) {
        ESP_LOGE(TAG, "ES8311 掛不上 I2C 匯流排");
        return false;
    }
    es8311_set_i2c_dev(s_i2c_dev);

    s_codec = es8311_create(0, ES8311_ADDR);
    if (!s_codec) {
        ESP_LOGE(TAG, "es8311_create 失敗");
        return false;
    }
    return true;
}

bool nx4_tts_init(i2c_master_bus_handle_t bus) {
    if (s_ready) return true;

    // 先把功放關著，初始化過程的雜訊不要送出去。
    gpio_config_t amp = {};
    amp.pin_bit_mask = 1ULL << PIN_AMP_EN;
    amp.mode = GPIO_MODE_OUTPUT;
    gpio_config(&amp);
    gpio_set_level((gpio_num_t) PIN_AMP_EN, 0);

    if (!codec_begin(bus)) return false;

    const int rate = NX4_VOICE_SAMPLE_RATE;

    i2s_config_t i2s_cfg = {};
    i2s_cfg.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX);
    i2s_cfg.sample_rate = rate;
    i2s_cfg.bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT;
    i2s_cfg.channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT;
    i2s_cfg.communication_format = I2S_COMM_FORMAT_STAND_I2S;
    i2s_cfg.intr_alloc_flags = ESP_INTR_FLAG_LEVEL1;
    i2s_cfg.dma_buf_count = 8;
    i2s_cfg.dma_buf_len = 64;
    i2s_cfg.use_apll = false;
    i2s_cfg.tx_desc_auto_clear = true;
    i2s_cfg.mclk_multiple = I2S_MCLK_MULTIPLE_256;

    i2s_pin_config_t pins = {};
    pins.mck_io_num = PIN_I2S_MCLK;
    pins.bck_io_num = PIN_I2S_BCLK;
    pins.ws_io_num = PIN_I2S_LRCK;
    pins.data_out_num = PIN_I2S_DOUT;
    pins.data_in_num = I2S_PIN_NO_CHANGE;

    if (i2s_driver_install(I2S_PORT, &i2s_cfg, 0, NULL) != ESP_OK ||
        i2s_set_pin(I2S_PORT, &pins) != ESP_OK) {
        ESP_LOGE(TAG, "I2S 初始化失敗");
        return false;
    }

    es8311_clock_config_t clk = {};
    clk.mclk_from_mclk_pin = true;
    clk.mclk_frequency = rate * 256;
    clk.sample_frequency = rate;

    if (es8311_init(s_codec, &clk, ES8311_RESOLUTION_16, ES8311_RESOLUTION_16) != ESP_OK) {
        ESP_LOGE(TAG, "ES8311 無回應，語音功能停用");
        return false;
    }
    es8311_sample_frequency_config(s_codec, rate * 256, rate);
    es8311_microphone_config(s_codec, false);   // 只放音，不錄音
    es8311_voice_volume_set(s_codec, s_volume, NULL);

    s_queue = xQueueCreate(QUEUE_LEN, sizeof(tts_msg_t));
    if (!s_queue) return false;

    // 優先權壓在 LVGL（loop() 跑在 priority 1）之上一級，
    // 但仍低於 Wi-Fi/DSI，語音不該搶到畫面更新前面太多。
    xTaskCreatePinnedToCore(tts_task, "nx4_tts", 4096, NULL, 2, NULL, 1);

    s_ready = true;
    ESP_LOGI(TAG, "語音就緒（%d Hz，%d 段音檔）", rate, nx4_voice_clip_count);
    return true;
}

// ── 播報介面 ─────────────────────────────────────────────────────────────
void nx4_tts_say(const char *clip_name) {
    if (!s_ready || !clip_name || !*clip_name) return;
    tts_msg_t msg;
    strncpy(msg.name, clip_name, sizeof(msg.name) - 1);
    msg.name[sizeof(msg.name) - 1] = '\0';
    // 佇列滿就丟掉：遲到的播報沒有意義，寧可漏念也不要卡住呼叫端。
    xQueueSend(s_queue, &msg, 0);
}

void nx4_tts_high_beam(bool on) {
    nx4_tts_say(on ? "high_beam_on" : "high_beam_off");
}

void nx4_tts_camera_alert(int limit) {
    // 只有整十的速限有預錄整句；其餘退回只念「前有測速照相」，
    // 總比把數字硬拼出來好聽。
    if (limit > 0 && limit % 10 == 0) {
        char name[NAME_LEN];
        snprintf(name, sizeof(name), "camera_%d", limit);
        if (find_clip(name)) {
            nx4_tts_say(name);
            return;
        }
    }
    nx4_tts_say("camera");
}

// 調整開頭靜音長度，用來在不重燒韌體的情況下找出功放的喚醒時間。
// 第二通道送 {"tts_lead": 毫秒}。
void nx4_tts_set_lead_in_ms(int ms) {
    if (ms < 0) ms = 0;
    if (ms > 1000) ms = 1000;
    s_lead_in_ms = ms;
    ESP_LOGI(TAG, "開頭靜音改為 %d ms", ms);
}

void nx4_tts_set_volume(int volume) {
    if (volume < 0) volume = 0;
    if (volume > 100) volume = 100;
    s_volume = volume;
    // 還沒初始化也要記下來，nx4_tts_init() 會在設定 codec 時套用，
    // 這樣開機時「先讀 NVS 再初始化音訊」的順序才不會被音量蓋掉。
    if (s_codec) es8311_voice_volume_set(s_codec, s_volume, NULL);
}

int nx4_tts_get_volume(void) { return s_volume; }
