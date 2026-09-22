import 'dart:math' as math;

import '../models/osm_road.dart';

/// 追蹤結果
class TrackedRoad {
  final OsmRoad road;

  /// 此道路的後驗機率（0~1），越高代表越確定
  final double confidence;

  /// 到此道路的垂直距離（公尺）
  final double distance;

  const TrackedRoad(this.road, this.confidence, this.distance);
}

/// 以「連續性」追蹤目前所在道路，解決高架與平面道路重疊時的誤判。
///
/// 逐點取最近道路的做法在高架正下方會來回跳動：兩者中心線常相距不到
/// 20 公尺，GPS 誤差就足以翻盤。但實際上車子不可能從平面道路直接
/// 「瞬移」到正上方的高架，一定要經過匝道。
///
/// 做法是隱馬可夫模型的前向濾波：
///   - 觀測機率：距離越近越可能，行進方向與路段不符、逆向行駛單行道則大幅降低
///   - 轉移機率：留在同一條路 ≫ 轉到相連的路 ≫ 跳到不相連的重疊道路
///
/// 「相連」由共用節點判斷：OSM 中交會的道路共用同一個節點，打包後座標完全相同；
/// 高架與底下的平面道路沒有共用節點，只能透過匝道轉換。
class RoadTracker {
  /// 納入候選的最大距離
  static const double candidateRadiusM = 50.0;

  /// 最佳道路超過此距離視為不在路上（與 RoadMatcher 一致）
  static const double maxDistanceM = 40.0;

  /// 觀測的距離標準差：GPS 誤差加上道路寬度。
  /// 刻意比實際 GPS 誤差大：GPS 誤差有時間相關性，把每點當獨立觀測會過度自信。
  final double sigmaM;

  /// 靜止時 heading 不可靠
  static const double headingMinSpeedKmh = 15.0;

  /// 轉到相連道路的機率（相對於留在原路 = 1）
  final double pConnected;

  /// 只有在交會點這個距離內，才允許轉到相連道路。
  ///
  /// 匝道同時連著平面道路與高架，而且常與平面道路平行一段距離；若在任何位置
  /// 都允許互轉，追蹤器會沿「平面 → 匝道 → 高架」一路溜上去。實際上車子只能
  /// 在交會點換路，離開交會點後就不可能再轉入。
  final double junctionRadiusM;

  /// 跳到不相連道路的機率。不能為 0，否則錯過匝道後永遠無法修正。
  final double pJump;

  static const double _mPerDegLat = 110540.0;

  /// 平面道路與快速路系統（國道、快速道路及其匝道）之間轉換時，
  /// 在 [pConnected] 之上再乘的係數。
  ///
  /// 交流道匝道同時連著平面道路與高架，而且常與平面道路並行一段；
  /// 若與一般路口轉彎一視同仁，平面道路上的車會被匝道「吸走」再滑上高架。
  /// 一般路口轉彎遠比上下交流道常見，所以跨系統的轉換要求更多證據。
  final double systemChangeFactor;

  /// 預設值來自 test/elevated_eval_test.dart 的參數掃描，
  /// 在高架情境與隨機市區路線驗證集之間取平衡。
  RoadTracker({
    this.sigmaM = 12.0,
    this.pConnected = 0.03,
    this.pJump = 0.0002,
    this.junctionRadiusM = 30.0,
    this.systemChangeFactor = 0.1,
  });

  /// 系統判定信心度低於此值視為不確定（實測此區間錯誤率 26~43%）
  static const double confidentThreshold = 0.9;

  static const Set<String> _fastSystem = {
    'motorway',
    'trunk',
    'motorway_link',
    'trunk_link',
  };

  static bool _isFastSystem(String identity) =>
      _fastSystem.contains(identity.substring(identity.lastIndexOf('|') + 1));

  /// 上一個定位點的道路機率分布，key 為道路識別
  Map<String, double> _belief = {};

  /// 上一個定位點，用來判斷這一步的移動路徑是否經過交會點
  double? _prevLat, _prevLon;

  /// 最近一次的觀測結果，供 [alternative] 查詢
  Map<String, _Observation> _lastObs = const {};

  /// 各 tile 的道路連通關係快取
  final Expando<_Topology> _topology = Expando<_Topology>();

  /// 重設追蹤（例如 GPS 中斷過久）
  void reset() {
    _belief = {};
    _lastObs = const {};
    _prevLat = null;
    _prevLon = null;
  }

