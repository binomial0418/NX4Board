---
name: dwin-dgus
description: 產生或修改 DWIN 智慧串口屏（T5L / DGUS II）的畫面設定檔 —— 14ShowFile.bin、13TouchFile.bin、22_Config.bin、背景 BMP、VP 位址表。當工作涉及 esp32_display/dwin_dashboard/、DGUS、DWIN_SET、儀表版面座標、VP/SP 位址或紅字警示時使用。
---

# DWIN DGUS 設定檔

儀表的 DWIN 版本。素材與設定檔全部由程式產生，**沒有手拉的美術檔**。

工作目錄：`esp32_display/dwin_dashboard/`

## 兩支程式

```bash
cd esp32_display/dwin_dashboard

# 背景圖與圖示（需要字型資料夾，見下）
python3 tools/gen_background.py <字型資料夾> [畫面高度]

# 設定檔、VP 位址表、以 DGUS 字格重畫的預覽
python3 tools/gen_dgus_config.py <字型資料夾> [畫面高度]

python3 tools/gen_dgus_config.py --selftest DWIN_400_org/DWIN_SET   # 格式回歸測試
python3 tools/gen_dgus_config.py --dump                            # 反解 14ShowFile.bin
python3 tools/gen_dgus_config.py --patch-cfg <原廠 T5LCFG.CFG>      # 開觸控上傳＋PWM 背光
```

畫面高度預設 480（DMG12480C068），給 400 則產生 DMG12400C074 版，輸出檔名加 `_400`。

字型檔**不在版控裡**，要自備 `Montserrat.ttf`、`Montserrat-Medium.ttf`、
`Montserrat-SemiBold.ttf`、`NotoSansTC-Medium.ttf`（Medium 字重要用
`python3 -m fontTools.varLib.instancer <可變字型> wght=500 -o ...` 抽）。
也可用環境變數 `NX4_FONTS` / `NX4_HEIGHT` 指定。

## 四條不能破壞的規則

1. **座標只有一份。** `gen_dgus_config.py` 是 `import gen_background` 取座標的。
   背景圖上的單位、冒號、斜線是靜態的，數值是螢幕疊上去的——兩份座標一旦分家就會歪。
   要移動任何東西，改 `gen_background.py` 上方的常數，兩邊一起跟著動。

2. **改格式後必跑 `--selftest`。** 它用參考專案的三個控制項重建
   `14ShowFile.bin` 並逐位元組比對，是這份格式唯一的回歸測試。

3. **DGUS 的字是等寬點陣：字寬 = 字級 ÷ 2。** 凡是靜態符號要和動態數字排在
   一起（時鐘的 `:`、日期的 `/`），背景圖必須用 `CELL()` / `cell_text()` 的
   字格座標畫，不能用 Montserrat 的字寬推。

4. **`preview.png` 是版面草圖，`preview_dgus.png` 才是驗座標用的**
   ——後者是拿產生出來的 `14ShowFile.bin` 重畫的。

## 已驗證的檔案格式

以 `DWIN_400_org/`（DGUS V7.650 排三個控制項存出來的參考專案）逐位元組確認。
完整欄位表在 `esp32_display/dwin_dashboard/README.md`，摘要：

- `14ShowFile.bin` = 16 位元組檔頭 `14 "DGUS_2" 10` + 4092 個頁項目 + 描述資料區
- 頁項目 = **1 位元組控制項數量 + 3 位元組檔案位移**（不是單純指標）
- 描述固定 32 位元組：`0x00` = `0x5A`、`0x01` = 類型、`0x02` = `*SP`、
  `0x04` = SP 描述長度（資料變數 13 字／圖示 10 字）、`0x06` = `*VP`、
  `0x08` = X、`0x0A` = Y
- **`SP+n` 對應描述的 `0x06+2n`**，顏色在 `0x0C` → **`SP+3`**（紅字警示靠這個）
- 對齊：左 = 0、右 = 1、置中 = 2
- `22_Config.bin` = 整個 VP 空間（從 `0x0000`）的映像 + 4 個位元組
- **背景圖是 `00.bmp`（24 位元未壓縮），不需要 ICL**；ICL 只剩圖示要用

## 還沒驗到的

觸控（`13TouchFile.bin`）格式、圖示描述 `0x16~0x19` 的 `00 00 00 3F`、
0# 字庫的字級上限、前導 0 顯示與否、`22_Config.bin` 那 4 個位元組在頭還是尾、
`120.lib` 的意義、`T5LCFG.CFG` 的設定位移。程式跑完會把清單印出來。

## 要逆向新的控制項類型時

別猜。請使用者在 DGUS 工具裡放那個控制項、填**好認的特徵值**（例如
VP `0x1234`、X 111、Y 222、紅色 `F800`），存檔後把整個 `DWIN_SET` 給你。
訣竅是**同型別放兩個、只差一個欄位**（例如只改 X 和對齊），diff 出來直接指認位移。

## 三個陷阱

- DGUS 工具的專案本體是 `DWprj.tft`，`DWIN_SET/` 是它的**輸出**。
  我們的 BIN **不能反向匯入**，而且在工具裡按「生成」會覆蓋 `DWIN_SET/`。
  所以我們的產出放 `dwin_set/`，不要跟 `DWIN_400_org/DWIN_SET/` 混用。
- `T5LCFG.CFG` **不要憑空產生**。原廠工具附的那份是 800×480，而且設定位元組
  的起算位移還沒確認，盲改會寫進解析度欄位。要以螢幕出廠 SD 卡那份為底。
- 螢幕不需要字型檔：中文全部畫進背景圖，動態值全是數字，用內建 0# ASCII。
  中文的動態內容（例如星期）要做成圖示由 VP 切換。
