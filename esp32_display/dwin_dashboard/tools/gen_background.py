#!/usr/bin/env python3
"""
DWIN DMG12480C068 (1280x480) 儀表背景圖產生器。

DGUS 的背景圖是靜態的：所有「不會變的東西」都畫進這張圖，
只有數值由 MCU 透過 UART 寫入 VP 後由螢幕疊上去。

因此本檔輸出兩張圖：
  background.png  — 只有靜態元素，這張才是要轉成 .ICL 下載到螢幕的
  preview.png     — 背景加上範例數值，用來評估版面（不會下載到螢幕）

用程式產生而非手拉，是為了讓美術素材也能進版控、能 diff。
"""
import os, math, sys
from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 480
OUT = os.path.join(os.path.dirname(__file__), "..", "assets")
FONTS = sys.argv[1] if len(sys.argv) > 1 else "fonts"

# ── 配色（沿用 LVGL 版）────────────────────────────────────────────────
BG        = (0x00, 0x00, 0x00)
CARD      = (0x0D, 0x11, 0x17)
TEXT      = (0xFF, 0xFF, 0xFF)
LABEL     = (0xE2, 0xE8, 0xF0)
UNIT      = (0x8B, 0x95, 0xA5)
TRACK     = (0x3A, 0x3F, 0x47)
BLUE      = (0x2E, 0x7D, 0xF7)
TEAL      = (0x14, 0xB8, 0xA6)
CYAN      = (0x38, 0xBD, 0xF8)
ORANGE    = (0xF5, 0x9E, 0x0B)
RED       = (0xEF, 0x44, 0x44)
AMBER     = (0xF9, 0x73, 0x16)
ALERT     = (0xFF, 0x2D, 0x2D)
DIVIDER   = (0x2A, 0x30, 0x3B)

# ── 版面 ────────────────────────────────────────────────────────────────
PAD      = 12
COL_W    = 320
LEFT_X   = PAD
RIGHT_X  = W - PAD - COL_W          # 978
ROW_H    = 144
ROW_GAP  = 12
ROW_Y    = [PAD, PAD + ROW_H + ROW_GAP, PAD + 2 * (ROW_H + ROW_GAP)]
ACCENT_W = 5

# 時速拱：上半橢圓（180°~360°）。橢圓比正圓更貼合 8:3 的長條螢幕，
# 而且拱下方整塊空間可以讓給時速大字。
GAUGE_CX, GAUGE_CY = 640, 185       # 橢圓中心（也是兩端點的高度）
GAUGE_A, GAUGE_B   = 288, 135       # 水平/垂直半軸
ARC_W              = 10             # 軌道線寬
TICK_LEN_MAJOR     = 18
TICK_LEN_MINOR     = 11
LABEL_INSET        = 42             # 刻度數字距離軌道的內縮量

# 轉速與增壓數值並排成一行，省下一整行的垂直空間給時速大字
RPM_CX, TURBO_CX, ROW2_Y = 556, 764, 385
TURBO_BAR_Y, TURBO_BAR_W = 440, 460

SPEED_MAX = 180
ROT, SPAN = 180, 180                # PIL 角度：180=左端、270=正上、360=右端

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

def ellipse_pt(deg, a, b):
    """橢圓參數式取點。a/b 縮小即可得到往內縮的同心橢圓。"""
    t = math.radians(deg)
    return GAUGE_CX + a * math.cos(t), GAUGE_CY + b * math.sin(t)

def arc_box(a, b):
    return [GAUGE_CX - a, GAUGE_CY - b, GAUGE_CX + a, GAUGE_CY + b]

