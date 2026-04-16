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
import 'package:intl/intl.dart';

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
  bool _demoIsReversing = false;
  int _demoTicks = 0;

  // 國道/快速道路旗標委派至 RoadTypeService（滑動分數 + 座標快取）
  bool get isOnHighway => RoadTypeService().isOnHighway;
  bool get isOnExpressway => RoadTypeService().isOnExpressway;

  // GPS upload tracking (Standardized tid: gps)
  DateTime? _lastGpsSentTime;
  double _lastGpsSentHeading = 0;
  final _gpsDataController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get gpsDataStream => _gpsDataController.stream;

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
  ObdConnectionState get obdConnectionState => _isDemoEnabled
      ? ObdConnectionState.connected
      : _obdService.connectionState;

  int? get obdRpm => _isDemoEnabled ? _demoRpm.toInt() : _obdService.rpm;
  int? get obdSpeed {
    final rawSpeed = _isDemoEnabled ? _demoSpeed.toInt() : _obdService.speed;
    if (rawSpeed == null || rawSpeed <= 0) return rawSpeed;
    return rawSpeed + 3;
  }

  int? get obdCoolant =>
      _isDemoEnabled ? _demoCoolant : _obdService.coolantTemp;
  double? get obdVoltage => _isDemoEnabled ? 14.2 : _obdService.voltage;
  double? get obdHevSoc => _isDemoEnabled ? _demoSoc : _obdService.hevSoc;
  double? get obdOdometer => _isDemoEnabled ? 33610.0 : _obdService.odometer;
  int? get obdFuel => _isDemoEnabled ? 75 : _obdService.fuelLevel;
  double? get obdTurbo => _isDemoEnabled ? _demoTurbo : _obdService.turbo;
  bool get isReversing => _isDemoEnabled ? _demoIsReversing : _obdService.isReversing;
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
      _obdService.addListener(_onObdServiceUpdated);

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

  void _onObdServiceUpdated() {
    notifyListeners();
  }

  @override
  void dispose() {
    _obdService.removeListener(_onObdServiceUpdated);
    _obdStatusTimer?.cancel();
    _demoTimer?.cancel();
    _gpsDataController.close();
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

      // 建立一個 10 秒（100 ticks）的大循環週期
      final cyclePos = _demoTicks % 100;

      // 1. 模擬轉速：前 20 步 (2秒) 設為 0 (觸發 EV)，之後在 1~1789 之間波動
      if (cyclePos < 20) {
        _demoRpm = 0;
      } else {
        // 利用正弦波在剩餘 80 步中產生 1.0 ~ 1789.0 的變化
        // (cyclePos - 20) / 80 會從 0 變到 1
        final wave = math.sin((cyclePos - 20) *
            (math.pi / 40)); // 半個正弦週期的話用 pi/80，這裡用 pi/40 跑完一個週期
        _demoRpm = 895 + 894 * wave;
      }

      // 2. 模擬時速：正弦波 60 ~ 130
      _demoSpeed = 95 + 35 * (math.sin(_demoTicks * 0.05));

      // 3. 模擬增壓：-0.4 ~ 0.7
      // 範圍 1.1, 中心 0.15, 振幅 0.55
      _demoTurbo = 0.15 + 0.55 * (math.sin(_demoTicks * 0.12));

      // 4. 模擬電池：60.0 ~ 80.0
      _demoSoc = 70.0 + 10.0 * (math.cos(_demoTicks * 0.02));

      // 5. 模擬水溫：88 與 101 之間循環切換 (每 3 秒切換一次)
      if (_demoTicks % 30 == 0) {
        _demoCoolant = (_demoCoolant == 88) ? 101 : 88;
      }

      // 6. 模擬倒車：每 2 秒切換一次
      if (_demoTicks % 20 == 0) {
        _demoIsReversing = !_demoIsReversing;
      }

      notifyListeners();
    });
  }

  /// Update current position and find nearby speed signs
  void updatePosition(Position position) {
    _currentPosition = position;
    final now = DateTime.now();

    // ── 檢查是否滿足標準 GPS 資料後送條件 (每 10s 或航向 > 30度) ──
    double headingDiff = (position.heading - _lastGpsSentHeading).abs();
    if (headingDiff > 180) headingDiff = 360 - headingDiff; // 處理 0/360 跨越

    bool shouldSendGps = false;
    if (_lastGpsSentTime == null) {
      shouldSendGps = true;
    } else {
      final int timeDiff = now.difference(_lastGpsSentTime!).inSeconds;
      if (timeDiff >= 10 || headingDiff >= 20) {
        shouldSendGps = true;
      }
    }

    if (shouldSendGps) {
      _lastGpsSentTime = now;
      _lastGpsSentHeading = position.heading;

      // 依照需求格式組裝 JSON
      final timestampSec = now.millisecondsSinceEpoch ~/ 1000;
      final gpsTimeStr =
          DateFormat('HHmmss.00').format(position.timestamp.toLocal());

      final Map<String, dynamic> gpsPayload = {
        "_type": "BVB-7980",
        "tid": "gps",
        "tst": timestampSec,
        "lat": position.latitude,
        "lon": position.longitude,
        "acc": position.accuracy > 0 ? position.accuracy : 15.0,
        "vel": double.parse((position.speed * 3.6).toStringAsFixed(2)),
        "cog": double.parse(position.heading.toStringAsFixed(1)),
        "satcnt": 10, // 套件無法取得，暫以需求範例值 10 提供
        "gpstime": gpsTimeStr,
      };
      _gpsDataController.add(gpsPayload);
    }

    // ── 加入軌跡（測速照相與國道偵測共用） ──
    final camService = CameraService();
    camService.addPosition(position);

    // ── 更新國道/快速道路旗標（快取 + 滑動分數，封裝於 RoadTypeService） ──
    RoadTypeService().addPosition(position.latitude, position.longitude);

    // ── 道路速限牌面偵測，傳入路型旗標避免重複查表 ──
    final speedLimitService = SpeedLimitService();
    final detectedLimit = speedLimitService.detectNearbyLimit(
      position.latitude,
      position.longitude,
      roadType: RoadTypeService().currentRoadType,
    );
    if (detectedLimit != null) {
      _roadSpeedLimit = detectedLimit;
    } else if (!speedLimitService.lastDetectedFromSign) {
      // 上次來源為路型（國道/快速道路），現已離開且無牌面 → 退回預設 40
      _roadSpeedLimit = 40;
    }
    // 上次來源為省道牌面 → 保留最後牌面值，不更動

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
      _currentSpeedLimit = null;
      _nearestCameraInfo = null;
      notifyListeners();
      return;
    }

    // ── 測速照相偵測 ──
    final camInfo = camService.checkNearbyCamera(
      currentRoadType: RoadTypeService().currentRoadType,
    );

    if (camInfo != null) {
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
      final int distM = camInfo['dist_m'] ?? 9999;
      final int? limit = camInfo['limit'];
      final bool isZone = camInfo['is_zone'] == true;

      // 提示距離門檻：
      //   區間測速        → 100m
      //   平面道路固定測速  → 500m
      //   國道/快速道路    → 1000m
      final bool isNormalRoad =
          RoadTypeService().currentRoadType == RoadType.none;
      final int alertThresholdM = isZone ? 100 : (isNormalRoad ? 500 : 1000);
      if (distM <= alertThresholdM) {
        TtsService().speakCameraAlert(camInfo, speedKmh);
      }

      // 距離 300m 內且超速 10km/h 以上 → 額外播報超速警示（區間測速不適用）
      if (!isZone && distM <= 300 && limit != null && speedKmh > limit + 10) {
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
