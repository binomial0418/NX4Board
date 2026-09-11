# NX4Board ESP32-P4 車載儀表顯示器（Waveshare LCD-5 版）

接收 NX4Board App **第二通道** WebSocket 推送的車輛資料，以 LVGL 在
5 吋 MIPI DSI 螢幕上即時渲染儀表畫面。

功能與協定和 `../nx4_dashboard`（JC1060P470C 版）完全相同，差別只在硬體：

| | `nx4_dashboard` | **本專案 `nx4_dashboard_lcd5`** |
|---|---|---|
| 板子 | JC1060P470C | Waveshare ESP32-P4-WIFI6-Touch-LCD-5 |
| 面板 | JD9165 1024x600 橫向 | HX8394 **720x1280 直向** 2-lane @ 700 Mbps |
| 背光 / 面板 RST | GPIO23 / GPIO5 | **GPIO26**（5 kHz）/ **GPIO27** |
| 觸控 | GT911（SDA 7 / SCL 8） | GT911（同腳位，位址需探測 0x5D / 0x14） |
| Flash / PSRAM | 16MB | **32MB / 32MB** |
| 螢幕方向 | 原生橫向，不旋轉 | **LVGL 畫 1280x720，PPA 硬體旋轉 90°** |

- **角色**：WiFi STA + WebSocket **Server**（手機是 Client，主動推送）
- **框架**：Arduino ESP32 core 3.x + LVGL 8.4.0，以 `arduino-cli` 編譯上傳
- **原廠資料**：<https://docs.waveshare.net/ESP32-P4-WIFI6-Touch-LCD-5>、
  <https://github.com/waveshareteam/ESP32-P4-WIFI6-Touch-LCD-5>

---

## 〇、螢幕旋轉（本版本獨有）

面板實體是 **720x1280 直向**，車上要橫著看，所以：

1. LVGL 以 **1280x720**（`pins_config.h` 的 `LCD_H_RES` / `LCD_V_RES`）繪圖，
   所有版面座標都用這組數字。
2. `my_disp_flush()` 不呼叫 `esp_lcd_panel_draw_bitmap()`，改用 **PPA**
   （ESP32-P4 的 Pixel Processing Accelerator）把髒區塊旋轉 90° 後直接寫進
   DPI 的 framebuffer。面板是 video mode、持續掃描該 buffer，寫進去就上畫面。
3. PPA 用 `PPA_TRANS_MODE_BLOCKING`，回來時已寫完，因此直接呼叫
   `lv_disp_flush_ready()`，不需要 `on_color_trans_done` 回呼。

座標換算（90° 逆時針，W = 1280）：`面板x = LVGL y`、`面板y = W - 1 - LVGL x`。
觸控走同一組公式的反函數，在 `my_touchpad_read()` 裡換算。

**裝上去發現畫面上下顛倒**：把 `nx4_dashboard_lcd5.ino` 的 `DISP_ROTATION`
從 `90` 改成 `270`，畫面與觸控會一起翻。

PPA 對區塊起點與長寬有對齊要求，所以 `my_rounder()` 把 LVGL 的髒區域一律
往外補到 4 的倍數（1280 與 720 都能被 4 整除，補完不會出界）。
LVGL 的繪圖緩衝也改用 `heap_caps_aligned_alloc(64, ...)`，對齊快取行。

---

## 一、系統架構

```
┌──────────────────┬─────────────────┬─────────────────────────────┐
│▌Hev電池          │▌胎壓 (PSI)      │   燈  門  鎖  廂            │
│  65.5         %  │  34    34       │                             │
│                  │  33    33       │        75                   │
├──────────────────┼─────────────────┤                             │
│▌水溫             │▌里程  33676  K  │                             │
│  88           C  │─────────────────│                             │
│                  │▌油箱     50   % │       1750 R                │
├──────────────────┼─────────────────┤                             │
│▌09/01 週一       │▌道路速限        │      +0.15 BAR              │
│  18:04           │  90             │  ▁▁▁▁▁▁┃▁▁▁▁▁▁              │
│                  │                 │  -1 -0.5 0 +.5 +1           │
└──────────────────┴─────────────────┴─────────────────────────────┘            └──────────────────────────┘
```

兩條通道**完全獨立**：第一通道的重連、逾時、WiFi 檢查都不影響第二通道，
反之亦然。

---

## 二、資料協定

手機每次 OBD 輪詢更新時推送（預設最短間隔 200 ms，可在 App 設定調整）：

```json
{
  "_type": "esp32_dash",
  "speed": 75,
  "rpm": 1750,
  "coolant": 88,
  "soc": 65.5,
  "fuel": 50,
  "speed_limit": 90,
  "odo": 33676,
  "turbo": 0.15,
  "time": "18:04:37",
  "date": "09/01 週一",
  "tires": { "fl": 34, "fr": 34, "rl": 33, "rr": 33 },
  "camera": { "active": true, "limit": 90 },
  "lights": { "low": true, "high": false },
  "doors": { "open": false, "unlocked": false, "trunk": false },
  "brightness": 40
}
```

