# NX4Board LCD-5 儀表（ESP-IDF 版）

Waveshare ESP32-P4-WIFI6-Touch-LCD-5 的車載儀表韌體，ESP-IDF 版本。
與 Arduino 版 [`../nx4_dashboard_lcd5`](../nx4_dashboard_lcd5) 功能相同、
共用同一份 UI、驅動與字型，差別只在平台層。

## 為什麼要有這一版

**ESP32-C6 副處理器的韌體版本。**

ESP32-P4 本身沒有射頻，Wi-Fi/BLE 全部經由板上的 ESP32-C6 走 SDIO，以
ESP-Hosted 協定轉送。主機端與 C6 的韌體版本必須相容。

Arduino core 3.3.7 綁死的是預編好的 `libespressif__esp_hosted.a`，版本
**2.11.6**，換不掉。而本板 C6 的出廠韌體對應的是 **1.4.x**——Waveshare 在
他們自己的 `04_wifistation/main/idf_component.yml` 註明「本倉庫不重建 C6
slave image」，並在 IDF < 6.0 時把 `esp_hosted` 釘在 `1.4.*`。

版本差了一個大版本以上，RPC 協定早就不同。實際症狀：

```
[HOSTED] host=2.11.6  slave=0.0.0  ch=10
E rpc_core: Response not received for [0x15e](Req_GetCoprocessorFwVersion)
```

`slave=0.0.0` 不是真的版本號，是 C6 根本不回應版本查詢。連線看起來正常、
`clients=1` 維持著，但封包大量遺失，畫面會凍結數十秒再自己恢復。
丟包率隨封包變大急遽惡化（16B 5%、500B 25%、1200B 95%），而第二通道的
推送約 470 bytes。完整診斷見 Arduino 版 README 的「ESP-Hosted 版本不符」。

ESP-IDF 可以自己指定 `esp_hosted` 版本，也就是**配合出廠的 C6，而不是反過來
冒險重刷副處理器**。這就是這一版存在的理由。

## 環境需求

**ESP-IDF >= 5.5.3**（實際使用 v5.5.5）。

不能更舊。ESP32-P4 的 rev3 晶片支援是在 5.5.3 才回補進 5.5.x 的，
v5.5.1 以前會在兩個地方卡住：

* `MIPI_DSI_PHY_PLLREF_CLK_SRC_XTAL` 不存在。舊版只有 RC_FAST / PLL_F25M /
  PLL_F20M，而 PLL_F20M 只在 esp32p4 < 3.0 有效。
* bootloader 會標成只支援 chip revision v0.1–v1.99，燒錄時直接被
  esptool 擋下（本板實測是 **v3.2**）。

也不能用 IDF >= 6.0：那會把 `esp_hosted` 拉到 2.12+，回到與 Arduino 版
相同的版本不符問題。

`components/nx4_lcd/include/esp_lcd_hx8394.h` 會自動挑選正確的時脈來源常數，
兩種命名都編得起來。判斷方式刻意用 `#ifdef` 而不是版本號：5.5.3 起
`MIPI_DSI_PHY_CLK_SRC_DEFAULT` 變成相容巨集、**指向 PLL_F20M(LEGACY)**，
沿用舊名等於選到 rev3 上無效的時脈；舊標頭裡它是 enum 常數（`#ifdef` 看不到），
新標頭裡才是巨集，正好用來區分。

## 首次設定

```bash
cp components/nx4_config/include/config.h.example \
   components/nx4_config/include/config.h
```

填入 WiFi 帳密（`config.h` 已被 .gitignore 排除）。螢幕上的設定面板存進 NVS
之後會優先於 config.h，所以實務上填不填都行。

## 建置

```bash
./build.sh              # 編譯
./build.sh -u           # 編譯後燒錄（自動偵測序列埠）
./build.sh -u -p PORT   # 燒錄至指定序列埠
./build.sh -m           # 燒錄後開啟序列監視器
./build.sh -c           # 先清除 build/ 再編譯
```

`build.sh` 包了一個這台機器上必要的 workaround，直接跑 `idf.py` 會失敗：

**Python 環境架構**。IDF 的 cmake 是 x86_64（跑在 Rosetta 下），而
`export.sh` 預設挑的 `idf5.5_py3.9_env` 是 universal binary，被 cmake
spawn 時會繼承 x86_64，但那個環境裝的輪子是 arm64，於是 `pydantic_core`
載不起來、configure 直接失敗。改用純 arm64 的 `idf5.5_py3.12_env` 即可
（arm64-only 的執行檔即使由 x86_64 父行程 exec 也會以 arm64 執行）。