  /// 道路識別：同一條路在不同 tile、不同 layer 會被切成多段，
  /// 以 ref + 路名 + 分級合併。
  static String identityOf(OsmRoad r) => '${r.ref ?? ''}|${r.name ?? ''}|${r.highway}';

  /// 處理一個定位點，回傳目前最可能所在的道路；不在任何道路上回傳 null。
  TrackedRoad? update(
    List<OsmRoad> roads,
    double lat,
    double lon, {
    double? headingDeg,
    double speedKmh = 0,
  }) {
    final heading =
        (headingDeg != null && headingDeg >= 0 && speedKmh >= headingMinSpeedKmh)
            ? headingDeg
            : null;

    final obs = _observe(roads, lat, lon, heading);
    final fromLat = _prevLat ?? lat;
    final fromLon = _prevLon ?? lon;
    _prevLat = lat;
    _prevLon = lon;
    if (obs.isEmpty) {
      _belief = {};
      _lastObs = const {};
      return null;
    }

    final topo = _topologyFor(roads);
    final posterior = <String, double>{};
    double total = 0;

    for (final entry in obs.entries) {
      final id = entry.key;
      double prior;
      if (_belief.isEmpty) {
        prior = 1.0;
      } else {
        prior = 0;
        _belief.forEach((prevId, p) {
          final double t;
          if (prevId == id) {
            t = 1.0;
          } else if (topo.passedJunction(
              prevId, id, fromLat, fromLon, lat, lon, junctionRadiusM)) {
            t = _isFastSystem(prevId) == _isFastSystem(id)
                ? pConnected
                : pConnected * systemChangeFactor;
          } else {
            t = pJump;
          }
          prior += p * t;
        });
      }
      final p = prior * entry.value.likelihood;
      posterior[id] = p;
      total += p;
    }

    if (total <= 0 || total.isNaN) {
      // 所有候選都不可能從前一狀態到達（例如長時間中斷後），重新開始
      reset();
      return update(roads, lat, lon, headingDeg: headingDeg, speedKmh: speedKmh);
    }

    String? bestId;
    double bestP = -1;
    posterior.updateAll((id, p) {
      final n = p / total;
      if (n > bestP) {
        bestP = n;
        bestId = id;
      }
      return n;
    });
    posterior.removeWhere((_, p) => p < 1e-6);
    _belief = posterior;
    _lastObs = obs;

    final best = obs[bestId]!;
    if (best.distance > maxDistanceM) return null;
    return TrackedRoad(best.road, bestP, best.distance);
  }

  /// 目前位於快速路系統（國道、快速道路及其匝道）的總機率。
  ///
  /// 速限與測速照相過濾真正需要的是「在高架系統上還是平面」，而不是
  /// 哪一條路；把同系統的機率加總，比單看第一名更穩定。
  double get fastSystemProbability {
    double p = 0;
    _belief.forEach((id, v) {
      if (_isFastSystem(id)) p += v;
    });
    return p;
  }

  /// 目前是否位於快速路系統
  bool get onFastSystem => fastSystemProbability >= 0.5;

  /// 高架／平面的判定是否有把握
  bool get isSystemConfident {
    final p = fastSystemProbability;
    return p >= confidentThreshold || p <= 1 - confidentThreshold;
  }

  /// 與目前判定「不同系統」（高架 vs 平面）的最可能道路。
  ///
  /// 在高架與平面重疊處判定沒把握時，用來同時呈現另一種可能。
  TrackedRoad? alternative() {
    final wantFast = !onFastSystem;
    String? bestId;
    double bestP = 0;
    _belief.forEach((id, p) {
      if (_isFastSystem(id) != wantFast) return;
      if (p > bestP) {
        bestP = p;
        bestId = id;
      }
    });
    final obs = bestId == null ? null : _lastObs[bestId];
    if (obs == null || obs.distance > maxDistanceM) return null;
    return TrackedRoad(obs.road, bestP, obs.distance);
  }

