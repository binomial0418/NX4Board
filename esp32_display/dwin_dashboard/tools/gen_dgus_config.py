#!/usr/bin/env python3
"""
DGUS 設定檔產生器 —— 產出 SD 卡 `DWIN_SET/` 需要的 14.BIN / 13.BIN /
22.BIN / T5LCFG.CFG，以及 ESP32 韌體用的 VP 位址表 `nx4_dwin_vp.h`。

座標「不」在這裡重新定義：本檔 import `gen_background.py`，用的是產生
背景圖那一組常數。背景圖上的單位、冒號、斜線是靜態的，數值是螢幕疊上去
的，兩者對不齊就整個歪掉，所以只能有一份座標。

    python3 tools/gen_dgus_config.py <字型資料夾> [畫面高度]

輸出（相對於 dwin_dashboard/）：
    dwin_set/14.BIN        顯示變數設定
    dwin_set/13.BIN        觸控設定（目前主畫面無觸控，內容為空白頁）
    dwin_set/22.BIN        VP 開機初值（含 SP 描述區）
    dwin_set/T5LCFG.CFG    系統設定（由原廠檔案改兩個位元）
    nx4_dwin_vp.h          ESP32 端的 VP 位址表

    python3 tools/gen_dgus_config.py --dump    把產生的 14.BIN 反解回可讀文字


⚠ 位元組格式的來源與可信度
────────────────────────────────────────────────────────────────────────
本機沒有 T5L DGUSII 開發指南的 PDF，下面 `SPEC` 區塊的欄位位移是依規格
記憶寫的，**尚未與開發指南 §6/§7 的表格逐欄核對，也還沒在實機驗證**。
硬體到貨（或拿到開發指南）後要核對的項目集中在 `SPEC` 區塊，並在
`VERIFY` 清單裡逐條列出——改那裡就好，控制項定義不必動。

`--dump` 會把產生的 14.BIN 反解成文字，方便和 DGUS 工具（Windows）存出來
的同版面檔案做欄位對照。
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# 讓 gen_background.py 用同一組字型與畫面高度被 import 進來當座標來源。
# 產生座標要量字寬，所以需要字型；--dump / --patch-cfg 不需要，就不 import，
# 手邊沒有字型檔時也能用它們檢查既有的產出。
L = None
if not {"--dump", "--patch-cfg", "--selftest"} & set(sys.argv):
    if len(sys.argv) > 1:
        os.environ["NX4_FONTS"] = sys.argv[1]
    if len(sys.argv) > 2:
        os.environ["NX4_HEIGHT"] = sys.argv[2]
    sys.path.insert(0, HERE)
    import gen_background as L  # noqa: E402  （import 前要先設好環境變數）


# ═══════════════════════════════════════════════════════════════════════
# SPEC —— 檔案格式常數。**唯一需要跟開發指南核對的區塊**
# ═══════════════════════════════════════════════════════════════════════

# ── 容器格式（以 DWIN_400_org/ 的參考專案實測）────────────────────────
# 14ShowFile.bin = 16 位元組檔頭 + 4092 個頁項目 + 描述資料區。
# 頁項目是「1 位元組控制項數量 + 3 位元組檔案位移」，不是單純的指標。
# 空頁的數量是 0、位移指向描述區結尾，所以整份檔案沒有「每頁固定大小」這回事。
HDR_14      = b"\x14DGUS_2\x10" + b"\x00" * 8
PAGE_COUNT  = 4092                            # (0x4000 - 16) / 4
INDEX_END   = len(HDR_14) + PAGE_COUNT * 4    # = 0x4000，描述資料從這裡開始
TAIL_PAD    = 32                              # 描述區之後補 32 位元組的 FF

# 13TouchFile.bin：空檔就是 FFFF 兩個位元組。
# **觸控的描述格式仍未知**——參考專案裡的觸控沒有被存進去（檔案還是 FFFF）。
TOUCH_END   = b"\xFF\xFF"

# 22_Config.bin：0x20000 = 整個 VP 空間（0x0000~0xFFFF，每格 2 位元組）+ 4 位元組
INIT_VP_BYTES     = 0x20000
INIT_HEADER_BYTES = 4     # ⚠ 未驗證：假設在檔頭。原廠檔全是 0，看不出來
INIT_BASE         = 0x0000

# ── 描述格式（32 位元組；欄位位移全部實測確認）────────────────────────
#   0x00 u8   0x5A 固定
#   0x01 u8   控制項類型
#   0x02 u16  *SP，0xFFFF = 不使用
#   0x04 u16  SP 描述長度（字）：資料變數 13、圖示變數 10
#   0x06 u16  *VP     ← SP 描述從這裡開始對應，所以 SP+n = 描述的 0x06+2n
#   0x08 u16  X
#   0x0A u16  Y
#   0x0C 之後依類型不同，見 data_var() / icon_var()
DESC_LEN    = 0x20
DESC_MAGIC  = 0x5A
SP_LEN_DATA = 13
SP_LEN_ICON = 10

VT_ICON = 0x00          # 圖示變數
VT_DATA = 0x10          # 資料變數

# 資料變數的資料型別（描述 0x13）
DT_INT16 = 0
DT_INT32 = 1

# 對齊方式（描述 0x10）：實測 左 = 0、右 = 1、置中 = 2
AL_LEFT, AL_RIGHT, AL_CENTER = 0, 1, 2

# 圖示疊圖方式（描述 0x15）：0 = 透明、1 = 不透明
ICON_OPAQUE = 1

# 圖示描述的 0x16~0x19，DGUS 工具寫的是 00 00 00 3F，意義不明。
# 它落在 SP 描述長度（10 字，剛好到 0x19）之內，不是填充，所以照抄。
ICON_TAIL   = bytes.fromhex("0000003f")

LIB_ASCII = 0           # 螢幕內建 0# ASCII 字庫，動態值全是數字所以夠用
ICL_MAIN  = 32          # 圖示所在的 ICL 編號（參考專案裡的 32.icl 就是這個編號）

SP_NONE = 0xFFFF        # 不使用變數描述指標

# 啟用 SP 時，描述從 0x06 起的內容改由 VP 空間的 SP 位址提供
# （描述 0x04 的「長度」就是這段有多長）。顏色在 0x0C → SP+3。
SP_MAP_BASE   = 0x06
SP_OFF_COLOR  = (0x0C - SP_MAP_BASE) // 2   # = 3

VERIFY = [
    "觸控（13TouchFile.bin）的描述格式 —— 參考專案裡沒存到，仍然未知",
    "圖示描述 0x16~0x19 的 00 00 00 3F 是什麼（照抄工具寫的值）",
    "0# ASCII 字庫可用的字級範圍（時速用到 230，是否超出上限）",
    "Data Variable 的前導 0 是顯示還是留白（時鐘的 08:04:07 會受影響）",
    "22_Config.bin 多出來的 4 個位元組在檔頭還是檔尾（INIT_HEADER_BYTES）",
    "120.lib 的內容意義（目前直接沿用原廠那份）",
    "T5LCFG.CFG 的設定位元組是否從檔案位移 8 起算（CFG_FILE_BASE）",
]

# 檔名沿用 DGUS 工具的命名（前面的編號才是關鍵，後綴只是給人看的）
NAME_14, NAME_13, NAME_22 = "14ShowFile.bin", "13TouchFile.bin", "22_Config.bin"

# T5LCFG.CFG —— 不由本工具憑空產生。
#
# 原廠 DGUS 工具附的那份（DGUS_V7650/Config/T5LCFG.CFG）是 800×480 的預設值，
# 直接拿來用會設錯解析度；而且從十六進位看，檔案位移 0x0D 與 0x12 附近就是
# 0x0320(800) 與 0x01E0(480)，代表「設定位元組從檔案位移 8 起算」這個假設
# 很可能是錯的——照著盲改會直接寫進解析度欄位。
#
# 因此正確流程是：以**螢幕出廠 SD 卡裡那份 CFG** 為底，確認位移後再改兩個位元。
#     python3 tools/gen_dgus_config.py --patch-cfg <原廠 T5LCFG.CFG>
CFG_FILE_BASE = 8       # ⚠ 未驗證：檔頭 "T5LC18\0\0" 之後是否就是設定位元組
CFG_BIT_TOUCH_UPLOAD = (0x05, 4)   # 觸控自動上傳；不開按鈕不會回傳
CFG_BIT_PWM_BACKLIGHT = (0x06, 7)  # PWM 背光；不開亮度指令無效


# ═══════════════════════════════════════════════════════════════════════
# VP 位址表（字位址；一個 VP = 2 位元組）
# ═══════════════════════════════════════════════════════════════════════

# 需要執行期改顏色的控制項，各配一段 13 字的 SP 描述區。
# 起始位址沿用 DGUS 工具的慣例（DWprj.hmi 的 SPADDRESS=5000）。
SP_SPEED   = 0x5000
SP_RPM     = 0x5010
SP_COOLANT = 0x5020
SP_LIMIT   = 0x5030

VP = {
    "speed":     0x2000,
    "rpm":       0x2001,
    "turbo":     0x2002,   # 有號，實際值 ×100
    "coolant":   0x2003,
    "soc":       0x2004,   # ×10
    "fuel":      0x2005,
    "limit":     0x2006,
    "odo":       0x2008,   # 32 位元，佔 0x2008~0x2009
    "tpms_fl":   0x200A,
    "tpms_fr":   0x200B,
    "tpms_rl":   0x200C,
    "tpms_rr":   0x200D,
    "clock_hh":  0x2010,
    "clock_mm":  0x2011,
    "clock_ss":  0x2012,
    "date_mm":   0x2013,
    "date_dd":   0x2014,
    "weekday":   0x2015,   # 0=週一 … 6=週日，對應 7 張圖示
}

# 圖示編號（ICL 打包順序，轉檔時要照這個順序放）
ICON_EV     = 0
ICON_WEEK_0 = 1        # week_0..week_6 → 1..7


# ═══════════════════════════════════════════════════════════════════════
# 工具
# ═══════════════════════════════════════════════════════════════════════

def rgb565(rgb):
    r, g, b = rgb
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)


def cw(fs):
    """DGUS 0# ASCII 的字寬 = 字級 / 2"""
    return fs // 2


