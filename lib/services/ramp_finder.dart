import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/osm_road.dart';
import 'road_tracker.dart';

/// 沿匝道追到的主線匯入點
class RampTarget {
  /// 匯入的主線（motorway / trunk）
  final OsmRoad mainRoad;

  final double lat;
  final double lon;

  /// 匯入時的行進方位，即匝道最後一段的方向
  final double headingDeg;

  /// 從匝道起點（已在匝道上時為目前位置）沿匝道到匯入點的距離
  final double rampLengthM;

  /// 從目前位置到匝道入口的直線距離；已在匝道上為 0
  final double entryDistanceM;

  /// 匝道路線（入口或目前位置到匯入點），扁平的 [lon, lat, ...]。
  /// 通過入口之後用來判斷車子到底有沒有上匝道
  final Float64List path;

  const RampTarget(this.mainRoad, this.lat, this.lon, this.headingDeg,
      this.rampLengthM, this.entryDistanceM, this.path);

  /// 目前位置到匝道路線的最短距離
  double distanceToPathM(double lat, double lon) {
    double best = double.infinity;
    for (int i = 0; i + 3 < path.length; i += 2) {
      final d = _Graph._pointSegmentM(lat, lon, path[i], path[i + 1], path[i + 2], path[i + 3]);
      if (d < best) best = d;
    }
    return best;
  }
}

/// 找出前方可以上國道／快速公路的匝道，並沿匝道追到主線的匯入點。
///
/// 兩種情況：
///   - 還在平面道路上：只找「從目前這條路分岔出去」且在前方 [lookAheadM] 內的
///     入口。交流道通常兩個方向各一個入口，此時還不知道要上哪邊，兩邊都回傳。
///   - 已經在匝道上：從目前位置往下追，只剩一條（或匝道分岔後的幾條）路徑。
///   - 在國道／快速公路主線上：找前方岔出去、通往另一條主線的系統交流道匝道
///     （台86 往東接國1 南北向、台88 往西只接國1 北上），追回同一條路的不算。
///
/// 匝道的連接靠 tile 裡共用的頂點座標（OSM 的交會點共用節點），與 [RoadTracker]
/// 判斷連續性的依據相同。依 oneway 方向追，所以出口匝道不會被當成入口。
/// 全台 1266 個平面入口中，96% 能這樣追到主線，入口到主線中位數約 550 m；
/// 追不到的是 OSM 上匝道與主線沒有接起來。
class RampFinder {
  /// 平面道路上往前找入口的距離
  static const double lookAheadM = 800;

  /// 主線上往前找系統交流道的距離。主線車速快，800 m 只剩約 30 秒，
  /// 系統交流道的預告標誌也多在 1～2 公里前
  static const double mainlineLookAheadM = 1500;

  /// 入口相對目前航向的容許角度；入口就在腳下時方位不可靠，不看角度
  static const double entryConeDeg = 60;
  static const double entryNearM = 40;

  /// 在匝道上時，判定目前位於哪一段匝道的距離與方位容許值
  static const double onRampRadiusM = 30;
  static const double onRampHeadingDeg = 60;
  static const double onRampSplitM = 10;

  /// 沿匝道最多追這麼遠（系統交流道的匝道可能超過 2 公里）
  static const double maxTraceM = 3000;

  static const _linkClasses = {'motorway_link', 'trunk_link'};
  static const _mainClasses = {'motorway', 'trunk'};

  static bool isRamp(OsmRoad road) => _linkClasses.contains(road.highway);

  static bool isMainline(OsmRoad road) => _mainClasses.contains(road.highway);

  static int _key(double lon, double lat) =>
      ((lon * 1e5).round() * 40000000) + (lat * 1e5).round();

