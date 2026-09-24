# 產生 NX4Board 專用的「後車廂開啟」圖示，並塞進 MDI 字型的空碼位 U+F0000。
# 造型參考手機端 native_dashboard.dart 的 _TrunkOpenPainter，但改成實心剪影，
# 好跟 MDI 其它圖示的份量一致（線稿版在 80px 下太細、加粗又會糊成一團）。
import math
from pathops import Path, difference, union
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.transformPen import TransformPen
from fontTools.misc.transform import Transform
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.boundsPen import BoundsPen

K = 0.5522847498
def circle(c, r):
    x, y = c; p = Path(); pen = p.getPen()
    pen.moveTo((x+r, y))
    pen.curveTo((x+r, y+r*K), (x+r*K, y+r), (x, y+r))
    pen.curveTo((x-r*K, y+r), (x-r, y+r*K), (x-r, y))
    pen.curveTo((x-r, y-r*K), (x-r*K, y-r), (x, y-r))
    pen.curveTo((x+r*K, y-r), (x+r, y-r*K), (x+r, y))
    pen.closePath(); return p
def polygon(pts):
    p = Path(); pen = p.getPen()
    pen.moveTo(pts[0])
    for q in pts[1:]: pen.lineTo(q)
    pen.closePath(); return p
def cub(p0, c1, c2, p3, n=24):
    return [((1-t)**3*p0[0]+3*(1-t)**2*t*c1[0]+3*(1-t)*t*t*c2[0]+t**3*p3[0],
             (1-t)**3*p0[1]+3*(1-t)**2*t*c1[1]+3*(1-t)*t*t*c2[1]+t**3*p3[1])
            for t in [i/n for i in range(n+1)]]

# painter 座標，y 向下。造型在 80px 實際尺寸下反覆比對過：
# 輪子要大且實心（挖輪轂會糊掉）、尾門要粗且明確鉸在車頂後緣，
# 沒有輪子就看不出是車，細線稿在這個尺寸完全讀不出來。
BODY = [(18,138), (16,104)] + cub((16,104),(22,90),(40,84),(56,82)) + \
       [(88,80), (116,32), (176,32), (202,138)]
LID  = [(168,30), (232,2), (244,30), (180,60)]       # 掀起的尾門，鉸在車頂後緣
WHEELS = ((64,146), (158,146))

solids = [polygon(BODY), polygon(LID)] + [circle(c, 26) for c in WHEELS]

final = Path(); union(solids, final.getPen())

rec = RecordingPen(); final.draw(rec)
bp = BoundsPen(None); rec.replay(bp)
x0, y0, x1, y1 = bp.bounds
print(f"墨水框: ({x0:.0f},{y0:.0f})-({x1:.0f},{y1:.0f})")

# MDI: upem 512、advance 512、圖示大致落在 0..470 x 0..385，基線在 y=0
s = min(350.0/(y1-y0), 470.0/(x1-x0))
w = (x1-x0)*s
t = Transform(s, 0, 0, -s, (512-w)/2 - x0*s, y1*s)   # y 翻轉並置中

pen = TTGlyphPen(None); rec.replay(TransformPen(pen, t))
glyph = pen.glyph()

font = TTFont("mdi.ttf")
glyph.recalcBounds(font["glyf"])
NAME, CP = "nx4-trunk-open", 0xF0000
order = font.getGlyphOrder() + [NAME]
font.setGlyphOrder(order)
font["glyf"].glyphs[NAME] = glyph
font["glyf"].glyphOrder = order
font["hmtx"].metrics[NAME] = (512, int(glyph.xMin))
# format 4 子表只吃 16-bit，U+F0000 只能寫進 format 12/13
hit = sum(1 for tb in font["cmap"].tables
          if tb.isUnicode() and tb.format in (12, 13) and not tb.cmap.__setitem__(CP, NAME))
assert hit, "找不到 format 12 cmap 子表"
font.save("mdi-nx4.ttf")
print(f"mdi-nx4.ttf 完成：{NAME} @ U+{CP:05X} bbox=({glyph.xMin},{glyph.yMin})-({glyph.xMax},{glyph.yMax})")
