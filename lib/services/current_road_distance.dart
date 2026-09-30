import 'osm_tile_service.dart';
import 'road_matcher.dart';
import 'road_type_service.dart' show RoadType;
import 'speed_limit_service.dart';

/// 給 [CameraService.checkNearbyCamera] 的平行道路判斷：相機到目前道路
/// （含路口直行換名的接續道路）的距離。道路圖資不會變，同一支相機在同一條路上
/// 只算一次（鍵是 道路鍵@相機座標）。
class CurrentRoadDistance {
  final Map<String, double> _cache = {};

  /// 只在追蹤器有把握在一條有路名或 ref 的平面道路上時提供；相機所在 tile
  /// 還沒載入就回傳 null（照舊提示——寧可誤報也不漏報）。
  double? Function(double lat, double lon)? forTracker(SpeedLimitService sl) {
    final road = sl.currentRoad;
    if (road == null || sl.isLevelUncertain) return null;
    if (sl.trackedRoadType != RoadType.none) return null;
    final key = road.routeKey;
    if (key == null) return null;
    final tiles = OsmTileService();
    return (lat, lon) {
      final ck = '$key@${lat}_$lon';
      final hit = _cache[ck];
      if (hit != null) return hit;
      if (!tiles.hasTileAt(lat, lon)) return null;
      final roads = tiles.cachedRoadsAround(lat, lon);
      final d = RoadMatcher.distanceToRoute(
          roads, RoadMatcher.straightContinuations(roads, key), lat, lon);
      if (_cache.length > 2000) _cache.clear();
      _cache[ck] = d;
      return d;
    };
  }
}
