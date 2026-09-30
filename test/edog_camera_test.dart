// tools/edog_convert.py 輸出格式的解析，以及 CameraRules 的相機判斷。
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:nx4board/services/camera_service.dart';
import 'package:nx4board/services/road_type_service.dart';

Position _pos(double lat, double lon, {double speedKmh = 0, double heading = 0}) => Position(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime(2026),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: heading,
      headingAccuracy: 0,
      speed: speedKmh / 3.6,
      speedAccuracy: 0,
    );

SpeedCamera _cam(String heading, String limit,
        {String kind = 'speed',
        String road = 'none',
        String code = '1',
        String tol = '0',
        String lat = '24.0',
        String lon = '120.6'}) =>
    SpeedCamera.fromEdogCsv([lat, lon, heading, limit, kind, road, '', code, tol]);

/// 由南往北開（航向 0），停在相機（24.0, 120.6）南方約 [distM] 公尺
Map<String, dynamic>? _approachNorthbound(List<SpeedCamera> cams, double distM,
    {RoadType roadType = RoadType.none,
    int? roadLimit,
    double speedKmh = 50,
    double lon = 120.6,
    double? Function(double, double)? distToRoad}) {
  final svc = CameraService()..setCamerasForTest(cams);
  for (final back in [distM + 100, distM + 50, distM]) {
    svc.addPosition(_pos(24.0 - back / 111000, lon, speedKmh: speedKmh));
  }
  return svc.checkNearbyCamera(
      currentRoadType: roadType, roadLimit: roadLimit, distanceToCurrentRoadM: distToRoad);
}