  /// [roads] 應涵蓋目前位置周圍數公里（見 OsmTileService.cachedRoadsAround），
  /// [tracked] 為追蹤器判定的所在道路。
  static List<RampTarget> find(
    List<OsmRoad> roads,
    double lat,
    double lon, {
    required OsmRoad tracked,
    required double headingDeg,
  }) {
    final graph = _Graph.build(roads);
    if (graph.segs.isEmpty) return const [];

    final starts = <_Start>[];
    if (isRamp(tracked)) {
      starts.addAll(graph.locateOnRamp(lat, lon, headingDeg));
    } else {
      final range = isMainline(tracked) ? mainlineLookAheadM : lookAheadM;
      starts.addAll(graph.entriesFrom(tracked, roads, lat, lon, headingDeg, range));
    }
    // 在主線上時，出口匝道可能繞回同一條路（交流道迴轉、對向），那不是交會道路
    final selfId = isMainline(tracked) ? RoadTracker.identityOf(tracked) : null;

    // 不同入口可能匯入同一主線同一方向，只留最近的
    final best = <String, RampTarget>{};
    for (final start in starts) {
      for (final t in graph.trace(start)) {
        if (selfId != null && RoadTracker.identityOf(t.mainRoad) == selfId) continue;
        final dirBucket = (t.headingDeg / 90).round() % 4;
        final key = '${RoadTracker.identityOf(t.mainRoad)}|$dirBucket';
        final existing = best[key];
        if (existing == null ||
            t.entryDistanceM + t.rampLengthM <
                existing.entryDistanceM + existing.rampLengthM) {
          best[key] = t;
        }
      }
    }
    return best.values.toList();
  }
}

class _Start {
  final int seg;
  final int pos;

  /// 起點到 [pos] 頂點之前已走的距離（在匝道中段起算時為 0）
  final double startLon;
  final double startLat;
  final double entryDistanceM;
  const _Start(this.seg, this.pos, this.startLon, this.startLat, this.entryDistanceM);
}

/// 匝道依 oneway 方向排好的折線，與頂點索引
class _Graph {
  /// 每段是扁平的 [lon, lat, ...]，點序即行車方向
  final List<Float64List> segs = [];

  /// 頂點 → 經過它的 (段, 位置)，含中段頂點——匝道常在另一條匝道的中段匯入
  final Map<int, List<(int, int)>> at = {};

  /// 主線頂點 → 主線道路
  final Map<int, OsmRoad> mainAt = {};

  static _Graph build(List<OsmRoad> roads) {
    final g = _Graph();
    for (final r in roads) {
      if (RampFinder._mainClasses.contains(r.highway)) {
        for (final line in r.lines) {
          for (int i = 0; i + 1 < line.length; i += 2) {
            g.mainAt.putIfAbsent(RampFinder._key(line[i], line[i + 1]), () => r);
          }
        }
        continue;
      }
      if (!RampFinder._linkClasses.contains(r.highway)) continue;
      // 雙向或未標 oneway 的匝道無法判斷行車方向（全台約 6%），不追
      final reversed = r.oneway == '-1';
      if (!(r.oneway == 'yes' || r.oneway == 'true' || r.oneway == '1' || reversed)) {
        continue;
      }
      for (final line in r.lines) {
        if (line.length < 4) continue;
        final seq = reversed ? _reverse(line) : line;
        final idx = g.segs.length;
        g.segs.add(seq);
        for (int i = 0; i + 3 < seq.length; i += 2) {
          g.at.putIfAbsent(RampFinder._key(seq[i], seq[i + 1]), () => []).add((idx, i ~/ 2));
        }
      }
    }
    return g;
  }

  static Float64List _reverse(Float64List line) {
    final out = Float64List(line.length);
    for (int i = 0; i + 1 < line.length; i += 2) {
      out[line.length - 2 - i] = line[i];
      out[line.length - 1 - i] = line[i + 1];
    }
    return out;
  }

  /// 已在匝道上：找目前所在的匝道段，從投影點之後的頂點開始追。
  ///
  /// 匝道分岔前後兩條分支幾乎重疊，只取最近的一段會在兩條之間來回跳，
  /// 所以最近距離再加 [RampFinder.onRampSplitM] 以內的分支全部回傳。
  List<_Start> locateOnRamp(double lat, double lon, double headingDeg) {
    final hits = <(double, _Start)>[];
    for (int s = 0; s < segs.length; s++) {
      final p = segs[s];
      for (int i = 0; i + 3 < p.length; i += 2) {
        final d = _pointSegmentM(lat, lon, p[i], p[i + 1], p[i + 2], p[i + 3]);
        if (d > RampFinder.onRampRadiusM) continue;
        final b = _bearing(p[i], p[i + 1], p[i + 2], p[i + 3]);
        if (_angleDiff(b, headingDeg) > RampFinder.onRampHeadingDeg) continue;
        hits.add((d, _Start(s, i ~/ 2, lon, lat, 0)));
      }
    }
    if (hits.isEmpty) return const [];
    final nearest = hits.map((h) => h.$1).reduce(math.min);
    return [
      for (final h in hits)
        if (h.$1 <= nearest + RampFinder.onRampSplitM) h.$2
    ];
  }

