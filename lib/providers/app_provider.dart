import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../models/speed_sign.dart';
import '../services/csv_parser.dart';
import '../services/location_service.dart';

class AppProvider extends ChangeNotifier {
  List<SpeedSign> _allSpeedSigns = [];
  Position? _currentPosition;
  List<SpeedSign> _nearbySpeedSigns = [];
  int? _currentSpeedLimit;
  int? _detectedSpeedLimit;
  bool _isLoading = true;
  String _status = 'Initializing...';
  bool _cameraActive = false;
  int _ocrFrameCount = 0;
  
  // Getters
  List<SpeedSign> get allSpeedSigns => _allSpeedSigns;
  Position? get currentPosition => _currentPosition;
  List<SpeedSign> get nearbySpeedSigns => _nearbySpeedSigns;
  int? get currentSpeedLimit => _currentSpeedLimit;
  int? get detectedSpeedLimit => _detectedSpeedLimit;
  bool get isLoading => _isLoading;
  String get status => _status;
  bool get cameraActive => _cameraActive;

  /// Initialize app - load CSV data
  Future<void> initialize() async {
    try {
      _status = 'Loading speed signs data...';
      notifyListeners();
      
      _allSpeedSigns = await CsvParser.loadSpeedSigns();
      _status = 'Data loaded: ${_allSpeedSigns.length} signs';
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _status = 'Error: $e';
      _isLoading = false;
      notifyListeners();
    }
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
      final nearest = _nearbySpeedSigns.first;
      final distance = nearest.calculateDistance(
        position.latitude,
        position.longitude,
      );
      
      // Trigger camera at 150m
      if (distance <= 150 && !_cameraActive) {
        _cameraActive = true;
        _status = 'Speed sign detected! Activating camera...';
      } else if (distance > 300 && _cameraActive) {
        _cameraActive = false;
        _currentSpeedLimit = null;
        _detectedSpeedLimit = null;
        _ocrFrameCount = 0;
        _status = 'Waiting for speed sign...';
      }
    } else {
      _cameraActive = false;
      _currentSpeedLimit = null;
      _status = 'No speed signs nearby';
    }
    
    notifyListeners();
  }

  /// Update detected speed limit from OCR
  /// Uses multi-frame verification (need 3 consecutive frames)
  void updateDetectedSpeed(int? detectedSpeed) {
    if (detectedSpeed == null) {
      _ocrFrameCount = 0;
      return;
    }

    // Check if detected speed matches expected speed
    if (_nearbySpeedSigns.isNotEmpty) {
      final expectedSpeed = _nearbySpeedSigns.first.speedLimit;
      
      if (detectedSpeed == expectedSpeed) {
        _ocrFrameCount++;
        
        // Confirm after 3 consecutive frames
        if (_ocrFrameCount >= 3) {
          _currentSpeedLimit = detectedSpeed;
          _detectedSpeedLimit = detectedSpeed;
          _status = 'Speed limit: ${detectedSpeed}km/h';
          _ocrFrameCount = 0; // Reset counter
        }
      } else {
        _ocrFrameCount = 0;
        _detectedSpeedLimit = null;
      }
    }
    
    notifyListeners();
  }

  /// Reset detected speed
  void resetDetectedSpeed() {
    _detectedSpeedLimit = null;
    _ocrFrameCount = 0;
    notifyListeners();
  }

  /// Get ROI placement for current nearest sign
  String getNearestSignPlacement() {
    if (_nearbySpeedSigns.isEmpty) return '中央';
    return _nearbySpeedSigns.first.placement.isEmpty 
      ? '中央' 
      : _nearbySpeedSigns.first.placement;
  }

  /// Check if speeding
  bool isExceedingSpeedLimit(double currentSpeed) {
    if (_currentSpeedLimit == null) return false;
    return currentSpeed > _currentSpeedLimit!;
  }
}
