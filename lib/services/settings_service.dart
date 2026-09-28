import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
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

  /// 前方路況（TDX）。需要 assets/private/tdx.json 憑證才會實際運作
  bool get trafficEnabled => _prefs?.getBool('traffic_enabled') ?? true;

  /// 國道與快速公路前方壅塞時語音提醒
  bool get trafficVoice => _prefs?.getBool('traffic_voice') ?? true;

  // ── ESP32 儀表顯示器 (第二通道 WebSocket) ──────────────────────────────
  /// ESP32-P4 顯示器的 WebSocket Server IP
  String get esp32Ip => _prefs?.getString('esp32_ip') ?? '192.168.4.2';

  /// ESP32-P4 顯示器的 WebSocket Server Port
  String get esp32Port => _prefs?.getString('esp32_port') ?? '8080';

  /// 是否啟用 ESP32 儀表即時推送（第二通道）
  bool get esp32Enabled => _prefs?.getBool('esp32_enabled') ?? false;

  /// 第二通道推送最小間隔（毫秒），避免高頻更新塞爆 ESP32
  int get esp32PushIntervalMs => _prefs?.getInt('esp32_push_interval_ms') ?? 200;

  // ── ESP32 螢幕亮度（依大燈狀態切換，單位 %）────────────────────────────
  /// 大燈關閉（日間）亮度
  int get esp32BrightnessDay => _prefs?.getInt('esp32_brightness_day') ?? 100;

  /// 近燈（大燈）開啟時亮度
  int get esp32BrightnessLowBeam =>
      _prefs?.getInt('esp32_brightness_low') ?? 40;

  /// 遠燈開啟時亮度
  int get esp32BrightnessHighBeam =>
      _prefs?.getInt('esp32_brightness_high') ?? 25;

  /// 設定頁的模擬推送是否進行中。
  ///
  /// 純執行期旗標（不寫入 SharedPreferences）。開啟時 dashboard_screen
  /// 會暫停自己的第二通道推送，否則兩邊會互相覆蓋、畫面跳動。
  bool esp32SimulationActive = false;

  /// 依目前大燈狀態換算出應套用的亮度百分比
  int esp32BrightnessFor({required bool lowBeam, required bool highBeam}) {
    if (highBeam) return esp32BrightnessHighBeam;
    if (lowBeam) return esp32BrightnessLowBeam;
    return esp32BrightnessDay;
  }
  /// MAP 與大氣壓兩顆感測器之間的零點差（kPa）。
  ///
  /// 實測熄火靜止時 MAP 讀 99、大氣壓讀 101，差 2 kPa，算出來的增壓
  /// 就永遠偏 -0.02 Bar。存起來是為了重新連線後立刻就有正確的零點，
  /// 不用等引擎再停一次才重新學。
  double get mapZeroOffsetKpa =>
      _prefs?.getDouble('map_zero_offset_kpa') ?? 0.0;

  /// DID 掃描找到的位址清單，格式 'HEADER|CMD'。
  /// 掃一次要四分鐘，存起來重開 App 就不用重掃。
  List<String> get discoveredDids =>
      _prefs?.getStringList('discovered_dids') ?? const [];

  /// 檔位探測是否開啟。開著的話每次連上 OBD 都會自動接續探測，
  /// 中途斷線重連不用再手動按一次（實車比對常常要跑好幾趟）。
  bool get gearProbeEnabled => _prefs?.getBool('gear_probe_enabled') ?? false;

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

  Future<void> setEsp32Ip(String ip) async {
    await _prefs?.setString('esp32_ip', ip);
  }

  Future<void> setEsp32Port(String port) async {
    await _prefs?.setString('esp32_port', port);
  }

  Future<void> setEsp32Enabled(bool value) async {
    await _prefs?.setBool('esp32_enabled', value);
  }

  Future<void> setEsp32PushIntervalMs(int ms) async {
    await _prefs?.setInt('esp32_push_interval_ms', ms);
  }

  Future<void> setEsp32BrightnessDay(int percent) async {
    await _prefs?.setInt('esp32_brightness_day', percent.clamp(0, 100));
  }

  Future<void> setEsp32BrightnessLowBeam(int percent) async {
    await _prefs?.setInt('esp32_brightness_low', percent.clamp(0, 100));
  }

  Future<void> setEsp32BrightnessHighBeam(int percent) async {
    await _prefs?.setInt('esp32_brightness_high', percent.clamp(0, 100));
  }

  Future<void> setMapZeroOffsetKpa(double kpa) async {
    await _prefs?.setDouble('map_zero_offset_kpa', kpa);
  }

  Future<void> setDiscoveredDids(List<String> dids) async {
    await _prefs?.setStringList('discovered_dids', dids);
  }

  Future<void> setGearProbeEnabled(bool value) async {
    await _prefs?.setBool('gear_probe_enabled', value);
  }

  Future<void> setTrafficEnabled(bool value) async {
    await _prefs?.setBool('traffic_enabled', value);
  }

  Future<void> setTrafficVoice(bool value) async {
    await _prefs?.setBool('traffic_voice', value);
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
      debugPrint('❌ getSystemVolume error: $e');
      return 0.5;
    }
  }

  /// 設定系統媒體音量 (0.0 ~ 1.0)
  Future<void> setSystemVolume(double volume) async {
    try {
      final normalizedVolume = volume.clamp(0.0, 1.0);
      await platform.invokeMethod('setVolume', {'volume': normalizedVolume});
    } catch (e) {
      debugPrint('❌ setSystemVolume error: $e');
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
