import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:volume_controller/volume_controller.dart';
import 'dart:typed_data';

class TtsService {
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal();

  final FlutterTts _flutterTts = FlutterTts();
  // volume_controller 使用 listener 回呼，不需要 StreamSubscription
  
  // 防重複報讀：針對同一 ID (或座標 Hash) 在 45 秒內不重複
  final Map<String, DateTime> _lastAlerts = {};
  static const Duration _duplicateCooldown = Duration(seconds: 45);

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

    // 監聽硬體音量鍵
    VolumeController().listener((volume) {
      _handleVolumeChange(volume);
    });

    _isInitialized = true;
    print('✅ TtsService Initialized');
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

    String msg = "前有測速照相";
    if (limit != null) {
      msg += "，速限 $limit";
    }
    final String direct = camInfo['direct'] ?? '';
    if (direct.isNotEmpty) {
      msg += "，$direct";
    }

    speak(msg);
  }

  Future<void> speak(String text) async {
    await _flutterTts.speak(text);
  }

  void clearCooldown() {
    _lastAlerts.clear();
    print('🧹 TtsService Cooldown Cleared');
  }

  Future<void> stop() async {
    await _flutterTts.stop();
  }

  void dispose() {
    VolumeController().removeListener();
    _flutterTts.stop();
  }
}