void main() {
  test('parses edog rows, including the type code and angle tolerance', () {
    final cam = SpeedCamera.fromEdogCsv(
        ['24.0', '120.6', '185', '110', 'speed', 'highway', '', 'A2', '3']);
    expect(cam.heading, 185);
    expect(cam.limit, 110);
    expect(cam.roadType, RoadType.highway);
    expect(cam.typeCode, 0xA2);
    expect(cam.angleTol, '3');

    // 舊格式（沒有 Code/AngleTol）依種類補預設類型
    final red = SpeedCamera.fromEdogCsv(['24.0', '120.6', '90', '', 'redlight', 'none', '']);
    expect(red.kind, CameraKind.redLight);
    expect(red.limit, isNull);
    expect(red.typeCode, 0xA4);
    expect(SpeedCamera.fromEdogCsv(['24.0', '120.6', '0', '90', 'zone_start', 'none', '3000']).isZone,
        isTrue);
  });

  test('type codes decode: two chars hex, one char minus 0', () {
    expect(CameraRules.typeOf('1'), 0x01);
    expect(CameraRules.typeOf('A4'), 0xA4);
    expect(CameraRules.typeOf('7A'), 0x7A);
    expect(CameraRules.typeOf('E'), 0x15);
    expect(CameraRules.typeOf('E1'), 0xE1);
    expect(CameraRules.typeOf('G'), 0x17);
    expect(CameraRules.typeOf('6B'), 0x6B);
  });

  test('alert distance depends on type and speed', () {
    expect(CameraRules.alertDistanceM(0x01, 50), 300);
    expect(CameraRules.alertDistanceM(0x01, 70), 500);
    expect(CameraRules.alertDistanceM(0xA4, 40), 300);
    expect(CameraRules.alertDistanceM(0x06, 90), 330); // 區間起點
    expect(CameraRules.alertDistanceM(0x15, 90), 330); // E
    expect(CameraRules.alertDistanceM(0x07, 90), 40); // 區間終點
    expect(CameraRules.alertDistanceM(0x16, 90), 120); // F
    expect(CameraRules.alertDistanceM(0xA6, 80), isNull);
    // 國道／快速道路的固定測速保留 1 km
    expect(CameraRules.alertDistanceM(0x01, 100, fastRoad: true), 1000);
    expect(CameraRules.alertDistanceM(0x06, 100, fastRoad: true), 330);
    expect(_approachNorthbound([_cam('0', '110', road: 'highway')], 900,
            roadType: RoadType.highway, speedKmh: 100)?['alert_m'],
        1000);

    // 50 km/h：400 m 還不提示，250 m 提示；80 km/h 時 450 m 就提示
    expect(_approachNorthbound([_cam('0', '60')], 400), isNull);
    expect(_approachNorthbound([_cam('0', '60')], 250)?['limit'], 60);
    expect(_approachNorthbound([_cam('0', '60')], 450, speedKmh: 80)?['alert_m'], 500);
  });

  test('heading filters opposite direction', () {
    expect(_approachNorthbound([_cam('10', '60')], 250)?['limit'], 60);
    expect(_approachNorthbound([_cam('190', '60')], 250), isNull);
  });

  test('camera must sit inside the 20° cone ahead', () {
    // 相機在 250 m 前方、橫向偏 120 m（約 26°）：隔壁平行道路，不提示
    expect(_approachNorthbound([_cam('0', '60')], 250, lon: 120.6 - 120 / 101700), isNull);
    // 橫向偏 60 m（約 13°）仍在錐內
    expect(_approachNorthbound([_cam('0', '60')], 250, lon: 120.6 - 60 / 101700)?['limit'], 60);
    // 第 12 欄 '4'：錐角放寬到 60°、受測方向容許 30°（彎道上的點）
    expect(_approachNorthbound([_cam('0', '60', tol: '4')], 250, lon: 120.6 - 120 / 101700)?['limit'],
        60);
    // '2' 錐角 40° 但受測方向只容許 20°，偏 26° 仍不提示
    expect(_approachNorthbound([_cam('0', '60', tol: '2')], 250, lon: 120.6 - 120 / 101700), isNull);
  });

  test('uses the GNSS heading when moving, not the trajectory', () {
    final svc = CameraService()..setCamerasForTest([_cam('90', '60', lat: '24.0', lon: '120.6')]);
    // 軌跡往北，但 GNSS 航向是 90（例：剛轉進東向道路，軌跡還沒跟上）
    for (final back in [150.0, 100.0]) {
      svc.addPosition(_pos(24.0 - back / 111000, 120.6 - 250 / 101700, speedKmh: 40, heading: 90));
    }
    svc.addPosition(_pos(24.0, 120.6 - 250 / 101700, speedKmh: 40, heading: 90));
    expect(svc.checkNearbyCamera()?['limit'], 60);
  });

  test('red light within 300m at city speed', () {
    final red = _cam('0', '', kind: 'redlight', code: 'A4');
    expect(_approachNorthbound([red], 400), isNull);
    final info = _approachNorthbound([red], 250);
    expect(info?['kind'], 'redLight');
    expect(info?['message'], '前有闖紅燈照相');
  });

  test('on an elevated road, skips the surface camera below by its lower limit', () {
    // 西濱高架 90，正下方平面道路 70 的相機被圖資算成快速道路
    final surface = _cam('0', '70', road: 'expressway');
    expect(_approachNorthbound([surface], 450, roadType: RoadType.expressway, roadLimit: 90, speedKmh: 90),
        isNull);
    // 速限不是實測值（未提供）時照常提示，寧可多報
    expect(_approachNorthbound([surface], 450, roadType: RoadType.expressway, speedKmh: 90)?['limit'], 70);
    // 同一條路速限差 10 以內（例如 80 路段）仍提示
    final same = _cam('0', '80', road: 'expressway');
    expect(_approachNorthbound([same], 450, roadType: RoadType.expressway, roadLimit: 90, speedKmh: 90)?['limit'],
        80);
  });

  test('keeps last heading while stopped, so a camera behind stays filtered', () {
    // 往東開到停下，相機在北邊、受測方向朝北（高架上另一條路線）
    final cam = _cam('0', '60', lat: '24.002');
    final svc = CameraService()..setCamerasForTest([cam]);
    for (final dx in [0.0, 50.0, 100.0]) {
      svc.addPosition(_pos(24.0, 120.6 + dx / 101000));
    }
    expect(svc.checkNearbyCamera(), isNull);
    // 停住不動：軌跡算不出方向，仍沿用「往東」，不會把北向相機當成前方
    for (var i = 0; i < 5; i++) {
      svc.addPosition(_pos(24.0, 120.6 + 100 / 101000));
    }
    expect(svc.checkNearbyCamera(), isNull);
  });

  test('camera drops out right after it is passed', () {
    final svc = CameraService()..setCamerasForTest([_cam('0', '60')]);
    // 往北接近，最後一點在相機北方 [past] 公尺
    Map<String, dynamic>? at(double past) {
      for (final m in [past - 60, past - 30, past]) {
        svc.addPosition(_pos(24.0 + m / 111000, 120.6, speedKmh: 40));
      }
      return svc.checkNearbyCamera();
    }
    expect(at(-50)?['limit'], 60); // 還在前方 50m
    expect(at(-15), isNull); // 20 m 內視為已通過
    expect(at(40), isNull); // 已在身後
  });

  test('overpass points parse and carry their own message', () {
    final cam = _cam('0', '110', kind: 'overpass', road: 'highway', code: 'A3');
    expect(cam.kind, CameraKind.overpass);
    expect(cam.roadType, RoadType.highway);
    final info = _approachNorthbound([cam], 450, roadType: RoadType.highway, speedKmh: 100);
    expect(info?['kind'], 'overpass');
    expect(info?['message'], startsWith('注意天橋偷拍'));
  });

  test('skips a surface camera on a parallel road', () {
    final cam = _cam('0', '60');
    expect(_approachNorthbound([cam], 250, distToRoad: (_, __) => 150), isNull); // 隔壁那條路
    expect(_approachNorthbound([cam], 250, distToRoad: (_, __) => 12)?['limit'], 60); // 目前這條路
    expect(_approachNorthbound([cam], 250, distToRoad: (_, __) => null)?['limit'], 60); // 無從判斷
    // 國道／快速道路相機不套用（高架與平面的判斷另有規則）
    final hw = _cam('0', '110', road: 'highway');
    expect(
        _approachNorthbound([hw], 450,
            roadType: RoadType.highway, speedKmh: 100, distToRoad: (_, __) => 150)?['limit'],
        110);
  });
}
