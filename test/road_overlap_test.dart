// 道路重疊狀態（SpeedLimitService.overlap）與相機分層（CameraLayerClassifier），真實圖資。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/services/camera_layer.dart';
import 'package:nx4board/services/camera_service.dart' show CameraAlgorithm;
import 'package:nx4board/services/osm_tile_service.dart';
import 'package:nx4board/services/road_type_service.dart';
import 'package:nx4board/services/speed_limit_service.dart';

Future<void> _drive(SpeedLimitService sl, OsmTileService tiles, double lat0, double lon0,
    double bearing, int n) async {
  final b = bearing * math.pi / 180;
  for (var i = 0; i < n; i++) {
    final lat = lat0 + 14.0 * i * math.cos(b) / 110540;
    final lon = lon0 + 14.0 * i * math.sin(b) / (111320 * math.cos(lat0 * math.pi / 180));
    await tiles.tileAt(lat, lon);
    sl.detectNearbyLimit(lat, lon, headingDeg: bearing, speedKmh: 50);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OsmTileService tiles;

  setUpAll(() async {
    tiles = OsmTileService();
    await tiles.initFromFile('assets/speed_tiles.bin');
    await RoadTypeService().init();
  });

  test('港埠路二段在台61 高架正下方：高架重疊，相機依類型與速限分層', () async {
    final sl = SpeedLimitService()
      ..setSignsForTest(const [])
      ..resetTrackingForTest();
    // 兩條線（相距約 8 m）之間，沿 201° 往南南西
    await _drive(sl, tiles, 24.2512, 120.5368, 201, 8);
    final ov = sl.overlap;
    expect(ov, isNotNull);
    expect(ov!.kind, AlternativeKind.level);
    expect(ov.upperRoad.ref, '61');
    expect(ov.upperLimit, 80);
    expect(ov.lowerRoad.name, '港埠路二段');

    final c = CameraLayerClassifier();
    // 速限 80 只對得上台61
    expect(c.classify(ov, 24.250418, 120.536384, 201, 80), CameraLayer.upper);
    // 速限對得上港埠路（推定值）
    expect(c.classify(ov, 24.250467, 120.536249, 201, ov.lowerLimit), CameraLayer.lower);
    // 闖紅燈照相一定在地面
    expect(c.classify(ov, 24.250418, 120.536384, 201, null, redLight: true), CameraLayer.lower);
    expect(CameraLayerClassifier.label(ov.kind, CameraLayer.lower), '高架下');
    // 圖資代碼標記優先：J（高架道路）即使速限對得上地面也算高架；G（平面車道）反之
    expect(c.classify(ov, 24.250467, 120.536249, 201, ov.lowerLimit, typeCode: 0x1A),
        CameraLayer.upper);
    expect(c.classify(ov, 24.250418, 120.536384, 201, 80, typeCode: 0x17), CameraLayer.lower);
  });

  test('臺灣大道八段快慢車道：70 歸快車道、40 歸慢車道', () async {
    final sl = SpeedLimitService()
      ..setSignsForTest(const [])
      ..resetTrackingForTest();
    const a = [24.249006, 120.538632], b = [24.248429, 120.540199];
    final bearing = CameraAlgorithm.calculateBearing(a[0], a[1], b[0], b[1]);
    await _drive(sl, tiles, a[0], a[1], bearing, 8);
    final ov = sl.overlap;
    expect(ov, isNotNull);
    expect(ov!.kind, AlternativeKind.lane);
    expect(ov.resolved, isFalse);
    final c = CameraLayerClassifier();
    expect(c.classify(ov, b[0], b[1], bearing, 70), CameraLayer.upper);
    expect(c.classify(ov, b[0], b[1], bearing, 40), CameraLayer.lower);
    expect(CameraLayerClassifier.label(ov.kind, CameraLayer.upper), '快車道');
  });

  test('一般道路：沒有重疊', () async {
    final sl = SpeedLimitService()
      ..setSignsForTest(const [])
      ..resetTrackingForTest();
    // 臺灣大道九段（單一道路）
    await _drive(sl, tiles, 24.2470, 120.5300, 291, 8);
    expect(sl.overlap, isNull);
  });
}
