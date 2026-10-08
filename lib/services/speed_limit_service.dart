import 'package:flutter/foundation.dart';

import '../models/osm_road.dart';
import '../models/speed_sign.dart';
import 'csv_parser.dart';
import 'osm_tile_service.dart';
import 'camera_service.dart' show CameraAlgorithm;
import 'road_matcher.dart';
import 'road_tracker.dart';
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
/// 「另一可能的速限」是哪一種：高架與正下方平面道路，或同一條路的快慢車道
enum AlternativeKind { level, lane }

/// 目前位置的道路重疊狀態（單一道路時 [SpeedLimitService.overlap] 為 null）。
///
/// 「上層」在高架重疊是高架、在快慢車道是快車道；「下層」是地面道路／慢車道。
class RoadOverlap {
  final AlternativeKind kind;
  final OsmRoad upperRoad, lowerRoad;
  final int? upperLimit, lowerLimit;

  /// 在上層的機率；快慢車道為 null——兩條線只差約 10 m，GPS 分不出來
  final double? upperProbability;

  const RoadOverlap(this.kind, this.upperRoad, this.lowerRoad, this.upperLimit,
      this.lowerLimit, this.upperProbability);

  /// 有把握在哪一層（≥ 90%）
  bool get resolved =>
      upperProbability != null && (upperProbability! >= 0.9 || upperProbability! <= 0.1);

  /// 有把握時是否在上層；沒把握為 null
  bool? get onUpper => resolved ? upperProbability! >= 0.5 : null;

  /// 傾向（≥ [SpeedLimitService.leanThreshold]）哪一層；分不出為 null
  bool? get leanUpper {
    final p = upperProbability;
    if (p == null) return null;
    if (p >= SpeedLimitService.leanThreshold) return true;
    if (p <= 1 - SpeedLimitService.leanThreshold) return false;
    return null;
  }
}

class SpeedLimitService {
  static final SpeedLimitService _instance = SpeedLimitService._internal();
  factory SpeedLimitService() => _instance;
  SpeedLimitService._internal();

  /// OSM 未標註 maxspeed 時，依道路分級推定的速限。
  ///
  /// 各值取自全台已標註路段依長度的中位數（見 tools/ 的量測腳本）：
  ///   motorway      110 佔 56%、100 佔 33%
  ///   trunk          90 佔 35%、80 佔 30%、100 佔 18%
  ///   motorway_link  50 佔 33%、40 佔 28%、60 佔 20%
  ///   trunk_link     40 佔 71%、60 佔 12%、50 佔 7%   ← 快速道路閘道
  ///   primary/secondary/tertiary_link  40 佔 57~65%
  static const Map<String, int> _defaultLimits = {
    'motorway': 110,
    'trunk': 90,
    'primary': 60,
    'secondary': 50,
    'tertiary': 50,
    'unclassified': 40,
    'residential': 40,
    'living_street': 30,
    'service': 30,
    'motorway_link': 50,
    'trunk_link': 40,
    'primary_link': 40,
    'secondary_link': 40,
    'tertiary_link': 40,
  };

  /// 省道牌面的比對半徑。因為已先確認位於同一條省道上，
  /// 可以比舊版的 150 公尺放寬，牌面本來就設得稀疏。
  static const double _signRadiusM = 500.0;

  /// 快速公路與國道系統不查牌面。
  ///
  /// 牌面資料是點位，沒有記錄屬於主線還是匝道，而匝道的公路編號與主線相同。
  /// 實測台61 梧棲段未標速限的主線，500 公尺內最近的同編號牌面有 20% 是匝道的
  /// 40、25% 是 60，只有 23% 拿到正確的 90。這類道路改用 OSM 標註加分級推定，
  /// 覆蓋率與可信度都比較高（motorway 100%、trunk 60%）。
  static const Set<String> _skipSignClasses = {
    'motorway',
    'trunk',
    'motorway_link',
    'trunk_link',
  };

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

  /// 以連續性追蹤所在道路，解決高架與平面重疊時逐點比對會來回跳動的問題
  final RoadTracker _tracker = RoadTracker();

  @visibleForTesting
  RoadTracker get trackerForTest => _tracker;
  DateTime? _lastTrackTime;
  double? _lastTrackLat, _lastTrackLon;

  /// 定位中斷超過這個時間、而且期間移動超過 [_trackerResetMoveM]（或中斷超過
  /// [_trackerStaleGap]）就重新開始追蹤，舊的道路狀態已不可信。
  ///
  /// 停車時手機常常不給定位點，等紅燈 30 秒以上很常見。車子沒動卻重設，
  /// 會丟掉「一直在平面道路」的連續性：2026-10-05 台61 下的西濱路三段停了 52 秒，
  /// 重設後 GPS 偏向高架中心線，起步不到 10 秒就被判上高架。
  static const Duration _trackerResetGap = Duration(seconds: 30);
  static const Duration _trackerStaleGap = Duration(minutes: 10);
  static const double _trackerResetMoveM = 100;