def digits_box(fs, nchars):
    return nchars * cw(fs)


# 基線位置與背景圖共用同一個定義（gen_background.BASELINE_RATIO）
BASELINE_RATIO = L.BASELINE_RATIO if L else 0.78

# 數字實際著墨的範圍（佔字格高度的比例）。字格比字高，上下都有留白，
# 檢查是否互相干擾時要用著墨範圍，不然相鄰兩列一定被判定成重疊。
INK_TOP, INK_BOTTOM = 0.08, 0.80


def top_from_baseline(baseline, fs):
    return int(round(baseline - fs * BASELINE_RATIO))


def even(n):
    """字級取偶數：點陣寬度 = 字級 / 2，奇數會有半個像素的誤差"""
    n = int(round(n))
    return n - (n & 1)


class Ctl:
    """一個顯示變數控制項"""

    def __init__(self, name, kind, desc, note=""):
        self.name, self.kind, self.desc, self.note = name, kind, desc, note
        self.rect = None      # 字格範圍 (x, y, w, h)
        self.ink = None       # 實際著墨範圍，用於重疊檢查

    def set_rect(self, x, y, w, h, text_like):
        self.rect = (x, y, w, h)
        # 圖示整塊都是實心的；數字只有中間那一段有筆畫
        self.ink = ((x, y + int(h * INK_TOP), w, int(h * (INK_BOTTOM - INK_TOP)))
                    if text_like else (x, y, w, h))


