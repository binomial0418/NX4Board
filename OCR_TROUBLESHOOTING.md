# NX4Board - OCR 故障排除與優化建議

## 已修復的問題

### 1. **Android v1 Embedding 已過時** ✅
- **症狀**: `Build failed due to use of deleted Android v1 embedding`
- **原因**: 舊的 Android 配置使用已棄用的 embedding
- **修復**: 
  - 生成新的 Kotlin MainActivity: `android/app/src/main/kotlin/com/duckegg/nx4board/MainActivity.kt`
  - 重新生成 Android 配置文件 (build.gradle.kts)
  - 更新 AndroidManifest.xml

### 2. **自定義 Rect 類衝突** ✅
- **症狀**: 與 Flutter ui.Rect 衝突
- **修復**: 使用 `dart:ui` 中的 Rect 並移除自定義實現
- **代碼變更**: `lib/services/ocr_service.dart`

### 3. **相機分辨率過高** ✅
- **症狀**: 可能導致圖像尺寸不匹配
- **修復**: `ResolutionPreset.high` → `ResolutionPreset.medium`

---

## 當前問題

### YUV420 圖像格式處理
```
OCR Error: Image dimension, ByteBuffer size and format don't match
```

**根本原因**: Google ML Kit Text Recognition 對 YUV420 平面數據的驗證過於嚴格

**嘗試過的解決方案**:
1. ❌ 使用 `InputImageFormat.yuv420` + planeData
2. ❌ 使用 `InputImageFormat.nv21` + 手動組合平面
3. ❌ 降低相機分辨率到 medium

---

## 建議的後續步驟

### 方案 1: 升級 google_mlkit_text_recognition
```yaml
# pubspec.yaml
google_mlkit_text_recognition: ^0.15.0  # 最新版本
google_mlkit_commons: ^0.11.0
```

### 方案 2: 使用替代 OCR 庫
- `mlkit` (較舊但可能更穩定)
- `tesseract_ocr` (純 Dart 實現)

### 方案 3: 在 Android 層處理圖像轉換
在 Kotlin 中進行適當的 YUV→RGB 轉換，然後發送給 ML Kit

### 方案 4: 跳過 planeData，只使用 Y 平面
```dart
InputImage.fromBytes(
  bytes: image.planes[0].bytes,  // 僅使用 Y 平面 (灰度)
  metadata: InputImageMetadata(...)
)
```

---

## 文件修改清單

✅ `android/app/src/main/kotlin/com/duckegg/nx4board/MainActivity.kt` - 新增
✅ `lib/services/ocr_service.dart` - 修正圖像轉換邏輯
✅ `lib/screens/camera_screen.dart` - 降低相機分辨率
✅ `android/app/src/main/AndroidManifest.xml` - 添加 tools namespace
✅ `android/build.gradle.kts` - 自動生成
✅ `android/app/build.gradle.kts` - 自動生成

---

## 應用狀態

- ✅ 應用可以正常啟動
- ✅ 相機權限正常
- ✅ 框架構建成功
- ❌ OCR 識別失敗 (圖像格式問題)

應用正在模擬器上運行，但每一幀都報告 OCR 錯誤。
