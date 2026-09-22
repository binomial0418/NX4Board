// 高架／平面判別的評估工具。
//
// 軌跡由真實 OSM 路網產生（見 test/fixtures/README.md），含時間相關的 GPS 誤差
// 與依 layer 推算的高度。每一點都附有真實所在道路，用來計算比對正確率。
//
//   flutter test test/elevated_eval_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/models/osm_road.dart';
import 'package:nx4board/services/osm_tile_service.dart';
import 'package:nx4board/services/road_matcher.dart';
import 'package:nx4board/services/road_tracker.dart';
import 'package:nx4board/services/speed_limit_service.dart';

const _fastClasses = {'motorway', 'trunk', 'motorway_link', 'trunk_link'};

class TracePoint {
  final double lat, lon, heading, speedKmh, baroAlt;
  final String? truthName, truthRef, truthHighway;
  final int? truthLimit;

  TracePoint.fromJson(Map<String, dynamic> j)
      : lat = (j['lat'] as num).toDouble(),
        lon = (j['lon'] as num).toDouble(),
        heading = (j['heading'] as num).toDouble(),
        speedKmh = (j['speedKmh'] as num).toDouble(),
        baroAlt = (j['baroAlt'] as num).toDouble(),
        truthName = j['truth']['name'] as String?,
        truthRef = j['truth']['ref'] as String?,
        truthHighway = j['truth']['h'] as String?,
        truthLimit = j['truth']['limit'] as int?;

  bool isSameRoad(OsmRoad road) =>
      (truthRef != null && road.ref == truthRef) ||
      (truthName != null && road.name == truthName);

  bool get hasIdentity => truthRef != null || truthName != null;
  bool get truthIsFast => _fastClasses.contains(truthHighway);
}

class Trace {
  final String label;
  final List<TracePoint> points;
  Trace(this.label, this.points);

  static List<Trace> load(String path) {
    final bytes = File(path).readAsBytesSync();
    final text = path.endsWith('.gz') ? utf8.decode(gzip.decode(bytes)) : utf8.decode(bytes);
    return (jsonDecode(text) as List<dynamic>).map((t) {
      final m = t as Map<String, dynamic>;
      return Trace(
        m['label'] as String,
        (m['points'] as List<dynamic>)
            .map((e) => TracePoint.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
    }).toList();
  }
}

/// 一種比對策略：輸入一個定位點，回傳比對到的道路（可為 null）
typedef Strategy = OsmRoad? Function(TracePoint p, List<OsmRoad> roads);

class Report {
  int total = 0, identified = 0, correct = 0, noMatch = 0;
  int limitTotal = 0, limitCorrect = 0, flips = 0;

  /// 高速路（國道／快速道路及其匝道）與平面道路互相誤判的點數。
  /// 這直接決定速限與測速照相過濾是否正確。
  int classConfusion = 0;
  String? _last;

  void add(TracePoint p, OsmRoad? m) {
    total++;
    final key = m == null ? null : '${m.name}|${m.ref}';
    if (_last != null && key != null && key != _last) flips++;
    if (key != null) _last = key;

    if (m == null) noMatch++;
    if (p.hasIdentity) {
      identified++;
      if (m != null && p.isSameRoad(m)) correct++;
    }
    if (m != null && _fastClasses.contains(m.highway) != p.truthIsFast) classConfusion++;
    if (p.truthLimit != null) {
      limitTotal++;
      if (m != null) {
        final lim = SpeedLimitService.parseMaxspeed(m.maxspeed) ??
            SpeedLimitService.defaultLimitFor(m.highway);
        if (lim == p.truthLimit) limitCorrect++;
      }
    }
  }

  void merge(Report o) {
    total += o.total;
    identified += o.identified;
    correct += o.correct;
    noMatch += o.noMatch;
    limitTotal += o.limitTotal;
    limitCorrect += o.limitCorrect;
    flips += o.flips;
    classConfusion += o.classConfusion;
  }

  static String _pct(int a, int b) =>
      b == 0 ? '  -  ' : '${(a * 100 / b).toStringAsFixed(1)}%'.padLeft(6);

  String row(String label) => '  ${label.padRight(22)}'
      ' 道路 ${_pct(correct, identified)}'
      '  速限 ${_pct(limitCorrect, limitTotal)}'
      '  高速/平面誤判 ${_pct(classConfusion, total)}'
      '  跳動 ${flips.toString().padLeft(4)}'
      '  無比對 ${noMatch.toString().padLeft(3)}';
}

Future<Report> run(Trace trace, Strategy Function() make, OsmTileService tiles) async {
  final strategy = make(); // 每條軌跡重新建立，狀態不跨軌跡
  final r = Report();
  for (final p in trace.points) {
    final roads = await tiles.tileAt(p.lat, p.lon) ?? const <OsmRoad>[];
    r.add(p, strategy(p, roads));
  }
  return r;
}

/// 目前上線的做法：每點獨立取最近道路，車速夠才用方向
Strategy baseline() => (p, roads) {
      final heading = p.speedKmh >= RoadMatcher.headingMinSpeedKmh ? p.heading : null;
      return RoadMatcher.nearest(roads, p.lat, p.lon, heading)?.road;
    };

Strategy Function() tracker([RoadTracker Function()? factory]) => () {
      final t = factory?.call() ?? RoadTracker();
      return (p, roads) =>
          t.update(roads, p.lat, p.lon, headingDeg: p.heading, speedKmh: p.speedKmh)?.road;
    };

Future<Map<String, Report>> evaluate(Map<String, Strategy Function()> strategies) async {
  final tiles = OsmTileService();
  await tiles.initFromFile('assets/speed_tiles.bin');
  final scenarios = Trace.load('test/fixtures/elevated_traces.json');
  final validation = Trace.load('test/fixtures/validation_traces.json.gz');
  final out = <String, Report>{};

  for (final s in scenarios) {
    // ignore: avoid_print
    print(s.label);
    for (final e in strategies.entries) {
      final r = await run(s, e.value, tiles);
      out['${s.label.substring(0, 2)}/${e.key}'] = r;
      // ignore: avoid_print
      print(r.row(e.key));
    }
  }
  // ignore: avoid_print
  print('驗證集 ${validation.length} 條隨機路線（合計）');
  for (final e in strategies.entries) {
    final total = Report();
    for (final v in validation) {
      total.merge(await run(v, e.value, tiles));
    }
    out['驗證/${e.key}'] = total;
    // ignore: avoid_print
    print(total.row(e.key));
  }
  return out;
}

void main() {
  test('高架／平面判別：道路追蹤優於逐點比對，且不退步', () async {
    final r = await evaluate({
      '逐點最近': baseline,
      '道路追蹤': tracker(),
    });

    double confusion(String k) => r[k]!.classConfusion / r[k]!.total;
    double limit(String k) => r[k]!.limitCorrect / r[k]!.limitTotal;

    // 高架情境：高速/平面誤判需壓在 2% 以下
    for (final s in ['S1', 'S2', 'S3']) {
      expect(confusion('$s/道路追蹤'), lessThan(0.02), reason: '$s 高速/平面誤判');
    }
    // 一般市區路線：不能因為黏著性而變差
    expect(limit('驗證/道路追蹤'), greaterThan(limit('驗證/逐點最近')));
    expect(confusion('驗證/道路追蹤'), lessThan(confusion('驗證/逐點最近')));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