def data_var(name, vp, x, y, fs, int_digits, dec_digits=0,
             color=None, align=AL_LEFT, dtype=DT_INT16, sp=SP_NONE,
             signed=False, note=""):
    color = rgb565(color or L.TEXT)
    nchars = int_digits + dec_digits + (1 if dec_digits else 0) + (1 if signed else 0)
    w, h = digits_box(fs, nchars), fs

    d = bytearray(DESC_LEN)
    d[0x00], d[0x01] = DESC_MAGIC, VT_DATA
    struct.pack_into(">HH", d, 0x02, sp, SP_LEN_DATA)
    struct.pack_into(">HHHH", d, 0x06, vp, x, y, color)
    d[0x0E] = LIB_ASCII
    d[0x0F] = fs
    d[0x10] = align
    d[0x11] = int_digits
    d[0x12] = dec_digits
    d[0x13] = dtype
    d[0x14] = 0          # 單位長度 0：單位一律畫在背景圖上，不由 DGUS 疊
    c = Ctl(name, "data", d, note)
    c.set_rect(x, y, w, h, True)
    c.sp, c.sp_words = sp, SP_LEN_DATA
    return c


def icon_var(name, vp, x, y, w, h, v_min, v_max, icon_min, icon_max,
             icl=ICL_MAIN, mode=ICON_OPAQUE, note=""):
    d = bytearray(DESC_LEN)
    d[0x00], d[0x01] = DESC_MAGIC, VT_ICON
    struct.pack_into(">HH", d, 0x02, SP_NONE, SP_LEN_ICON)
    struct.pack_into(">HHH", d, 0x06, vp, x, y)
    struct.pack_into(">HHHH", d, 0x0C, v_min, v_max, icon_min, icon_max)
    d[0x14] = icl
    d[0x15] = mode
    d[0x16:0x16 + len(ICON_TAIL)] = ICON_TAIL
    c = Ctl(name, "icon", d, note)
    c.set_rect(x, y, w, h, False)
    c.sp, c.sp_words = SP_NONE, SP_LEN_ICON
    return c


