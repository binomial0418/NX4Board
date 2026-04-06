import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../models/speed_sign.dart';
import '../services/csv_parser.dart';
import '../services/obd_spp_service.dart';
import '../services/wifi_service.dart';
import '../services/camera_service.dart';
import '../services/settings_service.dart';
import '../services/tts_service.dart';
import '../services/speed_limit_service.dart';
import '../services/road_type_service.dart';
import '../services/device_status_service.dart';
import 'dart:async';
import 'dart:math' as math;

class AppProvider extends ChangeNotifier {
  List<SpeedSign> _allSpeedSigns = [];
  Position? _currentPosition;
  List<SpeedSign> _nearbySpeedSigns = [];
  int? _currentSpeedLimit;
  int _roadSpeedLimit = 40; // 新增：道路速限 (SpeedLimitCard 專用)
  bool _isLoading = true;
  String _status = 'Initializing...';
  Map<String, dynamic>? _nearestCameraInfo;
  Map<String, dynamic>? _activeZoneCameraInfo;
  DateTime? _zoneCameraActiveUntil;
  static const Duration _zoneCameraDisplayDuration = Duration(seconds: 60);

  // Obd State Properties
  final ObdSppService _obdService = ObdSppService();
  Timer? _obdStatusTimer;
  bool _isWifiConnected = false;
  ThermalMode _lastThermalMode = ThermalMode.normal;

  // ── UI Demo Mode ────────────────────────────────────────────────────────
  bool _isDemoEnabled = false;
  Timer? _demoTimer;
  double _demoSpeed = 0;
  double _demoRpm = 0;
  double _demoTurbo = 0;
  double _demoSoc = 65.5;
  int _demoCoolant = 88;
  int _demoTicks = 0;

  bool get isDemoEnabled => _isDemoEnabled;

  // Getters
  List<SpeedSign> get allSpeedSigns => _allSpeedSigns;
  Position? get currentPosition => _currentPosition;
  List<SpeedSign> get nearbySpeedSigns => _nearbySpeedSigns;
  int? get currentSpeedLimit => _currentSpeedLimit;
  int get roadSpeedLimit => _roadSpeedLimit;
  bool get isLoading => _isLoading;
  String get status => _status;
  Map<String, dynamic>? get nearestCameraInfo => _nearestCameraInfo;

  // Obd getters (Modified for Demo Mode)
  ObdConnectionState get obdConnectionState =>
      _isDemoEnabled ? ObdConnectionState.connected : _obdService.connectionState;

  int? get obdRpm => _isDemoEnabled ? _demoRpm.toInt() : _obdService.rpm;
  int? get obdSpeed {
    final rawSpeed = _isDemoEnabled ? _demoSpeed.toInt() : _obdService.speed;
    if (rawSpeed == null || rawSpeed <= 0) return rawSpeed;
    return rawSpeed + 3;
  }
  int? get obdCoolant => _isDemoEnabled ? _demoCoolant : _obdService.coolantTemp;
  double? get obdVoltage => _isDemoEnabled ? 14.2 : _obdService.voltage;
  double? get obdHevSoc => _isDemoEnabled ? _demoSoc : _obdService.hevSoc;
  double? get obdOdometer => _obdService.odometer;
  int? get obdFuel => _isDemoEnabled ? 75 : _obdService.fuelLevel;
  double? get obdTurbo => _isDemoEnabled ? _demoTurbo : _obdService.turbo;
  int? get tpmsFl => _isDemoEnabled ? 35 : _obdService.tpmsFl?.floor();
  int? get tpmsFr => _isDemoEnabled ? 36 : _obdService.tpmsFr?.floor();
  int? get tpmsRl => _isDemoEnabled ? 35 : _obdService.tpmsRl?.floor();
  int? get tpmsRr => _isDemoEnabled ? 35 : _obdService.tpmsRr?.floor();
  int get serviceDistanceRemaining => _obdService.serviceDistanceRemaining;
  int get serviceDaysRemaining => _obdService.serviceDaysRemaining;
  List<String> get maintenanceLogHistory => _obdService.maintenanceLogHistory;
  Stream<String> get maintenanceLogStream => _obdService.maintenanceLogStream;
  bool get isWifiConnected => _isWifiConnected;
  double? get deviceBatteryTemp => DeviceStatusService().batteryTemperature;
  ThermalMode get thermalMode => DeviceStatusService().thermalMode;

