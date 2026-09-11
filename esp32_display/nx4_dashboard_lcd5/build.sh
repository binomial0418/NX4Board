#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# NX4Board ESP32-P4 儀表顯示器（Waveshare LCD-5 版）— arduino-cli 編譯 / 上傳
#
#   ./build.sh            編譯
#   ./build.sh -u         編譯後上傳（自動偵測序列埠）
#   ./build.sh -u -p PORT 編譯後上傳至指定序列埠
#   ./build.sh -m         上傳後開啟序列監視器 (115200)
#   ./build.sh -c         先清除 build/ 再編譯
#
# 前置需求見 README.md（arduino-cli core / library 安裝）。
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

SKETCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SKETCH_DIR/build"

# Waveshare ESP32-P4-WIFI6-Touch-LCD-5：
#   32MB Flash QIO 80MHz / 32MB PSRAM 開啟 / 13MB APP 分割
# CDCOnBoot=default：Serial 走 UART0。本板的燒錄埠（標示 UART 的 Type-C）
#   是 WCH CH343 USB-UART 橋接器接到 UART0，同一條線就能燒錄與讀日誌。
#   這與舊板 JC1060P470C 不同——那塊是走 USB-Serial-JTAG，要設成
#   CDCOnBoot=cdc,USBMode=hwcdc。在本板設 hwcdc 會讓 Serial 綁到
#   USB-Serial-JTAG，從 CH343 那條線一個字都讀不到。
# ChipVariant=postv3：原廠出貨為 rev3.x 晶片。若你手上是 rev1.x（含 rev1.3），
#   改成 ChipVariant=prev3，兩個 profile 的 PSRAM 時脈不同，不能混用。
FQBN="esp32:esp32:esp32p4:FlashSize=32M,PartitionScheme=app13M_data7M_32MB,PSRAM=enabled,FlashMode=qio,FlashFreq=80,UploadSpeed=921600,CDCOnBoot=default,USBMode=default,UploadMode=default,ChipVariant=postv3"

# 明確指定 lv_conf.h 路徑，避免 LVGL 找到其它專案的設定檔
LV_FLAGS="-DLV_CONF_PATH=${SKETCH_DIR}/lv_conf.h"

DO_UPLOAD=0
DO_MONITOR=0
DO_CLEAN=0
PORT=""

while getopts "ump:ch" opt; do
  case "$opt" in
    u) DO_UPLOAD=1 ;;
    m) DO_MONITOR=1 ;;
    p) PORT="$OPTARG" ;;
    c) DO_CLEAN=1 ;;
    h)
      sed -n '2,12p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "未知參數，請用 ./build.sh -h" >&2
      exit 1
      ;;
  esac
done

if [ ! -f "$SKETCH_DIR/config.h" ]; then
  echo "❌ 找不到 config.h"
  echo "   請先執行: cp config.h.example config.h  並填入 WiFi SSID / 密碼"
  exit 1
fi

if [ "$DO_CLEAN" = "1" ]; then
  echo "🧹 清除 $BUILD_DIR"
  rm -rf "$BUILD_DIR"
fi

echo "🔨 編譯 $FQBN"
arduino-cli compile \
  --fqbn "$FQBN" \
  --build-path "$BUILD_DIR" \
  --build-property "compiler.c.extra_flags=$LV_FLAGS" \
  --build-property "compiler.cpp.extra_flags=$LV_FLAGS" \
  "$SKETCH_DIR"

echo "✅ 編譯完成"

if [ "$DO_UPLOAD" = "1" ]; then
  if [ -z "$PORT" ]; then
    # macOS 上 ESP32-P4 一般會列舉為 /dev/cu.usbserial-* 或 /dev/cu.usbmodem*
    PORT="$(arduino-cli board list 2>/dev/null | awk '/(usbserial|usbmodem|ttyUSB|ttyACM)/ {print $1; exit}')"
  fi

  if [ -z "$PORT" ]; then
    echo "❌ 找不到序列埠，請用 -p /dev/cu.xxxx 指定" >&2
    exit 1
  fi

  echo "⬆️  上傳至 $PORT"

  # ── esptool 版本的坑 ──────────────────────────────────────────────────
  # Arduino core 3.3.7 內建的 esptool 5.1.0 燒不動這塊板（ESP32-P4 rev v3.2）：
  # stub flasher 上傳並啟動後，第一個 flash 指令就 "The chip stopped responding"；
  # 加 --no-stub 可以讀 flash ID，但一寫入就無聲中斷。實測 esptool 4.12.0 正常。
  # （4.8.1 反而連不上，v5 的重置時序才吃得住這塊板，所以要 4.12.0 這個版本。）
  #
  #   python3 -m venv /tmp/esptool-venv
  #   /tmp/esptool-venv/bin/pip install esptool==4.12.0
  #   NX4_ESPTOOL=/tmp/esptool-venv/bin/esptool.py ./build.sh -u
  #
  # 設了 NX4_ESPTOOL 就走它，否則用 arduino-cli（core 內建的 esptool）。
  if [ -n "${NX4_ESPTOOL:-}" ]; then
    BOOT_APP0="$(dirname "$(command -v arduino-cli)")/../.."
    BOOT_APP0="$(find "$HOME/Library/Arduino15/packages/esp32/hardware/esp32" \
      -name boot_app0.bin -maxdepth 4 2>/dev/null | head -1)"
    echo "   使用 $NX4_ESPTOOL"
    "$NX4_ESPTOOL" --chip esp32p4 --port "$PORT" --baud 460800 \
      --before default_reset --after hard_reset --connect-attempts 8 \
      write_flash -z --flash_mode dio --flash_freq 80m --flash_size 32MB \
      0x2000 "$BUILD_DIR/nx4_dashboard_lcd5.ino.bootloader.bin" \
      0x8000 "$BUILD_DIR/nx4_dashboard_lcd5.ino.partitions.bin" \
      0xe000 "$BOOT_APP0" \
      0x10000 "$BUILD_DIR/nx4_dashboard_lcd5.ino.bin"
  else
    arduino-cli upload \
      --fqbn "$FQBN" \
      --port "$PORT" \
      --input-dir "$BUILD_DIR" \
      "$SKETCH_DIR"
  fi

  echo "✅ 上傳完成"

  if [ "$DO_MONITOR" = "1" ]; then
    echo "📟 序列監視器 ($PORT @ 115200)，Ctrl-C 離開"
    arduino-cli monitor --port "$PORT" --config baudrate=115200
  fi
fi