# ═══════════════════════════════════════════════════════════════════════
# 主畫面（第 0 頁）的控制項
# ═══════════════════════════════════════════════════════════════════════

def build_controls():
    c = []

    # ── 中央：時速 ──────────────────────────────────────────────────
    # 右緣固定在 SPEED_RIGHT（背景圖上的 km/h 就貼在那裡），位數變多往左長
    fs = even(L.FS(230))
    w = digits_box(fs, 3)
    c.append(data_var(
        "speed", VP["speed"], L.SPEED_RIGHT - w, top_from_baseline(L.SPEED_BASE, fs),
        fs, 3, align=AL_RIGHT, sp=SP_SPEED,
        note="超速時由 ESP32 寫 SP+3 改成紅色"))

    # ── 中央：轉速 ──────────────────────────────────────────────────
    fs = even(L.FS(88))
    w = digits_box(fs, 4)
    c.append(data_var(
        "rpm", VP["rpm"], L.RPM_RIGHT - w, top_from_baseline(L.RPM_BASE, fs),
        fs, 4, color=L.BLUE, align=AL_RIGHT, sp=SP_RPM))

    # 轉速為 0（純電行駛）時，用不透明的 EV 圖示把整列蓋掉。
    # V_Min = V_Max = 0：轉速一大於 0，圖示自動消失，不必送額外指令。
    c.append(icon_var(
        "ev", VP["rpm"], L.EV_X, L.EV_Y, L.EV_W, L.EV_H,
        0, 0, ICON_EV, ICON_EV,
        note="不透明，底色與畫面同為純黑"))

    # ── 中央：增壓 ──────────────────────────────────────────────────
    fs = even(L.FS(44))
    w = digits_box(fs, 5)          # 符號 + 1 位整數 + 小數點 + 2 位小數
    c.append(data_var(
        "turbo", VP["turbo"], (L.CX - 34) - w // 2, L.TURBO_CY - fs // 2,
        fs, 1, 2, align=AL_CENTER, signed=True,
        note="值為 BAR ×100 的有號整數"))

    # ── 左欄 ────────────────────────────────────────────────────────
    fs = even(L.FS(72))
    c.append(data_var("soc", VP["soc"], L.LEFT_X + 26, L.ROW_Y[0] + L.V(46),
                      fs, 3, 1, note="值為 % ×10"))
    c.append(data_var("coolant", VP["coolant"], L.LEFT_X + 26, L.ROW_Y[1] + L.V(46),
                      fs, 3, sp=SP_COOLANT, note="過熱時由 ESP32 改紅色"))

    # 日期：MM/DD，斜線畫在背景圖上；星期是中文，做成 7 張圖示
    for i, key in ((0, "date_mm"), (3, "date_dd")):
        c.append(data_var(key, VP[key],
                          L.CELL(L.DATE_X0, L.DATE_FS, i), L.DATE_TOP,
                          L.DATE_FS, 2, color=L.LABEL))
    c.append(icon_var("weekday", VP["weekday"], L.WEEK_X, L.DATE_TOP,
                      L.WEEK_W, L.WEEK_H, 0, 6,
                      ICON_WEEK_0, ICON_WEEK_0 + 6,
                      note="0=週一 … 6=週日"))

    # 時鐘：HH:MM:SS，冒號畫在背景圖上
    for i, key in ((0, "clock_hh"), (3, "clock_mm"), (6, "clock_ss")):
        c.append(data_var(key, VP[key],
                          L.CELL(L.CLOCK_X0, L.CLOCK_FS, i), L.CLOCK_TOP,
                          L.CLOCK_FS, 2))

    # ── 右欄 ────────────────────────────────────────────────────────
    fs = even(L.FS(44))
    for i, key in enumerate(["tpms_fl", "tpms_fr", "tpms_rl", "tpms_rr"]):
        c.append(data_var(
            key, VP[key],
            L.RIGHT_X + 30 + (i % 2) * 150,
            L.ROW_Y[0] + L.V(42) + (i // 2) * L.V(44), fs, 2))

    fs = even(L.FS(38))
    right = L.RIGHT_X + L.COL_W - 44
    c.append(data_var("odo", VP["odo"], right - digits_box(fs, 6),
                      L.ROW_Y[1] + L.V(22), fs, 6,
                      align=AL_RIGHT, dtype=DT_INT32))
    c.append(data_var("fuel", VP["fuel"], right - digits_box(fs, 3),
                      L.ROW_Y[1] + L.V(88), fs, 3, align=AL_RIGHT))

    c.append(data_var("limit", VP["limit"], L.RIGHT_X + 26, L.ROW_Y[2] + L.V(46),
                      even(L.FS(72)), 3, sp=SP_LIMIT,
                      note="測速照相警示時由 ESP32 改紅色"))
    return c


# ═══════════════════════════════════════════════════════════════════════
# 檔案輸出
# ═══════════════════════════════════════════════════════════════════════

def build_14(controls):
    """14ShowFile.bin：檔頭 + 頁項目索引 + 描述資料區。

    頁項目 = 1 位元組控制項數量 + 3 位元組檔案位移。只有第 0 頁有內容，
    其餘 4091 頁數量為 0、位移指向描述區結尾——與原廠專案的作法一致。
    """
    body = b"".join(bytes(c.desc) for c in controls)
    end = INDEX_END + len(body)

    def entry(count, off):
        return bytes([count]) + off.to_bytes(3, "big")

    idx = [entry(len(controls), INDEX_END) if i == 0 else entry(0, end)
           for i in range(PAGE_COUNT)]
    return HDR_14 + b"".join(idx) + body + b"\xFF" * TAIL_PAD


def build_13():
    # 主畫面沒有觸控元件。原廠空專案就是這兩個位元組。
    return TOUCH_END


def build_22(controls):
    """22_Config.bin：整個 VP 空間的開機映像。

    有啟用 SP 的控制項，描述改由 VP 空間提供，開機時那段必須先有內容，
    否則第一秒會拿到全 0 的描述（座標 0、字級 0）。ESP32 連上後會再寫一次
    （見 nx4_dwin_vp.h 的 SP_INIT_*），所以就算這個檔沒被載入也只是難看一下。
    """
    vp = bytearray(INIT_VP_BYTES)

    def put(addr, value):
        struct.pack_into(">H", vp, addr * 2, value & 0xFFFF)

    for c in controls:
        if c.sp != SP_NONE:
            for k in range(c.sp_words):
                put(c.sp + k, struct.unpack_from(">H", c.desc, SP_MAP_BASE + k * 2)[0])

    return b"\x00" * INIT_HEADER_BYTES + bytes(vp)


def build_bmp():
    """背景圖轉成 24 位元 BMP，檔名用頁編號。

    原廠專案裡背景就是 `00.bmp`（1280×400、24 位元、未壓縮），不是 ICL——
    也就是說**背景圖不需要 Windows 轉檔**。ICL 只剩圖示還要用。
    """
    from PIL import Image
    src = os.path.join(ROOT, "assets", "background%s.png" % L.SUFFIX)
    if not os.path.exists(src):
        return None
    img = Image.open(src).convert("RGB")
    out = os.path.join(ROOT, "dwin_set%s" % L.SUFFIX, "00.bmp")
    img.save(out, "BMP")
    return out


def build_cfg(path):
    """把原廠 CFG 的兩個功能位元打開。位移未驗證，會印出前後對照供核對。"""
    cfg = bytearray(open(path, "rb").read())
    changes = []
    for label, (off, bit) in (("觸控自動上傳", CFG_BIT_TOUCH_UPLOAD),
                              ("PWM 背光控制", CFG_BIT_PWM_BACKLIGHT)):
        i = CFG_FILE_BASE + off
        before = cfg[i]
        cfg[i] |= (1 << bit)
        changes.append("  CFG 0x%02X bit%d (%s) → 檔案位移 0x%02X: 0x%02X → 0x%02X"
                       % (off, bit, label, i, before, cfg[i]))
    return bytes(cfg), changes


def build_header(controls):
    out = ["// 由 tools/gen_dgus_config.py 產生，請勿手改。",
           "// DWIN DGUS 的 VP 位址表；與 14.BIN 出自同一份定義。",
           "#pragma once", "", "// ── 資料 VP ──"]
    for k, v in VP.items():
        out.append("#define VP_%-10s 0x%04X" % (k.upper(), v))
    out += ["", "// ── 變數描述指標（改顏色用；顏色在 SP+%d）──" % SP_OFF_COLOR]
    for nm, sp in (("SPEED", SP_SPEED), ("RPM", SP_RPM),
                   ("COOLANT", SP_COOLANT), ("LIMIT", SP_LIMIT)):
        out.append("#define SP_%-8s 0x%04X" % (nm, sp))
        out.append("#define SP_%s_COLOR 0x%04X" % (nm, sp + SP_OFF_COLOR))
    out += ["", "// ── 顏色（RGB565）──",
            "#define CLR_WHITE 0x%04X" % rgb565(L.TEXT),
            "#define CLR_BLUE  0x%04X" % rgb565(L.BLUE),
            "#define CLR_RED   0x%04X" % rgb565(L.RED),
            "#define CLR_LABEL 0x%04X" % rgb565(L.LABEL),
            "",
            "// 開機時把各控制項的描述重寫一次（22_Config.bin 沒載入也能正常顯示）",
            "// 內容 = 描述 0x06 之後的那幾個字。"]
    for c in controls:
        if c.sp != SP_NONE:
            words = ", ".join(
                "0x%04X" % struct.unpack_from(">H", c.desc, SP_MAP_BASE + k * 2)[0]
                for k in range(c.sp_words))
            out.append("static const uint16_t SP_INIT_%s[%d] = {%s};"
                       % (c.name.upper(), c.sp_words, words))
    return "\n".join(out) + "\n"


# ═══════════════════════════════════════════════════════════════════════
# 報表與反解
# ═══════════════════════════════════════════════════════════════════════

def report(controls):
    print("%-10s %-5s %-6s %5s %5s %5s %5s  %s"
          % ("控制項", "類型", "VP", "X", "Y", "W", "H", "備註"))
    for c in controls:
        vp = struct.unpack_from(">H", c.desc, 0x06)[0]
        x, y, w, h = c.rect
        print("%-10s %-5s 0x%04X %5d %5d %5d %5d  %s"
              % (c.name, c.kind, vp, x, y, w, h, c.note))
        if x < 0 or y < 0 or x + w > L.W or y + h > L.H:
            print("   ⚠ 超出畫面")

    # 兩兩重疊檢查（以著墨範圍為準）。
    # 字格重疊本身無妨：DGUS 更新變數時是先用背景圖還原自己的字格再重畫，
    # 只要對方的筆畫不落在那塊裡就不會被擦掉。EV 圖示本來就是要蓋住轉速。
    expected = {("rpm", "ev")}
    for i, a in enumerate(controls):
        for b in controls[i + 1:]:
            ax, ay, aw, ah = a.ink
            bx, by, bw, bh = b.ink
            if (ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
                    and (a.name, b.name) not in expected
                    and (b.name, a.name) not in expected):
                print("   ⚠ %s 與 %s 的筆畫重疊" % (a.name, b.name))


# 各控制項的示範值，只用於預覽（字串已是 DGUS 會顯示的樣子）
SAMPLE = {
    "speed": "75", "rpm": "1750", "turbo": "0.15",
    "soc": "65.5", "coolant": "88", "limit": "90",
    "date_mm": "09", "date_dd": "01",
    "clock_hh": "18", "clock_mm": "04", "clock_ss": "37",
    "tpms_fl": "34", "tpms_fr": "34", "tpms_rl": "33", "tpms_rr": "33",
    "odo": "33676", "fuel": "50",
}


def render_preview(controls):
    """把 14.BIN 的落點畫回背景圖上。

    數字用 DGUS 的字格排：字寬 = 字級 / 2、基線在字格的 BASELINE_RATIO 處。
    Montserrat 的數字比那個格子寬，這裡把它橫向壓到格寬——DGUS 內建的
    0# ASCII 本來就是 1:2 的窄體，壓過的樣子反而比較接近實機。
    `preview.png` 是版面草圖，這張才是用來檢查座標寫對沒有的。
    """
    from PIL import Image, ImageDraw

    src = os.path.join(ROOT, "assets", "background%s.png" % L.SUFFIX)
    if not os.path.exists(src):
        print("（找不到 %s，略過預覽）" % os.path.basename(src))
        return
    img = Image.open(src).convert("RGB")

    def draw_mono(x0, top, fs, sval, rgb):
        used = len(sval) * cw(fs)
        tmp = Image.new("RGBA", (len(sval) * fs, int(fs * 1.3)), (0, 0, 0, 0))
        td = ImageDraw.Draw(tmp)
        font = L.F_NUM_MD(fs)
        for k, ch in enumerate(sval):
            td.text((k * fs + fs // 2, int(fs * BASELINE_RATIO)), ch,
                    font=font, fill=rgb + (255,), anchor="ms")
        tmp = tmp.resize((used, tmp.height), Image.LANCZOS)
        img.paste(tmp, (x0, top), tmp)

    for c in controls:
        x, y, w, h = c.rect
        if c.kind == "icon":
            if c.name == "weekday":
                ico = os.path.join(ROOT, "assets", "icons%s" % L.SUFFIX, "week_0.png")
                if os.path.exists(ico):
                    img.paste(Image.open(ico), (x, y))
            continue
        val = SAMPLE.get(c.name, "")
        fs, align = c.desc[0x0F], c.desc[0x10]
        used = len(val) * cw(fs)
        x0 = x if align == AL_LEFT else (
            x + w - used if align == AL_RIGHT else x + (w - used) // 2)
        color = struct.unpack_from(">H", c.desc, 0x0C)[0]
        draw_mono(x0, y, fs, val, (((color >> 11) & 0x1F) * 255 // 31,
                                   ((color >> 5) & 0x3F) * 255 // 63,
                                   (color & 0x1F) * 255 // 31))

    out = os.path.join(ROOT, "assets", "preview_dgus%s.png" % L.SUFFIX)
    img.save(out)
    print("預覽（DGUS 字格）：assets/%s" % os.path.basename(out))


def dump_14(path):
    raw = open(path, "rb").read()
    e = raw[len(HDR_14):len(HDR_14) + 4]
    count, off = e[0], int.from_bytes(e[1:], "big")
    print("檔頭 %r  第 0 頁：%d 個控制項，描述在 0x%X" % (raw[:8], count, off))
    for i in range(count):
        d = raw[off + i * DESC_LEN:off + (i + 1) * DESC_LEN]
        sp, splen = struct.unpack_from(">HH", d, 0x02)
        vp, x, y = struct.unpack_from(">HHH", d, 0x06)
        head = "#%02d %s VP=0x%04X (%d,%d) SP=%s(%d字)" % (
            i, "資料" if d[0x01] == VT_DATA else "圖示", vp, x, y,
            "-" if sp == SP_NONE else "0x%04X" % sp, splen)
        if d[0x01] == VT_DATA:
            print("%s 色=0x%04X 字級=%d 對齊=%d 位數=%d.%d 型別=%d"
                  % (head, struct.unpack_from(">H", d, 0x0C)[0],
                     d[0x0F], d[0x10], d[0x11], d[0x12], d[0x13]))
        else:
            vmin, vmax, imin, imax = struct.unpack_from(">HHHH", d, 0x0C)
            print("%s 值=%d..%d 圖示=%d..%d ICL=%d 疊圖=%d"
                  % (head, vmin, vmax, imin, imax, d[0x14], d[0x15]))


def selftest(ref_dir):
    """用參考專案的三個控制項重建 14ShowFile.bin，逐位元組比對。

    比對過就表示容器與描述格式都寫對了——這比對照文件可靠。
    """
    ctls = [
        data_var("ref_right", 0x1234, 111, 222, 30, 3, 2,
                 color=(0xFF, 0x00, 0x00), align=AL_RIGHT),
        data_var("ref_left", 0x1234, 333, 222, 30, 3, 2,
                 color=(0xFF, 0x00, 0x00), align=AL_LEFT),
        icon_var("ref_icon", 0x5678, 444, 222, 0, 0, 0, 6, 1, 7,
                 icl=0xFF, mode=0),
    ]
    ours = build_14(ctls)
    ref = open(os.path.join(ref_dir, "14ShowFile.bin"), "rb").read()
    if ours == ref:
        print("selftest: 14ShowFile.bin 與參考專案**完全一致**（%d 位元組）" % len(ref))
        return 0
    print("selftest: 不一致（我們 %d / 參考 %d 位元組）" % (len(ours), len(ref)))
    for i in range(min(len(ours), len(ref))):
        if ours[i] != ref[i]:
            print("  第一個相異位移 0x%X：我們 0x%02X，參考 0x%02X" % (i, ours[i], ref[i]))
            lo = (i // 16) * 16
            print("  我們 %s" % ours[lo:lo + 32].hex(" "))
            print("  參考 %s" % ref[lo:lo + 32].hex(" "))
            break
    return 1


# ═══════════════════════════════════════════════════════════════════════

def main():
    if "--selftest" in sys.argv:
        ref = sys.argv[sys.argv.index("--selftest") + 1]
        sys.exit(selftest(ref))

    if "--dump" in sys.argv:
        dump_14(os.path.join(ROOT, "dwin_set", NAME_14))
        return

    if "--patch-cfg" in sys.argv:
        src = sys.argv[sys.argv.index("--patch-cfg") + 1]
        cfg, changes = build_cfg(src)
        out = os.path.join(ROOT, "dwin_set")
        os.makedirs(out, exist_ok=True)
        open(os.path.join(out, "T5LCFG.CFG"), "wb").write(cfg)
        print("已由 %s 產生 dwin_set/T5LCFG.CFG" % src)
        for line in changes:
            print(line)
        print("⚠ 位移未驗證：改到的位元組請先對照開發指南 §5 的設定表")
        return

    controls = build_controls()
    out = os.path.join(ROOT, "dwin_set%s" % L.SUFFIX)
    os.makedirs(out, exist_ok=True)

    open(os.path.join(out, NAME_14), "wb").write(build_14(controls))
    open(os.path.join(out, NAME_13), "wb").write(build_13())
    open(os.path.join(out, NAME_22), "wb").write(build_22(controls))
    bmp = build_bmp()
    open(os.path.join(ROOT, "nx4_dwin_vp%s.h" % L.SUFFIX), "w").write(
        build_header(controls))

    report(controls)
    render_preview(controls)
    print("\n已輸出 %dx%d 的 %s/：%s、%s、%s%s，以及 nx4_dwin_vp%s.h"
          % (L.W, L.H, os.path.basename(out), NAME_14, NAME_13, NAME_22,
             "、00.bmp" if bmp else "", L.SUFFIX))
    print("另外要從 DWIN_SET_org/ 複製 120.lib（用途未明，先照抄）")
    print("T5LCFG.CFG 不由本工具產生：以螢幕出廠 SD 卡那份為底，")
    print("  python3 tools/gen_dgus_config.py --patch-cfg <原廠 T5LCFG.CFG>")
    print("\n⚠ 下列欄位尚未與開發指南核對，實機前必須確認：")
    for v in VERIFY:
        print("  - " + v)


if __name__ == "__main__":
    main()