  /// 在平面道路上：從 [tracked]（同一條路的所有片段）分岔出去、位於前方的入口
  List<_Start> entriesFrom(OsmRoad tracked, List<OsmRoad> roads, double lat, double lon,
      double headingDeg, double rangeM) {
    final id = RoadTracker.identityOf(tracked);
    final onRoad = <int>{};
    for (final r in roads) {
      if (RoadTracker.identityOf(r) != id) continue;
      for (final line in r.lines) {
        for (int i = 0; i + 1 < line.length; i += 2) {
          onRoad.add(RampFinder._key(line[i], line[i + 1]));
        }
      }
    }
    final out = <_Start>[];
    for (int s = 0; s < segs.length; s++) {
      final p = segs[s];
      if (!onRoad.contains(RampFinder._key(p[0], p[1]))) continue;
      final d = _distanceM(lat, lon, p[1], p[0]);
      if (d > rangeM) continue;
      if (d > RampFinder.entryNearM &&
          _angleDiff(_bearing(lon, lat, p[0], p[1]), headingDeg) > RampFinder.entryConeDeg) {
        continue;
      }
      out.add(_Start(s, 0, p[0], p[1], d));
    }
    return out;
  }

  /// 沿 oneway 方向走，碰到主線頂點就是匯入點；匝道分岔時各條都追
  List<RampTarget> trace(_Start start) {
    final out = <RampTarget>[];
    final seen = <(int, int)>{(start.seg, start.pos)};
    // 依已走距離由近到遠展開；每條分支帶著自己走過的路線
    final queue = Queue<(int, int, double, List<double>)>()
      ..add((start.seg, start.pos, 0.0, [start.startLon, start.startLat]));

    while (queue.isNotEmpty) {
      final (seg, pos, acc0, path0) = queue.removeFirst();
      final p = segs[seg];
      final path = [...path0];
      double acc = acc0;
      bool merged = false;
      for (int i = (pos + 1) * 2; i + 1 < p.length; i += 2) {
        acc += _distanceM(path[path.length - 1], path[path.length - 2], p[i + 1], p[i]);
        path..add(p[i])..add(p[i + 1]);
        final main = mainAt[RampFinder._key(p[i], p[i + 1])];
        if (main != null) {
          final h = _bearing(p[i - 2], p[i - 1], p[i], p[i + 1]);
          out.add(RampTarget(main, p[i + 1], p[i], h, acc, start.entryDistanceM,
              Float64List.fromList(path)));
          merged = true;
          break;
        }
      }
      if (merged || acc > RampFinder.maxTraceM) continue;
      final endKey = RampFinder._key(p[p.length - 2], p[p.length - 1]);
      for (final next in at[endKey] ?? const <(int, int)>[]) {
        if (seen.add(next)) queue.add((next.$1, next.$2, acc, path));
      }
    }
    return out;
  }

  static double _distanceM(double lat1, double lon1, double lat2, double lon2) {
    final kx = 111320.0 * math.cos(lat1 * math.pi / 180.0);
    final dx = (lon2 - lon1) * kx;
    final dy = (lat2 - lat1) * 110574.0;
    return math.sqrt(dx * dx + dy * dy);
  }

  static double _bearing(double lon1, double lat1, double lon2, double lat2) {
    final dx = (lon2 - lon1) * math.cos(lat1 * math.pi / 180.0);
    final dy = lat2 - lat1;
    return (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
  }

  static double _angleDiff(double a, double b) {
    final d = (a - b).abs() % 360;
    return d > 180 ? 360 - d : d;
  }

  static double _pointSegmentM(
      double lat, double lon, double lon1, double lat1, double lon2, double lat2) {
    final kx = 111320.0 * math.cos(lat * math.pi / 180.0);
    const ky = 110574.0;
    final ax = (lon1 - lon) * kx, ay = (lat1 - lat) * ky;
    final bx = (lon2 - lon) * kx, by = (lat2 - lat) * ky;
    final dx = bx - ax, dy = by - ay;
    final lenSq = dx * dx + dy * dy;
    final t = lenSq == 0 ? 0.0 : ((-ax * dx - ay * dy) / lenSq).clamp(0.0, 1.0);
    final px = ax + t * dx, py = ay + t * dy;
    return math.sqrt(px * px + py * py);
  }
}
