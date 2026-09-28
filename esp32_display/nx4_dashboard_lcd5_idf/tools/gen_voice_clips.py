#!/usr/bin/env python3
"""產生語音提示音檔，輸出成 components/nx4_audio/nx4_voice_clips.c 與 include/nx4_voice_clips.h。

只能在 macOS 上跑（用系統的 `say` 與 `afconvert`）。音色是 Meijia，
台灣中文。板子上原本用的是 esp-sr 的 esp-tts 即時合成，但那是音節拼接，
沒有語調模型，字與字之間是等長的機械停頓，聽起來很不自然；本專案要念的
句子是固定的幾句，直接預錄整句才是對的做法。

流程：say -> 16 kHz 單聲道 16-bit WAV -> 修剪頭尾靜音 -> IMA ADPCM (4:1)
-> C 陣列。約 235 KB，相較之下 esp-tts 光音色庫就要 3.6 MB。

    python3 tools/gen_voice_clips.py
"""
import os
import struct
import subprocess
import sys
import tempfile
import wave

VOICE = "Meijia"
RATE = 16000

# 速限整句全部預錄。台灣的速限標誌基本上都是整十，非整十的值會退回
# 只念「前有測速照相」（見韌體端 nx4_voice_camera_alert）。
SPEED_LIMITS = [20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120]

CLIPS = [
    ("boot", "系統啟動"),
    ("high_beam_on", "遠燈開啟"),
    ("high_beam_off", "遠燈關閉"),
    ("camera", "前有測速照相"),
    ("red_light", "前有闖紅燈照相"),
    ("passed", "通過"),
    ("overpass", "注意天橋偷拍"),
    ("door_open", "車門沒關好"),
    ("traffic", "注意前方路況"),
] + [(f"camera_{n}", f"前有測速照相，速限{n}") for n in SPEED_LIMITS]

# ── IMA ADPCM ────────────────────────────────────────────────────────────
# 韌體端 nx4_voice_decode() 必須與這裡逐位元一致，改一邊就要改另一邊。
STEP_TAB = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
    253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
    1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024,
    3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493,
    10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
    27086, 29794, 32767,
]
INDEX_TAB = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]


def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def adpcm_encode(samples):
    pred, idx, out, nib, hold = 0, 0, bytearray(), 0, 0
    for s in samples:
        step = STEP_TAB[idx]
        diff = s - pred
        code = 0
        if diff < 0:
            code = 8
            diff = -diff
        delta = step >> 3
        if diff >= step:
            code |= 4
            diff -= step
            delta += step
        if diff >= step >> 1:
            code |= 2
            diff -= step >> 1
            delta += step >> 1
        if diff >= step >> 2:
            code |= 1
            delta += step >> 2
        pred = clamp(pred - delta if code & 8 else pred + delta, -32768, 32767)
        idx = clamp(idx + INDEX_TAB[code], 0, 88)
        # 低位 nibble 先存，與解碼端的取樣順序一致
        if nib == 0:
            hold, nib = code, 1
        else:
            out.append((code << 4) | hold)
            nib = 0
    if nib:
        out.append(hold)
    return bytes(out)


# ── 音檔處理 ─────────────────────────────────────────────────────────────
def synth(text, wav_path):
    with tempfile.NamedTemporaryFile(suffix=".aiff", delete=False) as tmp:
        aiff = tmp.name
    try:
        subprocess.run(["say", "-v", VOICE, "-o", aiff, text], check=True)
        subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", aiff, wav_path],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    finally:
        os.unlink(aiff)


def read_wav(path):
    with wave.open(path) as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2 and w.getframerate() == RATE
        n = w.getnframes()
        return list(struct.unpack(f"<{n}h", w.readframes(n)))


def trim(samples, thresh=600, pad_ms=30):
    """去掉 say 在頭尾加的靜音，只留 30ms 緩衝。"""
    pad = RATE * pad_ms // 1000
    lo = next((i for i, s in enumerate(samples) if abs(s) > thresh), 0)
    hi = next((i for i in range(len(samples) - 1, -1, -1) if abs(samples[i]) > thresh),
              len(samples) - 1)
    return samples[max(0, lo - pad):min(len(samples), hi + pad + 1)]


# ── 輸出 ─────────────────────────────────────────────────────────────────
def c_array(data, indent="    "):
    lines = []
    for i in range(0, len(data), 16):
        lines.append(indent + " ".join(f"0x{b:02x}," for b in data[i:i + 16]))
    return "\n".join(lines)


def main():
    if sys.platform != "darwin":
        sys.exit("這個產生器需要 macOS 的 say / afconvert")

    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(here, "..", "components", "nx4_audio")
    h_dir = os.path.join(out_dir, "include")
    clips = []

    with tempfile.TemporaryDirectory() as tmpdir:
        for name, text in CLIPS:
            wav = os.path.join(tmpdir, name + ".wav")
            synth(text, wav)
            samples = trim(read_wav(wav))
            data = adpcm_encode(samples)
            clips.append((name, text, samples, data))
            print(f"{name:16s} {text:12s} {len(samples)/RATE:5.2f}s  {len(data):6d} bytes")

    total = sum(len(d) for _, _, _, d in clips)
    print(f"\n合計 {total/1024:.0f} KB")

    with open(os.path.join(h_dir, "nx4_voice_clips.h"), "w", encoding="utf-8") as f:
        f.write(f"""// 由 tools/gen_voice_clips.py 產生，請勿手動編輯。
// 音色 {VOICE}（台灣中文），{RATE} Hz 單聲道，IMA ADPCM 4-bit。
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {{
#endif

#define NX4_VOICE_SAMPLE_RATE {RATE}

typedef struct {{
    const char    *name;     // 查找用的代號
    const uint8_t *data;     // IMA ADPCM，每個 byte 兩個取樣（低位 nibble 在前）
    uint32_t       samples;  // 解碼後的取樣數
}} nx4_voice_clip_t;

extern const nx4_voice_clip_t nx4_voice_clips[];
extern const int              nx4_voice_clip_count;

#ifdef __cplusplus
}}
#endif
""")

    with open(os.path.join(out_dir, "nx4_voice_clips.c"), "w", encoding="utf-8") as f:
        f.write("// 由 tools/gen_voice_clips.py 產生，請勿手動編輯。\n")
        f.write('#include "nx4_voice_clips.h"\n\n')
        for name, text, samples, data in clips:
            f.write(f"// 「{text}」 {len(samples)/RATE:.2f}s\n")
            f.write(f"static const uint8_t clip_{name}[] = {{\n{c_array(data)}\n}};\n\n")
        f.write("const nx4_voice_clip_t nx4_voice_clips[] = {\n")
        for name, _, samples, _ in clips:
            f.write(f'    {{ "{name}", clip_{name}, {len(samples)} }},\n')
        f.write("};\n\n")
        f.write("const int nx4_voice_clip_count = "
                "(int)(sizeof(nx4_voice_clips) / sizeof(nx4_voice_clips[0]));\n")

    print(f"已寫入 {os.path.normpath(out_dir)}/nx4_voice_clips.c 與 include/nx4_voice_clips.h")


if __name__ == "__main__":
    main()
