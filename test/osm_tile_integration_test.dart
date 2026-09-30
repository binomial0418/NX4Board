// 以真實的 assets/speed_tiles.bin 驗證打包格式與比對結果。
// 輸出的 JSON 會與網頁版 speed-limit-core.js 的結果逐點比對，
// 確保 Dart 移植與原版行為一致。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/services/osm_tile_service.dart';
import 'package:nx4board/services/road_matcher.dart';

const _points = <List<double>>[
  [24.16536, 120.62268], // 國道一號 中港交流道
  [24.13690, 120.68680], // 台中車站
  [24.18000, 120.64600], // 逢甲
  [24.06430, 120.71890], // 中投公路
  [25.04780, 121.51700], // 台北車站
  [22.63080, 120.30250], // 高雄
  [23.99710, 121.60150], // 花蓮
  [24.80000, 121.00000], // 新竹山區
];

void main() {
  test('打包圖資可讀且比對結果穩定', () async {
    final file = File('assets/speed_tiles.bin');
    expect(await file.exists(), isTrue, reason: 'assets/speed_tiles.bin 不存在');

    final tiles = OsmTileService();
    await tiles.initFromFile(file.path);
    expect(tiles.isInitialized, isTrue);
    expect(tiles.tileCount, greaterThan(0));

    final results = <Map<String, dynamic>>[];
    for (final p in _points) {
      final lat = p[0], lon = p[1];
      final roads = await tiles.tileAt(lat, lon);
      final entry = <String, dynamic>{
        'lat': lat,
        'lon': lon,
        'tx': tiles.lonToTileX(lon),
        'ty': tiles.latToTileY(lat),
        'roads': roads?.length,
      };
      if (roads != null && roads.isNotEmpty) {
        final ranked = RoadMatcher.rank(roads, lat, lon, null);
        entry['top'] = ranked.take(3).map((m) => {
              'name': m.road.name,
              'ref': m.road.ref,
              'highway': m.road.highway,
              'maxspeed': m.road.maxspeed,
              'dist': double.parse(m.distance.toStringAsFixed(2)),
            }).toList();
      }
      results.add(entry);
    }

    File('build/dart_match_results.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(results));

    // 基本健全性：台中車站那格必須有道路
    final taichung = results[1];
    expect(taichung['roads'], greaterThan(0));
    expect(taichung['top'], isNotEmpty);
  });

  // 迴歸測試：RandomAccessFile 不允許並行操作，預抓 8 個鄰格若同時讀取，
  // 除了第一個都會失敗，連帶讓所在格讀不到、整個 OSM 比對被跳過。
  test('並行預抓與讀取不會互相干擾', () async {
    final tiles = OsmTileService();
    await tiles.initFromFile('assets/speed_tiles.bin');

    const lat = 24.2000, lon = 120.9000; // 先前測試沒碰過的格子，確保未快取
    tiles.prefetchAround(lat, lon);
    final results = await Future.wait([
      tiles.tileAt(lat, lon),
      tiles.tileAt(lat + 0.01, lon),
      tiles.tileAt(lat, lon + 0.01),
    ]);
    for (final r in results) {
      expect(r, isNotNull);
    }

    // 預抓的 9 格都要進快取，不能有任何一格因並行衝突而遺失
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tiles.tileAt(lat, lon); // 等 I/O 佇列排空
    final step = 360.0 / (1 << tiles.zoom);
    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
        expect(tiles.hasTileAt(lat + dy * step * 0.9, lon + dx * step), isTrue,
            reason: '鄰格 ($dx,$dy) 未載入');
      }
    }
  });

  // 實際誤報：中央路一段往北，被西邊港埠路一段的限速 60 相機觸發（相距約 150 m）
  test('相機到目前道路的距離分得出平行道路', () async {
    final tiles = OsmTileService();
    await tiles.initFromFile('assets/speed_tiles.bin');
    const userLat = 24.245637667473503, userLon = 120.53764866495439;
    const camLat = 24.24927, camLon = 120.53611; // 港埠路一段的 OSM 節點
    for (final d in [-0.02, 0.0, 0.02]) {
      for (final e in [-0.02, 0.0, 0.02]) {
        await tiles.tileAt(camLat + d, camLon + e);
      }
    }
    final roads = tiles.cachedRoadsAround(camLat, camLon);

    final user = RoadMatcher.rank(roads, userLat, userLon, null).first.road;
    expect(user.name, startsWith('中央路'));
    expect(RoadMatcher.distanceToRoute(
            roads, RoadMatcher.straightContinuations(roads, user.routeKey!), camLat, camLon),
        greaterThan(30));

    final own = RoadMatcher.rank(roads, camLat, camLon, null).first.road;
    expect(own.name, startsWith('港埠路'));
    expect(RoadMatcher.distanceToRoute(roads, {own.routeKey!}, camLat, camLon),
        lessThan(10));
  });
}
