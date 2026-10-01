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
///   1. 相機類型：闖紅燈照相一定在地面——高架上沒有紅綠燈
///   2. 速限：相機速限只對得上其中一層的速限
///   3. 座標：明顯靠近其中一層（高架重疊差 ≥ [levelGapM]、快慢車道差 ≥ [laneGapM]）
///   其他為 unknown。
/// 全台實測（高架重疊 613 支、快慢車道 41 支）：①＋②＋③可分出約 55%／83%，
/// 座標與速限都可判斷時兩者一致 90%。
class CameraLayerClassifier {
  static const double levelGapM = 8;
  static const double laneGapM = 4;
  static const double _nearM = 30;

  final Map<String, CameraLayer> _cache = {};

  CameraLayer classify(RoadOverlap ov, double lat, double lon, double? heading, int? limit,
      {bool redLight = false}) {
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
