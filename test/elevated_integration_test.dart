// 透過實際的 SpeedLimitService 與 CameraService 重播高架情境軌跡，
// 確認道路追蹤接上 App 之後，速限與測速照相過濾都正確，並與舊做法
// （RoadTypeService 以 200～300 公尺內的地標點判定路型）對照。
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:nx4board/services/camera_service.dart';
import 'package:nx4board/services/osm_tile_service.dart';
import 'package:nx4board/services/road_type_service.dart';
import 'package:nx4board/services/speed_limit_service.dart';

import 'elevated_eval_test.dart' as ev;

/// 放在台74 高架上、水平距離緊貼底下環中路的快速道路相機
final _camera74 = SpeedCamera(
  address: '台74線 模擬相機',
  longitude: 120.6397446,
  latitude: 24.1899148,
  direct: '雙向',
  limit: 80,
  roadType: RoadType.expressway,
);

/// 放在環中路上、正好在台74 高架下方的平面道路相機
final _cameraSurface = SpeedCamera(
  address: '臺中市北屯區環中路 模擬相機',
  longitude: 120.6397446,
  latitude: 24.1899148,
  direct: '雙向',
  limit: 60,
);

class _Replay {
  int points = 0;
  int limitCorrect = 0;
  int limitTotal = 0;

  /// 有把握地判定路型、卻判錯高速路／平面的點數
  int systemWrong = 0;

  /// 判定沒把握的點數
  int uncertain = 0;

  /// 回報的相機與所在道路系統不符（人在平面卻報高架相機，或反之）
  int wrongCamera = 0;

  /// 有把握時仍回報錯系統的相機
  int wrongCameraWhileConfident = 0;

  /// 所在道路系統的相機在範圍內卻沒有回報
  int missedCamera = 0;
}

/// [useTracker] 為 false 時模擬舊做法：路型只看 RoadTypeService 的地標判定
Future<_Replay> _replay(ev.Trace trace, OsmTileService tiles, {required bool useTracker}) async {
  final svc = SpeedLimitService();
  svc.setSignsForTest(const []);
  svc.resetTrackingForTest();
  final cams = CameraService()..setCamerasForTest([_camera74, _cameraSurface]);
  final landmarks = RoadTypeService()..resetForTest();

  final r = _Replay();
  var t = DateTime(2026, 1, 1);
  for (final p in trace.points) {
    await tiles.tileAt(p.lat, p.lon); // 確保 tile 已在快取，模擬背景預抓已完成
    t = t.add(const Duration(seconds: 1));

    landmarks.addPosition(p.lat, p.lon);
    final limit = svc.detectNearbyLimit(
      p.lat,
      p.lon,
      roadType: landmarks.currentRoadType,
      headingDeg: p.heading,
      speedKmh: p.speedKmh,
    );
    cams.addPosition(Position(
      latitude: p.lat,
      longitude: p.lon,
      timestamp: t,
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: p.heading,
      headingAccuracy: 0,
      speed: p.speedKmh / 3.6,
      speedAccuracy: 0,
    ));

    // 與 AppProvider.effectiveRoadType 相同的邏輯
    final roadType = useTracker
        ? (svc.trackedRoadType ?? landmarks.currentRoadType)
        : landmarks.currentRoadType;
    final surfaceConfirmed = useTracker && svc.surfaceConfirmed;
    final cam = cams.checkNearbyCamera(
      currentRoadType: roadType,
      surfaceConfirmed: surfaceConfirmed,
    );

    r.points++;
    if (p.truthLimit != null) {
      r.limitTotal++;
      if (limit == p.truthLimit) r.limitCorrect++;
    }
    if (useTracker) {
      if (svc.isLevelUncertain) {
        r.uncertain++;
      } else if (svc.trackedRoadType != null &&
          (svc.trackedRoadType != RoadType.none) != p.truthIsFast) {
        r.systemWrong++;
      }
    }

    // 相機正確與否：人在高速路系統應報台74 相機，在平面應報平面相機
    final expected = p.truthIsFast ? _camera74 : _cameraSurface;
    final reported = cam?['name'] as String?;
    final inRange = cam != null || _withinKm(p, expected, 0.9);
    if (reported != null && reported != expected.address) {
      r.wrongCamera++;
      if (useTracker && !svc.isLevelUncertain) r.wrongCameraWhileConfident++;
    } else if (reported == null && inRange && _ahead(p, expected)) {
      r.missedCamera++;
    }
  }
  return r;
}

bool _withinKm(ev.TracePoint p, SpeedCamera c, double km) =>
    CameraAlgorithm.haversine(p.lat, p.lon, c.latitude, c.longitude) <= km;

/// 相機在行進方向前方（與 CameraService 的幾何過濾一致），
/// 已經通過的相機不回報是正確行為，不算漏報
bool _ahead(ev.TracePoint p, SpeedCamera c) {
  final bearing = CameraAlgorithm.calculateBearing(p.lat, p.lon, c.latitude, c.longitude);
  var diff = (bearing - p.heading).abs();
  if (diff > 180) diff = 360 - diff;
  return diff <= 80;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OsmTileService tiles;
  late List<ev.Trace> scenarios;

  setUpAll(() async {
    tiles = OsmTileService();
    await tiles.initFromFile('assets/speed_tiles.bin');
    await RoadTypeService().init(); // 載入正式的國道／快速道路地標
    scenarios = ev.Trace.load('test/fixtures/elevated_traces.json');
  });

  ev.Trace scenario(String prefix) => scenarios.firstWhere((t) => t.label.startsWith(prefix));

  String summary(String name, _Replay r) =>
      '  ${name.padRight(10)} 速限 ${r.limitCorrect}/${r.limitTotal}'
      '  路型錯誤 ${r.systemWrong}  不確定 ${r.uncertain}'
      '  報錯相機 ${r.wrongCamera}（有把握時 ${r.wrongCameraWhileConfident}）'
      '  漏報 ${r.missedCamera}';

  Future<(_Replay, _Replay)> compare(String prefix) async {
    final trace = scenario(prefix);
    final old = await _replay(trace, tiles, useTracker: false);
    final now = await _replay(trace, tiles, useTracker: true);
    // ignore: avoid_print
    print('${trace.label}\n${summary('舊做法', old)}\n${summary('道路追蹤', now)}');
    return (old, now);
  }

  test('S2 行駛在高架正下方', () async {
    final (old, now) = await compare('S2');
    expect(now.wrongCameraWhileConfident, 0, reason: '有把握在環中路時，不應回報上方台74 的相機');
    expect(now.wrongCamera, lessThan(old.wrongCamera));
    expect(now.missedCamera, lessThanOrEqualTo(old.missedCamera));
    expect(now.systemWrong / now.points, lessThan(0.02));
    expect(now.limitCorrect / now.limitTotal, greaterThan(0.95));
  });

  test('S1 從平面上高架再下來', () async {
    final (old, now) = await compare('S1');
    expect(now.wrongCameraWhileConfident, 0);
    expect(now.wrongCamera, lessThanOrEqualTo(old.wrongCamera));
    expect(now.systemWrong / now.points, lessThan(0.02));
    expect(now.limitCorrect / now.limitTotal, greaterThan(0.90));
  });

  test('S3 從高架上開始（無歷史）', () async {
    final (_, now) = await compare('S3');
    expect(now.wrongCameraWhileConfident, 0);
    expect(now.systemWrong / now.points, lessThan(0.02));
    expect(now.limitCorrect / now.limitTotal, greaterThan(0.95));
  });
}
