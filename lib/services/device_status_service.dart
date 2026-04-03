import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 手機散熱狀態等級
/// - normal : 電池溫度 < 48°C 且 Android 熱狀態 < MODERATE
/// - warm   : 電池溫度 48–50°C 或 Android 熱狀態 = MODERATE
/// - hot    : 電池溫度 ≥ 50°C 或 Android 熱狀態 ≥ SEVERE
enum ThermalMode { normal, warm, hot }

/// 管理手機本身感測器資訊（電池溫度、散熱狀態等）
class DeviceStatusService {
  DeviceStatusService._();
  static final DeviceStatusService _instance = DeviceStatusService._();
  factory DeviceStatusService() => _instance;

  static const _channel = MethodChannel('com.duckegg.nx4board/device_info');

  double? _batteryTemperature;
  // Android PowerManager thermal status:
  // 0=NONE, 1=LIGHT, 2=MODERATE, 3=SEVERE, 4=CRITICAL, 5=EMERGENCY, 6=SHUTDOWN
  int _thermalStatus = 0;
  Timer? _pollTimer;
  bool _initialized = false;

  /// 電池溫度（°C），由 Android BatteryManager.EXTRA_TEMPERATURE 取得
  double? get batteryTemperature => _batteryTemperature;

  /// Android PowerManager 熱狀態原始值（0–6）
  int get thermalStatus => _thermalStatus;

  /// 綜合散熱等級：Android 熱 API 優先，電池溫度備援
  ThermalMode get thermalMode {
    if (_thermalStatus >= 3) return ThermalMode.hot;
    if (_thermalStatus >= 2) return ThermalMode.warm;
    final temp = _batteryTemperature;
    if (temp == null) return ThermalMode.normal;
    if (temp >= 50.0) return ThermalMode.hot;
    if (temp >= 48.0) return ThermalMode.warm;
    return ThermalMode.normal;
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _fetch();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _fetch());
  }

  Future<void> _fetch() async {
    if (!Platform.isAndroid) return;
    try {
      final double? temp =
          await _channel.invokeMethod<double>('getBatteryTemperature');
      if (temp != null) _batteryTemperature = temp;
    } catch (e) {
      debugPrint('[DeviceStatus] 無法取得電池溫度: $e');
    }
    try {
      final int? status =
          await _channel.invokeMethod<int>('getThermalStatus');
      if (status != null) _thermalStatus = status;
    } catch (e) {
      debugPrint('[DeviceStatus] 無法取得 Thermal Status: $e');
    }
    debugPrint(
        '[DeviceStatus] 電池溫度: $_batteryTemperature°C, '
        'ThermalStatus: $_thermalStatus → ${thermalMode.name}');
  }

  void dispose() {
    _pollTimer?.cancel();
    _initialized = false;
  }
}