def draw_static(d):
    # ── 左欄 ──────────────────────────────────────────────────────────
    card(d, LEFT_X, ROW_Y[0], COL_W, ROW_H, TEAL)
    text(d, (LEFT_X + 20, ROW_Y[0] + 12), "Hev電池", F_TC(24), LABEL)
    text(d, (LEFT_X + COL_W - 16, ROW_Y[0] + ROW_H - 26), "%", F_NUM(22), UNIT, "ra")

    card(d, LEFT_X, ROW_Y[1], COL_W, ROW_H, CYAN)
    text(d, (LEFT_X + 20, ROW_Y[1] + 12), "水溫", F_TC(24), LABEL)
    text(d, (LEFT_X + COL_W - 16, ROW_Y[1] + ROW_H - 26), "°C", F_NUM(22), UNIT, "ra")

    card(d, LEFT_X, ROW_Y[2], COL_W, ROW_H, AMBER)

    # ── 右欄 ──────────────────────────────────────────────────────────
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

    # ── 時速拱：灰色軌道 + 刻度 ────────────────────────────────────────
    d.arc(arc_box(GAUGE_A, GAUGE_B), ROT, ROT + SPAN, fill=TRACK, width=ARC_W)

    for v in range(0, SPEED_MAX + 1, 10):
        ang = ROT + SPAN * v / SPEED_MAX
        major = (v % 20 == 0)
        # 依速域上色：0-70 白、80-110 琥珀、120+ 紅
        col = (0xD8, 0xDE, 0xE9) if v <= 70 else (ORANGE if v <= 110 else RED)
        dim = (0x7A, 0x84, 0x94) if v <= 70 else ((0x8A, 0x6A, 0x2A) if v <= 110 else (0x8A, 0x3A, 0x3A))
        ln = TICK_LEN_MAJOR if major else TICK_LEN_MINOR
        x0, y0 = ellipse_pt(ang, GAUGE_A - ARC_W, GAUGE_B - ARC_W)
        x1, y1 = ellipse_pt(ang, GAUGE_A - ARC_W - ln, GAUGE_B - ARC_W - ln)
        d.line([x0, y0, x1, y1], fill=(col if major else dim), width=3 if major else 2)
        if major:
            lx, ly = ellipse_pt(ang, GAUGE_A - LABEL_INSET, GAUGE_B - LABEL_INSET)
            text(d, (lx, ly), str(v), F_NUM(18), col, "mm")

    # ── 增壓：軌道與刻度 ─────────────────────────────────────────────
    bx = GAUGE_CX - TURBO_BAR_W // 2
    d.rectangle([bx, TURBO_BAR_Y, bx + TURBO_BAR_W, TURBO_BAR_Y + 7], fill=(0x2A, 0x30, 0x3B))
    d.line([GAUGE_CX, TURBO_BAR_Y - 4, GAUGE_CX, TURBO_BAR_Y + 11], fill=UNIT)
    for i, lbl in enumerate(["-1", "-0.5", "0", "+0.5", "+1"]):
        text(d, (bx + i * TURBO_BAR_W // 4, TURBO_BAR_Y + 16), lbl, F_NUM(15), UNIT, "ma")

def draw_dynamic(d):
    """MCU 透過 VP 寫入、由螢幕疊在背景上的部分。僅供預覽。"""
    text(d, (LEFT_X + 26, ROW_Y[0] + 46), "65.5", F_NUM(72), TEXT)
    text(d, (LEFT_X + 26, ROW_Y[1] + 46), "88",   F_NUM(72), TEXT)
    text(d, (LEFT_X + 26, ROW_Y[2] + 20), "09/01 週一", F_TC(24), LABEL)
    text(d, (LEFT_X + 26, ROW_Y[2] + 56), "18:04", F_NUM(64), TEXT)

    for i, v in enumerate(["34", "34", "33", "33"]):
        text(d, (RIGHT_X + 30 + (i % 2) * 150, ROW_Y[0] + 46 + (i // 2) * 52),
             v, F_NUM(44), TEXT)
    text(d, (RIGHT_X + COL_W - 44, ROW_Y[1] + 22), "33676", F_NUM(38), TEXT, "ra")
    text(d, (RIGHT_X + COL_W - 44, ROW_Y[1] + 88), "50",    F_NUM(38), TEXT, "ra")
    text(d, (RIGHT_X + 26, ROW_Y[2] + 46), "90", F_NUM(72), TEXT)

    # 時速進度弧（0 -> 75）
    d.arc(arc_box(GAUGE_A, GAUGE_B), ROT, ROT + SPAN * 75 / SPEED_MAX,
          fill=BLUE, width=ARC_W)

    # 時速大字放在拱「下方」而非拱內——拱內會頂到刻度，下方才放得大
    text(d, (GAUGE_CX, 265), "75", F_NUM_SB(200), TEXT, "mm")

    text(d, (RPM_CX, ROW2_Y), "1750", F_NUM_SB(56), BLUE, "mm")
    text(d, (RPM_CX + 74, ROW2_Y + 16), "R", F_NUM(20), UNIT, "mm")
    text(d, (TURBO_CX - 32, ROW2_Y), "+0.15", F_NUM(40), TEXT, "mm")
    text(d, (TURBO_CX + 58, ROW2_Y + 12), "BAR", F_NUM(20), LABEL, "mm")

    bx = GAUGE_CX - TURBO_BAR_W // 2
    d.rectangle([GAUGE_CX, TURBO_BAR_Y, GAUGE_CX + 22, TURBO_BAR_Y + 7], fill=BLUE)

    # 連線資訊放中央區左上角的空白處。實作時應該移到 DGUS 的設定分頁，
    # 主畫面只留一個連線指示點即可。
    text(d, (GAUGE_CX - GAUGE_A, 14), "10.0.4.99", F_NUM(15), UNIT, "la")

os.makedirs(OUT, exist_ok=True)
bg = Image.new("RGB", (W, H), BG)
draw_static(ImageDraw.Draw(bg))
bg.save(os.path.join(OUT, "background.png"))

pv = bg.copy()
draw_dynamic(ImageDraw.Draw(pv))
pv.save(os.path.join(OUT, "preview.png"))
print("已輸出 background.png / preview.png (%dx%d)" % (W, H))