| 欄位 | 型別 | 說明 |
|---|---|---|
| `_type` | string | 必須為 `esp32_dash`，其他值一律忽略 |
| `speed` | int | 時速 km/h（OBD 優先，GPS 備援） |
| `rpm` | int | 引擎轉速 |
| `coolant` | int | 水溫 °C |
| `soc` | float | 混合動力電池 % |
| `fuel` | int | 油量 % |
| `speed_limit` | int | 目前路段速限 km/h，`0` 表示無資料 |
| `odo` | int | 里程 km |
| `turbo` | float | 渦輪增壓 Bar，範圍 -1.0 ~ +1.0 |
| `time` | string | `HH:MM:SS`，ESP32 無 RTC，時鐘由手機端提供。畫面只顯示到分鐘，但秒數仍用於本機 `lv_timer` 的累加，手機斷線後才能正確跨分鐘（只送 `HH:MM` 的舊格式也相容） |
| `date` | string | `MM/DD 週X`，同上。星期用字已收錄於中文字型 |
| `tires.{fl,fr,rl,rr}` | int | 四輪胎壓 psi，`0` 表示無資料 |
| `camera.active` | bool | 前方是否偵測到測速照相 |
| `camera.limit` | int | 該測速照相的速限 km/h |
| `lights.low` | bool | 近燈（大燈）是否開啟 |
| `lights.high` | bool | 遠燈是否開啟 |
| `doors.open` | bool | 任一車門開啟 |
| `doors.unlocked` | bool | 任一車門解鎖（22BC04 只有前兩門有訊號） |
| `doors.trunk` | bool | 後車廂開啟 |
| `brightness` | int | 螢幕背光 0–100 %，由手機端依大燈狀態決定 |
| `brightness_hold_ms` | int | 選用。設定頁「測試」按鈕專用，見下方 |

缺少的欄位會沿用上一次的值，避免畫面跳動。

### 螢幕亮度

手機端以 OBD **PID 22BC09**（IGMP 模組，`OBD.csv` 的
`IGMP_Headlights_Low_Beam` = `H/12`、`IGMP_Headlights_High_Beam` = `G/12`）
每 3 秒讀取一次大燈狀態，再依 App 設定換算出 `brightness` 一併推送：

| 大燈狀態 | 使用的設定 | 預設 |
|---|---|---|
| 遠燈開啟 | 遠燈亮度 | 25 % |
| 近燈開啟（遠燈關） | 近燈亮度 | 40 % |
| 皆關閉 | 大燈關閉亮度 | 100 % |

ESP32 收到後以 `lcd.example_bsp_set_lcd_backlight()` 套用（本板背光在
**GPIO26**，LEDC PWM 5 kHz / 10-bit），數值未變動時不會重設 duty。

App 設定頁每一列亮度旁的 **測試** 按鈕會送出帶 `brightness_hold_ms: 5000`
的封包；ESP32 在這 5 秒內會忽略儀表推送裡的 `brightness`，否則每 200 ms
一次的推送會立刻把測試值蓋掉。

---

## 三、畫面配置（LVGL 邏輯 1280 x 720）

版面比照手機端 App 的儀表畫面（專案根目錄 `rec.gif`）：純黑底、
左側兩欄帶分類色條的資訊卡、中右 0-180 圓形時速錶、最右側指示燈條。

座標由 `nx4_dashboard` 的 1024x600 等比重算（x 約 x1.25、y 約 x1.2），
**字型維持原本的點陣尺寸不變**，多出來的空間全部拿來留白。
所有常數集中在 `ui_dashboard.c` 上方，分成四組：版面骨架、卡片內部相對
位移、錶盤與狀態區、右側指示燈條。改 `CARD_H` 時卡片內部那一組要一起重算，
否則分隔線會壓到油箱那一列。

最右側窄欄是指示燈條（燈=大燈、門=車門、鎖=車門解鎖、廂=後車廂），
只有狀態成立的那一格會亮。

```
┌──────────────────┬──────────────────┬────────────────────┬────┐
│▌Hev電池          │▌胎壓 (PSI)       │                    │    │
│  65.5          % │  34      34      │        75          │ 燈 │
│                  │                  │                    │    │
├──────────────────┼──────────────────┤                    │ 門 │
│▌水溫             │▌里程   33676   K │       1750 R       │    │
│  88            C │──────────────────│                    │ 鎖 │
│                  │▌油箱      50   % │      +0.15 BAR     │    │
├──────────────────┼──────────────────┤  ▁▁▁▁▁▁┃▁▁▁▁▁▁     │ 廂 │
│▌09/01 週一       │▌道路速限         │  -1 -0.5 0 +0.5 +1 │    │
│  18:04           │  90              │                    │    │
│                  │                  │         10.0.4.99  │    │
└──────────────────┴──────────────────┴────────────────────┴────┘
```


偵測到測速照相時，「道路速限」卡片會轉為紅底閃爍的警示，標題改為
「測速照相」、數值改為該照相的速限；警示解除或資料逾時後自動恢復。

左欄色條對應：Hev電池=青綠、水溫=天藍、時鐘=橘、
胎壓=琥珀、里程/油箱=天藍、道路速限=紅。

**中央區**：時速 → 轉速 → 增壓，由上而下的垂直堆疊，沒有弧線也沒有刻度。
時速是 SemiBold 大字加字距，下方藍色轉速 + `R`；轉速為 0（引擎熄火、
HEV 純電行駛）時改顯示綠色 `EV` 並隱藏單位。

### 時速外環為什麼拿掉

原本是 0-180、270° 的圓形錶盤。拿掉之後版面語彙與兩側卡片一致，
橫向空間也重新分配過（`COL_W` 272 → 356 → 最後定在 **310**）。

但**釋出的空間比直覺少很多**。錶盤直徑 560，可是它本來就裝著一條 328px 寬的
時速列（`180` 在 184px 加字距），真正浪費的只有約 190px。中央區現在取 390，
是被**增壓刻度列**（370 的長條加上兩端標籤）決定的，不是被時速決定的。

原本評估時以為「照 DWIN 放大到 230px 行不通」，那是在中央區只有 390 的
前提下算的。後來把卡片由 356 收窄到 310、中央區拿到 482，時速就放到了
248——比 DWIN 的 230 還大。**關鍵不是錶環佔了多少，而是卡片要多寬。**

