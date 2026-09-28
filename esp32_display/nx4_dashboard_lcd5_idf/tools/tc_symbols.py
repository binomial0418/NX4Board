#!/usr/bin/env python3
"""列出「會顯示在畫面上」的中文字，給 lv_font_conv 的 --symbols 用。

nx4_font_tc_26 / tc_32 / tc_44 是只收用到的字的子集字型，新增任何中文字串卻忘了把
新字補進去，畫面上就會是方塊——而且功能完全正常，很容易到很後面才發現。
這支腳本就是為了不要再靠人工記憶。

只收真正進得了 LVGL 的字串：
  * ui_dashboard.c / ui_settings.c 的所有字串字面值
  * 其他檔案裡「當成參數傳給 ui_* 函式」的字串字面值
送去序列埠的 printf / ESP_LOG 不算，那些不需要字型。

    python3 tools/tc_symbols.py            # 印出字串
    python3 tools/tc_symbols.py --check    # 與現有字型比對，有缺字就非零結束
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "..", "main")

UI_FILES = ["ui_dashboard.c", "ui_settings.c"]
SCAN_FOR_UI_CALLS = ["main.c"]

# 執行期才拿到的字，掃不到原始碼但一定會上畫面。
#
# 日期是手機端算好直接送過來的（"01/01 週一"，見 dashboard_screen.dart 的
# _weekdayZh），板子這邊只是原樣顯示，所以星期幾這幾個字沒有任何 C 字串
# 字面值可以掃。漏掉的話日期會變方塊。
# 閘道前預知的路線編號也是手機送來的（"3甲"、"2甲"），國道支線的「甲」只出現在執行期。
RUNTIME = "週一二三四五六日甲"

STR = re.compile(r'"((?:[^"\\]|\\.)*)"')


def is_display_char(c):
    o = ord(c)
    return (0x4E00 <= o <= 0x9FFF        # 漢字
            or 0x3000 <= o <= 0x303F     # 、。〈〉《》「」
            or 0xFF00 <= o <= 0xFFEF)    # 全形標點


def collect():
    chars = set()
    for f in UI_FILES:
        src = io.open(os.path.join(MAIN, f), encoding="utf-8").read()
        for m in STR.finditer(src):
            chars |= {c for c in m.group(1) if is_display_char(c)}

    # 其他檔案只看傳給 ui_* 的字串，序列埠的訊息不需要字型
    for f in SCAN_FOR_UI_CALLS:
        for line in io.open(os.path.join(MAIN, f), encoding="utf-8"):
            if "ui_" not in line:
                continue
            for m in STR.finditer(line):
                chars |= {c for c in m.group(1) if is_display_char(c)}

    chars |= set(RUNTIME)
    return "".join(sorted(chars))


def main():
    syms = collect()
    if "--check" not in sys.argv:
        print(syms)
        return

    # 字型檔頭會記下產生時用的 --symbols，直接拿來比對
    missing = set()
    for f in ["nx4_font_tc_26.c", "nx4_font_tc_32.c", "nx4_font_tc_44.c"]:
        head = io.open(os.path.join(MAIN, f), encoding="utf-8").read(4096)
        m = re.search(r"--symbols (\S+)", head)
        have = set(m.group(1)) if m else set()
        missing |= set(syms) - have
    if missing:
        print("字型缺字（畫面上會是方塊）:", "".join(sorted(missing)))
        sys.exit(1)
    print(f"字型收錄完整（{len(syms)} 字）")


if __name__ == "__main__":
    main()
