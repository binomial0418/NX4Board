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
Map<String, dynamic>? _approachNorthbound(List<SpeedCamera> cams, double distM) {
  final svc = CameraService()..setCamerasForTest(cams);
  const camLat = 24.0;
  for (final back in [distM + 100, distM + 50, distM]) {
    svc.addPosition(_pos(camLat - back / 111000, 120.6));
  }
  return svc.checkNearbyCamera();
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
}
