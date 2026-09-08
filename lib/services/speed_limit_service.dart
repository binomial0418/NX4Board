import 'package:flutter/foundation.dart';

import '../models/osm_road.dart';
import '../models/speed_sign.dart';
import 'csv_parser.dart';
import 'osm_tile_service.dart';
import 'road_matcher.dart';
import 'road_type_service.dart' show RoadType;

/// 速限的來源，決定可信度也決定 UI 是否標示為推定值
enum LimitSource {
  none,

  /// OSM 的 maxspeed 標註（最可信，但全台僅 4.3% 道路有標）
  osm,

  /// 公路局省道牌面，且牌面所屬公路編號與比對到的道路 ref 相符
  sign,

  /// 依 OSM 道路分級推定
  inferred,

  /// 圖資未涵蓋時，退回國道/快速道路路型判定
  roadType,
}

/// 依 GPS 位置判斷目前路段的速限。
///
/// 判定順序：
///   1. 以 OSM 圖資比對出「目前在哪條路」（幾何比對，非最近點）
///   2. 該路有 maxspeed 標註 → 直接採用
///   3. 該路是省道（有 ref）→ 找同一條省道上的公路局牌面
///   4. 否則依道路分級推定
///   5. 圖資未載入或不在任何道路上 → 退回舊有的路型判定
class SpeedLimitService {
  static final SpeedLimitService _instance = SpeedLimitService._internal();
  factory SpeedLimitService() => _instance;
  SpeedLimitService._internal();

  /// OSM 未標註 maxspeed 時，依道路分級推定的速限
  static const Map<String, int> _defaultLimits = {
    'motorway': 100,
    'trunk': 80,
    'primary': 60,
    'secondary': 50,
    'tertiary': 50,
    'unclassified': 40,
    'residential': 40,
    'living_street': 30,
    'service': 30,
    'motorway_link': 60,
    'trunk_link': 50,
    'primary_link': 40,
    'secondary_link': 40,
    'tertiary_link': 40,
  };

  /// 省道牌面的比對半徑。因為已先確認位於同一條省道上，
  /// 可以比舊版的 150 公尺放寬，牌面本來就設得稀疏。
  static const double _signRadiusM = 500.0;

  List<SpeedSign> _allSigns = [];
  bool _initialized = false;

  int _currentLimit = 40;
  int get currentLimit => _currentLimit;

  LimitSource _source = LimitSource.none;
  LimitSource get source => _source;

  OsmRoad? _currentRoad;
  OsmRoad? get currentRoad => _currentRoad;

  double _matchDistanceM = 0;
  double get matchDistanceM => _matchDistanceM;

  /// 目前路名，無法判定時為空字串
  String get currentRoadName => _currentRoad?.displayName ?? '';

  /// 速限是否為推定值（非 OSM 標註也非牌面實測）
  bool get isInferred => _source == LimitSource.inferred;

  /// 舊介面相容：最後一次是否取自省道牌面
  bool get lastDetectedFromSign => _source == LimitSource.sign;

  /// 供測試注入牌面資料，略過 rootBundle
  @visibleForTesting
  void setSignsForTest(List<SpeedSign> signs) {
    _allSigns = signs;
    _initialized = true;
  }

  /// 供測試直接驗證速限判定鏈
  @visibleForTesting
  int? resolveLimitForTest(OsmRoad road, double lat, double lng) =>
      _resolveLimit(road, lat, lng);

  Future<void> init() async {
    if (_initialized) return;
    try {
      _allSigns = await CsvParser.loadSpeedSigns();
      await OsmTileService().init();
      _initialized = true;
      debugPrint('✅ SpeedLimitService: ${_allSigns.length} 面牌面, '
          'OSM ${OsmTileService().tileCount} tiles');
    } catch (e) {
      debugPrint('❌ SpeedLimitService initialization failed: $e');
    }
  }

