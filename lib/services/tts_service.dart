import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:perfect_volume_control/perfect_volume_control.dart';

class TtsService {
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal();

  final FlutterTts _flutterTts = FlutterTts();
  StreamSubscription<double>? _volumeSubscription;
  
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
    
    // 設定 Ios/Android 的 Audio Context 以支援 Ducking (播放語音時降低音樂)
    await _flutterTts.setAudioContext(
      androidAudioAttributes: const AndroidAudioAttributes(
        contentType: AndroidContentType.speech,
        usage: AndroidUsage.assistanceNavigationGuidance,
        flags: AndroidUint8List.fromList([1]), // FLAG_AUDIBILITY_ENFORCED
      ),
      appleAudioContext: AppleAudioContext(
        category: AppleAudioCategory.playback,
        options: [
          AppleAudioCategoryOption.duckOthers,
          AppleAudioCategoryOption.interruptSpokenAudioAndMixWithOthers,
        ],
      ),
    );

    // 監聽硬體音量鍵
    _volumeSubscription = PerfectVolumeControl.stream.listen((volume) {
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
    final String address = camInfo['name'] ?? '未知地點';
    final int? limit = camInfo['limit'];
    final String id = "${camInfo['lat']}_${camInfo['lon']}"; // 使用座標作為唯一識別

    final now = DateTime.now();
    if (_lastAlerts.containsKey(id)) {
      if (now.difference(_lastAlerts[id]!) < _duplicateCooldown) {
        return; // 冷卻中，不報讀
      }
    }

    _lastAlerts[id] = now;

    String msg = "前方測速照相";
    if (limit != null) {
      msg += "，限速 $limit 公里";
    }

    speak(msg);
  }

  Future<void> speak(String text) async {
    await _flutterTts.speak(text);
  }

  Future<void> stop() async {
    await _flutterTts.stop();
  }

  void dispose() {
    _volumeSubscription?.cancel();
    _flutterTts.stop();
  }
}
