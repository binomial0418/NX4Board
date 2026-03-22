import 'dart:math';
import 'package:flutter/services.dart';
import 'package:csv/csv.dart';
import 'package:geolocator/geolocator.dart';

class SpeedCamera {
  final String address;
  final double longitude;
  final double latitude;
  final String direct;
  final int? limit;

  SpeedCamera({
    required this.address,
    required this.longitude,
    required this.latitude,
    required this.direct,
    this.limit,
  });

  factory SpeedCamera.fromCsv(List<dynamic> row) {
    // CSV Format: CityName(0), RegionName(1), Address(2), DeptNm(3), BranchNm(4), Longitude(5), Latitude(6), direct(7), limit(8)
    final double lon = double.tryParse(row[5]?.toString() ?? '') ?? 0.0;
    final double lat = double.tryParse(row[6]?.toString() ?? '') ?? 0.0;
    final int? lim = int.tryParse(row[8]?.toString() ?? '');
    
    return SpeedCamera(
      address: row[2]?.toString() ?? '未知地點',
      longitude: lon,
      latitude: lat,
      direct: row[7]?.toString() ?? '',
      limit: lim,
    );
  }
}

class CameraService {
  static final CameraService _instance = CameraService._internal();
  factory CameraService() => _instance;
  CameraService._internal();

  List<SpeedCamera> _cameras = [];
  final List<Position> _trajectory = [];
  static const int _maxTrajectorySize = 5;
  static const double _searchRadiusKm = 1.0;

  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      final String csvData = await rootBundle.loadString('assets/camera_data.csv');
      final List<List<dynamic>> rows = const CsvToListConverter().convert(csvData);
      
      // Skip header and sub-header (row 0 and 1)
      for (int i = 2; i < rows.length; i++) {
        if (rows[i].length < 9) continue;
        _cameras.add(SpeedCamera.fromCsv(rows[i]));
      }
      _isInitialized = true;
    } catch (e) {
    }
  }

  void addPosition(Position pos) {
    _trajectory.add(pos);
    if (_trajectory.length > _maxTrajectorySize) {
      _trajectory.removeAt(0);
    }
  }

  Map<String, dynamic>? checkNearbyCamera() {
    if (_trajectory.length < 2) return null;

    final first = _trajectory.first;
    final last = _trajectory.last;
    
    final double moveDist = CameraAlgorithm.haversine(
      first.latitude, first.longitude, last.latitude, last.longitude
    );

    double? userHeading;
    String? userDir;

    // Threshold 5m to avoid drift noise
    if (moveDist >= 0.005) {
      userHeading = CameraAlgorithm.calculateBearing(
        first.latitude, first.longitude, last.latitude, last.longitude
      );
      userDir = CameraAlgorithm.bearingToDirection(userHeading);
    }

    SpeedCamera? nearestCam;
    double minOverallDist = _searchRadiusKm;
    double? finalAngleDiff;

    for (var cam in _cameras) {
      // 1. Calculate min distance in whole trajectory (in case we just passed it)
      double minTrajectoryDist = double.infinity;
      for (var p in _trajectory) {
        double d = CameraAlgorithm.haversine(p.latitude, p.longitude, cam.latitude, cam.longitude);
        if (d < minTrajectoryDist) minTrajectoryDist = d;
      }

      if (minTrajectoryDist > minOverallDist) continue;

      // 2. Angle and Direction checks if we have movement
      bool passCheck = true;
      double? currentAngleDiff;

      if (userHeading != null && userDir != null) {
        final bearingToCam = CameraAlgorithm.calculateBearing(
          last.latitude, last.longitude, cam.latitude, cam.longitude
        );
        
        currentAngleDiff = (bearingToCam - userHeading).abs();
        if (currentAngleDiff > 180) currentAngleDiff = 360 - currentAngleDiff;

        // Strictly filter cam on sides or behind (> 80 deg)
        if (currentAngleDiff > 80) {
          passCheck = false;
        }
      }

      if (!passCheck) continue;

      if (minTrajectoryDist < minOverallDist) {
        minOverallDist = minTrajectoryDist;
        nearestCam = cam;
        finalAngleDiff = currentAngleDiff;
      }
    }

    if (nearestCam != null) {
      final String msg = nearestCam.limit == null 
          ? "前有測速照相，${nearestCam.direct}"
          : "前有測速照相，速限 ${nearestCam.limit}，${nearestCam.direct}";

      return {
        "name": nearestCam.address,
        "limit": nearestCam.limit,
        "dist_m": (minOverallDist * 1000).round(),
        "lat": nearestCam.latitude,
        "lon": nearestCam.longitude,
        "direct": nearestCam.direct,
        "message": msg,
        "debug_heading": userHeading,
        "debug_angle": finalAngleDiff,
      };
    }

    return null;
  }
}

