// speed_sign.dart 的自製三角函式與牌面距離：拿 dart:math 當標準答案。
// 2026-10-09 之前 sqrt 對小數值沒收斂，牌面距離大了十幾倍，省道牌面從來對不到。
import 'dart:math' as m;

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/models/speed_sign.dart';

void main() {
  test('sqrt converges for tiny and large values', () {
    for (final x in [1e-12, 1e-8, 3.7e-5, 0.25, 1.0, 2.0, 1e6]) {
      expect(Math.sqrt(x), closeTo(m.sqrt(x), m.sqrt(x) * 1e-9), reason: 'x=$x');
    }
  });

  test('atan / atan2 over the whole range', () {
    for (final x in [-50.0, -3.0, -1.0, -0.5, 0.0, 0.3, 0.9, 1.0, 1.7, 40.0]) {
      expect(Math.atan(x), closeTo(m.atan(x), 1e-9), reason: 'x=$x');
    }
    for (final (y, x) in [(1.0, 2.0), (2.0, 1.0), (1.0, -3.0), (-2.0, -0.5), (-1.0, 0.2)]) {
      expect(Math.atan2(y, x), closeTo(m.atan2(y, x), 1e-9), reason: '($y, $x)');
    }
  });

  test('sin / cos beyond ±π', () {
    for (final x in [-7.0, -3.0, -0.1, 0.0, 0.5, 2.0, 4.0, 9.0]) {
      expect(Math.sin(x), closeTo(m.sin(x), 1e-9), reason: 'x=$x');
      expect(Math.cos(x), closeTo(m.cos(x), 1e-9), reason: 'x=$x');
    }
  });

  test('sign distance in meters', () {
    final sign = SpeedSign(
        roadNumber: '台1', county: '', lat: 25.0300000, lng: 121.5600000, speedLimit: 70,
        location: '', village: '', placement: '', direction: '', position: '');
    // 往南 0.009° 緯度（地球半徑 6371 km：1000.8 m）
    expect(sign.calculateDistance(25.0210000, 121.5600000), closeTo(1000.8, 1));
    // 14 m
    expect(sign.calculateDistance(25.0298740, 121.5600000), closeTo(14, 1));
  });
}
