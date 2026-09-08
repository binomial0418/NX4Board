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
}
