import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../models/speed_sign.dart';
import '../services/csv_parser.dart';
import '../services/obd_spp_service.dart';
import '../services/wifi_service.dart';
import '../services/camera_service.dart';
import '../services/settings_service.dart';
import '../services/tts_service.dart';
import 'dart:async';

class AppProvider extends ChangeNotifier {
  List<SpeedSign> _allSpeedSigns = [];
  Position? _currentPosition;
  List<SpeedSign> _nearbySpeedSigns = [];
  int? _currentSpeedLimit;
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
  double? get tpmsFl => _obdService.tpmsFl;
  double? get tpmsFr => _obdService.tpmsFr;
  double? get tpmsRl => _obdService.tpmsRl;
  double? get tpmsRr => _obdService.tpmsRr;
  int get serviceDistanceRemaining => _obdService.serviceDistanceRemaining;
  int get serviceDaysRemaining => _obdService.serviceDaysRemaining;
  List<String> get maintenanceLogHistory => _obdService.maintenanceLogHistory;
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

    // Find nearby signs within 500m
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
    if (_isSimulating) {
      _isSimulating = false;
      _simulationTimer?.cancel();
      _status = 'Simulation stopped';
      notifyListeners();
      return;
    }

    _isSimulating = true;
    _status = '模擬中: 近金湖鎮黃海路...';
    notifyListeners();

    // 模擬座標序列：從南往北接近金門金湖鎮黃海路 (24.458809, 118.43147)
    final List<Position> points = [
      Position(latitude: 24.450000, longitude: 118.43147, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 16.6, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
      Position(latitude: 24.453000, longitude: 118.43147, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 16.6, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
      Position(latitude: 24.456000, longitude: 118.43147, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 16.6, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
      Position(latitude: 24.458000, longitude: 118.43147, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 16.6, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
      Position(latitude: 24.458700, longitude: 118.43147, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 16.6, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
      Position(latitude: 24.459000, longitude: 118.43147, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 16.6, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
    ];

    int index = 0;
    _simulationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (index >= points.length) {
        _isSimulating = false;
        timer.cancel();
        _status = 'Simulation completed';
        notifyListeners();
        return;
      }
      print('DEBUG: Simulation Inject Point $index: ${points[index].latitude}');
      updatePosition(points[index]);
      index++;
    });
  }
}
