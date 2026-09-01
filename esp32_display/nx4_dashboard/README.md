# NX4Board ESP32-P4 車載儀表顯示器

接收 NX4Board App **第二通道** WebSocket 推送的車輛資料，以 LVGL 在
1024x600 MIPI DSI 螢幕上即時渲染儀表畫面。

- **硬體**：JC1060P470C（ESP32-P4 + JD9165 MIPI DSI 1024x600 + GT911 觸控）
- **角色**：WiFi STA + WebSocket **Server**（手機是 Client，主動推送）
- **框架**：Arduino ESP32 core 3.x + LVGL 8.4.0，以 `arduino-cli` 編譯上傳

---

## 一、系統架構

```
┌──────────────────────────┐            ┌──────────────────────────┐
│  Android 手機 (NX4Board) │            │  ESP32-P4 (本專案)       │
│                          │            │                          │
│  OBD SPP ──► AppProvider │            │  WebSocket Server :8080  │
│                 │        │            │           │              │
│      ┌──────────┴────────┐            │           ▼              │
│      │                   │            │   JSON 解析 → 資料結構   │
│  第一通道             第二通道 ───────────►         │              │
│  _channel            _esp32Channel     │           ▼              │
│  60 秒 / MQTT 後送   每次 OBD 輪詢即時 │   LVGL 只更新數值物件    │
│  (BVB-7980)          (esp32_dash)      │   → 1024x600 MIPI DSI    │
└──────────────────────────┘            └──────────────────────────┘
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
  "time": "18:04",
  "date": "09/01 週一",
  "tires": { "fl": 34, "fr": 34, "rl": 33, "rr": 33 },
  "camera": { "active": true, "limit": 90 },
  "lights": { "low": true, "high": false },
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
| `time` | string | `HH:MM`，ESP32 無 RTC，時鐘由手機端提供 |
| `date` | string | `MM/DD 週X`，同上。星期用字已收錄於中文字型 |
| `tires.{fl,fr,rl,rr}` | int | 四輪胎壓 psi，`0` 表示無資料 |
| `camera.active` | bool | 前方是否偵測到測速照相 |
| `camera.limit` | int | 該測速照相的速限 km/h |
| `lights.low` | bool | 近燈（大燈）是否開啟 |
| `lights.high` | bool | 遠燈是否開啟 |
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

ESP32 收到後以 `lcd.example_bsp_set_lcd_backlight()` 套用（JD9165 驅動以
GPIO23 的 LEDC PWM 控制背光，10-bit），數值未變動時不會重設 duty。

App 設定頁每一列亮度旁的 **測試** 按鈕會送出帶 `brightness_hold_ms: 5000`
的封包；ESP32 在這 5 秒內會忽略儀表推送裡的 `brightness`，否則每 200 ms
一次的推送會立刻把測試值蓋掉。

---

## 三、畫面配置（1024 x 600）

版面比照手機端 App 的儀表畫面（專案根目錄 `rec.gif`）：純黑底、
左側兩欄帶分類色條的資訊卡、右側 0-180 圓形時速錶。

```
┌──────────────┬──────────────┬────────────────────────────────────┐
│▌Hev電池      │▌胎壓 (PSI)   │           ‥  80  100 ⁚             │
│  65.5      % │  34    34    │        60              120         │
│              │  33    33    │                                    │
├──────────────┼──────────────┤     40         75         140      │
│▌水溫         │▌里程 33676 K │                                    │
│  88        C │──────────────│     20                    160      │
│              │▌油箱   50  % │        0    1750 R                 │
├──────────────┼──────────────┤                        180         │
│▌09/01 週一   │▌道路速限     │                                    │
│  18:04       │  90          │         +0.15  BAR            近燈 │
│              │              │    ▁▁▁▁▁▁▁┃▁▁▁▁▁▁       10.0.4.99 │
│              │              │    -1 -0.5  0 +0.5 +1              │
└──────────────┴──────────────┴────────────────────────────────────┘
```


偵測到測速照相時，「道路速限」卡片會轉為紅底閃爍的警示，標題改為
「測速照相」、數值改為該照相的速限；警示解除或資料逾時後自動恢復。

左欄色條對應：Hev電池=青綠、水溫=天藍、時鐘=橘、
胎壓=琥珀、里程/油箱=天藍、道路速限=紅。

**時速錶**：0-180 km/h，270° 範圍。刻度每 10 一格，數字每 20 一個，
並依速域上色 —— 0-70 白、80-110 琥珀、120-180 紅（以三段 scale 拼接，
角度按 270°/180 = 1.5° 每單位換算，彼此不重疊也不留空）。
藍色進度弧疊在灰色軌道上，中央為時速大字，下方藍色轉速 + `R`。

**右下角狀態區**只保留 IP 與大燈狀態，靠右對齊。連線狀態改由
「資料逾時整片淡出」表達，螢幕亮度僅在序列日誌以 `[BRT]` 回報，
兩者都不再佔用畫面，把右半部完整讓給時速環。

顏色提示：

- **時速**：超出速限 5 km/h 以上轉紅
- **轉速**：≥ 5500 rpm 轉紅
- **水溫**：≥ 105 °C 轉紅
- **油量**：≤ 15% 轉紅
- **胎壓**：< 28 psi 紅色（過低）、> 40 psi 琥珀色（過高）
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

### 3. 編譯 / 上傳

```bash
./build.sh              # 只編譯
./build.sh -u           # 編譯 + 上傳（自動偵測序列埠）
./build.sh -u -p /dev/cu.usbserial-1130
./build.sh -u -m        # 上傳後開啟序列監視器 (115200)
./build.sh -c           # 先清除 build/ 再編譯
```

使用的 FQBN（對應原廠 Demo 的 Arduino IDE 設定）：

```
esp32:esp32:esp32p4:FlashSize=16M,PartitionScheme=app3M_fat9M_16MB,\
PSRAM=enabled,FlashMode=qio,FlashFreq=80,UploadSpeed=921600,\
CDCOnBoot=cdc,USBMode=hwcdc
```

> `CDCOnBoot=cdc,USBMode=hwcdc` 與原廠 Demo 不同（原廠為 Disabled +
> USB-OTG）：這組設定讓 `Serial` 走燒錄用的那條 USB 線（USB-Serial-JTAG），
> `./build.sh -u -m` 就能直接讀開機日誌，不必另外接 USB-UART 轉板到 UART0。
> 實測若維持 `USBMode=default`（OTG/TinyUSB），CDC 會掛在另一個 USB 端點上，
> 燒錄埠讀不到任何輸出。

> 若你的板子是 **v3.00 或更新版**的 ESP32-P4 晶片，需在 FQBN 追加
> `,ChipVariant=postv3`。

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

本專案內附三個以 `lv_font_conv` 產生的字型：

| 檔案 | 內容 | 用途 |
|---|---|---|
| `nx4_font_num_160.c` | Montserrat 160 px，`0-9` `-` | 儀表中央時速大字 |
| `nx4_font_num_80.c` | Montserrat 80 px，`0-9` `.` `:` `%` | 卡片大數值、時鐘、轉速 |
| `nx4_font_tc_22.c` | Noto Sans TC 22 px，ASCII + 所需漢字 | 中文標籤 |

兩份字型皆為 SIL Open Font License 1.1，授權全文見
`OFL-Montserrat.txt` 與 `OFL-NotoSansTC.txt`。

> **產生時務必加 `--no-compress`。** lv_font_conv 預設會壓縮點陣，
> 而本專案 `lv_conf.h` 的 `LV_USE_FONT_COMPRESSED = 0`。載入壓縮字型時
> 字寬與行高都正確（版面看起來有預留位置），但**一個像素都畫不出來**，
> 非常容易誤判成版面或顏色問題。字型檔裡的 `.bitmap_format` 必須是 `0`。

重新產生（需 node）：

```bash
npx lv_font_conv@1.5.2 --no-compress --font Montserrat[wght].ttf \
  --size 112 --bpp 4 --format lvgl --lv-include lvgl.h \
  --range 0x30-0x39 --range 0x2D -o nx4_font_num_112.c

