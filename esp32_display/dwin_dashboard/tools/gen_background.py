#!/usr/bin/env python3
"""
DWIN DMG12480C068 (1280x480) 儀表背景圖產生器。

DGUS 的畫面分兩層：
  背景圖（靜態）— 卡片框、色條、中文標籤、單位。打包成 .ICL 下載到螢幕。
  變數控制項（動態）— 數值由 MCU 寫 VP，螢幕自己疊上去，定義在 14.BIN。

因此輸出兩張圖：
  background.png  只有靜態元素，這張才是要轉 ICL 的
  preview.png     背景加上範例數值，僅供評估版面

用程式產生而非手拉，是為了讓美術素材也能進版控、能 diff、能重現。
"""
import os, sys
from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 480
OUT = os.path.join(os.path.dirname(__file__), "..", "assets")
FONTS = sys.argv[1] if len(sys.argv) > 1 else "fonts"

# ── 配色（沿用 LVGL 版）────────────────────────────────────────────────
BG      = (0x00, 0x00, 0x00)
CARD    = (0x0D, 0x11, 0x17)
TEXT    = (0xFF, 0xFF, 0xFF)
LABEL   = (0xE2, 0xE8, 0xF0)
UNIT    = (0x8B, 0x95, 0xA5)
BLUE    = (0x2E, 0x7D, 0xF7)
TEAL    = (0x14, 0xB8, 0xA6)
CYAN    = (0x38, 0xBD, 0xF8)
ORANGE  = (0xF5, 0x9E, 0x0B)
RED     = (0xEF, 0x44, 0x44)
AMBER   = (0xF9, 0x73, 0x16)
DIVIDER = (0x2A, 0x30, 0x3B)
BAR_BG  = (0x2A, 0x30, 0x3B)

# ── 左右卡片欄 ─────────────────────────────────────────────────────────
PAD      = 12
COL_W    = 320
LEFT_X   = PAD
RIGHT_X  = W - PAD - COL_W
ROW_H    = 144
ROW_GAP  = 12
ROW_Y    = [PAD, PAD + ROW_H + ROW_GAP, PAD + 2 * (ROW_H + ROW_GAP)]
ACCENT_W = 5

# ── 中央區：時速 / 轉速 / 增壓 由上而下垂直排列 ────────────────────────
CX            = W // 2
# 單位是靜態的（畫在背景圖裡）位置不能動，所以數值一律「靠右對齊」，
# 單位緊貼在它的右下角。若數值置中，位數變化時與單位的間距就會不一致。
SPEED_RIGHT   = 796      # 時速數字的右緣
SPEED_BASE    = 203      # 時速數字的基線
SPEED_UNIT_X  = 810      # km/h 起點（貼在數字右下角）
RPM_RIGHT     = 690
RPM_BASE      = 317
RPM_UNIT_X    = 702
RPM_CY        = 297
TURBO_CY      = 374
TURBO_BAR_Y   = 420
TURBO_BAR_W   = 460
TURBO_BAR_X   = CX - TURBO_BAR_W // 2

def f(name, size):
    return ImageFont.truetype(os.path.join(FONTS, name), size)

F_TC     = lambda s: f("NotoSansTC.ttf", s)
F_NUM    = lambda s: f("Montserrat.ttf", s)
F_NUM_SB = lambda s: f("Montserrat-SemiBold.ttf", s)

def card(d, x, y, w, h, accent):
    d.rectangle([x, y, x + w - 1, y + h - 1], fill=CARD)
    d.rectangle([x, y, x + ACCENT_W - 1, y + h - 1], fill=accent)

def text(d, xy, s, font, fill, anchor="la"):
    d.text(xy, s, font=font, fill=fill, anchor=anchor)

