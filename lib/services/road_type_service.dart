import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

/// 偵測目前是否在國道或快速道路上
class RoadTypeService {
  static final RoadTypeService _instance = RoadTypeService._internal();
  factory RoadTypeService() => _instance;
  RoadTypeService._internal();

  // {道路代號: [[lat, lng], ...]}
  Map<String, List<List<double>>> _highways = {};    // 國道
  Map<String, List<List<double>>> _expressways = {}; // 快速道路

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    try {
      // 載入國道地標 (1km 間距)
      final hwJson = await rootBundle.loadString('assets/highway_landmarks.json');
      final hwData = json.decode(hwJson) as Map<String, dynamic>;
      _highways = hwData.map((k, v) => MapEntry(
        k,
        (v as List).map<List<double>>((p) => [(p[0] as num).toDouble(), (p[1] as num).toDouble()]).toList(),
      ));

      // 載入快速道路地標
      final ewJson = await rootBundle.loadString('assets/expressway_landmarks.json');
      final ewData = json.decode(ewJson) as Map<String, dynamic>;
      _expressways = ewData.map((k, v) => MapEntry(
        k,
        (v as List).map<List<double>>((p) => [(p[0] as num).toDouble(), (p[1] as num).toDouble()]).toList(),
      ));

      _initialized = true;
      final hwPts = _highways.values.fold(0, (s, l) => s + l.length);
      final ewPts = _expressways.values.fold(0, (s, l) => s + l.length);
      print('✅ RoadTypeService initialized: 國道 $hwPts pts, 快速道路 $ewPts pts');
    } catch (e) {
      print('❌ RoadTypeService init failed: $e');
    }
  }

  /// 判斷道路類型
  /// 回傳 'highway'（國道）、'expressway'（快速道路），或 null（省道/其他）
  String? detectRoadType(double lat, double lng) {
    if (!_initialized) return null;

    if (_isNearLandmarks(_highways, lat, lng, 600.0)) return 'highway';
    if (_isNearLandmarks(_expressways, lat, lng, 600.0)) return 'expressway';
    return null;
  }

  bool _isNearLandmarks(
    Map<String, List<List<double>>> data,
    double lat,
    double lng,
    double radiusM,
  ) {
    // 粗略過濾：緯度差 ≈ radiusM/111000 度
    final threshold = radiusM / 111000.0;

    for (final points in data.values) {
      for (final p in points) {
        if ((p[0] - lat).abs() < threshold && (p[1] - lng).abs() < threshold) {
          final dist = Geolocator.distanceBetween(lat, lng, p[0], p[1]);
          if (dist <= radiusM) return true;
        }
      }
    }
    return false;
  }
}
