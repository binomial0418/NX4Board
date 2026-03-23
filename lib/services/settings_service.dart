import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  SharedPreferences? _prefs;

  // ── Platform Channels ───────────────────────────────────────────────────
  static const platform = MethodChannel('com.duckegg.nx4board/volume');
  static const eventChannel = EventChannel('com.duckegg.nx4board/volumeEvents');

  String get wsIp => _prefs?.getString('ws_ip') ?? '192.168.4.1';
  String get wsPort => _prefs?.getString('ws_port') ?? '81';
  String get obdMac => _prefs?.getString('obd_mac') ?? '';
  bool get enableOcr => _prefs?.getBool('enable_ocr') ?? true;
  double get ttsVolume => _prefs?.getDouble('tts_volume') ?? 1.0;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  Future<void> setWsIp(String ip) async {
    await _prefs?.setString('ws_ip', ip);
  }

  Future<void> setWsPort(String port) async {
    await _prefs?.setString('ws_port', port);
  }

  Future<void> setObdMac(String mac) async {
    await _prefs?.setString('obd_mac', mac);
  }

  Future<void> setEnableOcr(bool value) async {
    await _prefs?.setBool('enable_ocr', value);
  }

  Future<void> setTtsVolume(double volume) async {
    await _prefs?.setDouble('tts_volume', volume);
  }

  // ── System Volume Methods ───────────────────────────────────────────────

  /// 取得目前系統媒體音量 (0.0 ~ 1.0)
  Future<double> getSystemVolume() async {
    try {
      final result = await platform.invokeMethod<double>('getVolume');
      return result ?? 0.5;
    } catch (e) {
      print('❌ getSystemVolume error: $e');
      return 0.5;
    }
  }

  /// 設定系統媒體音量 (0.0 ~ 1.0)
  Future<void> setSystemVolume(double volume) async {
    try {
      final normalizedVolume = volume.clamp(0.0, 1.0);
      await platform.invokeMethod('setVolume', {'volume': normalizedVolume});
    } catch (e) {
      print('❌ setSystemVolume error: $e');
    }
  }

  /// 監聽系統音量變化 (EventChannel)
  /// 當硬體音量鍵或其他來源改變系統音量時，會發出新的音量值 (0.0 ~ 1.0)
  Stream<double> get volumeChangeStream {
    return eventChannel
        .receiveBroadcastStream()
        .map((dynamic event) => (event as num?)?.toDouble() ?? 0.5);
  }
}
