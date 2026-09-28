// TDX 路段比對的評估。
//
// 兩組資料：
//   1. 沿 TDX 路段折線模擬整條路線行駛（加上時間相關的 GPS 誤差），
//      量測路段、方向、里程的正確率，並與 RoadRader 的羅盤四象限判向比較。
//   2. 台61 梧棲段真實路網軌跡（test/fixtures/wuqi_traces.json.gz），
//      串接 RoadTracker，確認走側車道時不會被當成快速公路主線。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/models/osm_road.dart';
import 'package:nx4board/models/tdx_section.dart';
import 'package:nx4board/services/osm_tile_service.dart';
import 'package:nx4board/services/road_tracker.dart';
import 'package:nx4board/services/traffic_matcher.dart';

import 'elevated_eval_test.dart' as ev;

OsmRoad _road(String ref, String highway) => OsmRoad(
      name: null,
      ref: ref,
      highway: highway,
      maxspeed: null,
      oneway: null,
      bridge: null,
      tunnel: null,
      layer: null,
      lines: [Float64List(0)],
    );

double _bearing(double lon1, double lat1, double lon2, double lat2) {
  final dx = (lon2 - lon1) * math.cos(lat1 * math.pi / 180);
  final dy = lat2 - lat1;
  return (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
}

double _angleDiff(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

/// RoadRader 前端的判向：航向切四象限，南北向道路只有 S 算里程遞增
int _roadRaderSign(double heading, bool eastWestRoad) {
  String dir;
  if (heading >= 45 && heading < 135) {
    dir = 'E';
  } else if (heading >= 135 && heading < 225) {
    dir = 'S';
  } else if (heading >= 225 && heading < 315) {
    dir = 'W';
  } else {
    dir = 'N';
  }
  if (eastWestRoad) {
    if (dir == 'N') dir = 'W';
    if (dir == 'S') dir = 'E';
    return dir == 'E' ? 1 : -1;
  }
  return dir == 'S' ? 1 : -1;
}

class _DriveResult {
  int points = 0;
  int matched = 0;
  int sectionCorrect = 0;
  int directionCorrect = 0;
  int roadRaderDirectionCorrect = 0;
  final kmErrors = <double>[];

  double pct(int n) => points == 0 ? 0 : n * 100 / points;
  double get kmErrP95 {
    if (kmErrors.isEmpty) return double.nan;
    final s = [...kmErrors]..sort();
    return s[(s.length * 0.95).floor().clamp(0, s.length - 1)];
  }
}

/// 沿 [line] 依序走完所有路段，每 [stepM] 公尺一點，GPS 誤差為一階自迴歸雜訊
_DriveResult _drive(TdxSectionIndex index, List<TdxSection> line, OsmRoad road,
    {required double sigmaM, required bool eastWest, int seed = 1, double stepM = 25}) {
  final rnd = math.Random(seed);
  double gauss() {
    final u1 = rnd.nextDouble().clamp(1e-12, 1.0);
    final u2 = rnd.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  final matcher = TrafficMatcher(index);
  final r = _DriveResult();
  // 一階自迴歸，相鄰點誤差相關（GPS 誤差不是白雜訊）
  const rho = 0.9;
  final innov = math.sqrt(1 - rho * rho);
  double ex = 0, ey = 0;

  for (final sec in line) {
    final p = sec.points;
    for (int i = 0; i + 3 < p.length; i += 2) {
      final segLen = sec.cumulativeM[i ~/ 2 + 1] - sec.cumulativeM[i ~/ 2];
      final heading = _bearing(p[i], p[i + 1], p[i + 2], p[i + 3]);
      for (double d = 0; d < segLen; d += stepM) {
        final t = segLen == 0 ? 0.0 : d / segLen;
        final lon = p[i] + (p[i + 2] - p[i]) * t;
        final lat = p[i + 1] + (p[i + 3] - p[i + 1]) * t;
        ex = rho * ex + innov * gauss() * sigmaM;
        ey = rho * ey + innov * gauss() * sigmaM;
        final kx = 111320.0 * math.cos(lat * math.pi / 180);
        final gLat = lat + ey / 110574.0;
        final gLon = lon + ex / kx;
        final gHeading = (heading + gauss() * 5 + 360) % 360;

        final m = matcher.update(gLat, gLon, road: road, headingDeg: gHeading, speedKmh: 80);
        r.points++;
        if (_roadRaderSign(gHeading, eastWest) == sec.kmSign) r.roadRaderDirectionCorrect++;
        if (m == null) continue;
        r.matched++;
        if (identical(m.section, sec)) r.sectionCorrect++;
        if (m.section.kmSign == sec.kmSign) r.directionCorrect++;
        r.kmErrors.add((m.km - sec.kmAt(sec.cumulativeM[i ~/ 2] + d)).abs());
      }
    }
  }
  return r;
}

void main() {
  late TdxSectionIndex index;

  setUpAll(() {
    index = TdxSectionIndex.decode(File('assets/tdx_sections.json.gz').readAsBytesSync());
  });

  group('accepts', () {
    TdxSection sec(String system, String ref) => TdxSection(
          id: 'x',
          liveApi: system,
          system: system,
          ref: ref,
          roadName: '',
          direction: 'N',
          startKm: 0,
          endKm: 1,
          speedLimit: 0,
          vdLinks: const {},
          points: Float64List(4),
        );

    test('國道只對 motorway', () {
      expect(TrafficMatcher.accepts(sec('F', '1'), _road('1', 'motorway')), isTrue);
      expect(TrafficMatcher.accepts(sec('F', '1'), _road('1', 'primary')), isFalse);
      expect(TrafficMatcher.accepts(sec('F', '1'), _road('1', 'motorway_link')), isFalse);
    });

    test('快速公路不對側車道', () {
      expect(TrafficMatcher.accepts(sec('P', '61'), _road('61', 'trunk')), isTrue);
      expect(TrafficMatcher.accepts(sec('P', '61'), _road('61', 'primary')), isFalse);
      expect(TrafficMatcher.accepts(sec('P', '61'), _road('61', 'trunk_link')), isFalse);
    });

    test('一般省道接受平面道路，編號要相符', () {
      expect(TrafficMatcher.accepts(sec('P', '1'), _road('1', 'primary')), isTrue);
      expect(TrafficMatcher.accepts(sec('P', '1'), _road('1;北77', 'primary')), isTrue);
      expect(TrafficMatcher.accepts(sec('P', '1'), _road('3', 'primary')), isFalse);
      // 台1 與國1 同編號，靠系統分開
      expect(TrafficMatcher.accepts(sec('P', '1'), _road('1', 'motorway')), isFalse);
    });
  });

  test('整條路線模擬行駛：路段、方向、里程', () {
    final cases = [
      ('台61線', _road('61', 'trunk'), false),
      ('台74線', _road('74', 'trunk'), false),
      ('台64線', _road('64', 'trunk'), true),
      ('國道1號', _road('1', 'motorway'), false),
      ('國道3號', _road('3', 'motorway'), false),
    ];
    for (final (name, road, eastWest) in cases) {
      for (final sign in [1, -1]) {
        final any = index.sections.firstWhere((s) => s.roadName == name && s.kmSign == sign);
        final line = index.lineOf(any);
        for (final sigma in [6.0, 15.0]) {
          final r = _drive(index, line, road, sigmaM: sigma, eastWest: eastWest);
          // ignore: avoid_print
          print('  $name ${sign > 0 ? '里程遞增' : '里程遞減'} σ=${sigma.toInt()}m'
              '  ${r.points} 點  比對 ${r.pct(r.matched).toStringAsFixed(1)}%'
              '  路段 ${r.pct(r.sectionCorrect).toStringAsFixed(1)}%'
              '  方向 ${r.pct(r.directionCorrect).toStringAsFixed(1)}%'
              '  （RoadRader 判向 ${r.pct(r.roadRaderDirectionCorrect).toStringAsFixed(1)}%）'
              '  里程誤差 p95 ${(r.kmErrP95 * 1000).toStringAsFixed(0)} m');

          expect(r.directionCorrect / r.points, greaterThan(0.95), reason: '$name $sign σ$sigma');
          expect(r.matched / r.points, greaterThan(0.95), reason: '$name $sign σ$sigma');
          expect(r.kmErrP95, lessThan(0.2), reason: '$name $sign σ$sigma');
        }
      }
    }
  });

  test('前方路段依行車方向排序且不含後方', () {
    final any = index.sections.firstWhere((s) => s.roadName == '台61線' && s.kmSign == -1);
    final line = index.lineOf(any);
    final sec = line[line.length ~/ 2];
    final matcher = TrafficMatcher(index);
    final p = sec.points;
    final mid = p.length ~/ 4 * 2;
    final heading = _bearing(p[mid - 2], p[mid - 1], p[mid], p[mid + 1]);
    final m = matcher.update(p[mid + 1], p[mid], road: _road('61', 'trunk'), headingDeg: heading, speedKmh: 80);
    expect(m, isNotNull);

    final ahead = matcher.ahead(10);
    expect(ahead.first.distanceM, 0);
    for (int i = 1; i < ahead.length; i++) {
      expect(ahead[i].distanceM, greaterThanOrEqualTo(ahead[i - 1].distanceM));
      expect(ahead[i].section.kmSign, -1);
      expect(ahead[i].section.startKm, lessThanOrEqualTo(m!.km + 0.001));
    }
    expect(ahead.last.distanceM, lessThanOrEqualTo(10000));
    // 台61 路段中位長度 0.7 km，10 km 內應有十段上下
    expect(ahead.length, greaterThan(5));
  });

  test('台61 梧棲段：側車道不當成主線，主線方向正確', () async {
    final tiles = OsmTileService();
    await tiles.initFromFile('assets/speed_tiles.bin');
    final traces = ev.Trace.load('test/fixtures/wuqi_traces.json.gz');

    for (final t in traces) {
      final tracker = RoadTracker();
      final matcher = TrafficMatcher(index);
      int onMain = 0, mainMatched = 0, mainWrongDir = 0;
      int onSurface = 0, surfaceMatched = 0;

      for (final p in t.points) {
        final roads = await tiles.tileAt(p.lat, p.lon);
        if (roads == null) continue;
        final tracked = tracker.update(roads, p.lat, p.lon, headingDeg: p.heading, speedKmh: p.speedKmh);
        // 與 TrafficService 相同：高架／平面沒把握時不比對
        final road = tracker.isSystemConfident ? tracked?.road : null;
        final m = matcher.update(p.lat, p.lon, road: road, headingDeg: p.heading, speedKmh: p.speedKmh);

        final truthMain = p.truthRef == '61' && p.truthHighway == 'trunk';
        if (truthMain) {
          onMain++;
          if (m != null) {
            mainMatched++;
            // 以真實航向對照路段頭尾方位判斷方向是否正確
            final sp = m.section.points;
            final b = _bearing(sp[0], sp[1], sp[sp.length - 2], sp[sp.length - 1]);
            if (_angleDiff(b, p.heading) > 90) mainWrongDir++;
          }
        } else {
          onSurface++;
          if (m != null && TrafficMatcher.isExpresswayRef(m.section.ref)) surfaceMatched++;
        }
      }
      // ignore: avoid_print
      print('  ${t.label.padRight(18)} 主線 $onMain 點 比對 ${onMain == 0 ? '-' : (mainMatched * 100 / onMain).toStringAsFixed(1)}%'
          ' 方向錯 $mainWrongDir  平面 $onSurface 點 誤對主線 $surfaceMatched');

      expect(mainWrongDir, 0, reason: t.label);
      // 側車道誤對到快速公路主線，路況就會報成高架上的
      expect(surfaceMatched / math.max(1, onSurface), lessThan(0.10), reason: t.label);
    }
  });
}
