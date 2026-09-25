#!/usr/bin/env python3
"""產生 NX4 儀表壓克力背板的 DXF 加工檔。

輸出 AutoCAD R12 ASCII DXF——這是雷射/CNC 廠商相容性最好的格式，
不需要外部套件。單位公釐，原點在背板左下角，Y 軸向上。

  NX4_壓克力背板_118.5x64.5.dxf   與模組 PCB 同尺寸（規格書主方案）
  NX4_壓克力背板_126.9x70.7.dxf   與前面板玻璃齊平（選配方案）

每片含：圓角外框、4 個鎖孔、1 個喇叭線出線長圓孔。

尺寸來源：Waveshare 官方機構圖 ESP32-P4-WIFI6-Touch-LCD-5-dimensions-20260408
"""
import math
import os

HOLE_D = 2.8          # M2.5 螺絲的通孔
CORNER_R = 3.0        # 四角圓角，與前面板玻璃一致
PITCH_X = 112.0       # 孔中心對孔中心
PITCH_Y = 57.0

# 喇叭線出線孔：直立長圓孔，長軸沿板寬方向（往板中央延伸）。
# 喇叭插座是板背面的 J5（1.25mm 2P），原廠 3D 模型量得中心在
# 距最近短邊 29.19、距長邊 4.14。插頭的線是朝板中央方向出來的，
# 孔若只開在插座正上方，線得在背板下方急轉 90° 才出得去；所以孔往
# 板中央拉長，讓線斜斜地出來。孔的上緣到板邊留 3.0 的料（= 板厚），
# 雷射切完不易斷。以左上鎖孔為基準定位，兩個方案共用同一組相對座標。
SLOT_W = 7.0          # 寬（沿板長）；1.25 2P 母端插頭約 4.3 x 3.2，可整顆穿過
SLOT_L = 14.0         # 長（沿板寬，往板中央）
SLOT_DX = 25.95       # 孔心相對左上鎖孔：往右
SLOT_DY = -6.25       # 孔心相對左上鎖孔：往下

# 兩個方案：(檔名後綴, 板寬, 板高, 左下角第一孔的 x, y)
VARIANTS = [
    ("118.5x64.5", 118.5, 64.5, 3.25, 3.75),   # 與 PCB 同尺寸
    ("126.9x70.7", 126.9, 70.7, 4.80, 6.85),   # 與玻璃齊平
]

LAYER_CUT = "CUT"


def _pair(code, value):
    return f"{code}\n{value}\n"


def line(x1, y1, x2, y2, layer=LAYER_CUT):
    return ("0\nLINE\n" + _pair(8, layer)
            + _pair(10, f"{x1:.4f}") + _pair(20, f"{y1:.4f}") + _pair(30, "0.0")
            + _pair(11, f"{x2:.4f}") + _pair(21, f"{y2:.4f}") + _pair(31, "0.0"))


def arc(cx, cy, r, a0, a1, layer=LAYER_CUT):
    """DXF 的 ARC 一律由 a0 逆時針畫到 a1（角度制）。"""
    return ("0\nARC\n" + _pair(8, layer)
            + _pair(10, f"{cx:.4f}") + _pair(20, f"{cy:.4f}") + _pair(30, "0.0")
            + _pair(40, f"{r:.4f}")
            + _pair(50, f"{a0:.4f}") + _pair(51, f"{a1:.4f}"))


def circle(cx, cy, r, layer=LAYER_CUT):
    return ("0\nCIRCLE\n" + _pair(8, layer)
            + _pair(10, f"{cx:.4f}") + _pair(20, f"{cy:.4f}") + _pair(30, "0.0")
            + _pair(40, f"{r:.4f}"))


def rounded_rect(w, h, r):
    """左下角為原點的圓角矩形，回傳 4 直線 + 4 圓弧。"""
    ents = [
        line(r, 0, w - r, 0),            # 下
        line(w, r, w, h - r),            # 右
        line(w - r, h, r, h),            # 上
        line(0, h - r, 0, r),            # 左
        arc(w - r, r, r, 270, 360),      # 右下
        arc(w - r, h - r, r, 0, 90),     # 右上
        arc(r, h - r, r, 90, 180),       # 左上
        arc(r, r, r, 180, 270),          # 左下
    ]
    return ents


def slot(cx, cy, width, length):
    """直立長圓孔（長軸沿 Y），回傳 2 直線 + 2 半圓弧。"""
    r = width / 2
    a = length / 2 - r                   # 圓心到孔心的距離
    return [
        line(cx + r, cy - a, cx + r, cy + a),   # 右
        line(cx - r, cy + a, cx - r, cy - a),   # 左
        arc(cx, cy + a, r, 0, 180),             # 上半圓
        arc(cx, cy - a, r, 180, 360),           # 下半圓
    ]


def slot_center(hx, hy):
    return hx + SLOT_DX, hy + PITCH_Y + SLOT_DY


def build(w, h, hx, hy):
    ents = rounded_rect(w, h, CORNER_R)
    for x in (hx, hx + PITCH_X):
        for y in (hy, hy + PITCH_Y):
            ents.append(circle(x, y, HOLE_D / 2))
    ents += slot(*slot_center(hx, hy), SLOT_W, SLOT_L)
    header = ("0\nSECTION\n" + _pair(2, "HEADER")
              + _pair(9, "$INSUNITS") + _pair(70, 4)          # 4 = 公釐
              + _pair(9, "$MEASUREMENT") + _pair(70, 1)       # 1 = 公制
              + _pair(9, "$EXTMIN") + _pair(10, "0.0") + _pair(20, "0.0") + _pair(30, "0.0")
              + _pair(9, "$EXTMAX") + _pair(10, f"{w:.4f}") + _pair(20, f"{h:.4f}") + _pair(30, "0.0")
              + "0\nENDSEC\n")
    tables = ("0\nSECTION\n" + _pair(2, "TABLES")
              + "0\nTABLE\n" + _pair(2, "LAYER") + _pair(70, 1)
              + "0\nLAYER\n" + _pair(2, LAYER_CUT) + _pair(70, 0)
              + _pair(62, 7) + _pair(6, "CONTINUOUS")
              + "0\nENDTAB\n0\nENDSEC\n")
    return header + tables + "0\nSECTION\n" + _pair(2, "ENTITIES") + "".join(ents) + "0\nENDSEC\n0\nEOF\n"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    for suffix, w, h, hx, hy in VARIANTS:
        name = f"NX4_壓克力背板_{suffix}.dxf"
        with open(os.path.join(here, name), "w", encoding="ascii", newline="\r\n") as f:
            f.write(build(w, h, hx, hy))
        holes = [(hx, hy), (hx + PITCH_X, hy), (hx, hy + PITCH_Y), (hx + PITCH_X, hy + PITCH_Y)]
        print(f"{name}")
        print(f"   外形 {w} x {h}、圓角 R{CORNER_R:g}、4 x Ø{HOLE_D:g} 通孔")
        print(f"   孔位 " + "  ".join(f"({x:g}, {y:g})" for x, y in holes))
        print(f"   邊距 左右 {hx:g} / {w - hx - PITCH_X:g}、上下 {hy:g} / {h - hy - PITCH_Y:g}")
        sx, sy = slot_center(hx, hy)
        print(f"   喇叭線孔 {SLOT_W:g} x {SLOT_L:g} 直立長圓孔，孔心 ({sx:g}, {sy:g})、"
              f"孔緣距上邊 {h - sy - SLOT_L / 2:g}、下緣 Y {sy - SLOT_L / 2:g}")


if __name__ == "__main__":
    main()
