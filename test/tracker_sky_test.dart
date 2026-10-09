// 頭頂天空證據（SkyView）：在高架與地面道路重疊處，用衛星訊號分辨上下。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/models/osm_road.dart';
import 'package:nx4board/services/road_tracker.dart';
import 'package:nx4board/services/sky_service.dart';
import 'package:nx4board/services/speed_limit_service.dart';

const _lat0 = 24.25, _lon0 = 120.55;
const _mLat = 1 / 110540.0;
const _mLon = 1 / (111320.0 * 0.9118); // cos(24.25°)

/// 沿正北方向的直路：x 為往東偏移（公尺），y 為起訖（公尺，往北）
OsmRoad _road(String name, String highway, double x, double y0, double y1,
    {bool elevated = false}) {
  final pts = <double>[];
  for (double y = y0; y <= y1; y += 50) {
    pts..add(_lon0 + x * _mLon)..add(_lat0 + y * _mLat);
  }
  return OsmRoad(
    name: name,
    ref: elevated ? '61' : null,
    highway: highway,
    maxspeed: elevated ? '90' : '50',
    oneway: 'yes',
    bridge: elevated ? 'yes' : null,
    tunnel: null,
    layer: elevated ? '1' : null,
    lines: [Float64List.fromList(pts)],
  );
}

/// 依序餵定位點（往北 50 km/h，每秒約 14 m），回傳最後追到的道路名稱
String? _drive(RoadTracker t, List<OsmRoad> roads, double x, double y0, double y1, SkyView sky,
    {double speedKmh = 50}) {
  String? name;
  for (double y = y0; y <= y1; y += speedKmh / 3.6) {
    final r = t.update(roads, _lat0 + y * _mLat, _lon0 + x * _mLon,
        headingDeg: 0, speedKmh: speedKmh, sky: sky);
    name = r?.road.name;
  }
  return name;
}

