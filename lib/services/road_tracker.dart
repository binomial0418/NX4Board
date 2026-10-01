import 'dart:math' as math;

import '../models/osm_road.dart';
import 'road_matcher.dart';
import 'speed_limit_service.dart';

/// 頭頂天空的狀態（由衛星訊號判斷，見 SkyService）。
///
/// 高架橋面會擋住頭頂（高仰角）的衛星：開在橋下時它們整批消失，在橋上則一定
/// 看得到。只在高架與地面道路重疊的地方當證據用，見 [RoadTracker.update]。
enum SkyView {
  /// 資料不足或介於中間，不當證據
  unknown,

  /// 頭頂被擋（連續數秒沒有高仰角強訊號衛星）
  blocked,

  /// 頭頂開闊
  open,
}

/// 高架重疊：目前位置附近同時有高架（OSM bridge 或 layer > 0）與同向的地面道路，
/// 不論是否屬於快速道路系統（台61／港埠路、陸橋與底下的側車道都算）。
class LevelOverlap {
  /// 在高架那一層的機率（兩層候選的後驗機率各自加總後正規化）
  final double elevatedProbability;

  /// 兩層各自最可能的道路
  final TrackedRoad elevated;
  final TrackedRoad ground;

  const LevelOverlap(this.elevatedProbability, this.elevated, this.ground);
}

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

  /// 手機回報的定位精度（Android Location.getAccuracy，約 68% 信賴半徑）大於 [sigmaM] 時
  /// 改用它，上限 [maxSigmaM]。高架下、大樓間訊號差時手機會回報較大的誤差，
  /// 這時位置本來就不可信，應該更依賴連續性與車速、車流等證據，
  /// 而不是讓偏移幾秒的定位把道路拉走。下限維持 [sigmaM]：空曠處手機常回報
  /// 3～5 m，比實際（含路寬、時間相關性）樂觀。
  ///
  /// σ 越大追蹤器越黏在原路上，上高架也會晚一點相信，所以上限不能太高。
  /// 以 σ 15 m 的軌跡、假設手機回報 20 m 實測（test/tracker_flow_test.dart）：
  /// 港埠路（含車流佐證）誤判 85 → 41 秒、梧棲側車道 W3 7.3% → 4.3%，
  /// 代價是 W1 上高架 8.3% → 8.9%、延遲多 1 秒；回報 25 m 時 W1 升到 10.2%。
  final double maxSigmaM;

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

  /// 跳到不相連道路的機率。只在「目前這條路已經無法解釋所在位置」時啟用，
  /// 也就是它的距離超過 [jumpDistanceM]。
  ///
  /// GPS 誤差有時間相關性，偏向隔壁道路的偏差常持續十幾秒，足以讓一個固定的
  /// 小機率被突破——高架與正下方的側車道就會反覆互跳。改成有條件之後，兩條
  /// 路都還貼合時不准跳，真的偏離了才允許，才能兼顧穩定與修正能力。
  final double pJump;
  final double jumpDistanceM;

  static const double _mPerDegLat = 110540.0;

  /// 車速合理性：目前車速超過候選道路速限這麼多之後開始扣分。
  ///
  /// 高架與正下方的側車道常相距不到 30 公尺，位置資訊不足以分辨，
  /// 但兩者速限差距很大（例如台61 的 80 對側車道的 50），車速就成了關鍵證據。
  /// 因為機率會正規化，這個懲罰只改變「候選之間」的相對權重——在一般道路上
  /// 超速不會有副作用，除非附近真的有速限更高的路。
  final double speedMarginKmh;
  final double speedScaleKmh;
  final double speedMaxPenalty;

  /// 低於此車速不採用車速證據（怠速、塞車時沒有鑑別力）
  final double speedEvidenceMinKmh;

  /// 平面道路與快速路系統（國道、快速道路及其匝道）之間轉換時，
  /// 在 [pConnected] 之上再乘的係數。
  ///
  /// 交流道匝道同時連著平面道路與高架，而且常與平面道路並行一段；
  /// 若與一般路口轉彎一視同仁，平面道路上的車會被匝道「吸走」再滑上高架。
  /// 一般路口轉彎遠比上下交流道常見，所以跨系統的轉換要求更多證據。
  final double systemChangeFactor;

  /// 從零開始追蹤（App 啟動、GPS 中斷後重設、附近沒有道路）時，快速路系統的
  /// 初始機率相對於平面道路的倍數。
  ///
  /// 沒有歷史時位置分不出高架與正下方的平面道路，而「只能經由匝道轉換」的
  /// 連續性規則會讓第一次選錯的結果一直延續：台61 梧棲港埠路（與上方高架相距
  /// 14～25 公尺）實測時速 50、σ 15 m 時 20 次有 13 次被困在高架上，最長 197 秒，
  /// 速限、測速照相與閘道路況都跟著錯。啟動多半發生在平面道路上，所以偏向平面。
  final double startFastPrior;

  /// 車流佐證：TDX 顯示所在快速路車流順暢，車速卻一直遠低於車流，
  /// 就不太可能在這條快速路上——高架下的平面道路位置分不出來時，這是能分辨的證據。
  ///
  /// 台61 梧棲港埠路與上方高架相距 9～25 公尺：GPS 往高架那側偏幾秒，
  /// 平面道路的機率就被壓到刪除門檻以下，之後 GPS 回到平面也回不來，
  /// 只能等偏離超過 [jumpDistanceM]。車速 50 對兩條路都不算超速，原本的車速證據
  /// 幫不上忙；車流 90 而自己一直 50，才是反證。塞車時車流本身就慢，不會觸發。
  ///
  /// 成立條件：車流 ≥ [flowMinKmh]，且最近 [flowWindow] 個定位點的平均車速
  /// 低於車流的 [flowRatio]。成立時快速路主線的觀測機率乘 [flowPenalty]，
  /// 並允許以 [flowJump] 轉回不相連的平面道路。
  final double flowMinKmh;
  final double flowRatio;
  final int flowWindow;
  final double flowPenalty;
  final double flowJump;

  /// 頭頂天空證據（[SkyView]）。只在「重疊路段」用：目前位置 [overlapM] 內同時有
  /// 高架（OSM bridge 或 layer > 0）與地面道路候選。
  ///   - 頭頂被擋：高架候選的觀測機率乘 [skyPenalty]，並允許以 [skyJump] 從高架
  ///     轉到不相連的地面道路
  ///   - 頭頂開闊：只有地面道路真的在橋面下方（離高架中心線 [underM] 內）才算數——
  ///     高架旁邊的側車道頭頂也是開闊的。成立時地面候選乘 [skyPenalty]，並允許
  ///     以 [skyJump] 從地面轉上高架
  final double overlapM;
  final double underM;
  final double skyPenalty;
  final double skyJump;

  /// 預設值來自 test/elevated_eval_test.dart 的參數掃描，
  /// 在高架情境與隨機市區路線驗證集之間取平衡。
  RoadTracker({
    this.sigmaM = 12.0,
    this.maxSigmaM = 20.0,
    this.pConnected = 0.03,
    this.pJump = 0.0002,
    this.jumpDistanceM = 45.0,
    this.junctionRadiusM = 30.0,
    this.systemChangeFactor = 0.1,
    this.speedMarginKmh = 15.0,
    this.speedScaleKmh = 15.0,
    this.speedMaxPenalty = 2.3, // ×0.1
    this.speedEvidenceMinKmh = 20.0,
    this.startFastPrior = 0.1,
    this.flowMinKmh = 70,
    this.flowRatio = 0.6,
    this.flowWindow = 20,
    this.flowPenalty = 0.3,
    this.flowJump = 0.05,
    this.overlapM = 25,
    this.underM = 12,
    this.skyPenalty = 0.2,
    this.skyJump = 0.05,
  });

  /// 系統判定信心度低於此值視為不確定（實測此區間錯誤率 26~43%）
  static const double confidentThreshold = 0.9;

  static const Set<String> _fastSystem = {
    'motorway',
    'trunk',
    'motorway_link',
    'trunk_link',
  };

  /// 快速路主線（不含匝道：匝道本來就開得慢，車流證據不適用）
  static bool _isMainline(String identity) {
    final h = identity.substring(identity.lastIndexOf('|') + 1);
    return h == 'motorway' || h == 'trunk';
  }

  /// 高架路段：OSM 標了 bridge（非 no）或 layer > 0
  static bool isElevated(OsmRoad r) {
    final b = r.bridge;
    if (b != null && b.isNotEmpty && b != 'no') return true;
    final layer = int.tryParse(r.layer ?? '');
    return layer != null && layer > 0;
  }

  static bool _isFastSystem(String identity) =>
      _fastSystem.contains(identity.substring(identity.lastIndexOf('|') + 1));

  /// 上一個定位點的道路機率分布，key 為道路識別
  Map<String, double> _belief = {};

  /// 上一個定位點，用來判斷這一步的移動路徑是否經過交會點
  double? _prevLat, _prevLon;

  /// 最近 [flowWindow] 個定位點的車速，車流佐證用
  final List<double> _recentSpeeds = [];

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
    _recentSpeeds.clear();
  }

  /// 道路識別：同一條路在不同 tile、不同 layer 會被切成多段，
  /// 以 ref + 路名 + 分級合併。
  static String identityOf(OsmRoad r) => '${r.ref ?? ''}|${r.name ?? ''}|${r.highway}';

  /// 處理一個定位點，回傳目前最可能所在的道路；不在任何道路上回傳 null。
  ///
  /// [fastFlowKmh] 是目前所在快速路路段的 TDX 即時車流（見 TrafficService.currentFlowKmh），
  /// 沒有資料時為 null，此時行為與原本相同。
  /// [accuracyM] 是手機回報的定位精度，見 [maxSigmaM]；沒有時用 [sigmaM]。
  /// [sky] 是頭頂天空狀態，見 [skyPenalty]；unknown 時不影響。
  TrackedRoad? update(
    List<OsmRoad> roads,
    double lat,
    double lon, {
    double? headingDeg,
    double speedKmh = 0,
    double? fastFlowKmh,
    double? accuracyM,
    SkyView sky = SkyView.unknown,
  }) {
    final sigma = (accuracyM != null && accuracyM > sigmaM)
        ? math.min(accuracyM, maxSigmaM)
        : sigmaM;
    _recentSpeeds.add(speedKmh);
    if (_recentSpeeds.length > flowWindow) _recentSpeeds.removeAt(0);
    final flowMismatch = fastFlowKmh != null &&
        fastFlowKmh >= flowMinKmh &&
        _recentSpeeds.length >= flowWindow &&
        _recentSpeeds.reduce((a, b) => a + b) / _recentSpeeds.length < fastFlowKmh * flowRatio;

    final heading =
        (headingDeg != null && headingDeg >= 0 && speedKmh >= headingMinSpeedKmh)
            ? headingDeg
            : null;

    final obs = _observe(roads, lat, lon, heading, speedKmh, sigma);
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
    // 天空證據要「該是高架」與「該是地面」的候選各自是誰
    final (skyAgainst, skyToward) = _skyEvidence(obs, sky, lat, lon);
    _lastSkyApplied = skyAgainst.isNotEmpty ? sky : SkyView.unknown;
    final posterior = <String, double>{};
    double total = 0;

    for (final entry in obs.entries) {
      final id = entry.key;
      double prior;
      if (_belief.isEmpty) {
        prior = _isFastSystem(id) ? startFastPrior : 1.0;
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
            // 前一條路還能好好解釋目前位置就不准跳；不在候選中則視為無限遠
            final prevObs = obs[prevId];
            final prevDist = prevObs?.distance ?? double.infinity;
            double jump = prevDist > jumpDistanceM ? pJump : 0.0;
            // 車流反證：允許從快速路轉回正下方不相連的平面道路
            if (flowMismatch && _isFastSystem(prevId) && !_isFastSystem(id)) {
              jump = math.max(jump, flowJump);
            }
            // 天空反證：允許從被否定的那一層轉到重疊的另一層
            if (skyAgainst.contains(prevId) && skyToward.contains(id)) {
              jump = math.max(jump, skyJump);
            }
            t = jump;
          }
          prior += p * t;
        });
      }
      var p = prior * entry.value.likelihood;
      if (flowMismatch && _isMainline(id)) p *= flowPenalty;
      if (skyAgainst.contains(id)) p *= skyPenalty;
      posterior[id] = p;
      total += p;
    }

    if (total <= 0 || total.isNaN) {
      // 所有候選都不可能從前一狀態到達（例如長時間中斷後），重新開始
      reset();
      return update(roads, lat, lon,
          headingDeg: headingDeg,
          speedKmh: speedKmh,
          fastFlowKmh: fastFlowKmh,
          accuracyM: accuracyM,
          sky: sky);
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

  /// 目前位置的高架重疊狀態；附近只有單一層時為 null。
  ///
  /// 兩層都要有候選在 [overlapM] 內，而且走向相近（≤ 30°，雙向等價）：
  /// 從高架正下方橫越的路口只是一瞬間的交叉，不算重疊。
  LevelOverlap? levelOverlap(double lat, double lon) {
    String? bestE, bestG;
    double pE = 0, pG = 0, maxE = -1, maxG = -1;
    final bearings = <String, double>{};
    _lastObs.forEach((id, o) {
      if (o.distance > overlapM) return;
      final p = _belief[id] ?? 0;
      if (isElevated(o.road)) {
        pE += p;
        if (p > maxE) { maxE = p; bestE = id; }
      } else {
        pG += p;
        if (p > maxG) { maxG = p; bestG = id; }
      }
    });
    if (bestE == null || bestG == null) return null;
    for (final id in [bestE!, bestG!]) {
      final n = RoadMatcher.nearestOnRoad(_lastObs[id]!.road, lat, lon);
      if (n == null) return null;
      bearings[id] = n.bearing;
    }
    var diff = (bearings[bestE]! - bearings[bestG]!).abs() % 180;
    if (diff > 90) diff = 180 - diff;
    if (diff > 30) return null;
    final total = pE + pG;
    final e = _lastObs[bestE]!, g = _lastObs[bestG]!;
    return LevelOverlap(total > 0 ? pE / total : 0.5, TrackedRoad(e.road, maxE, e.distance),
        TrackedRoad(g.road, maxG, g.distance));
  }

  /// 最近一次 [update] 實際套用的天空證據（不在重疊路段時為 unknown），供紀錄與除錯
  SkyView get lastSkyApplied => _lastSkyApplied;
  SkyView _lastSkyApplied = SkyView.unknown;

  /// 天空證據：(要否定的候選, 重疊路段另一層的候選)，以道路識別表示。
  /// 不在重疊路段或沒有證據時兩者皆空。
  (Set<String>, Set<String>) _skyEvidence(
      Map<String, _Observation> obs, SkyView sky, double lat, double lon) {
    const none = (<String>{}, <String>{});
    if (sky == SkyView.unknown) return none;
    final elevated = <String, _Observation>{};
    final ground = <String, _Observation>{};
    obs.forEach((id, o) {
      if (o.distance > overlapM) return;
      (isElevated(o.road) ? elevated : ground)[id] = o;
    });
    if (elevated.isEmpty || ground.isEmpty) return none;
    if (sky == SkyView.blocked) return (elevated.keys.toSet(), ground.keys.toSet());
    // 頭頂開闊：只否定真的在橋面下方的地面道路
    final out = <String>{};
    ground.forEach((id, g) {
      final foot = _nearestPoint(g.road, lat, lon);
      if (foot == null) return;
      for (final e in elevated.values) {
        if (_distanceTo(e.road, foot.$1, foot.$2) <= underM) {
          out.add(id);
          return;
        }
      }
    });
    return out.isEmpty ? none : (out, elevated.keys.toSet());
  }

  /// [road] 上離 (lat, lon) 最近的點
  static (double, double)? _nearestPoint(OsmRoad road, double lat, double lon) {
    final mPerDegLon = 111320.0 * math.cos(lat * math.pi / 180.0);
    double best = double.infinity;
    (double, double)? out;
    for (final line in road.lines) {
      for (int i = 0; i + 3 < line.length; i += 2) {
        final ax = (line[i] - lon) * mPerDegLon, ay = (line[i + 1] - lat) * _mPerDegLat;
        final bx = (line[i + 2] - lon) * mPerDegLon, by = (line[i + 3] - lat) * _mPerDegLat;
        final dx = bx - ax, dy = by - ay;
        final lenSq = dx * dx + dy * dy;
        var t = lenSq == 0 ? 0.0 : -(ax * dx + ay * dy) / lenSq;
        if (t < 0) t = 0;
        if (t > 1) t = 1;
        final px = ax + t * dx, py = ay + t * dy;
        final d = px * px + py * py;
        if (d < best) {
          best = d;
          out = (lat + py / _mPerDegLat, lon + px / mPerDegLon);
        }
      }
    }
    return out;
  }

  /// (lat, lon) 到 [road] 的距離（公尺）
  static double _distanceTo(OsmRoad road, double lat, double lon) {
    final mPerDegLon = 111320.0 * math.cos(lat * math.pi / 180.0);
    double best = double.infinity;
    for (final line in road.lines) {
      for (int i = 0; i + 3 < line.length; i += 2) {
        final d = _pointSegmentDistance((line[i] - lon) * mPerDegLon, (line[i + 1] - lat) * _mPerDegLat,
            (line[i + 2] - lon) * mPerDegLon, (line[i + 3] - lat) * _mPerDegLat);
        if (d < best) best = d;
      }
    }
    return best;
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

  /// 車速遠超過某條路的速限時，降低「正在這條路上」的可能性
  double _speedCost(OsmRoad road, double speedKmh) {
    if (speedKmh < speedEvidenceMinKmh) return 0;
    final limit = SpeedLimitService.parseMaxspeed(road.maxspeed) ??
        SpeedLimitService.defaultLimitFor(road.highway);
    if (limit == null) return 0;
    final excess = speedKmh - limit - speedMarginKmh;
    if (excess <= 0) return 0;
    final cost = excess / speedScaleKmh;
    return cost > speedMaxPenalty ? speedMaxPenalty : cost;
  }

  Map<String, _Observation> _observe(
    List<OsmRoad> roads,
    double lat,
    double lon,
    double? heading,
    double speedKmh,
    double sigma,
  ) {
    final mPerDegLon = 111320.0 * math.cos(lat * math.pi / 180.0);
    final out = <String, _Observation>{};

    for (final road in roads) {
      final oneway = road.oneway == 'yes' || road.oneway == 'true' || road.oneway == '1';
      final reversed = road.oneway == '-1';
      final speedPenalty = _speedCost(road, speedKmh);

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

          double cost = d * d / (2 * sigma * sigma) + speedPenalty;
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
