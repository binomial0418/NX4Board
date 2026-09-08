import 'dart:math' as math;

import '../models/osm_road.dart';

/// 一筆比對結果
class RoadMatch {
  final OsmRoad road;

  /// 目前位置到該道路的垂直距離（公尺）
  final double distance;

  /// 排序分數 = 距離 + 方向懲罰
  final double score;

  const RoadMatch({
    required this.road,
    required this.distance,
    required this.score,
  });

  double get headingPenalty => score - distance;
}

/// 把 GPS 座標比對到最近的道路。
///
/// 與網頁版 `speed-limit-core.js` 使用相同演算法，兩邊行為必須一致。
class RoadMatcher {
  /// 超過此距離視為不在任何道路上。
  ///
  /// 需同時容納 GPS 誤差與多車道的中心線偏移：OSM 的 way 畫在道路中央，
  /// 行駛於外側車道時本來就會差 10 公尺以上。
  static const double maxDistanceM = 40.0;

  /// 靜止時 heading 不可靠，低於此車速不使用方向判斷
  static const double headingMinSpeedKmh = 15.0;
  static const double headingToleranceDeg = 45.0;
  static const double headingPenaltyM = 40.0;

  static const double _mPerDegLat = 110540.0;

  /// 原點到線段 AB 的距離，座標已換算成以查詢點為原點的公尺
  static double pointSegmentDistance(
      double ax, double ay, double bx, double by) {
    final dx = bx - ax;
    final dy = by - ay;
    final lenSq = dx * dx + dy * dy;
    if (lenSq == 0) return math.sqrt(ax * ax + ay * ay);

    double t = -(ax * dx + ay * dy) / lenSq;
    if (t < 0) t = 0;
    if (t > 1) t = 1;

    final px = ax + t * dx;
    final py = ay + t * dy;
    return math.sqrt(px * px + py * py);
  }

  /// 路段方位角與行進方向的夾角超過容許值時回傳懲罰距離。
  /// 道路雙向等價，故以 180 度為週期比較。
  static double headingPenaltyFor(
      double ax, double ay, double bx, double by, double heading) {
    final bearing =
        ((math.atan2(bx - ax, by - ay) * 180 / math.pi) % 180 + 180) % 180;
    final target = ((heading % 180) + 180) % 180;
    double diff = (bearing - target).abs();
    if (diff > 90) diff = 180 - diff;
    return diff > headingToleranceDeg ? headingPenaltyM : 0.0;
  }

  /// 依分數排序所有候選道路。[heading] 為 null 時不計方向懲罰。
  static List<RoadMatch> rank(
    List<OsmRoad> roads,
    double lat,
    double lon,
    double? heading,
  ) {
    final mPerDegLon = 111320.0 * math.cos(lat * math.pi / 180.0);
    final result = <RoadMatch>[];

    for (final road in roads) {
      double bestDistance = double.infinity;
      double bestScore = double.infinity;

      for (final line in road.lines) {
        for (int i = 0; i + 3 < line.length; i += 2) {
          final ax = (line[i] - lon) * mPerDegLon;
          final ay = (line[i + 1] - lat) * _mPerDegLat;
          final bx = (line[i + 2] - lon) * mPerDegLon;
          final by = (line[i + 3] - lat) * _mPerDegLat;

          final distance = pointSegmentDistance(ax, ay, bx, by);
          double score = distance;
          if (heading != null) {
            score += headingPenaltyFor(ax, ay, bx, by, heading);
          }

          if (score < bestScore) {
            bestScore = score;
            bestDistance = distance;
          }
        }
      }

      if (bestScore < double.infinity) {
        result.add(RoadMatch(
          road: road,
          distance: bestDistance,
          score: bestScore,
        ));
      }
    }

    result.sort((a, b) => a.score.compareTo(b.score));
    return result;
  }

  /// 取最佳候選；超過 [maxDistanceM] 視為不在路上，回傳 null。
  static RoadMatch? nearest(
    List<OsmRoad> roads,
    double lat,
    double lon,
    double? heading,
  ) {
    if (roads.isEmpty) return null;
    final ranked = rank(roads, lat, lon, heading);
    if (ranked.isEmpty) return null;
    return ranked.first.distance <= maxDistanceM ? ranked.first : null;
  }
}
