import 'dart:async';
import 'package:battery_info/battery_info_plugin.dart';
import 'package:flutter/foundation.dart';

/// 管理手機本身感測器資訊（電池溫度等）
class DeviceStatusService {
  DeviceStatusService._();
  static final DeviceStatusService _instance = DeviceStatusService._();
  factory DeviceStatusService() => _instance;

  int? _batteryTemperature;
  Timer? _pollTimer;
  bool _initialized = false;

  /// 電池溫度（°C），由 Android BatteryManager 回傳，已除以 10
  int? get batteryTemperature => _batteryTemperature;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _fetch();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _fetch());
  }

  Future<void> _fetch() async {
    try {
      final info = await BatteryInfoPlugin().androidBatteryInfo;
      if (info?.temperature != null) {
        _batteryTemperature = info!.temperature;
        debugPrint('[DeviceStatus] 電池溫度: $_batteryTemperature °C');
      }
    } catch (e) {
      debugPrint('[DeviceStatus] 無法取得電池溫度: $e');
    }
  }

  void dispose() {
    _pollTimer?.cancel();
    _initialized = false;
  }
}
