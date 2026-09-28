// 閘道前預知路況：沿匝道追到主線匯入點，並對到正確方向的 TDX 路段。
//
// 用兩組「平面 → 匝道 → 高架主線」的軌跡（test/fixtures/README.md）：
//   W1 台61 梧棲（高架與側車道相距不到 30 公尺）、S1 台74。
// 量測：比實際上主線早多少秒就預知到正確的主線與方向，
// 以及預知的路段與上了主線之後 TrafficMatcher 實際對到的路段是否同一條路線。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/models/osm_road.dart';
import 'package:nx4board/models/tdx_section.dart';
import 'package:nx4board/services/osm_tile_service.dart';
import 'package:nx4board/services/ramp_finder.dart';
import 'package:nx4board/services/road_tracker.dart';
import 'package:nx4board/services/traffic_matcher.dart';

import 'elevated_eval_test.dart' as ev;

/// 載入周圍 3x3 tile 後回傳全部道路（App 端由 prefetchAround 預先載入）
Future<List<OsmRoad>> _roadsAround(OsmTileService tiles, double lat, double lon) async {
  for (final dy in const [-0.02, 0.0, 0.02]) {
    for (final dx in const [-0.022, 0.0, 0.022]) {
      await tiles.tileAt(lat + dy, lon + dx);
    }
  }
  return tiles.cachedRoadsAround(lat, lon);
}