  /// 偵測目前路段速限。
  ///
  /// [headingDeg] 與 [speedKmh] 用於排除平行道路；靜止時 heading 不可靠，
  /// 車速低於門檻會忽略方向。回傳 null 表示無法判定。
  int? detectNearbyLimit(
    double lat,
    double lng, {
    RoadType roadType = RoadType.none,
    double? headingDeg,
    double speedKmh = 0,
  }) {
    if (!_initialized) return null;

    final tiles = OsmTileService();
    tiles.prefetchAround(lat, lng);

    final roads = tiles.cachedTileAt(lat, lng);
    if (roads != null && roads.isNotEmpty) {
      final heading = (headingDeg != null &&
              headingDeg >= 0 &&
              speedKmh >= RoadMatcher.headingMinSpeedKmh)
          ? headingDeg
          : null;

      final match = RoadMatcher.nearest(roads, lat, lng, heading);
      if (match != null) {
        _currentRoad = match.road;
        _matchDistanceM = match.distance;
        return _resolveLimit(match.road, lat, lng);
      }

      // tile 已載入但不在任何道路 40 公尺內
      _currentRoad = null;
      _matchDistanceM = 0;
    }

    // 圖資尚未載入或範圍外 → 沿用舊有路型判定
    return _fallbackByRoadType(roadType);
  }

  /// 決定速限：OSM 標註 → 同路省道牌面 → 分級推定
  int? _resolveLimit(OsmRoad road, double lat, double lng) {
    final tagged = parseMaxspeed(road.maxspeed);
    if (tagged != null) {
      _currentLimit = tagged;
      _source = LimitSource.osm;
      return tagged;
    }

    final signLimit = _findSignOnRoad(road, lat, lng);
    if (signLimit != null) {
      _currentLimit = signLimit;
      _source = LimitSource.sign;
      return signLimit;
    }

    final inferred = _defaultLimits[road.highway];
    if (inferred != null) {
      _currentLimit = inferred;
      _source = LimitSource.inferred;
      return inferred;
    }

    _source = LimitSource.none;
    return null;
  }

  /// 找出與這條路同編號、且在 [_signRadiusM] 內最近的省道牌面。
  ///
  /// 先比對公路編號再比距離，可排除橫向道路上的牌面——
  /// 這是舊版「150 公尺內取最近」做不到的。
  int? _findSignOnRoad(OsmRoad road, double lat, double lng) {
    final refs = normalizedRefs(road.ref);
    if (refs.isEmpty || _allSigns.isEmpty) return null;

    const bboxDeg = _signRadiusM / 111000.0;
    double best = _signRadiusM;
    int? bestLimit;

    for (final sign in _allSigns) {
      if ((sign.lat - lat).abs() > bboxDeg) continue;
      if ((sign.lng - lng).abs() > bboxDeg) continue;
      if (!refs.contains(_stripRoadPrefix(sign.roadNumber))) continue;

      final dist = sign.calculateDistance(lat, lng);
      if (dist < best) {
        best = dist;
        bestLimit = sign.speedLimit;
      }
    }

    return bestLimit;
  }

  /// OSM 的 ref 可能是多值（"106;北77-1"），拆開後各自去掉「台」字，
  /// 以便與 CSV 的「台106」對應。
  @visibleForTesting
  static Set<String> normalizedRefs(String? ref) {
    if (ref == null || ref.isEmpty) return const {};
    return ref
        .split(';')
        .map((e) => _stripRoadPrefix(e.trim()))
        .where((e) => e.isNotEmpty)
        .toSet();
  }

  static String _stripRoadPrefix(String value) =>
      value.replaceAll('台', '').replaceAll('臺', '').trim();

  int? _fallbackByRoadType(RoadType roadType) {
    if (roadType == RoadType.highway) {
      _currentLimit = 110;
      _source = LimitSource.roadType;
      return 110;
    }
    if (roadType == RoadType.expressway) {
      _currentLimit = 90;
      _source = LimitSource.roadType;
      return 90;
    }
    _source = LimitSource.none;
    return null;
  }

  /// 解析 OSM 的 maxspeed 值，無法解析回傳 null
  static int? parseMaxspeed(String? value) {
    if (value == null) return null;
    final v = value.trim();
    if (v.isEmpty) return null;

    const twTags = {
      'TW:urban': 50,
      'TW:rural': 90,
      'TW:motorway': 110,
      'TW:living_street': 30,
    };
    final tag = twTags[v];
    if (tag != null) return tag;

    final match = RegExp(r'^(\d+)').firstMatch(v);
    if (match == null) return null;
    final parsed = int.tryParse(match.group(1)!);
    if (parsed == null || parsed < 5 || parsed > 140) return null;
    return parsed;
  }
}
