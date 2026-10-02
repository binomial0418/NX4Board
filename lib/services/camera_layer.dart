import 'osm_tile_service.dart';
import 'road_matcher.dart';
import 'road_tracker.dart';
import 'speed_limit_service.dart';

/// 測速照相屬於重疊道路的哪一層
enum CameraLayer {
  /// 分不出來
  unknown,

  /// 高架／快車道
  upper,

  /// 地面道路／慢車道
  lower,
}

/// 判斷重疊路段的相機在哪一層（[RoadOverlap]）。
///
/// 依序：
///   1. 圖資代碼的位置標記（[_upperCodes]／[_lowerCodes]）：圖資本身就為部分相機
///      標了「高架道路」「平面車道」「快速車道」等位置，是人工標的，最可信
///   2. 相機類型：闖紅燈照相一定在地面——高架上沒有紅綠燈
///   3. 速限：相機速限只對得上其中一層的速限
///   4. 座標：明顯靠近其中一層（高架重疊差 ≥ [levelGapM]、快慢車道差 ≥ [laneGapM]）
///   其他為 unknown。
/// 全台實測高架重疊 613 支：②～④可分出 55%；代碼標記有 323 支，與②～④都有結果時
/// 一致 94%，再補上 82 支原本分不出的，合計 86%。快慢車道 41 支沒有代碼標記，
/// ③④分出 83%。
class CameraLayerClassifier {
  static const double levelGapM = 8;
  static const double laneGapM = 4;
  static const double _nearM = 30;

  final Map<String, CameraLayer> _cache = {};

  /// 圖資代碼（第 3 碼，[CameraRules.typeOf] 的值）標明在高架上的：
  /// J 高架道路、N 高架高速公路、6B 高架區間、C6 高架道路科技執法、
  /// AE 高架道路移動式、B3 高架高速公路移動式
  static const Set<int> _upperCodes = {0x1A, 0x1E, 0x6B, 0xC6, 0xAE, 0xB3};

  /// 標明在地面的：G 平面車道、H 平面高速公路、6A 平面區間、AC 平面車道闖紅燈、
  /// A8／A9 平面車道路口科技執法、B1 平面車道、AD 平面車道移動式、B2 平面高速公路移動式
  static const Set<int> _lowerCodes = {0x17, 0x18, 0x6A, 0xAC, 0xA8, 0xA9, 0xB1, 0xAD, 0xB2};

  /// Q 快速車道：快慢車道時屬快車道
  static const int _fastLaneCode = 0x21;

  CameraLayer classify(RoadOverlap ov, double lat, double lon, double? heading, int? limit,
      {bool redLight = false, int? typeCode}) {
    if (typeCode != null) {
      if (ov.kind == AlternativeKind.level) {
        if (_upperCodes.contains(typeCode)) return CameraLayer.upper;
        if (_lowerCodes.contains(typeCode)) return CameraLayer.lower;
      } else if (typeCode == _fastLaneCode) {
        return CameraLayer.upper;
      }
    }
    final key = '${ov.kind.name}|${ov.upperRoad.name}|${ov.lowerRoad.name}|${lat}_$lon|$heading|$limit|$redLight';
    final hit = _cache[key];
    if (hit != null) return hit;
    final r = ov.kind == AlternativeKind.level
        ? _level(lat, lon, heading, limit, redLight)
        : _lane(ov, lat, lon, limit);
    if (_cache.length > 500) _cache.clear();
    _cache[key] = r;
    return r;
  }

  CameraLayer _level(double lat, double lon, double? heading, int? limit, bool redLight) {
    if (redLight) return CameraLayer.lower;
    // 相機附近（30 m 內、走向與受測方向相近）的高架與地面道路
    double dUp = double.infinity, dLow = double.infinity;
    final upLimits = <int>{}, lowLimits = <int>{};
    for (final road in OsmTileService().cachedRoadsAround(lat, lon)) {
      final n = RoadMatcher.nearestOnRoad(road, lat, lon);
      if (n == null || n.dist > _nearM) continue;
      if (heading != null) {
        var diff = (n.bearing - heading).abs() % 180;
        if (diff > 90) diff = 180 - diff;
        if (diff > 30) continue;
      }
      final roadLimit = SpeedLimitService.parseMaxspeed(road.maxspeed) ??
          SpeedLimitService.defaultLimitFor(road.highway);
      if (RoadTracker.isElevated(road)) {
        if (n.dist < dUp) dUp = n.dist;
        if (roadLimit != null) upLimits.add(roadLimit);
      } else {
        if (n.dist < dLow) dLow = n.dist;
        if (roadLimit != null) lowLimits.add(roadLimit);
      }
    }
    if (dUp.isInfinite && dLow.isInfinite) return CameraLayer.unknown;
    if (dUp.isInfinite) return CameraLayer.lower;
    if (dLow.isInfinite) return CameraLayer.upper;
    if (limit != null) {
      final up = upLimits.contains(limit), low = lowLimits.contains(limit);
      if (up && !low) return CameraLayer.upper;
      if (low && !up) return CameraLayer.lower;
    }
    if ((dUp - dLow).abs() >= levelGapM) return dUp < dLow ? CameraLayer.upper : CameraLayer.lower;
    return CameraLayer.unknown;
  }

  CameraLayer _lane(RoadOverlap ov, double lat, double lon, int? limit) {
    if (limit != null) {
      if (limit == ov.upperLimit && limit != ov.lowerLimit) return CameraLayer.upper;
      if (limit == ov.lowerLimit && limit != ov.upperLimit) return CameraLayer.lower;
    }
    final up = RoadMatcher.nearestOnRoad(ov.upperRoad, lat, lon);
    final low = RoadMatcher.nearestOnRoad(ov.lowerRoad, lat, lon);
    if (up == null || low == null || up.dist > _nearM || low.dist > _nearM) {
      return CameraLayer.unknown;
    }
    if ((up.dist - low.dist).abs() >= laneGapM) {
      return up.dist < low.dist ? CameraLayer.upper : CameraLayer.lower;
    }
    return CameraLayer.unknown;
  }

  /// 語音與畫面用的層級名稱；分不出來為 null
  static String? label(AlternativeKind kind, CameraLayer layer) => switch ((kind, layer)) {
        (AlternativeKind.level, CameraLayer.upper) => '高架上',
        (AlternativeKind.level, CameraLayer.lower) => '高架下',
        (AlternativeKind.lane, CameraLayer.upper) => '快車道',
        (AlternativeKind.lane, CameraLayer.lower) => '慢車道',
        _ => null,
      };
}
