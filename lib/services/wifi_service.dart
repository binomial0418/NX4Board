import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class WifiService {
  static const _channel = MethodChannel('wifi');
  static const _targetSsid = 'nx4_obd_relay';

  /// 檢查目前是否連線到 [_targetSsid]。
  /// 若回傳 SSID 為 `<unknown ssid>` 視同未連線（通常是定位權限未開）。
  static Future<bool> isConnected() async {
    try {
      final raw = await _channel.invokeMethod<String>('getSSID');
      final current = raw?.replaceAll('"', '').trim() ?? '';
      if (current == '<unknown ssid>' || current.isEmpty) return false;
      return current == _targetSsid;
    } catch (e) {
      debugPrint('[WiFi] isConnected error: $e');
      return false;
    }
  }

  /// 靜默確保連線到 [_targetSsid]。
  /// - 若已連線 → 直接回傳 true
  /// - 若未連線 → 呼叫原生層靜默切換已儲存的設定，無系統彈窗
  /// - 切換失敗 → 回傳 false，不中斷 App
  static Future<bool> ensureConnected() async {
    try {
      if (await isConnected()) {
        debugPrint('[WiFi] 已連線至 $_targetSsid，無需切換');
        return true;
      }
      debugPrint('[WiFi] 嘗試靜默切換至 $_targetSsid...');
      final ok = await _channel.invokeMethod<bool>('connectSaved') ?? false;
      debugPrint('[WiFi] 靜默切換結果: $ok');
      return ok;
    } catch (e) {
      debugPrint('[WiFi] ensureConnected error: $e');
      return false;
    }
  }

  /// 強制連線 (Android 10+)。
  /// 先確認定位權限，再透過 WifiNetworkSpecifier 方式請求連線。
  /// 回傳 true 表示連線成功。
  static Future<bool> forceConnect() async {
    try {
      // 確認定位權限（取得 SSID 與 WifiNetworkSpecifier 均需要）
      final locationGranted = await Permission.location.isGranted;
      if (!locationGranted) {
        final result = await Permission.location.request();
        if (!result.isGranted) {
          debugPrint('[WiFi] 定位權限未授予，無法強制連線');
          return false;
        }
      }

      debugPrint('[WiFi] 強制連線至 $_targetSsid...');
      final ok =
          await _channel.invokeMethod<bool>('connectSpecifier') ?? false;
      debugPrint('[WiFi] 強制連線結果: $ok');
      return ok;
    } catch (e) {
      debugPrint('[WiFi] forceConnect error: $e');
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