第一次用那個環境要先補裝 IDF 的 Python 相依：

```bash
~/.espressif/python_env/idf5.5_py3.12_env/bin/python -m pip install \
  -r $IDF_PATH/tools/requirements/requirements.core.txt \
  -c ~/.espressif/espidf.constraints.v5.5.txt
```

> 燒錄工具不必特別處理：IDF 5.5.5 要求的正是 esptool **4.12.0**，而那就是
> 這塊板子唯一能用的版本（4.10.0 連晶片都認不到，報 `Invalid head of packet`）。
> `build.sh` 仍留了 `NX4_ESPTOOL` 可以指定外部 esptool，備而不用。

## 專案結構

```
main/
  main.c              app_main、LVGL、顯示與觸控、封包解析、心跳
  nx4_wifi.c/.h       WiFi STA、NVS 憑證與音量、非阻塞掃描
  nx4_ws.c/.h         WebSocket Server（esp_http_server）
  ui_dashboard.c/.h   儀表版面      ← 與 Arduino 版共用
  ui_settings.c/.h    設定面板      ← 與 Arduino 版共用
  nx4_font_*.c        字型          ← 與 Arduino 版共用
  lv_conf.h           LVGL 設定     ← 只改了 tick 來源
components/
  nx4_config/         pins_config.h、config.h（獨立成元件，避免驅動相依 main）
  nx4_lcd/            HX8394 面板驅動 + C 包裝
  nx4_touch/          GT911 觸控 + C 包裝
  nx4_audio/          ES8311 + 預錄語音
```

## 移植時實際要改的東西

驅動層本來就是純 IDF API（`esp_lcd`、`driver/ledc`、`driver/i2s`、
`driver/i2c_master`），UI 與字型是純 LVGL 的 C，所以絕大多數檔案原封不動。
真正動到的只有這些：

| 項目 | Arduino 版 | 這一版 |
|---|---|---|
| 進入點 | `setup()` / `loop()` | `app_main()` 內的無窮迴圈 |
| WiFi | `WiFi.h` | `esp_wifi` + `esp_netif` |
| WebSocket | `WebSocketsServer` | `esp_http_server`（`CONFIG_HTTPD_WS_SUPPORT`）|
| JSON | ArduinoJson | cJSON（IDF 內建）|
| 設定儲存 | `Preferences` | `nvs_flash` |
| 時間 | `millis()` | `esp_timer_get_time() / 1000` |
| 日誌 | `Serial.printf` | `printf`（IDF 預設就走 UART0）|

另外三處零碎但必要的修改：

* `hx8394_lcd.cpp` 拿掉一個沒用到任何東西的 `#include "Arduino.h"`。
* `lv_conf.h` 的 tick 來源由 `millis()` 改成 `esp_timer_get_time()/1000`。
* `ui_dashboard.c` 的兩個補間 callback 把 `int32_t` 明確轉成 `int` 再餵給
  `%d`。Arduino 的工具鏈 `int32_t` 就是 `int`，IDF 的 riscv 工具鏈是
  `long int`，`-Werror=format` 會擋。

C++ 的兩個驅動類別（`hx8394_lcd`、`gt911_touch`）維持原樣不改，另外加一層
`nx4_lcd_c` / `nx4_touch_c` 把它們包成 C 介面給 `main.c` 用。

## 執行緒模型

**所有 LVGL 呼叫都只在 `app_main` 這個任務裡。**

Arduino 版的 `webSocket.loop()` 是在 `loop()` 內同步呼叫的，與 LVGL 同一個
任務，所以不必上鎖。ESP-IDF 的 httpd 有自己的任務，因此 WebSocket handler
**不解析、也不碰 LVGL**，只把最新一筆封包複製進單槽緩衝（`nx4_ws.c`），
由主迴圈取走後才解析與渲染。

單槽「後到覆蓋先到」正好符合原本 dirty flag 的語意：連續多筆推送只需要
渲染最後一筆。

## 分割表

`nvs` 的位置與大小刻意與 Arduino 版的 `default_32MB.csv` 一致
（`0x9000` / `0x5000`），這樣從 Arduino 版換過來時，已經存在 NVS 的
WiFi 憑證與語音音量不會遺失。
