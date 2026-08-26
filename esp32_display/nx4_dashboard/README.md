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
  "tires": { "fl": 34, "fr": 34, "rl": 33, "rr": 33 },
  "camera": { "active": true, "limit": 90 }
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
| `tires.{fl,fr,rl,rr}` | int | 四輪胎壓 psi，`0` 表示無資料 |
| `camera.active` | bool | 前方是否偵測到測速照相 |
| `camera.limit` | int | 該測速照相的速限 km/h |

缺少的欄位會沿用上一次的值，避免畫面跳動。

---

## 三、畫面配置（1024 x 600）

```
┌────────────────────────────────────────────────────────────────────┐
│ NX4BOARD                          192.168.4.2   LINKED  ●          │ 40px
├──────────────┬──────────────────────────────────┬──────────────────┤
│  ╭────────╮  │                                  │ COOLANT       C  │
│  │   90   │  │              75                  │ 88  ▁▁▁▁▁▁▁▁    │
│  ╰────────╯  │             km/h                 ├──────────────────┤
│   速限標誌   │                                  │ SOC              │
│              │                                  │      ◜ 65% ◝     │
│ ┌──────────┐ │  RPM                      1750   │      ◟     ◞     │
│ │ ⚠ CAMERA │ │  ████████████░░░░░░░░░░░░░░░░░   ├──────────────────┤
│ │    90    │ │                                  │ FUEL          %  │
│ └──────────┘ │                                  │ 50  ▁▁▁▁▁▁▁▁    │
├──────────────┴──────────────────────────────────┴──────────────────┤
│  FL  34  psi │  FR  34  psi │  RL  33  psi │  RR  33  psi          │ 120px
└────────────────────────────────────────────────────────────────────┘
```

顏色提示：

- **時速**：超出速限 5 km/h 以上轉紅
- **轉速條**：≥ 5500 rpm 轉紅
- **水溫**：≥ 105 °C 轉紅
- **SOC**：≤ 20% 轉紅
- **油量**：≤ 15% 轉紅
- **胎壓**：< 28 psi 紅色（過低）、> 40 psi 琥珀色（過高）
- **測速照相**：紅色面板以 500 ms 週期閃爍
- **逾時**（預設 5 秒未收到資料）：所有數值淡出至 40% 不透明度

### 效能設計

`ui_dashboard_create()` 只在開機時建立一次所有 LVGL 物件；
`ui_dashboard_update()` 逐欄位比對前一次的值，**只有變動的欄位才寫入**
Label 文字 / Bar / Arc 數值，因此每次推送僅會 invalidate 極小的區域。
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
PSRAM=enabled,FlashMode=qio,FlashFreq=80,UploadSpeed=921600
```

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
   - 按 **Save**，可用 **Dash Test** 送一筆測試資料驗證
4. 連上後狀態列右側會由 `NO LINK`（灰）變成 `LINKED`（綠）。

---

## 六、更大 / 中文字型

- 時速大字使用本資料夾內附的 `nx4_font_speed_120.c`
  （Montserrat 120 px，只收錄 `0-9`、`-`、空白，約 43 KB，
  授權見 `OFL-Montserrat.txt`）。
  編譯時加上 `-DNX4_NO_BIG_SPEED_FONT` 可退回 LVGL 內建的 Montserrat 48。
- 重新產生其它尺寸：

  ```bash
  npx lv_font_conv@1.5.2 --font Montserrat[wght].ttf --size 140 --bpp 4 \
    --format lvgl --lv-include lvgl.h \
    --range 0x30-0x39 --range 0x2D --range 0x20 -o nx4_font_speed_120.c
  ```

- 目前介面文字刻意採用英文（`COOLANT` / `FUEL` / `CAMERA` …），
  以便直接使用 LVGL 內建字型。若要顯示中文，請以 lv_font_conv 產生
  含所需漢字的字型（原廠 Demo 的 `Wifi_scan/weiruanyahei_14.c` 即為範例），
  再於 `ui_dashboard.c` 中把對應 `make_label()` 的字型換掉。

---

## 七、檔案結構

| 檔案 | 說明 |
|---|---|
| `nx4_dashboard.ino` | 主程式：LCD/觸控/LVGL 初始化、WiFi、WebSocket Server |
| `ui_dashboard.h/.c` | 儀表 UI 建立與數值更新（唯一會碰 LVGL 物件的地方） |
| `nx4_font_speed_120.c` | 時速大字字型（Montserrat 120 px，僅數字） |
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
| 開機後一直 `WiFi ...` | `config.h` 的 SSID/密碼；ESP32-P4 的 WiFi 走 ESP-Hosted，需確認 C6 韌體正常 |
| 狀態列一直 `NO LINK` | App 端 IP/Port 是否正確、是否已打開「啟用 ESP32 儀表推送」、兩者是否同網段 |
| 數值全部灰掉 | 超過 `DATA_TIMEOUT_MS`（預設 5 秒）沒收到推送，多半是手機端斷線或未在充電狀態 |
| `JSON 解析失敗` | 檢查是否誤把第一通道（`BVB-7980`）的 IP/Port 填成 ESP32 的 |
| 畫面撕裂 | 於 `nx4_dashboard.ino` 將 `disp_drv.full_refresh` 改為 `true` |
