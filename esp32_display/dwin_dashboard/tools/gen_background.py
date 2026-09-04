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

W = 1280
# 第二參數可指定畫面高度（DMG12480C068=480、DMG12400C074=400）。
# 兩者同為 1280 寬，因此只縮放垂直座標與字級。
# 也接受環境變數，讓 gen_dgus_config.py 能 import 本檔共用座標
H = int(os.environ.get("NX4_HEIGHT") or
        (sys.argv[2] if len(sys.argv) > 2 else 480))
S = H / 480.0
SUFFIX = "" if H == 480 else "_%d" % H

OUT = os.path.join(os.path.dirname(__file__), "..", "assets")
FONTS = os.environ.get("NX4_FONTS") or (sys.argv[1] if len(sys.argv) > 1 else "fonts")

def V(y):
    """垂直座標依畫面高度縮放"""
    return int(round(y * S))

def FS(size):
    """字級依畫面高度縮放"""
    return max(8, int(round(size * S)))

# ── 配色（沿用 LVGL 版）────────────────────────────────────────────────
BG      = (0x00, 0x00, 0x00)
CARD    = (0x0D, 0x11, 0x17)
TEXT    = (0xFF, 0xFF, 0xFF)
LABEL   = (0xE2, 0xE8, 0xF0)
UNIT    = (0xB4, 0xBF, 0xCC)   # 單位/刻度。原為 0x8B95A5，在黑底上偏暗
BLUE    = (0x2E, 0x7D, 0xF7)
TEAL    = (0x14, 0xB8, 0xA6)
CYAN    = (0x38, 0xBD, 0xF8)
ORANGE  = (0xF5, 0x9E, 0x0B)
RED     = (0xEF, 0x44, 0x44)
AMBER   = (0xF9, 0x73, 0x16)
GREEN   = (0x22, 0xC5, 0x5E)
DIVIDER = (0x2A, 0x30, 0x3B)
BAR_BG  = (0x2A, 0x30, 0x3B)

# ── 左右卡片欄 ─────────────────────────────────────────────────────────
PAD      = 12
COL_W    = 320
LEFT_X   = PAD
RIGHT_X  = W - PAD - COL_W
ROW_GAP  = V(12)
ROW_H    = (H - 2 * PAD - 2 * ROW_GAP) // 3
ROW_Y    = [PAD, PAD + ROW_H + ROW_GAP, PAD + 2 * (ROW_H + ROW_GAP)]
ACCENT_W = 5

# ── 中央區：時速 / 轉速 / 增壓 由上而下垂直排列 ────────────────────────
CX            = W // 2
# 單位是靜態的（畫在背景圖裡）位置不能動，所以數值一律「靠右對齊」，
# 單位緊貼在它的右下角。若數值置中，位數變化時與單位的間距就會不一致。
# 以「標稱位數」為設計基準：時速兩位、轉速四位。
# 該位數下數字剛好置中於畫面中線，單位固定貼在它右側。
# 位數變多時數字往左長（右緣固定），所以永遠不會壓到單位。
NOMINAL_SPEED = "75"
NOMINAL_RPM   = "1750"
UNIT_GAP      = 14       # 數值右緣到單位起點的間距
SPEED_BASE    = V(203)   # 時速基線
RPM_BASE      = V(317)   # 轉速基線

# 轉速為 0（引擎熄火、HEV 純電）時顯示 EV。
# 轉速數值是 Data Variable（只能顯示數字），而 "RPM" 單位是畫在背景圖裡的
# 靜態文字無法隱藏，因此改用一張「不透明」的圖示把整列蓋掉。
# 圖示底色與畫面背景同為純黑，蓋上去看不出接縫。
# DGUS 端用 Variable Icon (0x00) 或 Animation Icon (0x01)：
# 把 V_Min/V_Max 都設為 0，轉速一大於 0 就自動不顯示。
TURBO_CY      = V(374)
TURBO_BAR_Y   = V(420)
TURBO_BAR_W   = 460
TURBO_BAR_X   = CX - TURBO_BAR_W // 2

