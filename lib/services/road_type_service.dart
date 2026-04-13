import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

/// 道路類型
enum RoadType { none, highway, expressway }

/// 偵測目前是否在國道或快速道路上
///
/// 偵測策略：
///   每次收到新 GPS 點時呼叫 [addPosition]，只對該新點做地標比對
///   並以座標快取避免重複掃描；以滑動分數（+2/-1）配合門檻值提供
///   遲滯效果，避免 GPS 抖動造成路型頻繁切換。
class RoadTypeService {
  static final RoadTypeService _instance = RoadTypeService._internal();
  factory RoadTypeService() => _instance;
  RoadTypeService._internal();

  // {道路代號: [[lat, lng], ...]}
  Map<String, List<List<double>>> _highways = {};    // 國道
  Map<String, List<List<double>>> _expressways = {}; // 快速道路

  bool _initialized = false;

  // ── 座標快取 ─────────────────────────────────────────────────────────────
  // key: "${lat.toStringAsFixed(4)}_${lng.toStringAsFixed(4)}" ≈ 11m 解析度
  // 行車過程中點數有限（數百筆），不需要 LRU
  final Map<String, RoadType> _typeCache = {};

  // ── 滑動分數遲滯 ──────────────────────────────────────────────────────────
  // 偵測到目標路型：+2；未偵測到：-1；最大值 8；門檻 4
  // 進入：2 次連續偵測即可達到門檻（0→2→4）
  // 離開：需 5 次連續未偵測（8→7→6→5→4→3，低於門檻後切出）
  static const int _scoreMax = 8;
  static const int _scoreThreshold = 4;
  int _highwayScore = 0;
  int _expresswayScore = 0;

  RoadType _currentRoadType = RoadType.none;

  /// 目前判定的道路類型
  RoadType get currentRoadType => _currentRoadType;
  bool get isOnHighway => _currentRoadType == RoadType.highway;
  bool get isOnExpressway => _currentRoadType == RoadType.expressway;

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
      debugPrint('✅ RoadTypeService initialized: 國道 $hwPts pts, 快速道路 $ewPts pts');
    } catch (e) {
      debugPrint('❌ RoadTypeService init failed: $e');
    }
  }

  /// 傳入新 GPS 點，以快取 + 滑動分數更新路型狀態。
  /// 回傳 true 表示 [currentRoadType] 發生改變（供呼叫端決定是否觸發 UI 更新）。
  bool addPosition(double lat, double lng) {
    if (!_initialized) return false;
    final detected = _detectAndCache(lat, lng);
    return _updateScore(detected);
  }

  /// 單點道路類型判斷（含座標快取）
  RoadType _detectAndCache(double lat, double lng) {
    final key = '${lat.toStringAsFixed(4)}_${lng.toStringAsFixed(4)}';
    return _typeCache.putIfAbsent(key, () {
      if (_isNearLandmarks(_highways, lat, lng, 300.0)) return RoadType.highway;
      if (_isNearLandmarks(_expressways, lat, lng, 200.0)) return RoadType.expressway;
      return RoadType.none;
    });
  }

  /// 更新滑動分數並重新判定路型，回傳是否改變
  bool _updateScore(RoadType detected) {
    final prev = _currentRoadType;

    if (detected == RoadType.highway) {
      _highwayScore = (_highwayScore + 2).clamp(0, _scoreMax);
      _expresswayScore = (_expresswayScore - 1).clamp(0, _scoreMax);
    } else if (detected == RoadType.expressway) {
      _expresswayScore = (_expresswayScore + 2).clamp(0, _scoreMax);
      _highwayScore = (_highwayScore - 1).clamp(0, _scoreMax);
    } else {
      _highwayScore = (_highwayScore - 1).clamp(0, _scoreMax);
      _expresswayScore = (_expresswayScore - 1).clamp(0, _scoreMax);
    }

    if (_highwayScore >= _scoreThreshold) {
      _currentRoadType = RoadType.highway;
    } else if (_expresswayScore >= _scoreThreshold) {
      _currentRoadType = RoadType.expressway;
    } else {
      _currentRoadType = RoadType.none;
    }

    // 兩個分數同時歸零 → 已持續遠離所有高速公路，清除座標快取
    // 從國道離開後約需 9 次連續 none 才觸發（先降至門檻以下，再繼續降至 0）
    if (_highwayScore == 0 && _expresswayScore == 0) {
      _typeCache.clear();
    }

    return _currentRoadType != prev;
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
