#!/usr/bin/env bash
# NX4Board ESP-IDF 版的建置包裝。
#
#   ./build.sh              編譯
#   ./build.sh -u           編譯後燒錄（自動偵測序列埠）
#   ./build.sh -u -p PORT   燒錄至指定序列埠
#   ./build.sh -m           燒錄後開啟序列監視器
#   ./build.sh -c           先清除 build/ 再編譯
#
# 環境變數：
#   NX4_ESPTOOL   指定燒錄用的 esptool（預設找 idf.py 內附的）
#
# 為什麼不直接用 idf.py：
#
# (1) 燒錄工具：IDF 內附的 esptool 4.10.0 在這塊板子上連晶片都認不到
#     （"Invalid head of packet"），與 Arduino 版當初踩到的是同一類問題。
#     已知可用的是 4.12.0。設 NX4_ESPTOOL 指過去，沒設就退回 idf.py flash。
#
# (2) Python 環境架構：
#   這台機器的 IDF cmake 是 x86_64（跑在 Rosetta 下），而 export.sh 預設挑的
#   idf5.5_py3.9_env 是 universal binary。cmake 去 spawn 它時會繼承 x86_64，
#   但那個環境裝的套件輪子是 arm64，於是 pydantic_core 載不起來、configure 直接
#   失敗。改用純 arm64 的 idf5.5_py3.12_env 就沒這個問題（arm64-only 的執行檔
#   即使由 x86_64 的父行程 exec 也會以 arm64 執行）。
set -euo pipefail

SKETCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDF_EXPORT="${NX4_IDF_PATH:-$HOME/esp/esp-idf}/export.sh"
IDF_PY_ENV="${NX4_IDF_PY_ENV:-$HOME/.espressif/python_env/idf5.5_py3.12_env}"

UPLOAD=0; MONITOR=0; CLEAN=0; PORT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) UPLOAD=1; shift ;;
    -m) MONITOR=1; shift ;;
    -c) CLEAN=1; shift ;;
    -p) PORT="$2"; shift 2 ;;
    -h) sed -n '2,10p' "$0"; exit 0 ;;
    *)  echo "未知參數: $1（用 ./build.sh -h）" >&2; exit 1 ;;
  esac
done

# shellcheck disable=SC1090
source "$IDF_EXPORT" >/dev/null 2>&1
export IDF_PYTHON_ENV_PATH="$IDF_PY_ENV"
IDF_PY=("$IDF_PY_ENV/bin/python" "$IDF_PATH/tools/idf.py")

cd "$SKETCH_DIR"
[[ $CLEAN -eq 1 ]] && rm -rf build

if [[ -z "$PORT" && ( $UPLOAD -eq 1 || $MONITOR -eq 1 ) ]]; then
  PORT="$(ls /dev/cu.usbmodem* 2>/dev/null | head -1 || true)"
  [[ -n "$PORT" ]] && echo "序列埠: $PORT"
fi

echo "🔨 編譯"
"${IDF_PY[@]}" build

if [[ $UPLOAD -eq 1 ]]; then
  echo "⬆️  燒錄至 $PORT"
  if [[ -n "${NX4_ESPTOOL:-}" ]]; then
    # flash_args 是 idf.py 產生的，位址與檔名都在裡面，不必自己列
    ( cd build && "$NX4_ESPTOOL" --chip esp32p4 -p "$PORT" -b 921600 \
        --before default_reset --after hard_reset write_flash @flash_args )
  else
    "${IDF_PY[@]}" -p "$PORT" flash
  fi
fi
if [[ $MONITOR -eq 1 ]]; then
  "${IDF_PY[@]}" -p "$PORT" monitor
fi
echo "✅ 完成"
