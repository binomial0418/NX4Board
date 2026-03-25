#!/bin/bash

# 設定變數
REMOTE_NAME="duckegg"
FOLDER_ID="1EUkGPhnoaZHCxsdSkEc9JVORcnZzAyXx" 
APK_PATH="/Users/duckegg/code/flutter/NX4Board/build/app/outputs/flutter-apk/app-release.apk"
TARGET_NAME="app-release.apk"
RCLONE_BIN="/Users/duckegg/rclone"
ADB_BIN="/Users/duckegg/Library/Android/sdk/platform-tools/adb"
FLUTTER_BIN="/Users/duckegg/flutter/bin/flutter"

# 參數處理
ONLY_UPLOAD=false
while getopts "u" opt; do
  case $opt in
    u)
      ONLY_UPLOAD=true
      ;;
    *)
      ;;
  esac
done

if [ "$ONLY_UPLOAD" = false ]; then
    echo "📦 開始編譯 Flutter APK..."
fi

if [ -f "$APK_PATH" ] || [ "$ONLY_UPLOAD" = false ]; then
    echo "🚀 準備上傳至 Google Drive (Folder ID: $FOLDER_ID)..."
    
    # 使用參數方式指定 ID，這樣路徑寫 "remote:檔名" 就會直接進到該資料夾
    FULL_CMD="$RCLONE_BIN copyto \"$APK_PATH\" \"$REMOTE_NAME:$TARGET_NAME\" --drive-root-folder-id $FOLDER_ID --ignore-times"
    
    if [ "$ONLY_UPLOAD" = false ]; then
        # 從 pubspec.yaml 取得版本名稱 (例如 2.1.0)
        VERSION_NAME=$(grep 'version: ' pubspec.yaml | sed 's/version: //; s/+.*//' | tr -d '\r')
        # 產生時間戳記作為 Build Number (YYYYMMDDHH, 例如 2024032216)
        # 註：Android 限制 versionCode 上限為 2147483647，YYYYMMDDHH 格式可安全用到 2147 年
        BUILD_NUMBER=$(date +%Y%m%d%H)

        echo "------------------------------------------------"
        echo "編譯版本：$VERSION_NAME+$BUILD_NUMBER"
        echo "flutter build apk --release --target-platform android-arm64 --build-name=$VERSION_NAME --build-number=$BUILD_NUMBER"
        echo "------------------------------------------------"
        $FLUTTER_BIN build apk --release --target-platform android-arm64 --build-name=$VERSION_NAME --build-number=$BUILD_NUMBER
        
        # 編譯後再次確認檔案是否存在
        if [ ! -f "$APK_PATH" ]; then
            echo "❌ 編譯失敗，找不到產出的 APK 檔案。"
            exit 1
        fi

        # 複製到根目錄方便使用者存取與檢查版本
        cp "$APK_PATH" "app-release.apk"
        echo "📂 已同步最新 APK 到專案根目錄: app-release.apk"

        # 🔍 偵測是否有正在運行的模擬器
        echo "🔍 檢查是否有運行中的模擬器..."
        EMULATORS=$($ADB_BIN devices | grep -E "emulator-[0-9]+" | grep "device$" | awk '{print $1}')

        if [ -n "$EMULATORS" ]; then
            for EMULATOR in $EMULATORS; do
                echo "📲 正在安裝 APK 到模擬器: $EMULATOR..."
                $ADB_BIN -s "$EMULATOR" install -r "$APK_PATH"
                if [ $? -eq 0 ]; then
                    echo "✅ 模擬器 $EMULATOR 安裝完成！"
                    # 選項：嘗試啟動 App (com.duckegg.nx4board)
                    $ADB_BIN -s "$EMULATOR" shell monkey -p com.duckegg.nx4board -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
                else
                    echo "❌ 模擬器 $EMULATOR 安裝失敗。"
                fi
            done
        else
            echo "ℹ️ 未偵測到運行中的模擬器，跳過自動安裝步驟。"
        fi
    fi

    echo "------------------------------------------------"
    echo "上傳google drive："
    echo "$FULL_CMD"
    echo "------------------------------------------------"
    
    # 執行
    eval $FULL_CMD
    
    if [ $? -eq 0 ]; then
        echo "✅ 上傳成功！目標 ID 內已更新為: $TARGET_NAME"
    else
        echo "❌ 上傳失敗，請檢查網路或 Folder ID 權限。"
    fi
else
    echo "❌ 模式：僅上傳 (-u)，但找不到 APK 檔案：$APK_PATH"
    exit 1
fi