npx lv_font_conv@1.5.2 --no-compress --font NotoSansTC[wght].ttf \
  --size 22 --bpp 4 --format lvgl --lv-include lvgl.h --range 0x20-0x7E \
  --symbols "電池水溫胎壓里程油箱道路速限測照相遠近燈週一二三四五六日月" \\
  -o nx4_font_tc_22.c
```

若要新增中文字，把字加進 `--symbols` 後重新產生即可。

---

## 七、檔案結構

| 檔案 | 說明 |
|---|---|
| `nx4_dashboard.ino` | 主程式：LCD/觸控/LVGL 初始化、WiFi、WebSocket Server |
| `ui_dashboard.h/.c` | 儀表 UI 建立與數值更新（唯一會碰 LVGL 物件的地方） |
| `nx4_font_num_160.c` / `nx4_font_num_80.c` / `nx4_font_tc_22.c` | 專用字型，見「六、字型」 |
| `pins_config.h` | 螢幕解析度與腳位（取自原廠 Demo） |
| `lv_conf.h` | LVGL 設定（原廠 Demo + 開啟大字型） |
| `config.h.example` | WiFi / Port / 靜態 IP / 逾時設定範本 |
| `src/lcd/` | JD9165 MIPI DSI 驅動（原廠 Demo 原樣複製） |
| `src/touch/` | GT911 觸控驅動（原廠 Demo 原樣複製） |
| `build.sh` | arduino-cli 編譯 / 上傳腳本 |

`src/lcd`、`src/touch`、`lv_conf.h`、`pins_config.h` 來自
`esp32_display/硬體規格與範例/1-Demo示例/Demo_Arduino/JC1060P470C_I_W_Y_New_Panel_V2/lvgl_demo_v8`。

---

## 八、疑難排解

| 症狀 | 檢查 |
|---|---|
| 螢幕全黑 | `LCD_RST` 是否為 5；PSRAM 是否設為 `enabled`（沒開會在 `assert(buf)` 當掉） |
| 開機後一直 `WiFi ...` | 看序列日誌的 `[WiFi] 斷線, reason=N`：15=密碼錯誤、201=找不到 AP、202/203=認證或關聯失敗。韌體每 10 秒會自動重送 `begin()`，實測 ESP-Hosted 首次常以 `reason=8` 失敗、第二次才成功，屬正常 |
| 狀態列一直 `NO LINK` | App 端 IP/Port 是否正確、是否已打開「啟用 ESP32 儀表推送」、兩者是否同網段 |
| 數值全部灰掉 | 超過 `DATA_TIMEOUT_MS`（預設 5 秒）沒收到推送，多半是手機端斷線或未在充電狀態 |
| `JSON 解析失敗` | 檢查是否誤把第一通道（`BVB-7980`）的 IP/Port 填成 ESP32 的 |
| 畫面撕裂 | 於 `nx4_dashboard.ino` 將 `disp_drv.full_refresh` 改為 `true` |
| 某段文字完全不顯示但版面有留位置 | 該字型是壓縮格式。檢查字型檔的 `.bitmap_format` 是否為 `0`，不是的話用 `--no-compress` 重新產生 |
| 右下角出現 FPS / CPU 疊圖 | `lv_conf.h` 的 `LV_USE_PERF_MONITOR` 要設為 `0` |
| 亮度不會隨大燈變化 | 序列監視器看有無 `[BRT] 螢幕亮度 -> N%`；沒有代表手機端沒讀到 22BC09（App 日誌搜尋 `Headlights`），可能該車的 IGMP 請求 Header 不是 `ATSH302` |
