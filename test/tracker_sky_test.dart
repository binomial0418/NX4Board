// 頭頂天空證據（SkyView）：在高架與地面道路重疊處，用衛星訊號分辨上下。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/models/osm_road.dart';
import 'package:nx4board/services/road_tracker.dart';

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
String? _drive(RoadTracker t, List<OsmRoad> roads, double x, double y0, double y1, SkyView sky) {
  String? name;
  for (double y = y0; y <= y1; y += 14) {
    final r = t.update(roads, _lat0 + y * _mLat, _lon0 + x * _mLon,
        headingDeg: 0, speedKmh: 50, sky: sky);
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
}