**代價**：失去「目前速度佔上限多少」的視覺指示，只剩數字。
要補回來的話，`dwin_dashboard/README.md` 建議的作法是在時速下方加一條細的
水平進度條，比弧線更貼合長條螢幕。

**數值補間**：手機端最快也只有 3~5 Hz（受限於 OBD 輪詢），直接跳值
看起來會很鈍。時速（進度弧與大字）、轉速、增壓收到新值後改用 `lv_anim`
在「兩筆資料的實際間隔」內線性走到新值，由 LVGL 以自己的更新率補出
中間影格。動畫長度取**實測間隔**而非固定值（`anim_ms()`，夾在 60~500 ms），
這樣動畫剛好在下一筆資料抵達時結束，既不會提早停住也不會持續落後。
代價是畫面本質上落後真實值約一個取樣週期。

實測（`[HB]` 心跳的 `fps` 欄位，於 `my_disp_flush` 計數）：
4 Hz 推送時 76~98 FPS，2 Hz 時 99~109 FPS，均遠未觸及效能上限。

增壓區與右下角狀態區都落在錶弧底部缺口的高度，該處沒有弧線也沒有刻度。

**指示燈**：時速正上方的橫排四格，對應手機端狀態區的四個指示燈。
原本是畫面最右側的直排，那會吃掉右邊 102px（1178..1280）；改成橫排之後
中央區由 544 變成 626，時速得以由 272 放大到 310。
位置寫死，不成立時以 `LV_OBJ_FLAG_HIDDEN` 隱藏而非移除，這樣某一格熄滅時
其它三格不會往上遞補、位置跳來跳去。

| 順序 | 指示 | 來源欄位 | 顏色 |
|---|---|---|---|
| 1 | 大燈 | `lights.low` | 近燈綠、遠燈藍（圖示同時換成遠燈符號） |
| 2 | 車門開啟 | `doors.open` | 琥珀 |
| 3 | 車門解鎖 | `doors.unlocked` | 琥珀 |
| 4 | 後車廂開啟 | `doors.trunk` | 琥珀 |

**右下角**只剩 IP，靠右對齊。
**點 IP 可開啟 WiFi 設定面板**（字很小，可點範圍已往外擴 24px）。連線狀態改由
「資料逾時整片淡出」表達，逾時時指示燈也一起淡出——過期的車門狀態同樣不該
被當成現況。螢幕亮度僅在序列日誌以 `[BRT]` 回報。

**警示值**（達到即轉為**紅字**，門檻定義於 `ui_dashboard.c` 上方）：

| 項目 | 門檻 | 常數 |
|---|---|---|
| 油量 | ≤ 15 % | `ALERT_FUEL_MAX` |
| 胎壓（各輪獨立） | ≤ 30 psi | `ALERT_TIRE_MIN` |
| 水溫 | ≥ 110 °C | `ALERT_COOLANT` |

其餘顏色提示：

- **時速**：超出速限 5 km/h 以上轉紅
- **轉速**：≥ 5500 rpm 轉紅
- **胎壓**：> 40 psi 琥珀色（過高，次級提示）
- **逾時**（預設 5 秒未收到資料）：所有數值淡出至 40% 不透明度

### 效能設計

`ui_dashboard_create()` 只在開機時建立一次所有 LVGL 物件；
`ui_dashboard_update()` 逐欄位比對前一次的值，**只有變動的欄位才寫入**
Label 文字 / Meter / Bar 數值，因此每次推送僅會 invalidate 極小的區域。
搭配 `disp_drv.full_refresh = false`（局部刷新），可維持 60 FPS。

---

## 四、編譯與上傳

### 1. 前置安裝（只需一次）

```bash
# ESP32 core（需 3.1.0 以上；本專案在 3.3.7 驗證）
arduino-cli core update-index
arduino-cli core install esp32:esp32

# 函式庫
arduino-cli lib install "lvgl@8.4.0"
arduino-cli lib install "ArduinoJson"
arduino-cli lib install "WebSockets"        # Links2004/arduinoWebSockets
```

> LVGL 的設定檔已附在本資料夾（`lv_conf.h`，由原廠 Demo 修改而來，
> 額外開啟了 Montserrat 28–48 大字型）。`build.sh` 會以
> `-DLV_CONF_PATH=<本資料夾>/lv_conf.h` 明確指定，不需要動 LVGL 函式庫。

### 2. 設定 WiFi

```bash
cp config.h.example config.h
$EDITOR config.h        # 填入 WIFI_SSID / WIFI_PASS / WS_PORT
```

`config.h` 已列入 `.gitignore`，不會被提交。

也可以**直接在螢幕上設定**：點右下角的 IP 會開啟 WiFi 設定面板，
可掃描周邊網路、輸入 SSID 與密碼，按「儲存並連線」即套用。

設定會寫入 NVS（`Preferences`，namespace `nx4wifi`），**開機時 NVS 優先於
`config.h`** —— 在螢幕上設定過之後，重新燒錄韌體也不會被 `config.h` 蓋掉。
要恢復用 `config.h` 的設定，需清除 NVS（`./build.sh` 加 `EraseFlash=all`，
或在程式中呼叫 `g_prefs.clear()`）。

### 3. 編譯 / 上傳

```bash
./build.sh              # 只編譯
./build.sh -u           # 編譯 + 上傳（自動偵測序列埠）
./build.sh -u -p /dev/cu.usbserial-1130
./build.sh -u -m        # 上傳後開啟序列監視器 (115200)
./build.sh -c           # 先清除 build/ 再編譯
```

使用的 FQBN（對應原廠 Arduino 範例的 IDE 設定）：