void main() {
  // 高架 x=0 在 y 1000~3000；地面道路 x=6 在 y 0~3000（前 1000 m 高架還沒開始）
  final viaduct = _road('台61', 'trunk', 0, 1000, 3000, elevated: true);
  final ground = _road('港埠路', 'tertiary', 6, 0, 3000);

  test('under the viaduct: blocked sky moves the tracker off the viaduct', () {
    // 先讓追蹤器在只有高架的路段（地面道路此時在 300 m 外）確信在高架上
    final viaductOnly = _road('台61', 'trunk', 0, 0, 3000, elevated: true);
    final groundLater = _road('港埠路', 'tertiary', 6, 1000, 3000);
    final roads = [viaductOnly, groundLater];

    RoadTracker run(SkyView sky) {
      final t = RoadTracker();
      _drive(t, roads, 0, 0, 900, SkyView.unknown);
      expect(_drive(t, roads, 3, 1000, 1000, sky), '台61');
      return t;
    }

    // 沒有證據：連續性讓它一直留在高架（GPS 在兩條路正中間）
    final a = run(SkyView.unknown);
    expect(_drive(a, roads, 3, 1014, 1400, SkyView.unknown), '台61');
    // 頭頂被擋：幾秒內轉到正下方的地面道路
    final b = run(SkyView.blocked);
    expect(_drive(b, roads, 3, 1014, 1100, SkyView.blocked), '港埠路');
    expect(b.lastSkyApplied, SkyView.blocked);
  });

  test('on the viaduct: open sky moves the tracker up from the road below', () {
    final roads = [viaduct, ground];
    RoadTracker run() {
      final t = RoadTracker();
      _drive(t, roads, 6, 0, 900, SkyView.unknown); // 只有地面道路
      return t;
    }

    final a = run();
    expect(_drive(a, roads, 3, 1000, 1400, SkyView.unknown), '港埠路');
    final b = run();
    expect(_drive(b, roads, 3, 1000, 1100, SkyView.open), '台61');
  });

  test('open sky does not rule out a frontage road beside the viaduct', () {
    final beside = _road('側車道', 'tertiary', 20, 0, 3000);
    final roads = [viaduct, beside];
    final t = RoadTracker();
    _drive(t, roads, 20, 0, 900, SkyView.unknown);
    expect(_drive(t, roads, 18, 1000, 1600, SkyView.open), '側車道');
    expect(t.lastSkyApplied, SkyView.unknown); // 不在橋面正下方，證據不套用
  });

  test('no overlap, no effect', () {
    final roads = [ground];
    final t = RoadTracker();
    expect(_drive(t, roads, 6, 0, 900, SkyView.blocked), '港埠路');
    expect(t.lastSkyApplied, SkyView.unknown);
  });

  test('blocked sky does not rule out an on-ramp climbing beside the viaduct', () {
    // 匝道起點在地面、緊貼橋面邊緣，頭頂被擋很正常，不能因此刪掉它
    final ramp = _road('梧棲交流道', 'trunk_link', 0, 0, 3000, elevated: true);
    final t = RoadTracker();
    _drive(t, [ramp, ground], 3, 0, 600, SkyView.blocked);
    expect(t.lastSkyApplied, SkyView.unknown);
  });

  test('driving far above the surface road limit after an on-ramp jumps onto the viaduct', () {
    // 上匝道：從地面道路 (6, 950) 分出，與高架 (0, 1150) 相接
    final ramp = OsmRoad(
      name: '上匝道',
      ref: null,
      highway: 'trunk_link',
      maxspeed: null,
      oneway: 'yes',
      bridge: 'yes',
      tunnel: null,
      layer: '1',
      lines: [
        Float64List.fromList(
            [_lon0 + 6 * _mLon, _lat0 + 950 * _mLat, _lon0, _lat0 + 1150 * _mLat])
      ],
    );
    RoadTracker onGround(List<OsmRoad> roads) {
      final t = RoadTracker();
      _drive(t, roads, 6, 0, 900, SkyView.unknown, speedKmh: 60);
      return t;
    }

    // 經過匝道口後時速 85（≥ 50 + 25）：沒有天空證據也跳得上去
    final withRamp = [viaduct, ground, ramp];
    expect(_drive(onGround(withRamp), withRamp, 3, 920, 1600, SkyView.unknown, speedKmh: 85),
        '台61');
    // 經過匝道口但時速 65：仍在平面
    expect(_drive(onGround(withRamp), withRamp, 3, 920, 1600, SkyView.unknown, speedKmh: 65),
        '港埠路');
    // 沒經過上匝道起點，平面道路開到 78：仍在平面（要上高架一定要走匝道）
    final noRamp = [viaduct, ground];
    expect(_drive(onGround(noRamp), noRamp, 3, 920, 1600, SkyView.unknown, speedKmh: 78),
        '港埠路');
    // 經過的是下匝道的落地點（匝道最後一點接在地面道路上）：同樣不算
    final offRamp = OsmRoad(
      name: '下匝道',
      ref: null,
      highway: 'trunk_link',
      maxspeed: null,
      oneway: 'yes',
      bridge: 'yes',
      tunnel: null,
      layer: '1',
      lines: [
        Float64List.fromList(
            [_lon0, _lat0 + 750 * _mLat, _lon0 + 6 * _mLon, _lat0 + 950 * _mLat])
      ],
    );
    final withOff = [viaduct, ground, offRamp];
    expect(_drive(onGround(withOff), withOff, 3, 920, 1600, SkyView.unknown, speedKmh: 78),
        '港埠路');
    // 匝道口 GPS 斷訊的退路：沒看到匝道，但一直開到 ≥ 50 + 35
    expect(_drive(onGround(noRamp), noRamp, 3, 920, 1600, SkyView.unknown, speedKmh: 90),
        '台61');
  });

  group('SkyClassifier', () {
    SkyView feed(SkyClassifier c, int t0, int seconds, int used, {int hiStrong = 2}) {
      var v = SkyView.unknown;
      for (var i = 0; i < seconds; i++) {
        v = c.add(t0 + i * 1000, used: used, hiTotal: 6, hiStrong: hiStrong);
      }
      return v;
    }

    test('relative drop means blocked even with many satellites and strong overhead ones', () {
      final c = SkyClassifier();
      expect(feed(c, 0, 60, 36), SkyView.open);
      // 衛星多的日子，橋下仍有 14 顆（> 絕對門檻 10），頭頂強訊號還有 3
      expect(feed(c, 60000, 5, 14, hiStrong: 3), SkyView.blocked);
    });

    test('near the recent maximum means open even without strong overhead satellites', () {
      final c = SkyClassifier();
      feed(c, 0, 60, 36);
      expect(feed(c, 60000, 5, 33, hiStrong: 0), SkyView.open);
    });

    test('a road along the viaduct edge (about 0.7 of the maximum) is neither', () {
      final c = SkyClassifier();
      feed(c, 0, 60, 33);
      expect(feed(c, 60000, 5, 23), SkyView.unknown);
    });

    test('the reference outlives five minutes under the viaduct', () {
      final c = SkyClassifier();
      feed(c, 0, 60, 40);
      feed(c, 60000, 6 * 60, 14);
      // 橋下 6 分鐘後回到 21 顆：還遠低於 40，不是開闊
      expect(feed(c, 60000 + 6 * 60000, 5, 21), isNot(SkyView.open));
    });
  });

  test('a stop without fixes keeps the tracker; moving away or a long gap resets it', () {
    expect(SpeedLimitService.shouldResetTracking(const Duration(seconds: 20), 500), isFalse);
    expect(SpeedLimitService.shouldResetTracking(const Duration(seconds: 52), 8), isFalse);
    expect(SpeedLimitService.shouldResetTracking(const Duration(seconds: 52), 300), isTrue);
    expect(SpeedLimitService.shouldResetTracking(const Duration(minutes: 11), 0), isTrue);
  });
}
