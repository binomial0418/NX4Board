// 台61 梧棲段的迴歸測試。
//
// 實車回報：在台61 高架與正下方側車道之間判斷不準，且從平面上高架後
// 開了近一公里才切換。這一段的幾何是最壞情況——高架與側車道相距不到
// 30 公尺，位置資訊不足以分辨，只能靠連續性與車速證據。
//
// 軌跡由該路段的真實 OSM 路網產生，見 test/fixtures/README.md。
import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/models/osm_road.dart';
import 'package:nx4board/services/osm_tile_service.dart';
import 'package:nx4board/services/road_tracker.dart';

import 'elevated_eval_test.dart' as ev;

const _fast = {'motorway', 'trunk', 'motorway_link', 'trunk_link'};

class _Result {
  int points = 0;
  int confusion = 0;
  int correct = 0;
  int identified = 0;

  /// 實際進入台61 的秒數與追蹤器判定的秒數
  int? truthEnter;
  int? trackedEnter;

  int? get delaySeconds =>
      (truthEnter == null || trackedEnter == null) ? null : trackedEnter! - truthEnter!;
}

Future<_Result> _run(ev.Trace trace, OsmTileService tiles) async {
  final tracker = RoadTracker();
  final r = _Result();

  for (var i = 0; i < trace.points.length; i++) {
    final p = trace.points[i];
    final roads = await tiles.tileAt(p.lat, p.lon);
    if (roads == null) continue;

    final m = tracker.update(roads, p.lat, p.lon,
        headingDeg: p.heading, speedKmh: p.speedKmh);
    r.points++;

    if (p.truthRef == '61' && r.truthEnter == null) r.truthEnter = i;
    if (m != null) {
      if (m.road.ref == '61' && r.trackedEnter == null) r.trackedEnter = i;
      if (_fast.contains(m.road.highway) != p.truthIsFast) r.confusion++;
    }
    if (p.hasIdentity) {
      r.identified++;
      if (m != null && p.isSameRoad(m.road)) r.correct++;
    }
  }
  return r;
}

void main() {
  test('台61 梧棲段：上高架要即時切換', () async {
    final tiles = OsmTileService();
    await tiles.initFromFile('assets/speed_tiles.bin');
    final traces = ev.Trace.load('test/fixtures/wuqi_traces.json.gz');

    for (final t in traces) {
      final r = await _run(t, tiles);
      // ignore: avoid_print
      print('  ${t.label.padRight(18)} 道路 ${(r.correct * 100 / r.identified).toStringAsFixed(1)}%'
          '  高速/平面誤判 ${(r.confusion * 100 / r.points).toStringAsFixed(1)}%'
          '  上高架延遲 ${r.delaySeconds ?? '-'} 秒');

      final confusion = r.confusion / r.points;
      final severe = t.label.contains('15m'); // 高架下 GPS 被遮蔽的最壞情況

      if (t.label.contains('W1')) {
        // 上高架必須幾秒內切換，不能像實車回報那樣拖到將近一公里
        expect(r.delaySeconds, isNotNull, reason: '${t.label}：完全沒判定上高架');
        expect(r.delaySeconds!, lessThanOrEqualTo(severe ? 30 : 10), reason: t.label);
        expect(r.delaySeconds!, greaterThanOrEqualTo(0),
            reason: '${t.label}：不該在實際上高架之前就誤判');
        expect(confusion, lessThan(0.10), reason: t.label);
      } else {
        // 全程走高架下方的側車道，不該被誤判成在高架上
        expect(confusion, lessThan(severe ? 0.10 : 0.05), reason: t.label);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