```
esp32:esp32:esp32p4:FlashSize=32M,PartitionScheme=app13M_data7M_32MB,\
PSRAM=enabled,FlashMode=qio,FlashFreq=80,UploadSpeed=921600,\
CDCOnBoot=cdc,USBMode=hwcdc,ChipVariant=postv3
```

> `CDCOnBoot=cdc,USBMode=hwcdc` 與原廠 Demo 不同（原廠為 Disabled +
> USB-OTG）：這組設定讓 `Serial` 走燒錄用的那條 USB 線（USB-Serial-JTAG），
> `./build.sh -u -m` 就能直接讀開機日誌，不必另外接 USB-UART 轉板到 UART0。
> 實測若維持 `USBMode=default`（OTG/TinyUSB），CDC 會掛在另一個 USB 端點上，
> 燒錄埠讀不到任何輸出。

> `ChipVariant=postv3` 對應原廠出貨的 **rev3.x** ESP32-P4 晶片。
> 若你手上是 **rev1.x（含 rev1.3）**，要改成 `ChipVariant=prev3` —— 舊 profile
> 用 200 MHz PSRAM，兩個 profile 不能混用。這是**晶片**設定，不是 PCB 版號。

> **core 內建的 esptool 燒不動這塊板。** Arduino core 3.3.7 帶的 esptool 5.1.0
> 在 ESP32-P4 **rev v3.2** 上，stub flasher 啟動後第一個 flash 指令就回
> `The chip stopped responding`；改 `--no-stub` 可以正常讀 flash ID
> （GD25Q256、32MB 都認得出來），但一進入寫入就無聲中斷。降 baud 無效
> （921600 / 230400 / 115200 / 57600 都試過）。**esptool 4.12.0 可以正常燒錄**，
> 而 4.8.1 反而連不上——v5 的重置時序才吃得住這塊板，所以版本要挑 4.12.0。
>
> ```bash
> python3 -m venv /tmp/esptool-venv
> /tmp/esptool-venv/bin/pip install esptool==4.12.0
> NX4_ESPTOOL=/tmp/esptool-venv/bin/esptool.py ./build.sh -u -p /dev/cu.usbmodemXXXX
> ```

> 若板子停在「等待上電同步中」，按住 **BOOT** 再重新上電進下載模式。
> 原廠也提供 Flash Download Tool 直接燒 `firmware/` 裡的 bin（位址 `0x00`），
> 見 <https://docs.waveshare.net/ESP32-P4-WIFI6-Touch-LCD-5/Firmware-Flashing>。

---

## 五、與手機端連線

1. 讓手機與 ESP32 位於同一網段
   （建議手機開熱點讓 ESP32 連上，或兩者同時連車上 4G 路由器）。
2. ESP32 開機後，螢幕上方狀態列會顯示取得的 IP；
   也可從序列監視器看到 `[WiFi] 已連線，IP: ...`。
   若想固定 IP，把 `config.h` 的 `USE_STATIC_IP` 設為 `1`。
3. 在 App 的 **設定 → ESP32-P4 儀表顯示器 (第二通道)**：
   - 填入該 IP 與 Port（預設 `8080`）
   - 打開「啟用 ESP32 儀表推送」
   - 按 **Save**，再按 **模擬** 可在沒接 OBD 的情況下驗證整個畫面：
     它會每 200 ms 連續送出一段 40 秒的行程（怠速 → 加速至 120 →
     定速 → 測速照相警示 → 減速停止），跑完自動循環，再按一次「停止」結束。
     模擬期間儀表頁會暫停自己的推送，避免兩邊互相覆蓋。
4. 連上後狀態列右側會由 `NO LINK`（灰）變成 `LINKED`（綠）。

---

## 六、字型

本專案內附六個以 `lv_font_conv` 產生的字型：

| 檔案 | 內容 | line_height | 用途 |
|---|---|---|---|
| `nx4_font_num_310s.c` | Montserrat **SemiBold** 310 px，`0-9` `-` | 224 | 時速大字 |
| `nx4_font_num_96s.c` | Montserrat **SemiBold** 96 px，`0-9` `E` `V` `-` | 70 | 轉速（含 `EV`） |
| `nx4_font_num_145.c` | Montserrat 145 px，`0-9` `-` `!` | 104 | 水溫、道路速限 |
| `nx4_font_num_112.c` | Montserrat 112 px，`0-9` `.` `-` | 80 | Hev 電池 |
| `nx4_font_num_96.c` | Montserrat 96 px，`0-9` `:` `-` | 69 | 時鐘 `HH:MM` |
| `nx4_font_num_70.c` | Montserrat 70 px，`0-9` `-` | 49 | 胎壓四格 |
| `nx4_font_num_64t.c` | Montserrat 64 px，`0-9` `+` `-` `.` | 45 | 渦輪增壓 |
| `nx4_font_num_46.c` | Montserrat 46 px，`0-9` `-` | 33 | 里程 |
| `nx4_font_num_100.c` | Montserrat 100 px，`0-9` `-` | 72 | 油箱 |
| `nx4_font_tc_26.c` | Noto Sans TC 26 px，ASCII + 57 個漢字 | 32 | 中文標籤 |
| `nx4_font_icons_80.c` | MDI 4 個 + 自製 1 個，80 px | 71 | 右側指示燈條 |

### 字級為什麼是這些數字

相對 `nx4_dashboard`（1024x600 / 7 吋）的放大倍率，取自各元件**容器**的
放大倍率，不是憑感覺挑的：

