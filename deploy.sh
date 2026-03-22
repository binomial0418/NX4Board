#!/bin/bash

# 設定變數
REMOTE_NAME="duckegg"
FOLDER_ID="1EUkGPhnoaZHCxsdSkEc9JVORcnZzAyXx" 
APK_PATH="/Users/duckegg/code/flutter/NX4Board/build/app/outputs/flutter-apk/app-release.apk"
TARGET_NAME="app-release.apk"
RCLONE_BIN="/Users/duckegg/rclone"

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
        echo "------------------------------------------------"
        echo "編譯："
        echo "flutter build apk --release --target-platform android-arm64"
        echo "------------------------------------------------"
        flutter build apk --release --target-platform android-arm64
        
        # 編譯後再次確認檔案是否存在
        if [ ! -f "$APK_PATH" ]; then
            echo "❌ 編譯失敗，找不到產出的 APK 檔案。"
            exit 1
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