  Map<String, _Observation> _observe(
    List<OsmRoad> roads,
    double lat,
    double lon,
    double? heading,
  ) {
    final mPerDegLon = 111320.0 * math.cos(lat * math.pi / 180.0);
    final out = <String, _Observation>{};

    for (final road in roads) {
      final oneway = road.oneway == 'yes' || road.oneway == 'true' || road.oneway == '1';
      final reversed = road.oneway == '-1';

      double bestCost = double.infinity;
      double bestDist = double.infinity;

      for (final line in road.lines) {
        for (int i = 0; i + 3 < line.length; i += 2) {
          final ax = (line[i] - lon) * mPerDegLon;
          final ay = (line[i + 1] - lat) * _mPerDegLat;
          final bx = (line[i + 2] - lon) * mPerDegLon;
          final by = (line[i + 3] - lat) * _mPerDegLat;

          final d = _pointSegmentDistance(ax, ay, bx, by);
          if (d > candidateRadiusM) continue;

          double cost = d * d / (2 * sigmaM * sigmaM);
          if (heading != null) {
            final bearing = (math.atan2(bx - ax, by - ay) * 180 / math.pi + 360) % 360;
            double diff = (bearing - heading).abs() % 360;
            if (diff > 180) diff = 360 - diff;
            if (oneway || reversed) {
              // 單行道：方向相反代表這段是對向車道，不是我們所在的那一側
              final against = reversed ? diff < 90 : diff > 90;
              if (against) cost += 4.6; // ×0.01
            }
            final axial = diff > 90 ? 180 - diff : diff;
            if (axial > 45) cost += 2.3; // ×0.1
          }

          if (cost < bestCost) {
            bestCost = cost;
            bestDist = d;
          }
        }
      }

      if (bestCost == double.infinity) continue;
      final id = identityOf(road);
      final like = math.exp(-bestCost);
      final existing = out[id];
      if (existing == null || like > existing.likelihood) {
        out[id] = _Observation(road, like, bestDist);
      }
    }
    return out;
  }

  _Topology _topologyFor(List<OsmRoad> roads) {
    return _topology[roads] ??= _Topology.build(roads);
  }

  static double _pointSegmentDistance(double ax, double ay, double bx, double by) {
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
}

class _Observation {
  final OsmRoad road;
  final double likelihood;
  final double distance;
  const _Observation(this.road, this.likelihood, this.distance);
}

/// 單一 tile 內的道路連通關係：共用任一頂點座標即視為相連，並記下交會點位置
class _Topology {
  /// 道路對 → 交會點座標（扁平 [lon, lat, lon, lat, ...]）
  final Map<String, List<double>> _junctions;
  _Topology(this._junctions);

  factory _Topology.build(List<OsmRoad> roads) {
    final byVertex = <int, Set<String>>{};
    final coordOf = <int, List<double>>{};
    for (final road in roads) {
      final id = RoadTracker.identityOf(road);
      for (final line in road.lines) {
        for (int i = 0; i + 1 < line.length; i += 2) {
          // 座標在打包時已四捨五入到小數 5 位，共用節點會完全相等
          final key = ((line[i] * 1e5).round() * 40000000) + (line[i + 1] * 1e5).round();
          (byVertex[key] ??= <String>{}).add(id);
          coordOf[key] ??= [line[i], line[i + 1]];
        }
      }
    }
    final junctions = <String, List<double>>{};
    byVertex.forEach((vertex, ids) {
      if (ids.length < 2) return;
      final list = ids.toList();
      final c = coordOf[vertex]!;
      for (int a = 0; a < list.length; a++) {
        for (int b = a + 1; b < list.length; b++) {
          (junctions[_key(list[a], list[b])] ??= <double>[]).addAll(c);
        }
      }
    });
    return _Topology(junctions);
  }

  static String _key(String a, String b) =>
      a.compareTo(b) < 0 ? '$a\u0000$b' : '$b\u0000$a';

  /// 兩條路是否相連，且這一步的移動路徑（上一點 → 目前位置）
  /// 經過了它們某個交會點的 [radiusM] 範圍內。
  ///
  /// 只看目前位置的話，車速快時一步就跨過交會點，轉彎後會延遲好幾秒才跟上。
  bool passedJunction(String a, String b, double fromLat, double fromLon,
      double lat, double lon, double radiusM) {
    final pts = _junctions[_key(a, b)];
    if (pts == null) return false;
    final mPerDegLon = 111320.0 * math.cos(lat * math.pi / 180.0);
    // 以交會點為原點，檢查移動線段是否進入半徑內
    for (int i = 0; i + 1 < pts.length; i += 2) {
      final ax = (fromLon - pts[i]) * mPerDegLon;
      final ay = (fromLat - pts[i + 1]) * RoadTracker._mPerDegLat;
      final bx = (lon - pts[i]) * mPerDegLon;
      final by = (lat - pts[i + 1]) * RoadTracker._mPerDegLat;
      if (RoadTracker._pointSegmentDistance(ax, ay, bx, by) <= radiusM) return true;
    }
    return false;
  }
}