| 容器 | 舊 | 新 | 倍率 | 內容字型 |
|---|---|---|---|---|
| 錶盤（已移除） | 460 | 560 | 1.217 | 時速 150→184、轉速 76→92，沿用至今 |
| 卡片 `CARD_H` | 170 | 205 | 1.2 | 標籤 22→26 |

卡片的**數值**字級後來又重算過兩次：先拆成每張卡片各自的字型，再於移除
時速外環、`COL_W` 由 272 加寬到 356 之後整批放大。見下一節。

### 每張卡片各自的字級

原本六張卡片共用一個 96px 的 `F_VALUE`，而那個 96 是被 **Hev 電池最寬的
`99.9`** 綁死的——四個字元在 272px 的卡片裡剛好頂滿，害水溫、胎壓、油箱
都陪著一起縮。拆成各自的字型之後：

**兩欄不同寬**：左欄（Hev電池 / 水溫 / 時鐘）被時鐘的 `00:00` 綁在
`COL_W` **310**；右欄（胎壓 / 里程油箱 / 速限）內容較窄，`COL2_W` 收到
**296**，省下的 14px 直接變成中央區的寬度。

目前的採用值與最壞字串：

| 元素 | 最壞字串 | 字級 | 該字串寬 | 可用寬 |
|---|---|---|---|---|
| 水溫 | `120` | **145** | 231 | 270 |
| 道路速限 | `120` | **145** | 231 | 296 |
| Hev 電池 | `99.9` | **112** | 228 | 270 |
| 油箱 | `100` | **100** | 168 | 180 |
| 時鐘 | `00:00` | **96** | 275 | 284 |
| 胎壓 | `88` | **70** | 89 | 兩欄各 136 |
| 里程 | `999999` | **46** | 168 | 180 |

水溫與道路速限共用同一個 145px 字型（速限另外收錄 `!`，測速照相無速限時用）。

### 卡片寬度與時速大小是同一筆預算

`COL_W` 曾經一路加寬到 356，結果反而不好：卡片字級被「**卡片高度**」卡住
（`VALUE_Y` 80、卡片高 205，行高上限 125，對應字級約 172），橫向就吃不滿，
卡片內留下大片空白。

收窄回 310 之後，多數卡片字級幾乎沒動，省下的空間全給了中央區，時速由 184
放大到 **272**（+48%）。兩者是同一筆預算：

中央區的可用範圍是**卡片右緣 634 到畫面右邊距 1260，共 626px**。

這個數字前後修正過三次，每次都是拿掉一條自己畫的界線：

| 時期 | 中央區 | 時速 | 拿掉了什麼 |
|---|---|---|---|
| 圓形錶盤 | 560 | 184 | — |
| 拿掉外環 | 482 | 248 | 外環與刻度 |
| 修正邊界 | 530 | 272 | 676..1158 是多畫的框，實際可到卡片邊 |
| 圖示移上方 | **626** | **310** | 右側直排圖示改成時速上方的橫排 |

| `COL_W` | 中央區 | 時速上限 | Hev | 水溫 | 時鐘 | 里程 |
|---|---|---|---|---|---|---|
| 356 | 390 | 200 | 139 | 172 | 115 | 66 |
| 330 | 442 | 230 | 126 | 162 | 106 | 59 |
| **310** | **482** | **252** | **116** | **149** | **99** | **53** |
| 290 | 522 | 275 | 107 | 137 | 92 | 48 |

**中央區由上而下**：指示燈橫排 `56..127` → 時速 `180..404` →
轉速 `472..542` → 增壓值 `580..625` → 長條 `643..651` → 刻度 `663..687`。

轉速與增壓對齊右欄第三張卡（道路速限，`ROW3_Y` 482..687）：轉速頂端取
`ROW3_Y - 10` = 472、增壓刻度底端 687 貼卡片下緣，中央堆疊與兩側卡片
因此有共同的基準線。

中央區的次要元素一併調整：增壓值改用專用的 64px 字型（原本是 LVGL 內建
上限 48）、`BAR` 26→34、增壓刻度 18→22。

**轉速刻意壓到 96**，時速/轉速 = 2.58。原始設計是 150/76 = 1.97，兩者差不多
大；拿掉錶環之後時速失去了弧線的襯托，主從必須靠字級差拉開才夠分明。

### 胎壓的列距與字級是同一筆預算

胎壓卡的垂直空間是固定的：標題佔到 y=44、卡片高 205，只剩 161px 要塞
兩列數字加三段留白。字級愈大、兩列就愈擠：

「標題到數值的間隔」「兩列的間隔」「字級」三者共用這 161px：

| 字級 | 行高 | 上緣 | 列距 | 下緣 |
|---|---|---|---|---|
| 86 | 62 | 8 | 17 | 12 |
| 76 | 55 | 8 | 35 | 12 |
| **70** | **49** | **20** | **34** | **9** |

採用 70：列1 `64..113`、列2 `147..196`。標題間隔由 8 拉到 20、列距由 17 拉到
34，兩者同時改善，代價是字級退到 70。要再分開只能再縮字級，或把 `CARD_H`
加高（三列卡片目前佔 687px，畫面 720，只剩 33px 可動）。

上限是用 fontTools 從 TTF 逐字算出來的，同時考慮三件事：卡片寬度、靠右
對齊的單位所佔的位置、以及左側中文標籤的實際墨水寬。採用值一律比上限退
一點留餘裕。

> **里程是既有的臨界狀況**：`999999` 在 46px 下寬 168px，但「里程」標籤右緣
> 到數值右界只有 156px。五位數（`33676`，140px）沒問題，六位數會頂到標籤。
> 本次未動它——要修得縮字級或把標籤移到上一行。

