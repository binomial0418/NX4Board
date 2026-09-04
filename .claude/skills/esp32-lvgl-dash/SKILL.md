---
name: esp32-lvgl-dash
description: 修改 ESP32-P4 整合屏（JC1060P470C，1024×600 MIPI DSI）上的 LVGL 儀表韌體 —— 版面座標、字型、補間動畫、亮度、WiFi 設定面板、arduino-cli 編譯燒錄。當工作涉及 esp32_display/nx4_dashboard/、LVGL、lv_conf.h、lv_font_conv、JD9165、GT911 或 esp32_dash 協定的螢幕端時使用。
---

# ESP32-P4 + LVGL 儀表韌體

實車已完整驗證通過的儀表。工作目錄：`esp32_display/nx4_dashboard/`

手機（OBD/GPS）── WiFi/WebSocket ──► ESP32-P4 ──► 1024×600 螢幕

## 編譯與燒錄

```bash
cd esp32_display/nx4_dashboard
./build.sh                       # 只編譯
./build.sh -u -p /dev/cu.usbmodem101   # 編譯 + 上傳
./build.sh -u -m                 # 上傳後開序列監視器
./build.sh -c                    # 先清 build/
```

FQBN（`build.sh` 內）：
```
esp32:esp32:esp32p4:FlashSize=16M,PartitionScheme=app3M_fat9M_16MB,
PSRAM=enabled,FlashMode=qio,FlashFreq=80,UploadSpeed=921600,
CDCOnBoot=cdc,USBMode=hwcdc
```

需要 `lvgl@8.4.0`、`ArduinoJson`、`WebSockets`（Links2004）。
`lv_conf.h` 在 sketch 目錄，靠 `-DLV_CONF_PATH=<絕對路徑>` 指定。

`config.h` 不在版控（WiFi 帳密），從 `config.h.example` 複製。

## 八個坑（依難查程度排序）

1. **`lv_font_conv` 預設會壓縮。** 產生的字型 `.bitmap_format = 1`，而
   `lv_conf.h` 的 `LV_USE_FONT_COMPRESSED = 0` → **字寬行高全對、一個像素都畫不出來**。
   版面看起來有留位置，最難聯想到字型。**產生字型一律加 `--no-compress`**，
   並確認檔案裡 `.bitmap_format` 是 `0`。

2. **LVGL v8：物件設過 `lv_obj_align()` 之後，`lv_obj_set_pos()` 是「相對該對齊點的偏移」**，
   不是絕對座標。這個坑咬了兩次：時速大字實際跑到 x≈1110（畫面外）、
   螢幕鍵盤跑到 y=618。**`lv_keyboard_constructor()` 內建就會對自己
   `lv_obj_align(BOTTOM_MID)`**，所以鍵盤只能用 `lv_obj_align()` 定位。
   查過其他 widget（textarea/list/btn/label/btnmatrix）建構子都沒有這行。

3. **`LV_SPRINTF_USE_FLOAT = 0`** → `lv_snprintf` 不支援 `%f`。`%.1f` 印出方框、
   `%+.2f` 印出字面的 `f`。一律用整數拆小數位：
   `int v10 = (int)(x * 10 + 0.5f); ..."%d.%d", v10 / 10, v10 % 10`

4. **每個數字字型都必須收錄 `-`。** 未取得資料時佔位符是 `--`，字型少了它就是方框。
   新增任何佔位符或單位字元時，都要回頭檢查對應字型有沒有收錄。

5. **`lv_obj_align_to()` 是一次性的，不是綁定。** 目標物件之後移動，它不會跟。
   數值置中後單位會留在原地（`1750` 和 `R` 疊在一起就是這個）。
   要在 update 裡把數值與單位一起重算。

6. **序列埠讀不到輸出。** 原廠 Demo 是 `USBMode=default`（USB-OTG），CDC 掛在
   另一個端點上，燒錄用的那條線讀不到。要 **`CDCOnBoot=cdc,USBMode=hwcdc`** 兩個一起設。

7. **PSRAM 必須 `enabled`**，否則開機在 `assert(buf)` 當掉（雙緩衝要 1.2MB）。

8. **原廠 `lv_conf.h` 的 `LV_USE_PERF_MONITOR` 是 1**，右下角會有 FPS/CPU 疊圖蓋住內容。

其他小的：`lv_meter` 會在 `LV_PART_INDICATOR` **無條件畫指針樞紐圓點**
（沒有指針也會畫，要把 size 與 bg_opa 歸零）；Montserrat / Noto Sans TC 官方
發布是**可變字型，取不到粗體**，要用 `python3 -m fontTools.varLib.instancer
<可變字型> wght=500 -o <輸出>` 抽，或找靜態 TTF。

## WiFi（ESP-Hosted，兩個坑）

