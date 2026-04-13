import 'dart:math';
import 'package:flutter/foundation.dart';
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
      debugPrint('CameraService init error: $e');
    }
  }

  List<Position> get trajectory => List.unmodifiable(_trajectory);

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

    // Threshold 5m to avoid drift noise
    if (moveDist >= 0.005) {
      userHeading = CameraAlgorithm.calculateBearing(
        first.latitude, first.longitude, last.latitude, last.longitude
      );
    }

    SpeedCamera? nearestCam;
    double minOverallDist = _searchRadiusKm;
    double? finalAngleDiff;

    // 邊界框預篩（±0.01° ≈ 1.1km），避免對遠方相機做 haversine
    const double bboxDeg = 0.01;
    final refLat = last.latitude;
    final refLon = last.longitude;

    for (var cam in _cameras) {
      if ((cam.latitude - refLat).abs() > bboxDeg ||
          (cam.longitude - refLon).abs() > bboxDeg) { continue; }

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

      if (userHeading != null) {
        final bearingToCam = CameraAlgorithm.calculateBearing(
          last.latitude, last.longitude, cam.latitude, cam.longitude
        );

        currentAngleDiff = (bearingToCam - userHeading).abs();
        if (currentAngleDiff > 180) currentAngleDiff = 360 - currentAngleDiff;

        // 已通過判斷：照相機在身後（>90°）且距最新位置 <150m → 視為剛通過，直接略過
        final distFromLast = CameraAlgorithm.haversine(
          last.latitude, last.longitude, cam.latitude, cam.longitude
        );
        if (currentAngleDiff > 90 && distFromLast < 0.15) continue;

        // 幾何過濾：照相機必須在行進方向前方 80° 以內
        if (currentAngleDiff > 80) {
          passCheck = false;
        }

        // 語意過濾：照相機 direct 欄位與行進方向不符則排除
        if (passCheck) {
          final dirMatch = CameraAlgorithm.matchDirection(cam.direct, userHeading);
          if (dirMatch == false) passCheck = false;
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
        "address": nearestCam.address,
        "limit": nearestCam.limit,
        "dist_m": (minOverallDist * 1000).round(),
        "lat": nearestCam.latitude,
        "lon": nearestCam.longitude,
        "direct": nearestCam.direct,
        "is_zone": nearestCam.direct.contains('區間'),
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

  /// 方向比對結果：
  ///   true  = 照相機方向與使用者行進方向相符 → 觸發警示
  ///   false = 方向不符 → 略過
  ///   null  = 方向模糊或無法判斷 → 僅以距離判斷（不過濾）
  static bool? matchDirection(String camDirect, double? userHeading) {
    final d = camDirect.trim();

    // 1. 數字方位角
    final camBearing = double.tryParse(d);
    if (camBearing != null) {
      if (userHeading == null) return null;
      double diff = (userHeading - camBearing).abs();
      if (diff > 180) diff = 360 - diff;
      return diff < 45;
    }

    // 2. 明確雙向 → 一律通過
    if (d.contains('雙向') || d.contains('both')) return true;

    // 3. 同一字串內含兩個方向（e.g. "南向60北向70", "南向北(區間) 北向南(區間)"）
    if (RegExp(r'南向\d+北向|北向\d+南向').hasMatch(d)) return true;
    if (d.contains('南向北') && d.contains('北向南')) return true;

    // 4. 軸向標記不含方向性 → 視為雙向
    if (d == '南北向' || d == '南北' || d == '東西向') return true;

    // 5. 模糊方向 → 略過方向判斷，僅看距離
    if (d == '單向' || d == '多向') return null;
    // "往X"：X 超過一個字（地名）才算模糊；單一基方位（往東/南/西/北）屬明確
    if (d.startsWith('往') && !RegExp(r'^往[東南西北](?:方向|車道)?$').hasMatch(d)) return null;
    // "X往Y"：往 的前一字不是基方位 → 跨區路線
    if (!d.startsWith('往') && d.contains('往')) {
      final idx = d.indexOf('往');
      if (idx > 0 && !'東南西北'.contains(d[idx - 1])) return null;
    }

    // 6. 無法取得行進方向 → 略過
    if (userHeading == null) return null;

    bool check(double expected) {
      double diff = (userHeading - expected).abs();
      if (diff > 180) diff = 360 - diff;
      return diff <= 60;
    }

    // 7. 斜向（先於基方位比對，避免子字串誤判）
    if (d.contains('西南向東北') || d.contains('西南往東北')) return check(45);
    if (d.contains('東北向西南') || d.contains('東北往西南')) return check(225);
    if (d.contains('西北向東南') || d.contains('西北往東南')) return check(135);
    if (d.contains('東南向西北') || d.contains('東南往西北')) return check(315);

    // 8. 複合基方位（先於單純基方位，避免子字串誤判）
    if (d.contains('北向南') || d.contains('北往南') || d.contains('北至南') ||
        d.contains('南下')) { return check(180); }
    if (d.contains('南向北') || d.contains('南往北') || d.contains('南至北') ||
        d.contains('北上')) { return check(0); }
    if (d.contains('東向西') || d.contains('東往西') || d.contains('東至西') ||
        d.contains('由東向西')) { return check(270); }
    if (d.contains('西向東') || d.contains('西往東') || d.contains('西至東')) return check(90);

    // 9. 單純基方位
    if (d.contains('往南') || d.contains('南向') || d.contains('南下方向')) return check(180);
    if (d.contains('往北') || d.contains('北向') || d.contains('北上方向')) return check(0);
    if (d.contains('往東') || d.contains('東向')) return check(90);
    if (d.contains('往西') || d.contains('西向')) return check(270);

    // 10. 無法識別 → 模糊，略過方向判斷
    return null;
  }

  static double _toRadians(double degrees) => degrees * pi / 180;
}
