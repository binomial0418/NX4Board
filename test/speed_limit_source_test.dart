// 驗證速限判定鏈：OSM 標註 → 同編號省道牌面 → 分級推定
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/models/osm_road.dart';
import 'package:nx4board/models/speed_sign.dart';
import 'package:nx4board/services/speed_limit_service.dart';

const double _lat = 24.1477;
const double _lon = 120.6839;

OsmRoad _road({String? ref, String highway = 'primary', String? maxspeed}) {
  return OsmRoad(
    name: '測試路',
    ref: ref,
    highway: highway,
    maxspeed: maxspeed,
    oneway: null,
    bridge: null,
    tunnel: null,
    layer: null,
    lines: [Float64List.fromList([_lon, _lat, _lon + 0.001, _lat])],
  );
}

SpeedSign _sign(String roadNumber, int limit, {double dLat = 0, double dLng = 0}) {
  return SpeedSign(
    roadNumber: roadNumber,
    county: '臺中市',
    lat: _lat + dLat,
    lng: _lon + dLng,
    speedLimit: limit,
    location: '',
    village: '',
    placement: '',
    direction: '',
    position: '',
  );
}

void main() {
  group('公路編號正規化', () {
    test('去掉「台」字', () {
      expect(SpeedLimitService.normalizedRefs('台1'), {'1'});
    });
    test('OSM 的純數字', () {
      expect(SpeedLimitService.normalizedRefs('1'), {'1'});
    });
    test('分號多值拆開', () {
      expect(SpeedLimitService.normalizedRefs('106;北77-1'), {'106', '北77-1'});
    });
    test('甲乙線保留', () {
      expect(SpeedLimitService.normalizedRefs('19甲'), {'19甲'});
    });
    test('null 與空字串', () {
      expect(SpeedLimitService.normalizedRefs(null), isEmpty);
      expect(SpeedLimitService.normalizedRefs(''), isEmpty);
    });
  });

  group('速限判定順序', () {
    final svc = SpeedLimitService();

    setUp(() {
      svc.setSignsForTest([
        _sign('台1', 70),                              // 同路，近
        _sign('台3', 50, dLat: 0.0005),                // 不同路，更近
        _sign('台1', 40, dLat: 0.01),                  // 同路，超過 500m
      ]);
    });

    test('OSM 有 maxspeed → 直接採用，不查牌面', () {
      final limit = svc.resolveLimitForTest(
          _road(ref: '1', maxspeed: '90'), _lat, _lon);
      expect(limit, 90);
      expect(svc.source, LimitSource.osm);
    });

    test('無 maxspeed 但有同編號牌面 → 採用牌面', () {
      final limit = svc.resolveLimitForTest(_road(ref: '1'), _lat, _lon);
      expect(limit, 70);
      expect(svc.source, LimitSource.sign);
    });

    test('橫向道路的牌面不會被誤抓', () {
      // 台3 的牌面雖然更近，但目前在台1 上，不應採用 50
      final limit = svc.resolveLimitForTest(_road(ref: '1'), _lat, _lon);
      expect(limit, isNot(50));
    });

    test('超過 500m 的同路牌面不採用', () {
      svc.setSignsForTest([_sign('台1', 40, dLat: 0.01)]);
      final limit = svc.resolveLimitForTest(_road(ref: '1'), _lat, _lon);
      expect(limit, 60); // 落到 primary 推定值
      expect(svc.source, LimitSource.inferred);
    });

    test('非省道且無標註 → 依分級推定', () {
      final limit = svc.resolveLimitForTest(
          _road(ref: null, highway: 'residential'), _lat, _lon);
      expect(limit, 40);
      expect(svc.source, LimitSource.inferred);
      expect(svc.isInferred, isTrue);
    });

    test('未知分級 → 無法判定', () {
      final limit = svc.resolveLimitForTest(
          _road(ref: null, highway: 'raceway'), _lat, _lon);
      expect(limit, isNull);
      expect(svc.source, LimitSource.none);
    });

    test('各分級推定值', () {
      expect(svc.resolveLimitForTest(_road(highway: 'motorway'), _lat, _lon), 100);
      expect(svc.resolveLimitForTest(_road(highway: 'trunk'), _lat, _lon), 80);
      expect(svc.resolveLimitForTest(_road(highway: 'secondary'), _lat, _lon), 50);
      expect(svc.resolveLimitForTest(_road(highway: 'service'), _lat, _lon), 30);
    });
  });
}