ESP32-P4 沒有原生 WiFi，靠 C6 協處理器。

- **初次連線失敗會永遠卡住**：原本只在「已連線→斷線」的轉換才重連，
  開機第一次就失敗時 `was_connected` 從未為 true。要改成未連線時定期重送 `begin()`。
- **`WiFi.setSleep(false)` 不能在 `begin()` 之前呼叫**，會讓 ESP-Hosted 重新初始化，
  剛送出的連線請求以 `reason=8 (ASSOC_LEAVE)` 被中止。移到取得 IP 之後。

實測行為：第一次 `reason=8` 失敗、10 秒後重試才成功，**屬正常**。

## 補間（讓低資料率看起來順）

手機端受 OBD 輪詢限制只有 3~5 Hz，直接跳值很鈍。作法是收到新值後用
`lv_anim` **線性**過渡，動畫長度取「**兩筆資料的實測間隔**」而非固定值
（`anim_ms()`，夾 60~500ms）——這樣動畫剛好在下一筆抵達時結束，
既不提早停頓也不持續落後。用 ease-out 反而會停停走走。

同一組 `(var, exec_cb)` 重新啟動會取代前一段動畫，所以新資料到時是從
目前顯示值接著走，不會跳回起點。

實測：4 Hz 推送時 76~98 FPS、2 Hz 時 99~109 FPS（`[HB]` 心跳的 `fps` 欄位，
在 `my_disp_flush` 計數）。效能不是瓶頸。

## 診斷手段（都在序列埠）

| 標籤 | 內容 |
|---|---|
| `[HB]` | 每 10 秒：WiFi 狀態碼、IP、client 數、最後資料距今、亮度、**實測 fps**、時速/轉速/大燈 |
| `[FIELD]` | 手機**曾經送過**哪些欄位（`odo=Y time=N ...`）—— 用來分辨「韌體壞了」還是「App 版本舊」 |
| `[WS-RAW]` | 連線後第一筆封包原樣印出 |
| `[TOUCH]` | 按下瞬間的座標 |
| `[BRT]` | 亮度變更 |
| `[WiFi] 斷線, reason=N` | 15=密碼錯、201=找不到 AP、202/203=認證或關聯失敗、8=見上面 |

**缺欄位在協定上是合法的**（沿用舊值），所以 App 版本舊時畫面只會「不更新」
而不會報錯——`[FIELD]` 就是為了這個加的。

## 架構

| 檔案 | 職責 |
|---|---|
| `nx4_dashboard.ino` | LCD/觸控/LVGL 初始化、WiFi、WebSocket Server、JSON 解析、背光 |
| `ui_dashboard.c/.h` | 儀表版面與數值更新、補間 |
| `ui_settings.c/.h` | WiFi 設定面板（掃描清單、輸入框、螢幕鍵盤） |
| `src/lcd/`、`src/touch/` | JD9165 與 GT911 驅動，**原廠 Demo 原樣複製，不要改** |

UI 層是純 LVGL 的 C 檔，不碰 Arduino API；掃描、連線、NVS 儲存都由 `.ino`
透過 callback 完成。**背景圖裡的靜態文字無法隱藏**，要蓋掉整列（例如轉速歸零
顯示 `EV`）就用不透明元件覆蓋。

`ui_dashboard_create()` 只在開機建立一次所有物件；`ui_dashboard_update()`
逐欄位比對，**只有變動的欄位才寫入**，配合 `full_refresh = false` 局部刷新。

## 改版面時

座標常數集中在 `ui_dashboard.c` 上方。改字級之後**務必重算相依的尺寸**——
例如 EV 是靠不透明圖示蓋住轉速那一列，轉速字級一改就蓋不住了。
`H_SPEED` / `H_RPM` / `H_VALUE` 這些是字型的 `line_height`，換字型要一起改。

## 產生字型

```bash
npx lv_font_conv@1.5.2 --no-compress --font <字型>.ttf \
  --size 112 --bpp 4 --format lvgl --lv-include lvgl.h \
  --range 0x30-0x39 --range 0x2D -o nx4_font_num_112.c
```

`--bpp 4` 足夠（8 會讓檔案大一倍、視覺上看不出差別）。數字字型只收
`0x30-0x39` 與 `0x2D`；中文另外用 `--symbols` 逐字列出實際會用到的字，
全字集會爆 flash。產生後把新字型加進 `ui_dashboard.c` 的 `LV_FONT_DECLARE`。

## 協定與版面細節

`esp32_dash` JSON 的完整欄位表、畫面座標圖、疑難排解，
見 `esp32_display/nx4_dashboard/README.md`。手機端送出在
`lib/screens/dashboard_screen.dart` 的 `_sendEsp32DashData()`（200ms 節流），
**與既有 60 秒 MQTT 通道彼此獨立**，改動時不要讓兩者互相影響。
