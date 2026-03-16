# NX4Board - 行車儀表板與測速偵測系統

一個為 OPPO Reno 4Z 開發的 Flutter 應用，結合 GPS 定位和 Google ML Kit OCR 文字辨識，提供即時的省道速限警告功能。

## 功能

- ✅ **GPS 位置監聽**：透過 Geolocator 套件實時監聽手機位置
- ✅ **省道速限資料庫**：整合「省道速限圖資.csv」的所有路牌座標和速限資訊
- ✅ **距離計算**：使用 Haversine 公式計算車輛到路牌的距離
- ✅ **智慧觸發**：
  - 300m 內：準備 AI 資源
  - 150m 內：啟動相機進行 OCR 辨識
  - 超過 300m：關閉相機，節省電量
- ✅ **ML Kit OCR 辨識**：Google ML Kit Text Recognition 辨識路牌上的速限數字
- ✅ **動態 ROI**：根據 CSV 資料的「設置位置」欄位（左側/右側/中央），動態調整掃描區域
- ✅ **多幀校驗**：連續 3 幀辨識相同數字才確認速限，降低誤判率
- ✅ **CSV 交叉驗證**：比對 OCR 結果與預期速限，確保精準度
- ✅ **實時界面**：顯示附近路牌列表、距離、方向標識

## 系統需求

### 開發環境
- Flutter 3.0+
- Dart 3.0+
- Android SDK 29+
- Java 11 或更新版本

### 目標設備
- OPPO Reno 4Z (Android 10+)
- 其他 Android 9.0+ 的設備

## 安裝依賴

```bash
cd /Users/duckegg/code/web/NX4Board
flutter pub get
```

## 項目結構

```
lib/
├── main.dart                      # App 入口點
├── models/
│   └── speed_sign.dart           # 速限標誌資料模型 + Haversine 距離計算
├── services/
│   ├── csv_parser.dart           # CSV 解析及查詢服務
│   ├── location_service.dart     # GPS 位置監聽服務
│   └── ocr_service.dart          # Google ML Kit OCR 服務
├── providers/
│   └── app_provider.dart         # 應用狀態管理 (Provider)
├── screens/
│   ├── home_screen.dart          # 主畫面 - 位置和附近路牌顯示
│   └── camera_screen.dart        # 相機畫面 - OCR 辨識
└── widgets/
    ├── speed_limit_display.dart  # 速限圓牌顯示元件
    └── status_display.dart       # 狀態指示元件

assets/
└── 省道速限圖資.csv              # 省道速限圖資（自動載入）

android/
└── app/src/main/
    └── AndroidManifest.xml       # 權限配置（位置、相機、網路）
```

## CSV 資料說明

**省道速限圖資.csv** 包含以下重要欄位：
- `公路編號`：道路編號（台1、台21...）
- `隸屬縣市`：所在縣市
- `坐標-E-WGS84`：經度 (WGS84 座標系)
- `坐標-N-WGS84`：緯度 (WGS84 座標系)
- `牌面內容`：速限數字（20-120 km/h）
- `設置位置`：標誌位置（左側/右側/中央）
- `牌面方向`：標誌朝向（順向/逆向）
- `隸屬鄉鎮`：鄉鎮名稱

## 核心演算法

### Haversine 公式（距離計算）

```dart
distance = 2 * R * atan2(sqrt(a), sqrt(1-a))

其中：
  a = sin²(Δlat/2) + cos(lat1) × cos(lat2) × sin²(Δlng/2)
  R = 地球半徑 ≈ 6,371,000 公尺
```

### 動態 ROI 區域選擇

```
設置位置 = "左側" → ROI = 畫面左 40%、高 50%
設置位置 = "右側" → ROI = 畫面右 40%、高 50%
設置位置 = "中央" → ROI = 畫面中央 60%、高 30%
未知/無設置位置 → 全畫面掃描 (Fallback)
```

### 多幀校驗邏輯

```
第 1 幀：OCR 結果 == 預期速限 → Frame count = 1
第 2 幀：OCR 結果 == 預期速限 → Frame count = 2
第 3 幀：OCR 結果 == 預期速限 → Frame count = 3 → 確認！
若任意幀不符 → 重置計數器
```

