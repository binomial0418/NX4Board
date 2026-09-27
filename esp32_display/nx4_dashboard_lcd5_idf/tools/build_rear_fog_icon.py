# 產生「後霧燈」圖示，塞進 mdi-nx4.ttf 的空碼位 U+F0001。
# 必須在 build_trunk_icon.py 之後執行（讀它的輸出、原地覆寫）。
#
# MDI 只有 car-light-fog（U+F0C4B），那是前霧燈：光線朝左。車規的後霧燈
# 符號是同一個造型左右翻轉、光線朝右，所以直接把它鏡射過來，不另外畫。
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.reverseContourPen import ReverseContourPen
from fontTools.misc.transform import Transform

font = TTFont("mdi-nx4.ttf")
glyphs = font.getGlyphSet()
src = font.getBestCmap()[0xF0C4B]           # car-light-fog

# 以 advance 512 的中線翻轉。鏡射會讓外框的繞行方向反過來，
# 再用 ReverseContourPen 轉回 TrueType 慣例的順時針，避免挖洞處被填滿。
pen = TTGlyphPen(None)
glyphs[src].draw(TransformPen(ReverseContourPen(pen), Transform(-1, 0, 0, 1, 512, 0)))
glyph = pen.glyph()
glyph.recalcBounds(font["glyf"])

NAME, CP = "nx4-rear-fog", 0xF0001
order = font.getGlyphOrder() + [NAME]
font.setGlyphOrder(order)
font["glyf"].glyphs[NAME] = glyph
font["glyf"].glyphOrder = order
font["hmtx"].metrics[NAME] = (512, int(glyph.xMin))
# 與後車廂同理：U+F0001 只能寫進 format 12/13
hit = sum(1 for tb in font["cmap"].tables
          if tb.isUnicode() and tb.format in (12, 13) and not tb.cmap.__setitem__(CP, NAME))
assert hit, "找不到 format 12 cmap 子表"
font.save("mdi-nx4.ttf")
print(f"mdi-nx4.ttf 完成：{NAME} @ U+{CP:05X} bbox=({glyph.xMin},{glyph.yMin})-({glyph.xMax},{glyph.yMax})")
