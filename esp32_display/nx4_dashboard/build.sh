#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# NX4Board ESP32-P4 儀表顯示器 — arduino-cli 編譯 / 上傳腳本
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

# JC1060P470C：ESP32-P4 / 16MB Flash QIO 80MHz / PSRAM 開啟 / 3MB APP 分割
FQBN="esp32:esp32:esp32p4:FlashSize=16M,PartitionScheme=app3M_fat9M_16MB,PSRAM=enabled,FlashMode=qio,FlashFreq=80,UploadSpeed=921600"

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
  arduino-cli upload \
    --fqbn "$FQBN" \
    --port "$PORT" \
    --input-dir "$BUILD_DIR" \
    "$SKETCH_DIR"

  echo "✅ 上傳完成"

  if [ "$DO_MONITOR" = "1" ]; then
    echo "📟 序列監視器 ($PORT @ 115200)，Ctrl-C 離開"
    arduino-cli monitor --port "$PORT" --config baudrate=115200
  fi
fi
