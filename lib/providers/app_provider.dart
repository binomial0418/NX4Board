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
import 'dart:async';

class AppProvider extends ChangeNotifier {
  List<SpeedSign> _allSpeedSigns = [];
  Position? _currentPosition;
  List<SpeedSign> _nearbySpeedSigns = [];
  int? _currentSpeedLimit;
  int _roadSpeedLimit = 40; // 新增：道路速限 (SpeedLimitCard 專用)
  bool _isLoading = true;
  String _status = 'Initializing...';
  Map<String, dynamic>? _nearestCameraInfo;

  // Obd State Properties
  final ObdSppService _obdService = ObdSppService();
  Timer? _obdStatusTimer;
  bool _isWifiConnected = false;

  // Getters
  List<SpeedSign> get allSpeedSigns => _allSpeedSigns;
  Position? get currentPosition => _currentPosition;
  List<SpeedSign> get nearbySpeedSigns => _nearbySpeedSigns;
  int? get currentSpeedLimit => _currentSpeedLimit;
  int get roadSpeedLimit => _roadSpeedLimit;
  bool get isLoading => _isLoading;
  String get status => _status;
  Map<String, dynamic>? get nearestCameraInfo => _nearestCameraInfo;

  // Obd getters
  ObdConnectionState get obdConnectionState => _obdService.connectionState;
  int? get obdRpm => _obdService.rpm;
  int? get obdSpeed => _obdService.speed;
  int? get obdCoolant => _obdService.coolantTemp;
  double? get obdVoltage => _obdService.voltage;
  double? get obdHevSoc => _obdService.hevSoc;
  double? get obdOdometer => _obdService.odometer;
  int? get obdFuel => _obdService.fuelLevel;
  double? get obdTurbo => _obdService.turbo;
  int? get tpmsFl => _obdService.tpmsFl?.floor();
  int? get tpmsFr => _obdService.tpmsFr?.floor();
  int? get tpmsRl => _obdService.tpmsRl?.floor();
  int? get tpmsRr => _obdService.tpmsRr?.floor();
  int get serviceDistanceRemaining => _obdService.serviceDistanceRemaining;
  int get serviceDaysRemaining => _obdService.serviceDaysRemaining;
  List<String> get maintenanceLogHistory => _obdService.maintenanceLogHistory;
  List<String> get maintenanceLogHistoryHistory => _obdService.maintenanceLogHistory;
  Stream<String> get maintenanceLogStream => _obdService.maintenanceLogStream;
  bool get isWifiConnected => _isWifiConnected;

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

      // Poll OBD state to update UI globally
      _obdStatusTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
        final wifiOk = await WifiService.isConnected();
        if (wifiOk != _isWifiConnected) {
          _isWifiConnected = wifiOk;
        }
        notifyListeners();
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
    TtsService().dispose();
    super.dispose();
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
      print('🚩 SPEED SIGN DETECTED: $detectedLimit km/h');
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

    notifyListeners();

    // ── 測速點偵測開關 ──
    if (!SettingsService().enableOcr) {
      print('ℹ️ Speed camera detection skipped: enableOcr is FALSE');
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
      print('📸 CAMERA DETECTED: ${camInfo['name']}, Dist: ${camInfo['dist_m']}m');
      _nearestCameraInfo = camInfo;
      if (camInfo['limit'] != null) {
        _currentSpeedLimit = camInfo['limit'];
      }
      
      // 觸發 TTS 語音報讀
      TtsService().speakCameraAlert(camInfo, position.speed * 3.6);
    } else {
      _nearestCameraInfo = null;
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
    print('🚀 AppProvider.simulateSpeedCameraPath called, current _isSimulating: $_isSimulating');
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
      Position(latitude: 24.2458, longitude: 120.5525, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 16.6, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
      Position(latitude: 24.2439, longitude: 120.5517, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 16.6, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
      Position(latitude: 24.2419, longitude: 120.5506, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 16.6, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
      Position(latitude: 24.2396, longitude: 120.5496, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 16.6, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
      Position(latitude: 24.2389, longitude: 120.5494, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 16.6, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
      Position(latitude: 24.2383, longitude: 120.5492, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 16.6, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
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