  /// Initialize app - load CSV data
  Future<void> initialize() async {
    try {
      _status = 'Loading speed signs data...';
      notifyListeners();

      _allSpeedSigns = await CsvParser.loadSpeedSigns();
      _status = 'Data loaded: ${_allSpeedSigns.length} signs';
      _isLoading = false;

      // Initialize Road Type Service (國道/快速道路偵測)
      await RoadTypeService().init();

      // Initialize Speed Limit Service
      await SpeedLimitService().init();

      // Initialize Camera Service
      await CameraService().init();

      // Initialize BLE Service
      await _obdService.init();

      // Initialize TTS Service
      await TtsService().init();

      // Initialize Device Status Service (電池溫度等)
      await DeviceStatusService().init();

      // Poll OBD state to update UI globally
      _obdStatusTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        bool changed = false;

        final wifiOk = await WifiService.isConnected();
        if (wifiOk != _isWifiConnected) {
          _isWifiConnected = wifiOk;
          changed = true;
        }

        final currentMode = DeviceStatusService().thermalMode;
        if (currentMode != _lastThermalMode) {
          _lastThermalMode = currentMode;
          debugPrint('[AppProvider] 熱模式變更 → ${currentMode.name}');
          changed = true;
        }

        if (changed) notifyListeners();
      });