void main() {
  late TdxSectionIndex index;
  final tiles = OsmTileService();

  setUpAll(() async {
    index = TdxSectionIndex.decode(File('assets/tdx_sections.json.gz').readAsBytesSync());
    await tiles.initFromFile('assets/speed_tiles.bin');
  });

  /// 軌跡第一次上主線之前，最後一段連續預知的評估
  Future<void> run(ev.Trace t) async {
    final tracker = RoadTracker();
    final matcher = TrafficMatcher(index);

    int? enterIdx;
    TdxSection? actual;
    final predicted = <int, List<TdxSection>>{};
    final lookAhead = <int, double>{};

    for (var i = 0; i < t.points.length; i++) {
      final p = t.points[i];
      final roads = await tiles.tileAt(p.lat, p.lon);
      if (roads == null) continue;
      final tracked = tracker.update(roads, p.lat, p.lon, headingDeg: p.heading, speedKmh: p.speedKmh);
      final road = tracker.isSystemConfident ? tracked?.road : null;

      final onMain = p.truthHighway == 'motorway' || p.truthHighway == 'trunk';
      if (onMain) {
        enterIdx ??= i;
        final m = matcher.update(p.lat, p.lon, road: road, headingDeg: p.heading, speedKmh: p.speedKmh);
        if (m != null) {
          actual ??= m.section;
          break;
        }
        continue;
      }
      if (enterIdx != null || road == null) continue;

      final around = await _roadsAround(tiles, p.lat, p.lon);
      final targets = RampFinder.find(around, p.lat, p.lon, tracked: road, headingDeg: p.heading);
      final secs = <TdxSection>[];
      for (final tg in targets) {
        final pos = matcher.locate(tg.lat, tg.lon, tg.mainRoad, tg.headingDeg);
        if (pos != null) secs.add(pos.section);
      }
      if (secs.isNotEmpty) {
        predicted[i] = secs;
        lookAhead[i] = targets.map((x) => x.entryDistanceM + x.rampLengthM).reduce((a, b) => a > b ? a : b);
      }
    }

    expect(actual, isNotNull, reason: '${t.label}：上主線後沒有對到 TDX 路段');
    final a = actual!;
    bool correct(TdxSection s) => s.roadName == a.roadName && s.kmSign == a.kmSign;

    // 最後一段連續預知：由上主線前最後一個有預知的點往前回推
    final last = predicted.keys.reduce((x, y) => x > y ? x : y);
    var first = last;
    while (predicted.containsKey(first - 1)) {
      first--;
    }
    final block = [for (var i = first; i <= last; i++) predicted[i]!];
    final wrong = block.where((s) => !s.any(correct)).length;
    final both = block.where((s) => s.length > 1).length;
    // ignore: avoid_print
    print('  ${t.label.padRight(18)} ${a.roadName}${a.kmSign > 0 ? '里程遞增' : '里程遞減'}：'
        '提前 ${enterIdx! - first} 秒、${lookAhead[first]!.round()} m 開始預知，'
        '連續 ${block.length} 秒（兩方向並列 $both 秒、錯誤 $wrong 秒），'
        '最後預知到上主線間隔 ${enterIdx - last} 秒');

    expect(wrong, 0, reason: t.label);
    expect(block.length, greaterThanOrEqualTo(10), reason: t.label);
  }

  test('台61 梧棲：從側車道上高架前預知', () async {
    for (final t in ev.Trace.load('test/fixtures/wuqi_traces.json.gz')) {
      if (!t.label.contains('W1')) continue;
      await run(t);
    }
  });

  // S1 實際路線是「平面 → 國4 → 台74 系統交流道 → 台74」，第一個上的主線是國4
  test('S1：平面經匝道上國4 前預知', () async {
    for (final t in ev.Trace.load('test/fixtures/elevated_traces.json')) {
      if (!t.label.contains('S1')) continue;
      await run(t);
    }
  });

  // 在主線上接近系統交流道：S1 在國4 上，之後經系統交流道上台74
  test('S1：國4 主線上預知台74 系統交流道', () async {
    final t = ev.Trace.load('test/fixtures/elevated_traces.json').firstWhere((t) => t.label.startsWith('S1'));
    final tracker = RoadTracker();
    final matcher = TrafficMatcher(index);
    final predicted = <int, List<TdxSection>>{};
    final range = <int, double>{};
    int? leaveMain;
    TdxSection? actual;

    for (var i = 0; i < t.points.length; i++) {
      final p = t.points[i];
      final roads = await tiles.tileAt(p.lat, p.lon);
      if (roads == null) continue;
      final tracked = tracker.update(roads, p.lat, p.lon, headingDeg: p.heading, speedKmh: p.speedKmh);
      final road = tracker.isSystemConfident ? tracked?.road : null;

      if (p.truthRef == '74' && p.truthHighway == 'trunk') {
        final m = matcher.update(p.lat, p.lon, road: road, headingDeg: p.heading, speedKmh: p.speedKmh);
        if (m != null) {
          actual = m.section;
          break;
        }
        continue;
      }
      final onFreeway4 = p.truthRef == '4' && p.truthHighway == 'motorway';
      if (!onFreeway4) {
        if (predicted.isNotEmpty) leaveMain ??= i;
        continue;
      }
      if (road == null || road.highway != 'motorway') continue;
      final around = await _roadsAround(tiles, p.lat, p.lon);
      final targets = RampFinder.find(around, p.lat, p.lon, tracked: road, headingDeg: p.heading);
      final secs = <TdxSection>[];
      for (final tg in targets) {
        final pos = matcher.locate(tg.lat, tg.lon, tg.mainRoad, tg.headingDeg);
        if (pos != null && pos.section.roadName != '國道4號') secs.add(pos.section);
      }
      if (secs.isNotEmpty) {
        predicted[i] = secs;
        range[i] = targets.map((x) => x.entryDistanceM).reduce((a, b) => a > b ? a : b);
      }
    }

    expect(actual, isNotNull, reason: '沒有上到台74');
    final a = actual!;
    final hits = predicted.entries.where((e) => e.value.any((s) => s.roadName == a.roadName && s.kmSign == a.kmSign));
    expect(hits, isNotEmpty, reason: '國4 上沒有預知到台74 ${a.kmSign > 0 ? '里程遞增' : '里程遞減'}');
    final first = hits.map((e) => e.key).reduce((x, y) => x < y ? x : y);
    final wrongRoad = predicted.values.expand((s) => s).where((s) => s.roadName == '國道4號').length;
    // ignore: avoid_print
    print('  國4 上提前 ${(leaveMain ?? first) - first} 秒、離出口 ${range[first]!.round()} m 預知到 '
        '${a.roadName}${a.kmSign > 0 ? '里程遞增' : '里程遞減'}（預知 ${predicted.length} 秒）');
    expect(wrongRoad, 0);
  });
}
