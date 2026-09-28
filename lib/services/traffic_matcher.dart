import 'dart:math' as math;

import '../models/osm_road.dart';
import '../models/tdx_section.dart';
import 'speed_limit_service.dart';

/// 目前所在的 TDX 路段與里程
class SectionPosition {
  final TdxSection section;

  /// 沿路段折線已走的距離（公尺）
  final double alongM;

  /// 由路段起訖里程內插出的目前里程
  final double km;

  /// 到路段折線的距離（公尺）
  final double distanceM;

  const SectionPosition(this.section, this.alongM, this.km, this.distanceM);
}

/// 前方的一個路段
class AheadSection {
  final TdxSection section;

  /// 從目前位置到路段起點的距離（公尺）；目前所在路段為 0
  final double distanceM;

  /// 路段在前方的長度（公尺）；目前所在路段只算剩下的部分
  final double lengthM;

  const AheadSection(this.section, this.distanceM, this.lengthM);
}

/// 把 GPS 位置對到 TDX 路段，並列出同一路線前方的路段。
///
/// 所在道路交給 [RoadTracker] 判斷（它處理高架與平面的連續性），這裡只接受
/// 與追蹤結果同系統、同編號的路段——位置比對本身分不出相距 10 公尺的高架與側車道。
/// 方向靠航向對照路段折線的方位，因為雙向路段的折線只相距約 11 公尺。
///
/// RoadRader 舊做法的問題都在這裡避開：
///   - 里程取自路段折線內插，不再用最近一支 VD 的里程（台61 VD 里程 95% 錯誤）
///   - 方向取自路段折線，不再用羅盤四象限（台61 東西走向路段會判反）
///   - 所在道路取自追蹤器，不再取 500 公尺內最近的點（高架下的平面道路會誤判）
class TrafficMatcher {
  final TdxSectionIndex index;

  /// TDX 折線與 OSM 同編號道路的距離 p95 為 7 公尺，再加上 GPS 誤差
  final double matchRadiusM;

  /// 航向與路段方位的容許差。雙向路段方位相差 180°，這個值只要排除對向即可
  final double headingToleranceDeg;

  /// 低於這個車速時 GPS 航向不可靠，只沿用上一次的路段
  final double minHeadingSpeedKmh;

  /// 上一次的路段（或其下一段）的加分，避免路段交界處來回跳動
  final double stickinessM;

  SectionPosition? _current;
  SectionPosition? get current => _current;

  TrafficMatcher(
    this.index, {
    this.matchRadiusM = 35,
    this.headingToleranceDeg = 60,
    this.minHeadingSpeedKmh = 10,
    this.stickinessM = 8,
  });

  void reset() => _current = null;

  /// 快速公路的編號區間（台61～台88）。這些路的 TDX 路段是主線，
  /// OSM 上同編號的 primary 多半是高架下的側車道，不能對上去。
  static bool isExpresswayRef(String ref) {
    final m = RegExp(r'^(\d+)').firstMatch(ref);
    if (m == null) return false;
    final n = int.parse(m.group(1)!);
    return n >= 61 && n <= 88;
  }

  /// 追蹤到的 OSM 道路是否可能就是這個 TDX 路段
  static bool accepts(TdxSection section, OsmRoad road) {
    final h = road.highway;
    // 匝道不屬於任何主線路段
    if (h.endsWith('_link')) return false;
    if (section.system == 'F') {
      if (h != 'motorway') return false;
    } else {
      if (h == 'motorway') return false;
      if (isExpresswayRef(section.ref) && h != 'trunk') return false;
    }
    return SpeedLimitService.normalizedRefs(road.ref).contains(section.ref);
  }

  /// 以最新定位更新所在路段。[road] 為追蹤器判定的道路，null 或沒把握時應傳 null。
  SectionPosition? update(
    double lat,
    double lon, {
    required OsmRoad? road,
    double? headingDeg,
    double speedKmh = 0,
  }) {
    if (road == null) return _current = null;
    final headingUsable =
        headingDeg != null && headingDeg >= 0 && speedKmh >= minHeadingSpeedKmh;
    return _current = _best(lat, lon, road, headingUsable ? headingDeg : null,
        _current?.section);
  }

  /// 不動到目前狀態，直接找某個位置與行進方位所在的路段。
  /// 閘道前預知路況用：[road] 是匝道匯入的主線、[headingDeg] 是匯入時的方位。
  ///
  /// 匯入點附近常常沒有路段：TDX 的路段折線在交流道範圍內有缺口（台74 台中系統
  /// 往西的匯入點離最近的往西路段 1 公里多）。對不到時改往行進方向前方找
  /// [gapSearchM] 內、起點在前方且起始方向一致的路段，從它的起點算起；
  /// 回傳的 [SectionPosition.distanceM] 此時是匯入點到該起點的缺口長度。
  SectionPosition? locate(double lat, double lon, OsmRoad road, double headingDeg) =>
      _best(lat, lon, road, headingDeg, null) ?? _firstAhead(lat, lon, road, headingDeg);

