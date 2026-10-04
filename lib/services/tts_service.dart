import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:volume_controller/volume_controller.dart';
import 'settings_service.dart';

class TtsService {
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal();

  final FlutterTts _flutterTts = FlutterTts();
  // volume_controller 使用 listener 回呼，不需要 StreamSubscription

  // 防重複報讀：針對同一 ID (或座標 Hash) 延長至 10 分鐘不重複，確保單次通過只會警示一次
  final Map<String, DateTime> _lastAlerts = {};
  final Map<String, DateTime> _speedingAlerts = {};
  final Map<String, DateTime> _passedAlerts = {};
  static const Duration _duplicateCooldown = Duration(minutes: 10);

  // 音量回饋 Debounce
  DateTime? _lastVolumeFeedbackTime;
  static const Duration _volumeFeedbackDebounce = Duration(milliseconds: 1500);

  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;

    await _flutterTts.setLanguage("zh-TW");
    await _flutterTts.setSpeechRate(0.55);
    await _flutterTts.setPitch(1.0);

    // 暫時移除複雜的 AudioContext 設定，避免 API 不相容導致編譯失敗
    // 待編譯成功後再評估特定版本的 Ducking 實作方式

    // 從系統音量讀取初始值並套用
    final systemVolume = await SettingsService().getSystemVolume();
    VolumeController().setVolume(systemVolume);

    // 監聽硬體音量鍵變化
    VolumeController().listener((volume) {
      _handleVolumeChange(volume);
    });

    _isInitialized = true;
    debugPrint('✅ TtsService Initialized');
  }

  /// 處理音量變動回饋 (Debounce 1.5s)
  void _handleVolumeChange(double volume) {
    final now = DateTime.now();
    if (_lastVolumeFeedbackTime == null ||
        now.difference(_lastVolumeFeedbackTime!) > _volumeFeedbackDebounce) {
      _lastVolumeFeedbackTime = now;
      speak("語音音量已更新");
    }
  }

  /// 超速接近照相點警示（500m 內且超速）
  /// 國語：速限 xx，台語：開慢一點
  void speakSpeedingAlert(Map<String, dynamic> camInfo) {
    final String id = "${camInfo['lat']}_${camInfo['lon']}_speeding";
    final int? limit = camInfo['limit'];
    final now = DateTime.now();

    if (_speedingAlerts.containsKey(id) &&
        now.difference(_speedingAlerts[id]!) < _duplicateCooldown) {
      return;
    }
    _speedingAlerts[id] = now;

    final String limitPart = limit != null ? '速限$limit，' : '';
    speak('$limitPart泥再不減速就要噴錢錢摟');
  }

  /// 通過相機點。與提示共用冷卻時間，同一支相機不會重複念。
  /// 回傳這次是否真的有念（冷卻中回傳 false）。
  bool speakCameraPassed(Map<String, dynamic> camInfo) {
    final String id = "${camInfo['lat']}_${camInfo['lon']}";
    final now = DateTime.now();
    if (_passedAlerts.containsKey(id) &&
        now.difference(_passedAlerts[id]!) < _duplicateCooldown) {
      return false;
    }
    _passedAlerts[id] = now;
    speak('通過');
    return true;
  }

  /// 智慧報讀測速點
  void speakCameraAlert(Map<String, dynamic> camInfo, double currentSpeed) {
    final String id = "${camInfo['lat']}_${camInfo['lon']}";

    // ignore: unused_local_variable
    final String address = camInfo['name'] ?? '未知地點';
// 使用座標作為唯一識別
    final int? limit = camInfo['limit'];

    final now = DateTime.now();
    if (_lastAlerts.containsKey(id)) {
      if (now.difference(_lastAlerts[id]!) < _duplicateCooldown) {
        return; // 冷卻中，不報讀
      }
    }

    _lastAlerts[id] = now;

    final bool isZone = camInfo['is_zone'] == true;
    String msg;
    if (camInfo['kind'] == 'overpass') {
      // 天橋偷拍只念這句，不報速限（國道速限駕駛本來就知道）
      msg = "注意天橋偷拍";
    } else if (isZone) {
      msg = "進入區間測速路段";
      if (limit != null) msg += "，速限 $limit";
    } else {
      // 重疊道路沒把握時，相機帶有層級（「高架下」「快車道」…）
      final String? layer = camInfo['layer_label'];
      msg = switch (camInfo['kind']) {
        'redLight' => layer != null ? "$layer闖紅燈照相" : "前有闖紅燈照相",
        'zoneEnd' => "區間測速終點",
        _ => layer != null ? "$layer測速照相" : "前有測速照相",
      };
      if (limit != null) msg += "，速限 $limit";
      final String direct = camInfo['direct'] ?? '';
      if (direct.isNotEmpty) msg += "，$direct";
    }

    speak(msg);
  }

  /// 設定系統音量並播放測試語音
  Future<void> setVolumeAndPreview(double volume) async {
    // 只透過 SettingsService 同步到系統音量，避免重複調用
    await SettingsService().setSystemVolume(volume);
    await Future.delayed(const Duration(milliseconds: 200));
    await speak('音量測試');
  }

  Future<void> speak(String text) async {
    await _flutterTts.speak(text);
  }

  void clearCooldown() {
    _lastAlerts.clear();
    debugPrint('🧹 TtsService Cooldown Cleared');
  }

  Future<void> stop() async {
    await _flutterTts.stop();
  }

  void dispose() {
    VolumeController().removeListener();
    _flutterTts.stop();
  }
}
