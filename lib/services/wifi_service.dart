import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WifiService {
  static const _channel = MethodChannel('wifi');
  static const _ssidPrefix = 'nx4_obd_';

  /// 檢查目前是否連線到 [_ssidPrefix] 開頭的 AP。
  /// 若回傳 SSID 為 `<unknown ssid>` 視同未連線（通常是定位權限未開）。
  static Future<bool> isConnected() async {
    try {
      final raw = await _channel.invokeMethod<String>('getSSID');
      final current = raw?.replaceAll('"', '').trim() ?? '';
      if (current == '<unknown ssid>' || current.isEmpty) return false;
      return current.startsWith(_ssidPrefix);
    } catch (e) {
      debugPrint('[WiFi] isConnected error: $e');
      return false;
    }
  }

  /// 開啟系統 WiFi 設定頁（供手動連線備案）。
  static Future<void> openWifiSettings() async {
    try {
      await _channel.invokeMethod('openSettings');
    } catch (e) {
      debugPrint('[WiFi] openWifiSettings error: $e');
    }
  }
}
