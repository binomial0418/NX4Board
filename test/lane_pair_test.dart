// 快慢車道：同名、同向、速限不同、中心線相距 ≤15 m 的兩條平行線（真實圖資）。
import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/services/camera_service.dart' show CameraAlgorithm;
import 'package:nx4board/services/osm_tile_service.dart';
import 'package:nx4board/services/road_type_service.dart';
import 'package:nx4board/services/speed_limit_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('臺灣大道八段快車道 70／慢車道 40：主速限固定 70、另一可能 40', () async {
    final tiles = OsmTileService();
    await tiles.initFromFile('assets/speed_tiles.bin');
    await RoadTypeService().init();
    final sl = SpeedLimitService()
      ..setSignsForTest(const [])
      ..resetTrackingForTest();

    // 兩條中心線（相距約 10~12 m）中間的點，沿道路方向；取自 OSM 線形
    const pts = [
      [24.249006, 120.538632],
      [24.248429, 120.540199],
      [24.247861, 120.542412],
      [24.246965, 120.544260],
    ];
    var lanes = 0, total = 0;
    for (var i = 0; i + 1 < pts.length; i++) {
      final heading = CameraAlgorithm.calculateBearing(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]);
      for (var k = 0; k < 10; k++) {
        final lat = pts[i][0] + (pts[i + 1][0] - pts[i][0]) * k / 10;
        final lon = pts[i][1] + (pts[i + 1][1] - pts[i][1]) * k / 10;
        await tiles.tileAt(lat, lon);
        final limit = sl.detectNearbyLimit(lat, lon, headingDeg: heading, speedKmh: 50);
        total++;
        if (sl.alternativeKind == AlternativeKind.lane) {
          lanes++;
          expect(limit, 70);
          expect(sl.alternativeLimit, 40);
          expect(sl.alternativeLean, isFalse); // 相距比 GPS 誤差小，不標傾向
        }
      }
    }
    expect(lanes, greaterThanOrEqualTo(total * 0.9));
  });
}