# ─────────────────────────────────────────────────────────────────────────
def draw_static(d):
    # 左欄
    card(d, LEFT_X, ROW_Y[0], COL_W, ROW_H, TEAL)
    text(d, (LEFT_X + 20, ROW_Y[0] + 12), "Hev電池", F_TC(24), LABEL)
    text(d, (LEFT_X + COL_W - 16, ROW_Y[0] + ROW_H - 26), "%", F_NUM(22), UNIT, "ra")

    card(d, LEFT_X, ROW_Y[1], COL_W, ROW_H, CYAN)
    text(d, (LEFT_X + 20, ROW_Y[1] + 12), "水溫", F_TC(24), LABEL)
    text(d, (LEFT_X + COL_W - 16, ROW_Y[1] + ROW_H - 26), "°C", F_NUM(22), UNIT, "ra")

    card(d, LEFT_X, ROW_Y[2], COL_W, ROW_H, AMBER)

    # 右欄
    card(d, RIGHT_X, ROW_Y[0], COL_W, ROW_H, ORANGE)
    text(d, (RIGHT_X + 20, ROW_Y[0] + 12), "胎壓 (PSI)", F_TC(24), LABEL)

    card(d, RIGHT_X, ROW_Y[1], COL_W, ROW_H, CYAN)
    text(d, (RIGHT_X + 20, ROW_Y[1] + 26), "里程", F_TC(24), LABEL)
    text(d, (RIGHT_X + COL_W - 16, ROW_Y[1] + 32), "K", F_NUM(20), UNIT, "ra")
    d.line([RIGHT_X + 20, ROW_Y[1] + 72, RIGHT_X + COL_W - 20, ROW_Y[1] + 72], fill=DIVIDER)
    text(d, (RIGHT_X + 20, ROW_Y[1] + 92), "油箱", F_TC(24), LABEL)
    text(d, (RIGHT_X + COL_W - 16, ROW_Y[1] + 98), "%", F_NUM(20), UNIT, "ra")

    card(d, RIGHT_X, ROW_Y[2], COL_W, ROW_H, RED)
    text(d, (RIGHT_X + 20, ROW_Y[2] + 12), "道路速限", F_TC(24), LABEL)

    # 中央區的固定文字：單位貼在各自數值的右下角，與數值基線對齊
    text(d, (SPEED_UNIT_X, SPEED_BASE), "km/h", F_NUM(34), UNIT, "ls")
    text(d, (RPM_UNIT_X, RPM_BASE), "RPM", F_NUM(22), UNIT, "ls")

    # 增壓：軌道、中線、刻度
    d.rectangle([TURBO_BAR_X, TURBO_BAR_Y,
                 TURBO_BAR_X + TURBO_BAR_W, TURBO_BAR_Y + 7], fill=BAR_BG)
    d.line([CX, TURBO_BAR_Y - 4, CX, TURBO_BAR_Y + 11], fill=UNIT)
    for i, lbl in enumerate(["-1", "-0.5", "0", "+0.5", "+1"]):
        text(d, (TURBO_BAR_X + i * TURBO_BAR_W // 4, TURBO_BAR_Y + 16),
             lbl, F_NUM(15), UNIT, "ma")

def draw_dynamic(d):
    """MCU 透過 VP 寫入、由螢幕疊上去的部分。僅供預覽。"""
    # 左欄
    text(d, (LEFT_X + 26, ROW_Y[0] + 46), "65.5", F_NUM(72), TEXT)
    text(d, (LEFT_X + 26, ROW_Y[1] + 46), "88",   F_NUM(72), TEXT)
    text(d, (LEFT_X + 26, ROW_Y[2] + 20), "09/01 週一", F_TC(24), LABEL)
    text(d, (LEFT_X + 26, ROW_Y[2] + 56), "18:04", F_NUM(64), TEXT)

    # 右欄
    for i, v in enumerate(["34", "34", "33", "33"]):
        text(d, (RIGHT_X + 30 + (i % 2) * 150, ROW_Y[0] + 46 + (i // 2) * 52),
             v, F_NUM(44), TEXT)
    text(d, (RIGHT_X + COL_W - 44, ROW_Y[1] + 22), "33676", F_NUM(38), TEXT, "ra")
    text(d, (RIGHT_X + COL_W - 44, ROW_Y[1] + 88), "50",    F_NUM(38), TEXT, "ra")
    text(d, (RIGHT_X + 26, ROW_Y[2] + 46), "90", F_NUM(72), TEXT)

    # 中央：時速 → 轉速 → 增壓
    text(d, (SPEED_RIGHT, SPEED_BASE), "75", F_NUM_SB(230), TEXT, "rs")
    text(d, (RPM_RIGHT, RPM_BASE), "1750", F_NUM_SB(58), BLUE, "rs")

    text(d, (CX - 34, TURBO_CY), "+0.15", F_NUM(44), TEXT, "mm")
    text(d, (CX + 44, TURBO_CY + 14), "BAR", F_NUM(20), LABEL, "lm")
    d.rectangle([CX, TURBO_BAR_Y, CX + 34, TURBO_BAR_Y + 7], fill=BLUE)

os.makedirs(OUT, exist_ok=True)
bg = Image.new("RGB", (W, H), BG)
draw_static(ImageDraw.Draw(bg))
bg.save(os.path.join(OUT, "background.png"))

pv = bg.copy()
draw_dynamic(ImageDraw.Draw(pv))
pv.save(os.path.join(OUT, "preview.png"))
print("已輸出 background.png / preview.png (%dx%d)" % (W, H))
