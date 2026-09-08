// RoadMatcher 的行為必須與網頁版 speed-limit-core.js 完全一致，
// 這裡的案例與 速限查詢API版/tools/test_core.js 一一對應。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/models/osm_road.dart';
import 'package:nx4board/services/road_matcher.dart';
import 'package:nx4board/services/speed_limit_service.dart';

const double _lat = 24.1477;
const double _lon = 120.6839;

double _dLat(double m) => m / 110540.0;
double _dLon(double m) => m / (111320.0 * math.cos(_lat * math.pi / 180.0));

OsmRoad _road({
  String? name,
  String? ref,
  String highway = 'primary',
  String? maxspeed,
  required List<List<double>> lines,
}) {
  return OsmRoad(
    name: name,
    ref: ref,
    highway: highway,
    maxspeed: maxspeed,
    oneway: null,
    bridge: null,
    tunnel: null,
    layer: null,
    lines: lines.map(Float64List.fromList).toList(),
  );
}

void main() {
  group('點到線段距離', () {
    test('垂足落在線段內', () {
      expect(RoadMatcher.pointSegmentDistance(-100, 50, 100, 50), closeTo(50, 0.01));
    });
    test('垂足在端點外 → 取端點', () {
      expect(RoadMatcher.pointSegmentDistance(100, 0, 200, 0), closeTo(100, 0.01));
    });
    test('線段退化成點', () {
      expect(RoadMatcher.pointSegmentDistance(30, 40, 30, 40), closeTo(50, 0.01));
    });
  });

  group('方向懲罰（x=東 y=北）', () {
    test('朝北 vs 南北向路 → 無懲罰', () {
      expect(RoadMatcher.headingPenaltyFor(0, 0, 0, 100, 0), 0);
    });
    test('朝南 vs 南北向路 → 無懲罰（雙向等價）', () {
      expect(RoadMatcher.headingPenaltyFor(0, 0, 0, 100, 180), 0);
    });
    test('朝東 vs 南北向路 → 有懲罰', () {
      expect(RoadMatcher.headingPenaltyFor(0, 0, 0, 100, 90), greaterThan(0));
    });
    test('朝東 vs 東西向路 → 無懲罰', () {
      expect(RoadMatcher.headingPenaltyFor(0, 0, 100, 0, 90), 0);
    });
  });

  group('maxspeed 解析', () {
    test('純數字', () => expect(SpeedLimitService.parseMaxspeed('50'), 50));
    test('帶單位', () => expect(SpeedLimitService.parseMaxspeed('60 km/h'), 60));
    test('台灣預設標籤', () => expect(SpeedLimitService.parseMaxspeed('TW:urban'), 50));
    test('null', () => expect(SpeedLimitService.parseMaxspeed(null), isNull));
    test('無法解析', () => expect(SpeedLimitService.parseMaxspeed('none'), isNull));
    test('超出合理範圍', () => expect(SpeedLimitService.parseMaxspeed('999'), isNull));
  });

  group('最近道路比對', () {
    // 主線在東側 10m、側車道在東側 40m（南北向），橫向路在北側 20m
    final roads = [
      _road(name: '主線', maxspeed: '60', lines: [
        [_lon + _dLon(10), _lat - _dLat(200), _lon + _dLon(10), _lat + _dLat(200)]
      ]),
      _road(name: '側車道', highway: 'service', lines: [
        [_lon + _dLon(40), _lat - _dLat(200), _lon + _dLon(40), _lat + _dLat(200)]
      ]),
      _road(name: '橫向路', highway: 'residential', maxspeed: '40', lines: [
        [_lon - _dLon(200), _lat + _dLat(20), _lon + _dLon(200), _lat + _dLat(20)]
      ]),
    ];

    test('無方向 → 取最近', () {
      expect(RoadMatcher.nearest(roads, _lat, _lon, null)!.road.name, '主線');
    });
    test('朝東 → 改判橫向路', () {
      expect(RoadMatcher.nearest(roads, _lat, _lon, 90)!.road.name, '橫向路');
    });
    test('朝北 → 維持主線', () {
      expect(RoadMatcher.nearest(roads, _lat, _lon, 0)!.road.name, '主線');
    });
    test('rank 第一名與 nearest 一致', () {
      expect(RoadMatcher.rank(roads, _lat, _lon, null).first.road.name, '主線');
    });
    test('rank 回傳全部候選', () {
      expect(RoadMatcher.rank(roads, _lat, _lon, null).length, 3);
    });
  });

  group('比對半徑', () {
    test('超過 maxDistanceM → 不比對', () {
      final beyond = RoadMatcher.maxDistanceM + 20;
      final far = [
        _road(name: '遠路', maxspeed: '50', lines: [
          [_lon + _dLon(beyond), _lat - _dLat(200), _lon + _dLon(beyond), _lat + _dLat(200)]
        ])
      ];
      expect(RoadMatcher.nearest(far, _lat, _lon, null), isNull);
    });
    test('半徑內 → 有比對', () {
      final within = RoadMatcher.maxDistanceM - 5;
      final near = [
        _road(name: '近路', maxspeed: '50', lines: [
          [_lon + _dLon(within), _lat - _dLat(200), _lon + _dLon(within), _lat + _dLat(200)]
        ])
      ];
      expect(RoadMatcher.nearest(near, _lat, _lon, null), isNotNull);
    });
  });

  test('多點折線取最近段', () {
    final poly = [
      _road(name: '折線', maxspeed: '50', lines: [
        [
          _lon - _dLon(100), _lat + _dLat(100),
          _lon, _lat + _dLat(15),
          _lon + _dLon(100), _lat + _dLat(100),
        ]
      ])
    ];
    expect(RoadMatcher.nearest(poly, _lat, _lon, null)!.distance, closeTo(15, 1));
  });
}
