import 'package:geolocator/geolocator.dart';
import '../models/speed_sign.dart';
import 'csv_parser.dart';

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
      print('✅ SpeedLimitService initialized with ${_allSigns.length} signs');
    } catch (e) {
      print('❌ SpeedLimitService initialization failed: $e');
    }
  }

  /// 偵測附近速限位牌
  /// [lat], [lng] 為目前的 GPS 座標
  /// 回傳最新的速限值，若偵測到則更新內部狀態
  int? detectNearbyLimit(double lat, double lng) {
    if (!_initialized || _allSigns.isEmpty) return null;

    // 1. 效能優化：經緯度差值過濾 (±0.0005 度約為 55m)
    final candidates = _allSigns.where((s) =>
      (s.lat - lat).abs() < 0.0005 && (s.lng - lng).abs() < 0.0005
    ).toList();

    if (candidates.isEmpty) return null;

    // 2. 精確距離計算 (50 公尺內)
    double minDistance = 50.1;
    int? detectedLimit;

    for (var sign in candidates) {
      double dist = Geolocator.distanceBetween(lat, lng, sign.lat, sign.lng);
      if (dist < 50 && dist < minDistance) {
        minDistance = dist;
        detectedLimit = sign.speedLimit;
      }
    }

    if (detectedLimit != null) {
      _currentLimit = detectedLimit;
      return detectedLimit;
    }

    return null;
  }
}