  static const double gapSearchM = 1500;

  SectionPosition? _firstAhead(double lat, double lon, OsmRoad road, double headingDeg) {
    final kx = 111320.0 * math.cos(lat * math.pi / 180.0);
    const ky = 110574.0;
    SectionPosition? best;
    for (final s in index.near(lat, lon, gapSearchM)) {
      if (!accepts(s, road)) continue;
      final p = s.points;
      if (p.length < 4) continue;
      final dx = (p[0] - lon) * kx;
      final dy = (p[1] - lat) * ky;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d > gapSearchM || (best != null && d >= best.distanceM)) continue;
      // 起點要在前方，路段一開始的方向也要跟匯入方向一致（排除對向）
      final toStart = (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
      if (d > 50 && _angleDiff(toStart, headingDeg) > 45) continue;
      final first = (math.atan2((p[2] - p[0]) * kx, (p[3] - p[1]) * ky) * 180 / math.pi + 360) % 360;
      if (_angleDiff(first, headingDeg) > headingToleranceDeg) continue;
      best = SectionPosition(s, 0, s.startKm, d);
    }
    return best;
  }

  SectionPosition? _best(
      double lat, double lon, OsmRoad road, double? headingDeg, TdxSection? prev) {
    final prevNext = prev == null ? null : _nextOf(prev);

    SectionPosition? best;
    double bestScore = double.infinity;

    for (final s in index.near(lat, lon, matchRadiusM)) {
      if (!accepts(s, road)) continue;
      final proj = _project(s, lat, lon);
      if (proj == null || proj.distance > matchRadiusM) continue;

      double score = proj.distance;
      if (headingDeg != null) {
        final diff = _angleDiff(headingDeg, proj.bearing);
        if (diff > headingToleranceDeg) continue;
        score += diff / headingToleranceDeg * 10;
      } else if (!identical(s, prev)) {
        // 航向不可靠時分不出雙向，只能維持原路段
        continue;
      }
      if (identical(s, prev) || identical(s, prevNext)) score -= stickinessM;

      if (score < bestScore) {
        bestScore = score;
        best = SectionPosition(s, proj.along, s.kmAt(proj.along), proj.distance);
      }
    }
    return best;
  }

  /// 目前位置前方 [scanKm] 公里內、同一路線同方向的路段，依距離排序
  List<AheadSection> ahead(double scanKm) {
    final cur = _current;
    return cur == null ? const [] : aheadFrom(cur, scanKm);
  }

  /// [from] 前方 [scanKm] 公里內、同一路線同方向的路段，依距離排序
  List<AheadSection> aheadFrom(SectionPosition from, double scanKm) {
    final sec = from.section;
    final sign = sec.kmSign;
    final out = <AheadSection>[
      AheadSection(sec, 0, math.max(0, sec.lengthM - from.alongM)),
    ];
    for (final s in index.lineOf(sec)) {
      if (identical(s, sec)) continue;
      final startKm = (s.startKm - from.km) * sign;
      final endKm = (s.endKm - from.km) * sign;
      if (endKm <= 0) continue; // 已經在後方
      if (startKm > scanKm) break;
      final start = math.max(0.0, startKm);
      out.add(AheadSection(s, start * 1000, (endKm - start) * 1000));
    }
    out.sort((a, b) => a.distanceM.compareTo(b.distanceM));
    return out;
  }

  TdxSection? _nextOf(TdxSection s) {
    final line = index.lineOf(s);
    final i = line.indexOf(s);
    return (i >= 0 && i + 1 < line.length) ? line[i + 1] : null;
  }

  static double _angleDiff(double a, double b) {
    final d = (a - b).abs() % 360;
    return d > 180 ? 360 - d : d;
  }

  /// 點到折線的投影：距離、沿線位置、投影所在線段的方位
  static _Projection? _project(TdxSection s, double lat, double lon) {
    final p = s.points;
    if (p.length < 4) return null;
    final kx = 111320.0 * math.cos(lat * math.pi / 180.0);
    const ky = 110574.0;

    _Projection? best;
    for (int i = 0; i + 3 < p.length; i += 2) {
      final ax = (p[i] - lon) * kx;
      final ay = (p[i + 1] - lat) * ky;
      final bx = (p[i + 2] - lon) * kx;
      final by = (p[i + 3] - lat) * ky;
      final dx = bx - ax;
      final dy = by - ay;
      final lenSq = dx * dx + dy * dy;
      final t = lenSq == 0 ? 0.0 : ((-ax * dx - ay * dy) / lenSq).clamp(0.0, 1.0);
      final px = ax + t * dx;
      final py = ay + t * dy;
      final d = math.sqrt(px * px + py * py);
      if (best == null || d < best.distance) {
        final seg = i ~/ 2;
        final along = s.cumulativeM[seg] + t * math.sqrt(lenSq);
        final bearing = (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
        best = _Projection(d, along, bearing);
      }
    }
    return best;
  }
}

class _Projection {
  final double distance;
  final double along;
  final double bearing;
  const _Projection(this.distance, this.along, this.bearing);
}