class CameraAlgorithm {
  static const double earthRadiusKm = 6371.0;

  static double haversine(double lat1, double lon1, double lat2, double lon2) {
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    
    final a = sin(dLat / 2) * sin(dLat / 2) +
              cos(_toRadians(lat1)) * cos(_toRadians(lat2)) * 
              sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusKm * c;
  }

  static double calculateBearing(double lat1, double lon1, double lat2, double lon2) {
    final lat1Rad = _toRadians(lat1);
    final lat2Rad = _toRadians(lat2);
    final dLonRad = _toRadians(lon2 - lon1);

    final x = sin(dLonRad) * cos(lat2Rad);
    final y = cos(lat1Rad) * sin(lat2Rad) -
              sin(lat1Rad) * cos(lat2Rad) * cos(dLonRad);

    final bearingRad = atan2(x, y);
    return (bearingRad * 180 / pi + 360) % 360;
  }

  static String bearingToDirection(double bearing) {
    if (bearing >= 337.5 || bearing < 22.5) return 'N';
    if (bearing >= 22.5 && bearing < 67.5) return 'NE';
    if (bearing >= 67.5 && bearing < 112.5) return 'E';
    if (bearing >= 112.5 && bearing < 157.5) return 'SE';
    if (bearing >= 157.5 && bearing < 202.5) return 'S';
    if (bearing >= 202.5 && bearing < 247.5) return 'SW';
    if (bearing >= 247.5 && bearing < 292.5) return 'W';
    return 'NW';
  }

  static bool matchDirection(String userDir, String camDirect, String address, double? userHeading) {
    // Ported from camera_manager.py match_camera_direction
    
    // 0. Digital bearing check
    final double? camBearing = double.tryParse(camDirect);
    if (camBearing != null && userHeading != null) {
      double diff = (userHeading - camBearing).abs();
      if (diff > 180) diff = 360 - diff;
      return diff < 45;
    }

    final String full = "${camDirect.toLowerCase()} ${address.toLowerCase()}";

    // 0. Hard guards
    if (address.contains('北向') && ['S', 'SE', 'SW'].contains(userDir)) return false;
    if (address.contains('南向') && ['N', 'NE', 'NW'].contains(userDir)) return false;
    if (address.contains('東向') && ['W', 'NW', 'SW'].contains(userDir)) return false;
    if (address.contains('西向') && ['E', 'NE', 'SE'].contains(userDir)) return false;

    // 1. Both directions
    if (full.contains('雙向') || full.contains('both')) return true;

    // 2. Complex directions
    if (full.contains('北向南') || full.contains('北往南') || full.contains('北至南')) {
      return ['S', 'SE', 'SW'].contains(userDir);
    }
    if (full.contains('南向北') || full.contains('南往北') || full.contains('南至北')) {
      return ['N', 'NE', 'NW'].contains(userDir);
    }
    if (full.contains('東向西') || full.contains('東往西') || full.contains('東至西')) {
      return ['W', 'NW', 'SW'].contains(userDir);
    }
    if (full.contains('西向東') || full.contains('西往東') || full.contains('西至東')) {
      return ['E', 'NE', 'SE'].contains(userDir);
    }

    // 3. Simple keyword
    if (full.contains('北向') || full.contains('北上') || full.contains('往北') || full.contains('north')) {
      return ['N', 'NE', 'NW'].contains(userDir);
    }
    if (full.contains('南向') || full.contains('南下') || full.contains('往南') || full.contains('south')) {
      return ['S', 'SE', 'SW'].contains(userDir);
    }
    if (full.contains('東向') || full.contains('東行') || full.contains('往東') || full.contains('east')) {
      return ['E', 'NE', 'SE'].contains(userDir);
    }
    if (full.contains('西向') || full.contains('西行') || full.contains('往西') || full.contains('west')) {
      return ['W', 'NW', 'SW'].contains(userDir);
    }

    return true; // Fallback
  }

  static double _toRadians(double degrees) => degrees * pi / 180;
}