## 使用流程

### 1. 首次執行
```bash
flutter run
```

### 2. 授予權限
- 位置（精確位置 + 背景位置）
- 相機

### 3. 應用運作
1. **主畫面**：顯示附近的速限標誌列表（500m 內）
2. **靠近路牌**（距離 ≤ 150m）：
   - 自動啟動相機
   - 開始 ML Kit OCR 掃描
   - 動態調整 ROI 區域
3. **OCR 確認**（連續 3 幀）：
   - 辨識結果與 CSV 預期值吻合
   - 更新 UI 顯示確認的速限
4. **遠離路牌**（距離 > 300m）：
   - 關閉相機，節省電量
   - 重置偵測狀態

### 4. 測試相機功能
在主畫面點擊「測試相機」按鈕進入相機畫面，可以：
- 實時查看相機預覽
- 查看動態 ROI 區域（綠色框）
- 監控 OCR 掃描進度和偵測結果

## APK 打包步驟

### 預備工作

1. **建立簽名金鑰**（如果還沒有）
```bash
keytool -genkey -v -keystore ~/.android/speed_limit_app.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias speed_limit_app
```

2. **設定簽名配置** - 編輯 `android/app/build.gradle`
```gradle
android {
    ...
    signingConfigs {
        release {
            keyStore file("/Users/duckegg/.android/speed_limit_app.jks")
            keyStorePassword "your_keystore_password"
            keyAlias "speed_limit_app"
            keyPassword "your_key_password"
        }
    }

    buildTypes {
        release {
            signingConfig signingConfigs.release
        }
    }
}
```

### 編譯 APK（針對 arm64-v8a）

```bash
# 清理舊編譯產物
flutter clean

# 下載依賴
flutter pub get

# 編譯 release APK（arm64-v8a）
flutter build apk --release --target-platform android-arm64

# 或同時編譯多個架構
flutter build apk --release --split-per-abi
```

編譯完成後，APK 位置：
```
build/app/outputs/flutter-apk/app-release.apk
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk（單架構）
```

### 安裝到設備

```bash
# 使用 adb 安裝
adb install -r build/app/outputs/flutter-apk/app-release.apk

# 或通過 Flutter 直接部署
flutter install --release
```

## 效能最佳化（針對 Reno 4Z）

1. **天璣 800 APU 加速**：
   - 目前使用 ML Kit 預設配置（CPU 推論）
   - 若要啟用 NNAPI：需在 `ocr_service.dart` 中配置

2. **電量管理**：
   - GPS 採樣頻率：距離變化 ≥ 10m 或 30 秒更新一次
   - 相機只在 150m 內啟動
   - 300m 外自動關閉相機

3. **記憶體最佳化**：
   - CSV 資料一次性載入記憶體（約 500KB）
   - Haversine 計算在 Dart 層完成（無需外部庫）
   - 僅保存附近 500m 的路牌引用

## 故障排除

### 相機無法啟動
- 檢查權限是否已授予
- 確認 Android 版本 ≥ 9.0
- 查看 logcat：`flutter logs`

### GPS 無法定位
- 檢查位置權限（精確位置 + 背景位置）
- 確保在戶外或信號良好區域
- 重啟應用並重新授權

### OCR 辨識不準確
- 確保路牌在相機視範圍內
- 相機對焦清晰
- 確認路牌數字大小適中（不要過小）
- 查看 logcat 中的 OCR 偵測結果：`flutter logs | grep OCR`

### 編譯錯誤

**Error: uses-permission without corresponding uses-feature**
→ 檢查 `android/app/src/main/AndroidManifest.xml`

**Error: com.google.mlkit not found**
→ 執行 `flutter pub get` 並清理 `flutter clean`

## 授權

本專案為學習和非商業用途開發。

## 版本

- Version 1.0.0
- Flutter 3.0+
- Google ML Kit Text Recognition 0.8.0+

---

**開發時間**：2026/3/6  
**目標設備**：OPPO Reno 4Z (天璣 800)  
**主要開發語言**：Dart (Flutter)
