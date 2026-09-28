// tools/edog_convert.py 輸出格式的解析，以及依受測方位角過濾行進方向。
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:nx4board/services/camera_service.dart';
import 'package:nx4board/services/road_type_service.dart';

Position _pos(double lat, double lon) => Position(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime(2026),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

/// 由南往北開，停在相機南方約 [distM] 公尺
Map<String, dynamic>? _approachNorthbound(List<SpeedCamera> cams, double distM,
    {RoadType roadType = RoadType.none, int? roadLimit}) {
  final svc = CameraService()..setCamerasForTest(cams);
  const camLat = 24.0;
  for (final back in [distM + 100, distM + 50, distM]) {
    svc.addPosition(_pos(camLat - back / 111000, 120.6));
  }
  return svc.checkNearbyCamera(currentRoadType: roadType, roadLimit: roadLimit);
}

void main() {
  test('parses edog rows', () {
    final cam = SpeedCamera.fromEdogCsv(['24.0', '120.6', '185', '110', 'speed', 'highway', '']);
    expect(cam.heading, 185);
    expect(cam.limit, 110);
    expect(cam.roadType, RoadType.highway);
    expect(cam.direct, isEmpty);

    final red = SpeedCamera.fromEdogCsv(['24.0', '120.6', '90', '', 'redlight', 'none', '']);
    expect(red.kind, CameraKind.redLight);
    expect(red.limit, isNull);
    expect(SpeedCamera.fromEdogCsv(['24.0', '120.6', '0', '90', 'zone_start', 'none', '3000']).isZone, isTrue);
  });

  test('heading filters opposite direction', () {
    SpeedCamera cam(double heading) =>
        SpeedCamera.fromEdogCsv(['24.0', '120.6', '$heading', '60', 'speed', 'none', '']);

    expect(_approachNorthbound([cam(10)], 400)?['limit'], 60);
    expect(_approachNorthbound([cam(190)], 400), isNull);
  });

  test('red light only within 300m', () {
    final red = SpeedCamera.fromEdogCsv(['24.0', '120.6', '0', '', 'redlight', 'none', '']);
    expect(_approachNorthbound([red], 600), isNull);
    final info = _approachNorthbound([red], 250);
    expect(info?['kind'], 'redLight');
    expect(info?['message'], '前有闖紅燈照相');
  });

  test('on an elevated road, skips the surface camera below by its lower limit', () {
    // 西濱高架 90，正下方平面道路 70 的相機被圖資算成快速道路
    final surface = SpeedCamera.fromEdogCsv(['24.0', '120.6', '0', '70', 'speed', 'expressway', '']);
    expect(_approachNorthbound([surface], 800, roadType: RoadType.expressway, roadLimit: 90), isNull);
    // 速限不是實測值（未提供）時照常提示，寧可多報
    expect(_approachNorthbound([surface], 800, roadType: RoadType.expressway)?['limit'], 70);
    // 同一條路速限差 10 以內（例如 80 路段）仍提示
    final same = SpeedCamera.fromEdogCsv(['24.0', '120.6', '0', '80', 'speed', 'expressway', '']);
    expect(_approachNorthbound([same], 800, roadType: RoadType.expressway, roadLimit: 90)?['limit'], 80);
  });

  test('keeps last heading while stopped, so a camera behind stays filtered', () {
    // 往東開到停下，相機在北邊、受測方向朝北（高架上另一條路線）
    final cam = SpeedCamera.fromEdogCsv(['24.003', '120.6', '0', '60', 'speed', 'none', '']);
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
    final cam = SpeedCamera.fromEdogCsv(['24.0', '120.6', '0', '60', 'speed', 'none', '']);
    final svc = CameraService()..setCamerasForTest([cam]);
    // 往北接近，最後一點在相機北方 [past] 公尺
    Map<String, dynamic>? at(double past) {
      for (final m in [past - 60, past - 30, past]) {
        svc.addPosition(_pos(24.0 + m / 111000, 120.6));
      }
      return svc.checkNearbyCamera();
    }
    expect(at(-50)?['limit'], 60);   // 還在前方 50m
    expect(at(40), isNull);          // 通過 40m 後就不再是前方相機
  });

  test('overpass points parse and carry their own message', () {
    final cam = SpeedCamera.fromEdogCsv(['24.0', '120.6', '0', '110', 'overpass', 'highway', '']);
    expect(cam.kind, CameraKind.overpass);
    expect(cam.roadType, RoadType.highway);
    final info = _approachNorthbound([cam], 800, roadType: RoadType.highway);
    expect(info?['kind'], 'overpass');
    expect(info?['message'], startsWith('注意天橋偷拍'));
  });
}