  static bool shouldResetTracking(Duration gap, double movedM) =>
      gap > _trackerResetGap && (movedM > _trackerResetMoveM || gap > _trackerStaleGap);

  /// 由道路追蹤推得的路型；圖資無法判定時為 null，呼叫端應退回 RoadTypeService
  RoadType? _trackedRoadType;
  RoadType? get trackedRoadType => _trackedRoadType;

  /// 追蹤器有把握「在平面道路上」。測速照相據此排除國道／快速道路的相機，
  /// 避免行駛在高架正下方時被上方的相機誤報。
  bool _surfaceConfirmed = false;
  bool get surfaceConfirmed => _surfaceConfirmed;

  /// 高架／平面判定沒把握時，另一系統最可能的道路與其速限
  OsmRoad? _alternativeRoad;
  int? _alternativeLimit;
  OsmRoad? get alternativeRoad => _alternativeRoad;
  int? get alternativeLimit => _alternativeLimit;

  /// [alternativeLimit] 的來源：高架上下（[alternativeRoad] 有值）或快慢車道
  AlternativeKind? _alternativeKind;
  AlternativeKind? get alternativeKind => _alternativeKind;

  /// 目前位置的道路重疊狀態；單一道路為 null。測速照相依它決定提示方式。
  RoadOverlap? _overlap;
  RoadOverlap? get overlap => _overlap;

  /// 高架重疊時，追蹤器傾向的是不是目前主速限那一層（雙速限紅線用）
  bool _levelLean = false;

  /// 快慢車道：兩條 OSM 中心線相距在此以內才算（全台同名、同向、不同速限的平行路段
  /// 共 319 對，中心線間距 p25 10.2 m、中位 18.4 m；緊鄰、只隔分隔島的快慢車道
  /// 約 8~12 m，再寬的多半是隔綠帶的側車道，GPS 分得開，照最近那條即可）
  static const double laneMaxSeparationM = 15;

  /// 快慢車道：車子離兩條中心線都在此以內
  static const double laneMaxDistanceM = 20;

  /// 有另一可能的速限時，追蹤器是否仍傾向目前這一條：主要判斷所屬系統（高架或平面）
  /// 的機率 ≥ [leanThreshold]。面板雙速限時在它下方畫紅線。
  bool get alternativeLean {
    // 快慢車道相距約 10 m，比 GPS 誤差還小，不標傾向
    if (_alternativeLimit == null || _alternativeKind != AlternativeKind.level) return false;
    if (_overlap != null) return _levelLean;
    final p = _tracker.fastSystemProbability;
    return (_tracker.onFastSystem ? p : 1 - p) >= leanThreshold;
  }

  static const double leanThreshold = 0.7;
  String get alternativeRoadName => _alternativeRoad?.displayName ?? '';

  /// 高架與平面的判定是否不確定，且兩者速限不同（此時 [alternativeRoad] 有值）
  bool get isLevelAmbiguous => _alternativeRoad != null;

  /// 追蹤器對「高架或平面」沒把握，不論兩者速限是否相同。
  /// 測速照相在此狀態下兩邊都查，寧可多報也不漏報。
  bool _levelUncertain = false;
  bool get isLevelUncertain => _levelUncertain;

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