> **時鐘是少數被寬度而非高度卡死的。** Montserrat 的數字不等寬，`0` 最寬
> （0.662 em），所以 `00:00` 就是最壞情況。86px 下佔 246px，起點必須由 32
> 左移到 `CLOCK_X 16`，右邊才留得下 10px。垂直則有餘裕：日期佔到 y=78，
> 時鐘在 78..205 之間置中，`CLOCK_Y` 由 92 下移到 110。

> 油箱放大後**不能再沿用原本往左縮排 61px 的寫法**。88px 下 `100` 寬 149px，
> 縮排後左緣會落在 31，直接壓到右緣 72 的「油箱」標籤。改成與里程同樣靠右
> 對齊到 -32。

**道路速限是另一個例外**，刻意再放大到 1.3 倍（96→125）。行車時最需要一眼看到的
就是這個數字，而且它同時是測速照相警示的欄位。`VALUE_Y` 不用跟著改：標題
佔到 y=44、卡片高 205，89px 的數值置中後起點仍是 80。最寬的 `120` 佔 199px，
起點 44、右緣 243，卡片內界 258，還有餘裕。

這樣每個元件佔畫面的比例與原設計一致，只是用上了新面板多出來的 50% 像素。
LVGL 內建字型也一併跟上：里程 38→46、單位 16→20 與 18→22、`BAR` 22→26、
增壓刻度與 IP 14→18。增壓數值含 `+` 與 `.`，只能用內建字型，44→48 是
LVGL 內建的上限。

**注意物理尺寸仍然變小了。** 舊板 7 吋是 6.61 px/mm，新板 5 吋橫放是
11.56 px/mm，要維持相同的實體大小得放大 1.75 倍，但 1280 px 的畫布放不下
（1024 x 1.75 = 1792）。5 吋螢幕無法重現 7 吋的實體版面，上述倍率是在
可用像素內的最佳解，實際字高約為舊板的 0.7 倍。

### 版面驗算

改字級後務必重算相依尺寸。已知的邊界條件：

| 項目 | 最壞字串 | 寬度 | 可用 |
|---|---|---|---|
| Hev 電池 | `99.9` | 196 | 232 |
| 時鐘 | `00:00` | 220 | 258 |
| 時速 | `180` | 328 | 錶盤內圈約 456 |
| 轉速 | `7000` | 254 | 該高度處約 271 |
| 時鐘 | `00:00` | 246 | 卡片 272（起點 16、右留白 10） |

`VALUE_DX` 是唯一**不能**跟著放大的常數：字級到 96px 後，`99.9` 的右緣會
壓到靠右對齊的 `%`，所以由 20 收窄成 12。程式對 SOC ≥ 100 已特判成不帶
小數的 `100`，因此 `100.0` 不會出現。

