import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../models/speed_sign.dart';
import '../services/csv_parser.dart';
import '../services/obd_spp_service.dart';
import '../services/wifi_service.dart';
import '../services/camera_service.dart';
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
  double? get tpmsFl => _obdService.tpmsFl;
  double? get tpmsFr => _obdService.tpmsFr;
  double? get tpmsRl => _obdService.tpmsRl;
  double? get tpmsRr => _obdService.tpmsRr;
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

    // ── 測速照相偵測 ──
    final camService = CameraService();
    camService.addPosition(position);
    final camInfo = camService.checkNearbyCamera();
    
    if (camInfo != null) {
      _nearestCameraInfo = camInfo;
      if (camInfo['limit'] != null) {
        _currentSpeedLimit = camInfo['limit'];
      }
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
}