# ── 動態數值在 DGUS 端的字元格 ─────────────────────────────────────────
# DGUS 的 0# ASCII 字型是等寬點陣：字高 = 字級、字寬 = 字級 / 2。
# 時鐘的 ":" 與日期的 "/" 是分隔符號，Data Variable 顯示不出來，
# 只能畫進背景圖；位置必須用 DGUS 的字元格算，不能用 Montserrat 的字寬，
# 否則背景的冒號會跟螢幕疊上去的數字對不齊。
def CW(fs):
    """DGUS 0# ASCII 的字寬"""
    return fs // 2

def CELL(x0, fs, i):
    """第 i 個字元格的左緣"""
    return x0 + i * CW(fs)

# 點陣字的基線大約落在字格高度的這個比例處。背景圖上的冒號、斜線與單位
# 都要對到這條線，數值才不會浮起來。gen_dgus_config.py 也用同一個值算 Y。
BASELINE_RATIO = 0.78

def cell_text(d, x0, fs, top, i, sval, font, fill):
    """把字串逐字放進字元格（每格置中），模擬 DGUS 的等寬點陣排版。

    Montserrat 的數字比 DGUS 的 fs/2 寬，整串直接畫會越格、
    把背景的冒號蓋掉，預覽就看不出實機的落點。
    """
    base = top + int(fs * BASELINE_RATIO)
    for k, ch in enumerate(sval):
        text(d, (CELL(x0, fs, i + k) + CW(fs) // 2, base), ch, font, fill, "ms")

# 時鐘 HH:MM:SS 共 8 格，冒號在第 2、5 格
CLOCK_FS  = FS(60)
CLOCK_X0  = LEFT_X + 26
CLOCK_TOP = ROW_Y[2] + V(56)
# 日期 MM/DD 共 5 格，斜線在第 2 格；星期是圖示，接在第 6 格之後
DATE_FS   = FS(24)
DATE_X0   = LEFT_X + 26
DATE_TOP  = ROW_Y[2] + V(20)
WEEK_X    = CELL(DATE_X0, DATE_FS, 6)
WEEK_W    = DATE_FS * 2       # 「週一」兩個中文字
WEEK_H    = DATE_FS

def f(name, size):
    return ImageFont.truetype(os.path.join(FONTS, name), size)

# 字重層次：中央區 SemiBold（主角）> 卡片 Medium > 單位 Regular
F_TC     = lambda s: f("NotoSansTC-Medium.ttf", s)   # 卡片標籤
F_NUM    = lambda s: f("Montserrat.ttf", s)          # 單位等次要文字
F_NUM_MD = lambda s: f("Montserrat-Medium.ttf", s)   # 卡片數值
F_NUM_SB = lambda s: f("Montserrat-SemiBold.ttf", s) # 中央區時速/轉速/增壓

F_UNIT   = lambda s: f("Montserrat-Medium.ttf", s)   # 單位與刻度

def tw(font, txt):
    b = font.getbbox(txt)
    return b[2] - b[0]

# 由標稱位數推出右對齊基準線與單位位置（不寫死座標，改字級會自動跟著算）
SPEED_RIGHT  = CX + tw(F_NUM_SB(FS(230)), NOMINAL_SPEED) // 2
SPEED_UNIT_X = SPEED_RIGHT + UNIT_GAP
RPM_RIGHT    = CX + tw(F_NUM_SB(FS(88)), NOMINAL_RPM) // 2
RPM_UNIT_X   = RPM_RIGHT + UNIT_GAP

# EV 圖示需涵蓋轉速最寬情況與單位
_ev_left  = RPM_RIGHT - tw(F_NUM_SB(FS(88)), "8888") - 20
_ev_right = RPM_UNIT_X + tw(F_UNIT(FS(30)), "RPM") + 20
EV_X, EV_Y = _ev_left, V(245)
EV_W, EV_H = _ev_right - _ev_left, V(90)

def card(d, x, y, w, h, accent):
    d.rectangle([x, y, x + w - 1, y + h - 1], fill=CARD)
    d.rectangle([x, y, x + ACCENT_W - 1, y + h - 1], fill=accent)

def text(d, xy, s, font, fill, anchor="la"):
    d.text(xy, s, font=font, fill=fill, anchor=anchor)

# ─────────────────────────────────────────────────────────────────────────
def draw_static(d):
    # 左欄
    card(d, LEFT_X, ROW_Y[0], COL_W, ROW_H, TEAL)
    text(d, (LEFT_X + 20, ROW_Y[0] + V(12)), "Hev電池", F_TC(FS(24)), LABEL)
    text(d, (LEFT_X + COL_W - 16, ROW_Y[0] + ROW_H - V(26)), "%", F_UNIT(FS(24)), UNIT, "ra")

    card(d, LEFT_X, ROW_Y[1], COL_W, ROW_H, CYAN)
    text(d, (LEFT_X + 20, ROW_Y[1] + V(12)), "水溫", F_TC(FS(24)), LABEL)
    text(d, (LEFT_X + COL_W - 16, ROW_Y[1] + ROW_H - V(26)), "°C", F_UNIT(FS(24)), UNIT, "ra")

    card(d, LEFT_X, ROW_Y[2], COL_W, ROW_H, AMBER)

    # 右欄
    card(d, RIGHT_X, ROW_Y[0], COL_W, ROW_H, ORANGE)
    text(d, (RIGHT_X + 20, ROW_Y[0] + V(10)), "胎壓 (PSI)", F_TC(FS(24)), LABEL)

    card(d, RIGHT_X, ROW_Y[1], COL_W, ROW_H, CYAN)
    text(d, (RIGHT_X + 20, ROW_Y[1] + V(26)), "里程", F_TC(FS(24)), LABEL)
    text(d, (RIGHT_X + COL_W - 16, ROW_Y[1] + V(32)), "K", F_UNIT(FS(22)), UNIT, "ra")
    d.line([RIGHT_X + 20, ROW_Y[1] + V(72), RIGHT_X + COL_W - 20, ROW_Y[1] + V(72)], fill=DIVIDER)
    text(d, (RIGHT_X + 20, ROW_Y[1] + V(92)), "油箱", F_TC(FS(24)), LABEL)
    text(d, (RIGHT_X + COL_W - 16, ROW_Y[1] + V(98)), "%", F_UNIT(FS(22)), UNIT, "ra")

    card(d, RIGHT_X, ROW_Y[2], COL_W, ROW_H, RED)
    text(d, (RIGHT_X + 20, ROW_Y[2] + V(12)), "道路速限", F_TC(FS(24)), LABEL)

    # 中央區的固定文字：單位貼在各自數值的右下角，與數值基線對齊
    text(d, (SPEED_UNIT_X, SPEED_BASE), "km/h", F_UNIT(FS(34)), UNIT, "ls")
    text(d, (RPM_UNIT_X, RPM_BASE), "RPM", F_UNIT(FS(30)), UNIT, "ls")

    # 時鐘與日期的分隔符號（數字由 DGUS 疊上去，分隔符號只能是靜態的）
    for i in (2, 5):
        cell_text(d, CLOCK_X0, CLOCK_FS, CLOCK_TOP, i, ":",
                  F_NUM_MD(CLOCK_FS), TEXT)
    cell_text(d, DATE_X0, DATE_FS, DATE_TOP, 2, "/", F_NUM_MD(DATE_FS), LABEL)

    # 增壓：軌道、中線、刻度
    d.rectangle([TURBO_BAR_X, TURBO_BAR_Y,
                 TURBO_BAR_X + TURBO_BAR_W, TURBO_BAR_Y + V(7)], fill=BAR_BG)
    d.line([CX, TURBO_BAR_Y - 4, CX, TURBO_BAR_Y + 11], fill=UNIT)
    for i, lbl in enumerate(["-1", "-0.5", "0", "+0.5", "+1"]):
        text(d, (TURBO_BAR_X + i * TURBO_BAR_W // 4, TURBO_BAR_Y + V(16)),
             lbl, F_UNIT(FS(17)), UNIT, "ma")

def draw_dynamic(d):
    """MCU 透過 VP 寫入、由螢幕疊上去的部分。僅供預覽。"""
    # 左欄
    text(d, (LEFT_X + 26, ROW_Y[0] + V(46)), "65.5", F_NUM_MD(FS(72)), TEXT)
    text(d, (LEFT_X + 26, ROW_Y[1] + V(46)), "88",   F_NUM_MD(FS(72)), TEXT)
    # 日期與時鐘：數字逐格畫，位置與 DGUS 的等寬字元格一致
    for i, v in ((0, "09"), (3, "01")):
        cell_text(d, DATE_X0, DATE_FS, DATE_TOP, i, v, F_NUM_MD(DATE_FS), LABEL)
    text(d, (WEEK_X, DATE_TOP), "週一", F_TC(DATE_FS), LABEL)
    # 60px 而非 64px：最寬的 "00:00:00" 在 64px 下是 276px，
    # 卡片可用寬度只有 278px，餘裕不足以吸收實機的字型渲染差異
    for i, v in ((0, "18"), (3, "04"), (6, "37")):
        cell_text(d, CLOCK_X0, CLOCK_FS, CLOCK_TOP, i, v, F_NUM_MD(CLOCK_FS), TEXT)

    # 右欄
    for i, v in enumerate(["34", "34", "33", "33"]):
        # 列距 52 -> 44、起點上移，原本第二列數字底部距卡片下緣只剩 2px
        text(d, (RIGHT_X + 30 + (i % 2) * 150, ROW_Y[0] + V(42) + (i // 2) * V(44)),
             v, F_NUM_MD(FS(44)), TEXT)
    text(d, (RIGHT_X + COL_W - 44, ROW_Y[1] + V(22)), "33676", F_NUM_MD(FS(38)), TEXT, "ra")
    text(d, (RIGHT_X + COL_W - 44, ROW_Y[1] + V(88)), "50",    F_NUM_MD(FS(38)), TEXT, "ra")
    text(d, (RIGHT_X + 26, ROW_Y[2] + V(46)), "90", F_NUM_MD(FS(72)), TEXT)

    # 中央：時速 → 轉速 → 增壓
    text(d, (SPEED_RIGHT, SPEED_BASE), NOMINAL_SPEED, F_NUM_SB(FS(230)), TEXT, "rs")
    text(d, (RPM_RIGHT, RPM_BASE), NOMINAL_RPM, F_NUM_SB(FS(88)), BLUE, "rs")

    text(d, (CX - 34, TURBO_CY), "+0.15", F_NUM_SB(FS(44)), TEXT, "mm")
    text(d, (CX + 44, TURBO_CY + V(14)), "BAR", F_UNIT(FS(22)), UNIT, "lm")
    d.rectangle([CX, TURBO_BAR_Y, CX + 34, TURBO_BAR_Y + V(7)], fill=BLUE)

def draw_ev_icon():
    """EV 圖示：尺寸涵蓋轉速數值與 RPM 單位，底色與畫面背景一致。"""
    ico = Image.new("RGB", (EV_W, EV_H), BG)
    d = ImageDraw.Draw(ico)
    text(d, (EV_W // 2, EV_H // 2), "EV", F_NUM_SB(FS(88)), GREEN, "mm")
    return ico

def draw_week_icons():
    """星期圖示 0..6（週一..週日）。

    星期是中文，Data Variable 只能顯示數字，而螢幕端不放中文字庫，
    所以做成 7 張圖示由 Variable Icon 依 VP 值切換。底色與畫面一致。
    """
    out = []
    for name in ["週一", "週二", "週三", "週四", "週五", "週六", "週日"]:
        ico = Image.new("RGB", (WEEK_W, WEEK_H), CARD)
        text(ImageDraw.Draw(ico), (WEEK_W // 2, WEEK_H // 2), name,
             F_TC(DATE_FS), LABEL, "mm")
        out.append(ico)
    return out

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    bg = Image.new("RGB", (W, H), BG)
    draw_static(ImageDraw.Draw(bg))
    bg.save(os.path.join(OUT, "background%s.png" % SUFFIX))

    pv = bg.copy()
    draw_dynamic(ImageDraw.Draw(pv))
    pv.save(os.path.join(OUT, "preview%s.png" % SUFFIX))

    ev_icon = draw_ev_icon()
    ev_icon.save(os.path.join(OUT, "icon_ev%s.png" % SUFFIX))

    icon_dir = os.path.join(OUT, "icons%s" % SUFFIX)
    os.makedirs(icon_dir, exist_ok=True)
    for i, ico in enumerate(draw_week_icons()):
        ico.save(os.path.join(icon_dir, "week_%d.png" % i))

    # EV 狀態預覽：一般畫面再把 EV 圖示疊上轉速那一列
    pv_ev = pv.copy()
    pv_ev.paste(ev_icon, (EV_X, EV_Y))
    pv_ev.save(os.path.join(OUT, "preview_ev%s.png" % SUFFIX))

    print("已輸出 %dx%d 的 background/preview/preview_ev/icon_ev%s" % (W, H, SUFFIX))