Montserrat 與 Noto Sans TC 皆為 SIL Open Font License 1.1，授權全文見
`OFL-Montserrat.txt` 與 `OFL-NotoSansTC.txt`。圖示取自
[Material Design Icons](https://pictogrammers.com/library/mdi/)，
Pictogrammers Free License，全文見 `LICENSE-MaterialDesignIcons.txt`。

### 指示燈圖示

MDI 的碼位落在 Plane 15 私有區（如 `U+F0C4A`），是 4-byte UTF-8。產生時用
lv_font_conv 的 `=>` 語法重映到 `U+E000`-`U+E004`，換成 3-byte UTF-8 並讓
整個範圍連續，cmap 就能收成單一個 `FORMAT0_TINY` 子表：

| 重映後 | 來源 | 原碼位 | 用途 |
|---|---|---|---|
| `U+E000` | MDI `car-light-dimmed` | `U+F0C4A` | 近燈 |
| `U+E001` | MDI `car-light-high` | `U+F0C4C` | 遠燈 |
| `U+E002` | MDI `car-door` | `U+F0B6B` | 車門開啟 |
| `U+E003` | MDI `lock-open-variant` | `U+F0FC6` | 車門解鎖 |
| `U+E004` | **自製** `nx4-trunk-open` | `U+F0000` | 後車廂開啟 |

### 後車廂圖示是自己畫的

MDI 的 164 個 Automotive 圖示、以及 Google Material Symbols 全集，都沒有
「後車廂／尾門開啟」。原本借用 `car-back`（車尾正視圖），但它完全沒有
「開啟」的線索，看不出是什麼。

`tools/build_trunk_icon.py` 會畫一個出來並塞進 MDI 字型的空碼位 `U+F0000`，
輸出 `mdi-nx4.ttf`：

```bash
pip install fonttools skia-pathops
cd tools && python3 build_trunk_icon.py     # 需要同目錄下的 mdi.ttf
```

造型取自手機端 `native_dashboard.dart` 的 `_TrunkOpenPainter`（側視車身 +
掀起的尾門），但改成**實心剪影**。在 80px 的實際尺寸下反覆比對過：

- 細線稿完全讀不出來，加粗到看得見又會糊成一團
- 輪子要大且實心，挖輪轂會消失
- 尾門要鉸接在車頂後緣，留縫會看起來像飛走的蓋子
- 拿掉輪子就不像車了

腳本會把描邊與多邊形用 skia-pathops 聯集成單一外框，再以 fontTools 寫成
glyph。注意 `U+F0000` 只能寫進 format 12/13 的 cmap 子表，format 4 只吃
16-bit，塞進去會在 compile 時 `OverflowError`。

```bash
npx -y lv_font_conv@1.5.2 --no-compress --bpp 4 --format lvgl \
  --lv-include lvgl.h --font mdi-nx4.ttf --size 80 \
  --range '0xF0C4A=>0xE000' --range '0xF0C4C=>0xE001' \
  --range '0xF0B6B=>0xE002' --range '0xF0FC6=>0xE003' \
  --range '0xF0000=>0xE004' -o nx4_font_icons_80.c
```

`ui_dashboard.c` 上方的 `ICO_*` 巨集是這五個碼位的 UTF-8 字面值，
**改動 `--range` 順序時要一起改**。

> Regular 以外的字重必須用**靜態**的 TTF。Google Fonts 上游發布的
> `Montserrat[wght].ttf` 與 `NotoSansTC[wght].ttf` 都是可變字型，而且**預設
> 字重是 100（Thin）不是 400**，直接餵給 lv_font_conv 會得到極細的字。
> 先用 fontTools 抽出靜態字重：
>
> ```bash
> python3 -m fontTools.varLib.instancer Montserrat[wght].ttf wght=600 -o Montserrat-SemiBold.ttf
> python3 -m fontTools.varLib.instancer Montserrat[wght].ttf wght=400 -o Montserrat-Regular.ttf
> python3 -m fontTools.varLib.instancer NotoSansTC[wght].ttf wght=400 -o NotoSansTC-Regular.ttf
> ```

> 每個數字字型都必須收錄 `-`：畫面在尚未取得資料時以 `--` 當佔位符，
> 字型少了它會顯示成空白方框。新增任何佔位符或單位字元時，
> 記得檢查對應字型有沒有收錄該字元。

> 時速與轉速另外以 `lv_obj_set_style_text_letter_space()` 加上字距
> （`LS_SPEED` 7px、`LS_RPM` 4px）。字重負責「粗細」、字距負責「疏密」，
> 兩者是分開的：光調字重解決不了數字擠在一起的問題。

> **產生時務必加 `--no-compress`。** lv_font_conv 預設會壓縮點陣，
> 而本專案 `lv_conf.h` 的 `LV_USE_FONT_COMPRESSED = 0`。載入壓縮字型時
> 字寬與行高都正確（版面看起來有預留位置），但**一個像素都畫不出來**，
> 非常容易誤判成版面或顏色問題。字型檔裡的 `.bitmap_format` 必須是 `0`。

重新產生全部六個（需 node 與 fontTools，`$F` 指向上面抽出的靜態 TTF）：

```bash
conv() { npx -y lv_font_conv@1.5.2 --no-compress --bpp 4 \
           --format lvgl --lv-include lvgl.h "$@"; }

conv --font $F/Montserrat-SemiBold.ttf --size 184 \
     --range 0x30-0x39 --range 0x2D -o nx4_font_num_184s.c
conv --font $F/Montserrat-SemiBold.ttf --size 92 \
     --range 0x30-0x39 --range 0x2D --range 0x45 --range 0x56 -o nx4_font_num_92s.c
conv --font $F/Montserrat-Regular.ttf --size 122 \
     --range 0x30-0x39 --range 0x2D --range 0x2E -o nx4_font_num_122.c
conv --font $F/Montserrat-Regular.ttf --size 150 \
     --range 0x30-0x39 --range 0x2D --range 0x21 -o nx4_font_num_150.c
conv --font $F/Montserrat-Regular.ttf --size 110 \
     --range 0x30-0x39 --range 0x2D --range 0x3A -o nx4_font_num_110.c
conv --font $F/Montserrat-Regular.ttf --size 106 \
     --range 0x30-0x39 --range 0x2D -o nx4_font_num_106.c
conv --font $F/Montserrat-Regular.ttf --size 80 \
     --range 0x30-0x39 --range 0x2D -o nx4_font_num_80.c
conv --font $F/Montserrat-Regular.ttf --size 60 \
     --range 0x30-0x39 --range 0x2D -o nx4_font_num_60.c
conv --font $F/NotoSansTC-Regular.ttf --size 26 --range 0x20-0x7E \
     --symbols "一三下不並二五儲入六到取名四壓失存定密已找按掃描擇敗日月水池油消測溫照燈相碼程稱箱網胎設請路輸近速週道遠選里限電點" \
     -o nx4_font_tc_26.c
```

`--symbols` 那一串是目前介面實際用到的 57 個漢字。**新增中文字時必須把字
加進去重新產生**，否則畫面上會是空白方框。可以用這段從原始碼撈出完整字集：

```bash
python3 -c "
import re
c=set()
for f in ['ui_dashboard.c','ui_settings.c']:
    for s in re.findall(r'\"((?:[^\"\\\\]|\\\\.)*)\"', open(f,encoding='utf-8').read()):
        c |= {x for x in s if ord(x) > 0x2E80}
print(''.join(sorted(c)))
"
```

> 注意這只撈得到原始碼裡的字面字串。星期用字（`週一` 到 `週日`）來自手機
> 推送的 `date` 欄位，不在原始碼裡，所以上面的 `--symbols` 清單才是準的。

---

## 七、檔案結構

| 檔案 | 說明 |
|---|---|
| `nx4_dashboard_lcd5.ino` | 主程式：LCD/觸控/LVGL 初始化、**PPA 旋轉**、WiFi、WebSocket Server |
| `ui_dashboard.h/.c` | 儀表 UI 建立與數值更新 |
| `ui_settings.h/.c` | WiFi 設定面板（掃描清單、輸入欄位、螢幕鍵盤） |
| `nx4_font_num_*.c` / `nx4_font_tc_26.c` | 專用字型，六個，見「六、字型」 |
| `pins_config.h` | 邏輯/實體解析度與腳位（依原廠 `docs/IO_ZH.md`） |
| `lv_conf.h` | LVGL 設定（原廠 Demo + 開啟大字型） |
| `config.h.example` | WiFi / Port / 靜態 IP / 逾時設定範本 |
| `src/lcd/` | **HX8394** MIPI DSI 驅動（結構沿用 JD9165 版，換初始化序列與時序） |
| `src/touch/` | GT911 觸控驅動（加上 0x5D / 0x14 位址探測） |
| `build.sh` | arduino-cli 編譯 / 上傳腳本 |

本專案由 `../nx4_dashboard` 複製後改板級程式而來，UI、協定、WiFi、
WebSocket 的邏輯完全相同。`src/touch`、`lv_conf.h`、字型沿用未改；
`src/lcd` 是新寫的 HX8394 驅動，初始化序列與 DSI 時序取自原廠
`examples/arduino/libraries/displays/displays_config.h`。

> **兩份要一起改的東西**：`esp32_dash` 協定欄位、警示門檻、補間邏輯。
> 只改一邊會讓兩塊板子行為不一致。

---

## 八、疑難排解

| 症狀 | 檢查 |
|---|---|
| 螢幕全黑 | 背光是否在 **GPIO26**；PSRAM 是否 `enabled`（沒開會在 `assert(buf)` 當掉）；`ChipVariant` 是否與晶片 revision 相符 |
| 開機迴圈，只印 `abort() was called at PC ...` 沒有斷言訊息 | DSI PHY 的 `phy_clk_src` 用了 `MIPI_DSI_PHY_CLK_SRC_DEFAULT`。那是舊相容巨集、指向 PLL_F20M，只在 esp32p4 < 3.0 可用，rev3 的 HAL 會直接 `abort()`。要用 `MIPI_DSI_PHY_PLLREF_CLK_SRC_DEFAULT`（= XTAL） |
| 開機停在 `lcd.begin()` 不動、沒有崩潰也沒有看門狗 | 有人把面板重置腳接回去了。建立 DSI 匯流排後再脈衝 GPIO27，會讓初始化序列第 16 筆（`0xBD 0x00`）的 `esp_lcd_panel_io_tx_param()` 永遠不返回。`reset_gpio_num` 必須是 -1，見 `hx8394_lcd.cpp` |
| 畫面上下顛倒 | 把 `.ino` 的 `DISP_ROTATION` 由 `90` 改成 `270`，畫面與觸控會一起翻 |
| 序列埠出現 `[PPA] 旋轉失敗` | PPA 對區塊對齊有要求。確認 `my_rounder()` 有掛上 `disp_drv.rounder_cb`，且繪圖緩衝是 `heap_caps_aligned_alloc(64, ...)` 配出來的 |
| 觸控完全沒反應 | 看開機日誌有沒有 `GT911 位址 0x..`。印出 `在 0x5D 與 0x14 都沒有回應` 代表 I2C 不通（檢查 `TP_I2C_SDA/SCL`）；有位址但點不到，看 `[TOUCH] raw=(..) lvgl=(..)` 的換算對不對 |
| 開機後一直 `WiFi ...` | 看序列日誌的 `[WiFi] 斷線, reason=N`：15=密碼錯誤、201=找不到 AP、202/203=認證或關聯失敗。韌體每 10 秒會自動重送 `begin()`，實測 ESP-Hosted 首次常以 `reason=8` 失敗、第二次才成功，屬正常 |
| 狀態列一直 `NO LINK` | App 端 IP/Port 是否正確、是否已打開「啟用 ESP32 儀表推送」、兩者是否同網段 |
| 數值全部灰掉 | 超過 `DATA_TIMEOUT_MS`（預設 5 秒）沒收到推送，多半是手機端斷線或未在充電狀態 |
| `JSON 解析失敗` | 檢查是否誤把第一通道（`BVB-7980`）的 IP/Port 填成 ESP32 的 |
| 畫面撕裂 | 於 `nx4_dashboard_lcd5.ino` 將 `disp_drv.full_refresh` 改為 `true` |
| 某段文字完全不顯示但版面有留位置 | 該字型是壓縮格式。檢查字型檔的 `.bitmap_format` 是否為 `0`，不是的話用 `--no-compress` 重新產生 |
| 右下角出現 FPS / CPU 疊圖 | `lv_conf.h` 的 `LV_USE_PERF_MONITOR` 要設為 `0` |
| 右側指示燈永遠不亮 | 序列日誌看 `[FIELD]` 的 `doors=`：`N` 代表手機 App 版本較舊、沒送 `doors` 物件 |
| 指示燈顯示成空白方框 | `nx4_font_icons_80.c` 的碼位與 `ui_dashboard.c` 的 `ICO_*` 巨集對不上，或字型沒重新產生 |
| 螢幕鍵盤不出現 | `lv_keyboard_constructor()` 內建就對自己做了 `lv_obj_align(BOTTOM_MID)`，之後再用 `lv_obj_set_pos()` 會被當成相對偏移而把鍵盤推出畫面。要用 `lv_obj_align()` 定位。開機時的 `[UI] 設定面板 ...` 會印出實際座標 |
| 點 IP 沒反應 | 先看序列日誌有沒有 `[TOUCH] raw=... lvgl=...`：沒有代表 GT911 沒作用，有的話代表換算後的座標對不上點擊區 |
| 設定過的 WiFi 想改回 config.h | NVS 優先於 config.h，需清除 NVS 才會回退 |
| 亮度只有全亮或全暗 | 本板背光路徑會對 PWM 做交流耦合。若 100% 時反而不亮，把 `hx8394_lcd.cpp` 的滿載 duty 由 1023 降到 1000 左右，讓波形保持有切換 |
| 亮度不會隨大燈變化 | 序列監視器看有無 `[BRT] 螢幕亮度 -> N%`；沒有代表手機端沒讀到 22BC09（App 日誌搜尋 `Headlights`），可能該車的 IGMP 請求 Header 不是 `ATSH302` |
