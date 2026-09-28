// TDX 呼叫頻率：沿整條路線模擬行駛，統計任意 60 秒內的 HTTP 請求數。
//
// TDX 免費會員限制每分鐘 5 次。假 API 依 TdxClient 的分批規則（每批
// TdxClient.chunkSize 個 ID 一個請求）換算成實際請求數，時鐘由測試推進。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/models/osm_road.dart';
import 'package:nx4board/models/tdx_section.dart';
import 'package:nx4board/services/osm_tile_service.dart';
import 'package:nx4board/services/road_tracker.dart';
import 'package:nx4board/services/tdx_client.dart';
import 'package:nx4board/services/traffic_service.dart';

import 'elevated_eval_test.dart' as ev;

class _FakeApi implements TdxApi {
  final DateTime Function() clock;
  final List<DateTime> calls = [];

  /// Live/Highway 沒有路段車速的路線（實際上是台66～88）
  final Set<String> noSectionLive;
  final Map<String, TdxSection> byId;

  _FakeApi(this.clock, this.noSectionLive, this.byId);

  void _record(int ids) {
    final n = (ids / TdxClient.chunkSize).ceil();
    for (int i = 0; i < n; i++) {
      calls.add(clock());
    }
  }

  @override
  Future<Map<String, double>> sectionSpeeds(String api, List<String> ids) async {
    _record(ids.length);
    return {
      for (final id in ids)
        if (!noSectionLive.contains(byId[id]?.roadName)) id: 80.0,
    };
  }

  @override
  Future<Map<String, Map<String, double>>> vdLinkSpeeds(List<String> vdIds) async {
    _record(vdIds.length);
    return {};
  }

  int maxInWindow(Duration w) {
    int best = 0, j = 0;
    for (int i = 0; i < calls.length; i++) {
      while (calls[i].difference(calls[j]) >= w) {
        j++;
      }
      best = math.max(best, i - j + 1);
    }
    return best;
  }
}

OsmRoad _road(String ref, String highway) => OsmRoad(
      name: null, ref: ref, highway: highway, maxspeed: null, oneway: null,
      bridge: null, tunnel: null, layer: null, lines: [Float64List(0)]);

double _bearing(double lon1, double lat1, double lon2, double lat2) {
  final dx = (lon2 - lon1) * math.cos(lat1 * math.pi / 180);
  return (math.atan2(dx, lat2 - lat1) * 180 / math.pi + 360) % 360;
}

