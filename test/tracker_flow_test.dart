// RoadTracker 的車流佐證（fastFlowKmh）。
//
// 台61 梧棲港埠路在高架正下方（相距 9～25 公尺），時速 50 對兩條路都不算超速，
// GPS 往高架偏幾秒就會被困在高架上。TDX 車流 90 而自己一直 50 是反證。
// 路線由 OSM 路網規劃：港埠路三段往南 → 梧棲交流道南下入口 → 台61 南下
// （test/fixtures/gangbu_route.json.gz，每秒一點）。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/services/osm_tile_service.dart';
import 'package:nx4board/services/road_tracker.dart';

import 'elevated_eval_test.dart' as ev;

const _fast = {'motorway', 'trunk', 'motorway_link', 'trunk_link'};

void main() {
  final tiles = OsmTileService();
  setUpAll(() => tiles.initFromFile('assets/speed_tiles.bin'));

  /// 港埠路上（還沒進匝道）被有把握地判在快速路上的秒數，20 個隨機誤差各算一次
  Future<List<int>> gangbu(double sigma, double? flow) async {
    final pts = (jsonDecode(utf8.decode(gzip.decode(File('test/fixtures/gangbu_route.json.gz').readAsBytesSync()))) as List)
        .cast<Map<String, dynamic>>();
    final out = <int>[];
    for (int seed = 0; seed < 20; seed++) {
      final tracker = RoadTracker();
      final rnd = math.Random(seed);
      double ex = 0, ey = 0;
      double g() => math.sqrt(-2 * math.log(rnd.nextDouble().clamp(1e-12, 1.0))) * math.cos(2 * math.pi * rnd.nextDouble());
      int wrong = 0;
      for (final p in pts) {
        if ((p['road'] as String) != '港埠路三段' && !(p['road'] as String).startsWith('港埠路')) break;
        ex = 0.9 * ex + 0.436 * g() * sigma;
        ey = 0.9 * ey + 0.436 * g() * sigma;
        final lat = (p['lat'] as num).toDouble() + ey / 110574;
        final lon = (p['lon'] as num).toDouble() + ex / 101500;
        final roads = await tiles.tileAt(lat, lon);
        final tr = tracker.update(roads ?? const [], lat, lon,
            headingDeg: (p['heading'] as num).toDouble(), speedKmh: (p['speedKmh'] as num).toDouble(), fastFlowKmh: flow);
        if (tr != null && tracker.isSystemConfident && _fast.contains(tr.road.highway)) wrong++;
      }
      out.add(wrong);
    }
    return out;
  }

  test('港埠路：車流 90 時不會長時間困在上方高架', () async {
    for (final sigma in [6.0, 10.0, 15.0]) {
      final off = await gangbu(sigma, null);
      final on = await gangbu(sigma, 90);
      final maxOff = off.reduce(math.max), maxOn = on.reduce(math.max);
      final sumOff = off.reduce((a, b) => a + b), sumOn = on.reduce((a, b) => a + b);
      // ignore: avoid_print
      print('  σ=${sigma.toInt()}m  誤判合計 $sumOff → $sumOn 秒，最長 $maxOff → $maxOn 秒');
      expect(maxOn, lessThanOrEqualTo(45), reason: 'σ$sigma');
      expect(sumOn, lessThanOrEqualTo(sumOff), reason: 'σ$sigma');
    }
  });

  test('真的在高架上：車流與車速相符時不受影響', () async {
    final traces = [
      ...ev.Trace.load('test/fixtures/wuqi_traces.json.gz').where((t) => t.label.startsWith('W1')),
      ...ev.Trace.load('test/fixtures/elevated_traces.json').where((t) => t.label.startsWith('S3')),
    ];
    for (final t in traces) {
      int confOff = 0, confOn = 0, n = 0;
      for (final flow in [null, 90.0]) {
        final tracker = RoadTracker();
        for (final p in t.points) {
          final roads = await tiles.tileAt(p.lat, p.lon);
          if (roads == null) continue;
          final m = tracker.update(roads, p.lat, p.lon, headingDeg: p.heading, speedKmh: p.speedKmh,
              // 只有在快速路上才會有車流（路況服務比對到主線時才有值）
              fastFlowKmh: p.truthIsFast ? flow : null);
          if (flow == null) n++;
          if (m != null && _fast.contains(m.road.highway) != p.truthIsFast) {
            if (flow == null) { confOff++; } else { confOn++; }
          }
        }
      }
      // ignore: avoid_print
      print('  ${t.label.padRight(18)} 高速/平面誤判 ${(confOff * 100 / n).toStringAsFixed(1)}% → ${(confOn * 100 / n).toStringAsFixed(1)}%');
      expect(confOn, lessThanOrEqualTo(confOff + n ~/ 100), reason: t.label);
    }
  });

  // 手機回報的定位精度（accuracyM）：訊號差時用較大的 σ，更依賴連續性。
  // 軌跡沒有真實的回報精度，這裡假設手機回報 20 m（σ 15 m 的軌跡）。
  test('定位精度：側車道改善、上高架不明顯變差', () async {
    for (final t in ev.Trace.load('test/fixtures/wuqi_traces.json.gz').where((t) => t.label.contains('15m'))) {
      final conf = <double?, double>{};
      for (final acc in [null, 20.0]) {
        final tracker = RoadTracker();
        int n = 0, bad = 0;
        for (final p in t.points) {
          final roads = await tiles.tileAt(p.lat, p.lon);
          if (roads == null) continue;
          final m = tracker.update(roads, p.lat, p.lon, headingDeg: p.heading, speedKmh: p.speedKmh, accuracyM: acc);
          n++;
          if (m != null && _fast.contains(m.road.highway) != p.truthIsFast) bad++;
        }
        conf[acc] = bad * 100 / n;
      }
      // ignore: avoid_print
      print('  ${t.label.padRight(18)} 精度 20 m：高速/平面誤判 ${conf[null]!.toStringAsFixed(1)}% → ${conf[20.0]!.toStringAsFixed(1)}%');
      if (t.label.contains('W3')) expect(conf[20.0]!, lessThan(conf[null]!), reason: t.label);
      expect(conf[20.0]!, lessThanOrEqualTo(conf[null]! + 1.0), reason: t.label);
    }
  });
}