      notifyListeners();
    } catch (e) {
      _status = 'Error: $e';
      _isLoading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _obdStatusTimer?.cancel();
    _demoTimer?.cancel();
    TtsService().dispose();
    DeviceStatusService().dispose();
    super.dispose();
  }

  // ── Demo Mode Logic ──────────────────────────────────────────────────────
  void toggleDemoMode() {
    _isDemoEnabled = !_isDemoEnabled;
    if (_isDemoEnabled) {
      _startDemoTimer();
      _status = 'Demo Mode: ON';
    } else {
      _demoTimer?.cancel();
      _status = 'Demo Mode: OFF';
    }
    notifyListeners();
  }

  void _startDemoTimer() {
    _demoTimer?.cancel();
    _demoTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      _demoTicks++;
      
      // 模擬時速：正弦波 60 ~ 130
      _demoSpeed = 95 + 35 * (math.sin(_demoTicks * 0.05));
      
      // 模擬轉速：與時速相關 + 抖動
      _demoRpm = 1200 + (_demoSpeed * 15) + (math.sin(_demoTicks * 0.2) * 50);
      
      // 模擬增壓：-0.4 ~ 1.5
      _demoTurbo = 0.5 + 1.0 * (math.sin(_demoTicks * 0.12));
      
      // 模擬電池：60.0 ~ 80.0
      _demoSoc = 70.0 + 10.0 * (math.cos(_demoTicks * 0.02));
      
      // 模擬水溫：88 與 101 之間循環切換 (每 3 秒切換一次)
      if (_demoTicks % 30 == 0) {
        _demoCoolant = (_demoCoolant == 88) ? 101 : 88;
      }

      notifyListeners();
    });
  }

  /// Update current position and find nearby speed signs
  void updatePosition(Position position) {
    _currentPosition = position;

    // ── 道路速限牌面偵測 (SpeedLimitService) ──
    final speedLimitService = SpeedLimitService();
    final detectedLimit = speedLimitService.detectNearbyLimit(
      position.latitude,
      position.longitude,
    );
    if (detectedLimit != null) {
      _roadSpeedLimit = detectedLimit;
      debugPrint('🚩 SPEED SIGN DETECTED: $detectedLimit km/h');
    } else {
      _roadSpeedLimit = speedLimitService.currentLimit;
    }

    // Find nearby signs within 500m (Legacy logic, keep for backward compatibility or other indicators)
    _nearbySpeedSigns = CsvParser.findNearby(
      _allSpeedSigns,
      position.latitude,
      position.longitude,
      500,
    );

    // Update current speed limit from nearest sign
    if (_nearbySpeedSigns.isNotEmpty) {
      _status = 'Nearby signs detected...';
      _currentSpeedLimit = _nearbySpeedSigns.first.speedLimit;
    } else {
      _currentSpeedLimit = null;
      _status = 'No speed signs nearby';
    }

    // ── 測速點偵測開關 ──
    if (!SettingsService().enableOcr) {
      debugPrint('ℹ️ Speed camera detection skipped: enableOcr is FALSE');
      _currentSpeedLimit = null;
      _nearestCameraInfo = null;
      notifyListeners();
      return;
    }

    // ── 測速照相偵測 ──
    final camService = CameraService();
    camService.addPosition(position);
    final camInfo = camService.checkNearbyCamera();

    if (camInfo != null) {
      debugPrint(
          '📸 CAMERA DETECTED: ${camInfo['name']}, Dist: ${camInfo['dist_m']}m');
      _nearestCameraInfo = camInfo;
      if (camInfo['limit'] != null) {
        _currentSpeedLimit = camInfo['limit'];
      }
      if (camInfo['is_zone'] == true) {
        _activeZoneCameraInfo = camInfo;
        _zoneCameraActiveUntil = DateTime.now().add(_zoneCameraDisplayDuration);
      } else {
        _activeZoneCameraInfo = null;
        _zoneCameraActiveUntil = null;
      }
      final double speedKmh = position.speed * 3.6;
      TtsService().speakCameraAlert(camInfo, speedKmh);

      // 距離 500m 內且超速 10km/h 以上 → 額外播報超速警示
      final int distM = camInfo['dist_m'] ?? 9999;
      final int? limit = camInfo['limit'];
      if (distM <= 500 && limit != null && speedKmh > limit + 10) {
        TtsService().speakSpeedingAlert(camInfo);
      }
    } else {
      if (_zoneCameraActiveUntil != null &&
          DateTime.now().isBefore(_zoneCameraActiveUntil!)) {
        _nearestCameraInfo = _activeZoneCameraInfo;
      } else {
        _nearestCameraInfo = null;
        _activeZoneCameraInfo = null;
        _zoneCameraActiveUntil = null;
      }
    }

    notifyListeners();
  }

  /// Check if speeding
  bool isExceedingSpeedLimit(double currentSpeed) {
    if (_currentSpeedLimit == null) return false;
    return currentSpeed > _currentSpeedLimit!;
  }

  /// 手動查詢保養資訊
  Future<void> queryMaintenanceInfo() async {
    await _obdService.queryMaintenanceInfo();
    notifyListeners();
  }

  // ── 測速路徑模擬工具 ──
  bool _isSimulating = false;
  bool get isSimulating => _isSimulating;
  Timer? _simulationTimer;

  void simulateSpeedCameraPath() {
    debugPrint(
        '🚀 AppProvider.simulateSpeedCameraPath called, current _isSimulating: $_isSimulating');
    if (_isSimulating) {
      _isSimulating = false;
      _simulationTimer?.cancel();
      _status = 'Simulation stopped';
      notifyListeners();
      return;
    }

    _isSimulating = true;
    _status = '模擬中...';
    TtsService().clearCooldown();
    notifyListeners();

    // 模擬座標序列：從北往南接近台中梧棲中華路一段 (24.236662, 120.548325)
    final List<Position> points = [
      Position(
          latitude: 24.2458,
          longitude: 120.5525,
          timestamp: DateTime.now(),
          accuracy: 1,
          altitude: 0,
          heading: 0,
          speed: 16.6,
          speedAccuracy: 1,
          floor: 0,
          isMocked: true,
          altitudeAccuracy: 0,
          headingAccuracy: 0),
      Position(
          latitude: 24.2439,
          longitude: 120.5517,
          timestamp: DateTime.now(),
          accuracy: 1,
          altitude: 0,
          heading: 0,
          speed: 16.6,
          speedAccuracy: 1,
          floor: 0,
          isMocked: true,
          altitudeAccuracy: 0,
          headingAccuracy: 0),
      Position(
          latitude: 24.2419,
          longitude: 120.5506,
          timestamp: DateTime.now(),
          accuracy: 1,
          altitude: 0,
          heading: 0,
          speed: 16.6,
          speedAccuracy: 1,
          floor: 0,
          isMocked: true,
          altitudeAccuracy: 0,
          headingAccuracy: 0),
      Position(
          latitude: 24.2396,
          longitude: 120.5496,
          timestamp: DateTime.now(),
          accuracy: 1,
          altitude: 0,
          heading: 0,
          speed: 16.6,
          speedAccuracy: 1,
          floor: 0,
          isMocked: true,
          altitudeAccuracy: 0,
          headingAccuracy: 0),
      Position(
          latitude: 24.2389,
          longitude: 120.5494,
          timestamp: DateTime.now(),
          accuracy: 1,
          altitude: 0,
          heading: 0,
          speed: 16.6,
          speedAccuracy: 1,
          floor: 0,
          isMocked: true,
          altitudeAccuracy: 0,
          headingAccuracy: 0),
      Position(
          latitude: 24.2383,
          longitude: 120.5492,
          timestamp: DateTime.now(),
          accuracy: 1,
          altitude: 0,
          heading: 0,
          speed: 16.6,
          speedAccuracy: 1,
          floor: 0,
          isMocked: true,
          altitudeAccuracy: 0,
          headingAccuracy: 0),
    ];

    int index = 0;
    _simulationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (index >= points.length) {
        _isSimulating = false;
        timer.cancel();
        _status = '模擬完成';
        notifyListeners();
        return;
      }
      updatePosition(points[index]);
      notifyListeners();
      index++;
    });
  }
}