void main() {
  late TdxSectionIndex index;
  setUpAll(() {
    index = TdxSectionIndex.decode(File('assets/tdx_sections.json.gz').readAsBytesSync());
  });

  Future<void> drive(String roadName, OsmRoad road, double kmh) async {
    var now = DateTime(2026, 9, 28, 8);
    final byId = {for (final s in index.sections) s.id: s};
    final api = _FakeApi(() => now, {
      for (final n in [66, 68, 72, 74, 76, 78, 82, 84, 86, 88]) '台$n線',
    }, byId);
    final svc = TrafficService()..setUpForTest(index, api, () => now);

    final line = index.lineOf(index.sections.firstWhere((s) => s.roadName == roadName && s.kmSign == 1));
    final step = kmh / 3.6; // 每秒一個定位點
    int seconds = 0, withData = 0;
    double carry = 0;
    for (final sec in line) {
      final p = sec.points;
      for (int i = 0; i + 3 < p.length; i += 2) {
        final segLen = sec.cumulativeM[i ~/ 2 + 1] - sec.cumulativeM[i ~/ 2];
        final h = _bearing(p[i], p[i + 1], p[i + 2], p[i + 3]);
        double d = carry;
        for (; d < segLen; d += step) {
          final t = d / segLen;
          svc.update(p[i + 1] + (p[i + 3] - p[i + 1]) * t, p[i] + (p[i + 2] - p[i]) * t,
              road: road, headingDeg: h, speedKmh: kmh, roadLimit: 90);
          await Future<void>.delayed(Duration.zero); // 讓假 API 的回應進來
          now = now.add(const Duration(seconds: 1));
          seconds++;
          if (svc.state?.segments.first.speed != null) withData++;
        }
        carry = d - segLen;
      }
    }
    final perMin = api.calls.length / (seconds / 60);
    // ignore: avoid_print
    print('  $roadName ${kmh.round()} km/h ${(seconds / 60).round()} 分鐘：'
        '共 ${api.calls.length} 次，平均每分鐘 ${perMin.toStringAsFixed(2)} 次，'
        '任意 60 秒最多 ${api.maxInWindow(const Duration(seconds: 60))} 次，'
        '所在路段有車速 ${(withData * 100 / seconds).toStringAsFixed(1)}% 的時間');
    expect(api.maxInWindow(const Duration(seconds: 60)), lessThanOrEqualTo(TdxClient.maxPerMinute));
  }

  /// 真實路網軌跡：含閘道前預知（同時查國道、省道與 VD）
  Future<void> replay(ev.Trace t) async {
    var now = DateTime(2026, 9, 28, 8);
    final byId = {for (final s in index.sections) s.id: s};
    final api = _FakeApi(() => now, {
      for (final n in [66, 68, 72, 74, 76, 78, 82, 84, 86, 88]) '台$n線',
    }, byId);
    final svc = TrafficService()..setUpForTest(index, api, () => now);
    final tiles = OsmTileService();
    await tiles.initFromFile('assets/speed_tiles.bin');
    final tracker = RoadTracker();
    int previewSeconds = 0;
    for (final p in t.points) {
      for (final dy in const [-0.02, 0.0, 0.02]) {
        for (final dx in const [-0.022, 0.0, 0.022]) {
          await tiles.tileAt(p.lat + dy, p.lon + dx);
        }
      }
      final roads = tiles.cachedTileAt(p.lat, p.lon)!;
      final tr = tracker.update(roads, p.lat, p.lon, headingDeg: p.heading, speedKmh: p.speedKmh);
      svc.update(p.lat, p.lon,
          road: tracker.isSystemConfident ? tr?.road : null,
          headingDeg: p.heading, speedKmh: p.speedKmh, roadLimit: 60);
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(seconds: 1));
      if (svc.rampPreviews.isNotEmpty) previewSeconds++;
    }
    final minutes = t.points.length / 60;
    // ignore: avoid_print
    print('  ${t.label.padRight(18)} ${minutes.toStringAsFixed(1)} 分鐘：共 ${api.calls.length} 次，'
        '平均每分鐘 ${(api.calls.length / minutes).toStringAsFixed(2)} 次，'
        '任意 60 秒最多 ${api.maxInWindow(const Duration(seconds: 60))} 次'
        '（閘道預知 $previewSeconds 秒）');
    expect(api.maxInWindow(const Duration(seconds: 60)), lessThanOrEqualTo(TdxClient.maxPerMinute));
  }

  test('沿路線行駛的 TDX 請求頻率', () async {
    await drive('台61線', _road('61', 'trunk'), 90);
    await drive('國道1號', _road('1', 'motorway'), 110);
    await drive('台74線', _road('74', 'trunk'), 80);
  });

  test('平面省道不查詢', () async {
    var now = DateTime(2026, 9, 28, 8);
    final api = _FakeApi(() => now, const {}, const {});
    final svc = TrafficService()..setUpForTest(index, api, () => now);
    final line = index.lineOf(index.sections.firstWhere((s) => s.roadName == '台1線' && s.kmSign == 1));
    final road = _road('1', 'primary');
    int matchedPoints = 0;
    for (final sec in line.take(40)) {
      final p = sec.points;
      for (int i = 0; i + 3 < p.length; i += 2) {
        svc.update(p[i + 1], p[i], road: road,
            headingDeg: _bearing(p[i], p[i + 1], p[i + 2], p[i + 3]), speedKmh: 50, roadLimit: 60);
        await Future<void>.delayed(Duration.zero);
        now = now.add(const Duration(seconds: 5));
        matchedPoints++;
      }
    }
    expect(matchedPoints, greaterThan(100));
    expect(svc.state, isNull);
    expect(api.calls, isEmpty);
  });

  test('含閘道前預知的真實軌跡', () async {
    await replay(ev.Trace.load('test/fixtures/elevated_traces.json').firstWhere((t) => t.label.startsWith('S1')));
    await replay(ev.Trace.load('test/fixtures/wuqi_traces.json.gz').firstWhere((t) => t.label.startsWith('W1 上高架 σ=6m')));
  });

  test('限流器：任意 60 秒最多 max 次', () {
    var now = DateTime(2026);
    final l = RateLimiter(4, const Duration(seconds: 60), clock: () => now);
    for (int i = 0; i < 4; i++) {
      expect(l.waitNeeded(), Duration.zero);
      l.record();
      now = now.add(const Duration(seconds: 5));
    }
    // 第 5 次要等到第 1 次（t=0）滑出視窗，現在 t=20 → 等 40 秒
    expect(l.waitNeeded(), const Duration(seconds: 40));
    now = now.add(const Duration(seconds: 40));
    expect(l.waitNeeded(), Duration.zero);
  });
}
