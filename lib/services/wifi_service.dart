import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WifiService {
  static const _channel = MethodChannel('wifi');
  static const _targetSsid = 'nx4_obd_relay';

  /// 確保手機目前連線到 [_targetSsid]。
  /// - 若已連線 → 直接回傳 true
  /// - 若未連線 → 呼叫原生層靜默切換已儲存的設定，無系統彈窗
  /// - 切換失敗（例如尚未儲存或 Android 限制）→ 回傳 false，不中斷 App
  /// 檢查目前是否連線到 [_targetSsid]
  static Future<bool> isConnected() async {
    try {
      final raw = await _channel.invokeMethod<String>('getSSID');
      final current = raw?.replaceAll('"', '') ?? '';
      return current == _targetSsid;
    } catch (e) {
      debugPrint('[WiFi] isConnected error: $e');
      return false;
    }
  }

  /// 確保手機目前連線到 [_targetSsid]。
  /// - 若已連線 → 直接回傳 true
  /// - 若未連線 → 呼叫原生層靜默切換已儲存的設定，無系統彈窗
  /// - 切換失敗（例如尚未儲存或 Android 限制）→ 回傳 false，不中斷 App
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
}
