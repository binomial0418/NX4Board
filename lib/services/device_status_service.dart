import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 管理手機本身感測器資訊（電池溫度等）
class DeviceStatusService {
  DeviceStatusService._();
  static final DeviceStatusService _instance = DeviceStatusService._();
  factory DeviceStatusService() => _instance;

  static const _channel = MethodChannel('com.duckegg.nx4board/device_info');

  double? _batteryTemperature;
  Timer? _pollTimer;
  bool _initialized = false;

  /// 電池溫度（°C），由 Android BatteryManager.EXTRA_TEMPERATURE 取得
  double? get batteryTemperature => _batteryTemperature;

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
      if (temp != null) {
        _batteryTemperature = temp;
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
