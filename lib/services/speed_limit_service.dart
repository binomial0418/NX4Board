import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
import '../models/speed_sign.dart';
import 'csv_parser.dart';
import 'road_type_service.dart' show RoadType;

class SpeedLimitService {
  static final SpeedLimitService _instance = SpeedLimitService._internal();
  factory SpeedLimitService() => _instance;
  SpeedLimitService._internal();

  List<SpeedSign> _allSigns = [];
  bool _initialized = false;

  // 目前偵測到的速限，初始預設為 40
  int _currentLimit = 40;
  int get currentLimit => _currentLimit;

  /// 初始化：從 CSV 載入所有牌面資料
  Future<void> init() async {
    if (_initialized) return;
    try {
      _allSigns = await CsvParser.loadSpeedSigns();
      _initialized = true;
      debugPrint('✅ SpeedLimitService initialized with ${_allSigns.length} signs');
    } catch (e) {
      debugPrint('❌ SpeedLimitService initialization failed: $e');
    }
  }

  /// 偵測附近速限
  /// 優先順序：省道 CSV 牌面 (150m 內) → 國道 (110) → 快速道路 (90)
  /// [lat], [lng] 為目前的 GPS 座標
  /// [roadType] 由 [RoadTypeService] 預先計算的路型旗標傳入，避免重複單點查表
  /// 回傳偵測到的速限值並更新內部狀態；若無法判斷則回傳 null
  int? detectNearbyLimit(double lat, double lng, {RoadType roadType = RoadType.none}) {
    // 1. 省道：從 CSV 牌面資料取得速限
    if (!_initialized || _allSigns.isEmpty) return null;

    // 效能優化：經緯度差值過濾 (±0.0015 度約為 165m)
    final candidates = _allSigns
        .where(
            (s) => (s.lat - lat).abs() < 0.0015 && (s.lng - lng).abs() < 0.0015)
        .toList();

    if (candidates.isNotEmpty) {
      // 精確距離計算 (150 公尺內)
      double minDistance = 150.1;
      int? detectedLimit;

      for (var sign in candidates) {
        double dist = Geolocator.distanceBetween(lat, lng, sign.lat, sign.lng);
        if (dist < 150 && dist < minDistance) {
          minDistance = dist;
          detectedLimit = sign.speedLimit;
        }
      }

      if (detectedLimit != null) {
        _currentLimit = detectedLimit;
        return detectedLimit;
      }
    }

    // 2. 以路型旗標判斷速限
    if (roadType == RoadType.highway) {
      _currentLimit = 110;
      debugPrint('🛣️ 國道偵測: 速限 110 km/h');
      return 110;
    }

    if (roadType == RoadType.expressway) {
      _currentLimit = 90;
      debugPrint('🛣️ 快速道路偵測: 速限 90 km/h');
      return 90;
    }
    return null;
  }
}