  /// 供測試在不同軌跡之間清除追蹤狀態
  @visibleForTesting
  void resetTrackingForTest() {
    _tracker.reset();
    _lastTrackTime = null;
    _clearSystemState();
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

  /// 最近一次實際套用的天空證據（不在高架重疊路段時為 unknown），見 [RoadTracker.update]
  SkyView get lastSkyApplied => _tracker.lastSkyApplied;

  /// 定位精度（手機回報）比這個差就不更新追蹤，見 [detectNearbyLimit]
  static const double maxTrustedAccuracyM = 50;

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
    double? fastFlowKmh,
    double? accuracyM,
    SkyView sky = SkyView.unknown,
  }) {
    if (!_initialized) return null;

    // 定位精度差到這個程度時，手機給的多半是自己沿原航向推算的位置（2026-10-04 台61 下：
    // 衛星 4→0 顆，精度 110~150 m，位置是一條等速直線），拿來追蹤只會漂到高架上。
    // 維持上一次的道路與速限，等衛星回來再更新
    if (accuracyM != null && accuracyM > maxTrustedAccuracyM && _currentRoad != null) {
      return _currentLimit;
    }

    final tiles = OsmTileService();
    tiles.prefetchAround(lat, lng);

    final roads = tiles.cachedTileAt(lat, lng);
    if (roads != null && roads.isNotEmpty) {
      final now = DateTime.now();
      if (_lastTrackTime != null &&
          shouldResetTracking(now.difference(_lastTrackTime!),
              CameraAlgorithm.haversine(_lastTrackLat!, _lastTrackLon!, lat, lng) * 1000)) {
        _tracker.reset();
      }
      _lastTrackTime = now;
      _lastTrackLat = lat;
      _lastTrackLon = lng;

      final tracked = _tracker.update(
        roads,
        lat,
        lng,
        headingDeg: headingDeg,
        speedKmh: speedKmh,
        fastFlowKmh: fastFlowKmh,
        accuracyM: accuracyM,
        sky: sky,
      );
      if (tracked != null) {
        _currentRoad = tracked.road;
        _matchDistanceM = tracked.distance;
        _updateSystemState(tracked.road, lat, lng);
        final limit = _resolveLimit(tracked.road, lat, lng);
        _overlap = null;
        _levelLean = false;
        final level = _tracker.levelOverlap(lat, lng);
        if (level != null) {
          _applyLevelOverlap(tracked.road, level, lat, lng);
          return limit;
        }
        if (_alternativeLimit != null || limit == null) return limit;
        return _checkLanePair(tracked.road, limit, lat, lng, tiles.cachedRoadsAround(lat, lng));
      }

      // tile 已載入但不在任何道路 40 公尺內
      _currentRoad = null;
      _matchDistanceM = 0;
    }

    _clearSystemState();

    // 圖資尚未載入或範圍外 → 沿用舊有路型判定
    return _fallbackByRoadType(roadType);
  }

  /// 依追蹤結果更新路型與「另一可能」。
  ///
  /// 有把握時直接給出路型；沒把握時路型交給呼叫端的保守處理（掃描所有相機），
  /// 並找出另一系統的候選道路，供 UI 同時呈現兩個速限。
  void _updateSystemState(OsmRoad road, double lat, double lng) {
    _alternativeRoad = null;
    _alternativeLimit = null;
    _alternativeKind = null;

    _levelUncertain = !_tracker.isSystemConfident;
    if (!_levelUncertain) {
      _trackedRoadType = _roadTypeOf(road);
      _surfaceConfirmed = _trackedRoadType == RoadType.none;
      return;
    }

    _trackedRoadType = RoadType.none;
    _surfaceConfirmed = false;

    final alt = _tracker.alternative();
    if (alt == null) return;
    final altLimit = _limitFor(alt.road, lat, lng).$1;
    // 速限相同就沒有必要讓駕駛看兩個數字
    if (altLimit == null || altLimit == _limitFor(road, lat, lng).$1) return;
    _alternativeRoad = alt.road;
    _alternativeLimit = altLimit;
    _alternativeKind = AlternativeKind.level;
  }

  /// 高架重疊（[RoadTracker.levelOverlap]）：記下重疊狀態；沒把握且兩層速限不同時，
  /// 另一層的速限當作另一可能（取代只看「快速道路系統 vs 一般道路」的舊判斷，
  /// 陸橋與 OSM 標成一般道路的快速道路段也涵蓋）。
  void _applyLevelOverlap(OsmRoad road, LevelOverlap level, double lat, double lng) {
    final upperLimit = _limitFor(level.elevated.road, lat, lng).$1;
    final lowerLimit = _limitFor(level.ground.road, lat, lng).$1;
    final ov = RoadOverlap(AlternativeKind.level, level.elevated.road, level.ground.road,
        upperLimit, lowerLimit, level.elevatedProbability);
    _overlap = ov;
    final onUpperRoad = RoadTracker.isElevated(road);
    if (ov.resolved) {
      // 有把握：只留目前這一層
      if (_alternativeKind == AlternativeKind.level) {
        _alternativeRoad = null;
        _alternativeLimit = null;
        _alternativeKind = null;
      }
      return;
    }
    final otherRoad = onUpperRoad ? level.ground.road : level.elevated.road;
    final otherLimit = onUpperRoad ? lowerLimit : upperLimit;
    final ownLimit = onUpperRoad ? upperLimit : lowerLimit;
    if (otherLimit == null || ownLimit == null || otherLimit == ownLimit) return;
    _alternativeRoad = otherRoad;
    _alternativeLimit = otherLimit;
    _alternativeKind = AlternativeKind.level;
    _levelLean = ov.leanUpper == onUpperRoad;
  }

  /// 快慢車道：同一條路被 OSM 畫成兩條同向的平行線、各標不同速限（臺灣大道八段
  /// 快車道 70、慢車道 40，相距約 10 m）。追蹤器以「編號＋路名＋等級」認路，兩條是
  /// 同一條路，只會依當下離哪條線近在兩個速限間跳。偵測到時主速限固定用較高的那個
  /// （快車道），較低的當作另一可能，面板顯示雙速限。回傳主速限。
  int _checkLanePair(OsmRoad road, int limit, double lat, double lng, List<OsmRoad> roads) {
    final name = road.name;
    final own = parseMaxspeed(road.maxspeed);
    if (name == null || own == null) return limit;
    final here = RoadMatcher.nearestOnRoad(road, lat, lng);
    if (here == null || here.dist > laneMaxDistanceM) return limit;
    for (final other in roads) {
      if (identical(other, road) || other.name != name) continue;
      final otherLimit = parseMaxspeed(other.maxspeed);
      if (otherLimit == null || otherLimit == own) continue;
      final o = RoadMatcher.nearestOnRoad(other, lat, lng);
      if (o == null || o.dist > laneMaxDistanceM) continue;
      var diff = (o.bearing - here.bearing).abs() % 360;
      if (diff > 180) diff = 360 - diff;
      if (diff > 20) continue; // 同向
      // 兩條中心線在這裡的間距，且另一條要在「側邊」：同一條路速限變化處前後兩段
      // 頭尾相接、也同名同向不同速限，但它們是一前一後，不是並排
      final sep = RoadMatcher.nearestOnRoad(other, here.footLat, here.footLon);
      if (sep == null || sep.dist < 3 || sep.dist > laneMaxSeparationM) continue;
      final side = CameraAlgorithm.calculateBearing(
          here.footLat, here.footLon, sep.footLat, sep.footLon);
      final off = CameraAlgorithm.angleDiff(side, here.bearing);
      if (off < 60 || off > 120) continue;
      final hi = own > otherLimit ? own : otherLimit;
      _alternativeLimit = own > otherLimit ? otherLimit : own;
      _alternativeKind = AlternativeKind.lane;
      _overlap = RoadOverlap(AlternativeKind.lane, own > otherLimit ? road : other,
          own > otherLimit ? other : road, hi, _alternativeLimit, null);
      _currentLimit = hi;
      return hi;
    }
    return limit;
  }

  void _clearSystemState() {
    _overlap = null;
    _levelLean = false;
    _levelUncertain = false;
    _trackedRoadType = null;
    _surfaceConfirmed = false;
    _alternativeRoad = null;
    _alternativeLimit = null;
    _alternativeKind = null;
  }

  /// OSM 道路分級對應到既有的路型：國道系統 → highway，快速道路系統 → expressway
  static RoadType _roadTypeOf(OsmRoad road) {
    switch (road.highway) {
      case 'motorway':
      case 'motorway_link':
        return RoadType.highway;
      case 'trunk':
      case 'trunk_link':
        return RoadType.expressway;
      default:
        return RoadType.none;
    }
  }

  /// 決定速限並更新目前狀態：OSM 標註 → 同路省道牌面 → 分級推定
  int? _resolveLimit(OsmRoad road, double lat, double lng) {
    final (limit, source) = _limitFor(road, lat, lng);
    _source = source;
    if (limit != null) _currentLimit = limit;
    return limit;
  }

  /// 計算某條路的速限與來源，不改動任何狀態
  (int?, LimitSource) _limitFor(OsmRoad road, double lat, double lng) {
    final tagged = parseMaxspeed(road.maxspeed);
    if (tagged != null) return (tagged, LimitSource.osm);

    final signLimit = _findSignOnRoad(road, lat, lng);
    if (signLimit != null) return (signLimit, LimitSource.sign);

    final inferred = _defaultLimits[road.highway];
    if (inferred != null) return (inferred, LimitSource.inferred);

    return (null, LimitSource.none);
  }

  /// 找出與這條路同編號、且在 [_signRadiusM] 內最近的省道牌面。
  ///
  /// 先比對公路編號再比距離，可排除橫向道路上的牌面——
  /// 這是舊版「150 公尺內取最近」做不到的。
  int? _findSignOnRoad(OsmRoad road, double lat, double lng) {
    if (_skipSignClasses.contains(road.highway)) return null;
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
  /// 以便與 CSV 的「台106」對應。路況也用它對 TDX 路段編號。
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

  /// 依道路分級推定的速限，未知分級回傳 null
  static int? defaultLimitFor(String highway) => _defaultLimits[highway];

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
