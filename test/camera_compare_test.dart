// 相機提示：舊做法（80° 前方）與新規則（CameraRules）的比較，重播模擬行車軌跡。
//
// 軌跡由 scratch 的 gen_cam_traces.py 產生（含圖資相機座標，不進 git），用
//   CAM_TRACES=/path/cam_traces_50.json flutter test test/camera_compare_test.dart
// 執行；沒設定或沒有圖資時略過。
//
// 設定：
//   A 舊做法：80° 前方、軌跡航向、提示距離 平面 500 / 國道 1000 m
//   B A ＋ 目前道路過濾
//   C 新做法：CameraRules ＋ 道路關卡（現行）
//   D 只有 CameraRules（不接任何道路關卡）
import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:nx4board/services/camera_layer.dart';
import 'package:nx4board/services/camera_service.dart';
import 'package:nx4board/services/current_road_distance.dart';
import 'package:nx4board/services/osm_tile_service.dart';
import 'package:nx4board/services/road_type_service.dart';
import 'package:nx4board/services/speed_limit_service.dart';

import 'support/camera_service_v1.dart' as v1;

const _configs = ['A', 'B', 'C', 'D'];

class _Stat {
  int trueDrives = 0, trueAlerted = 0, parDrives = 0, parAlerted = 0, parAlertSec = 0;
  final List<double> firstAlertM = [];
  final List<double> warnSec = [];
}

String _pct(int a, int b) => b == 0 ? '-' : '${(a * 100 / b).toStringAsFixed(1)}%';

double _median(List<double> v) {
  if (v.isEmpty) return 0;
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

double _pctile(List<double> v, double p) {
  if (v.isEmpty) return 0;
  final s = [...v]..sort();
  return s[(s.length * p).floor().clamp(0, s.length - 1)];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final tracesPath = Platform.environment['CAM_TRACES'];
  final csvFile = File('assets/private/edog_cameras.csv');
  final skip = tracesPath == null || !File(tracesPath).existsSync() || !csvFile.existsSync();

  test('camera alert: old vs new rules', () async {
    final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
        .convert(csvFile.readAsStringSync())
        .skip(1)
        .where((r) => r.length >= 7)
        .toList();
    final camsNew = rows.map(SpeedCamera.fromEdogCsv).toList();
    final camsOld = rows.map(v1.SpeedCamera.fromEdogCsv).toList();

    final tiles = OsmTileService();
    await tiles.initFromFile('assets/speed_tiles.bin');
    await RoadTypeService().init();

    final drives = (jsonDecode(File(tracesPath!).readAsStringSync()) as List).cast<Map>();
    final stats = {for (final g in ['speed', 'redlight', 'highway']) g: {for (final c in _configs) c: _Stat()}};

    for (final drive in drives) {
      final cam = drive['cam'] as Map;
      final group = cam['group'] as String;
      final targetKey = '${double.parse(cam['row'][0])}_${double.parse(cam['row'][1])}';
      final isTrue = drive['kind'] == 'true';
      final pts = (drive['pts'] as List).cast<List>();
      final camLat = (cam['lat'] as num).toDouble(), camLon = (cam['lon'] as num).toDouble();
      // 真實接近要有足夠的助跑距離（上游道路轉彎時產生器只能從相機前幾十公尺開始）
      if (isTrue &&
          CameraAlgorithm.haversine((pts.first[4] as num).toDouble(), (pts.first[5] as num).toDouble(),
                  camLat, camLon) <
              0.3) { continue; }

      final alertedBy = <String, bool>{};
      final whyBy = <String, String>{};
      for (final c in _configs) {
        final sl = SpeedLimitService()
          ..setSignsForTest(const [])
          ..resetTrackingForTest();
        final landmarks = RoadTypeService()..resetForTest();
        final newSvc = CameraService()..setCamerasForTest(camsNew);
        final oldSvc = v1.CameraService()..setCamerasForTest(camsOld);
        final roadDist = CurrentRoadDistance();
        final layers = CameraLayerClassifier();
        String? oldAlertedId;
        var t = DateTime(2026);
        bool alerted = false, passed = false;
        int alertSec = 0;
        double? firstM;
        // 漏報診斷：離相機最近（且在前方）時的狀態
        String why = '';
        double bestD = 1e9;

        for (final p in pts) {
          final lat = (p[0] as num).toDouble(), lon = (p[1] as num).toDouble();
          final heading = (p[2] as num).toDouble(), speed = (p[3] as num).toDouble();
          final trueLat = (p[4] as num).toDouble(), trueLon = (p[5] as num).toDouble();
          await tiles.tileAt(lat, lon);
          await tiles.tileAt(camLat, camLon);
          t = t.add(const Duration(seconds: 1));
          landmarks.addPosition(lat, lon);
          final limit = sl.detectNearbyLimit(lat, lon,
              roadType: landmarks.currentRoadType, headingDeg: heading, speedKmh: speed);
          final pos = Position(
              latitude: lat,
              longitude: lon,
              timestamp: t,
              accuracy: 5,
              altitude: 0,
              altitudeAccuracy: 0,
              heading: heading,
              headingAccuracy: 0,
              speed: speed / 3.6,
              speedAccuracy: 0);

          // 與 AppProvider 相同的道路關卡
          final tracked = sl.trackedRoadType;
          final effective = tracked ?? landmarks.currentRoadType;
          final onHighSpeed = tracked != null && tracked != RoadType.none && !sl.isLevelUncertain;
          final roadLimit = onHighSpeed && sl.source == LimitSource.osm ? limit : null;
          final distFn = roadDist.forTracker(sl);

          String? alertKey;
          if (c == 'A' || c == 'B') {
            oldSvc.addPosition(pos);
            final info = oldSvc.checkNearbyCamera(
                currentRoadType: effective,
                surfaceConfirmed: sl.surfaceConfirmed,
                roadLimit: roadLimit,
                distanceToCurrentRoadM: c == 'B' ? distFn : null);
            if (info == null) {
              oldAlertedId = null;
            } else {
              final id = '${info['lat']}_${info['lon']}';
              final int distM = info['dist_m'] ?? 9999;
              final thr = info['is_zone'] == true ? 100 : (effective == RoadType.none ? 500 : 1000);
              if (distM <= thr) oldAlertedId = id;
              if (oldAlertedId == id) alertKey = id;
            }
          } else {
            newSvc.addPosition(pos);
            // 與 AppProvider 相同：重疊道路有把握時排除另一層的相機
            final ov = sl.overlap;
            bool Function(SpeedCamera)? skip;
            if (ov != null && ov.resolved) {
              final other = ov.onUpper! ? CameraLayer.lower : CameraLayer.upper;
              skip = (cam) =>
                  layers.classify(ov, cam.latitude, cam.longitude, cam.heading, cam.limit,
                      redLight: cam.kind == CameraKind.redLight, typeCode: cam.typeCode) ==
                  other;
            }
            final info = c == 'C'
                ? newSvc.checkNearbyCamera(
                    currentRoadType: effective,
                    surfaceConfirmed: sl.surfaceConfirmed,
                    roadLimit: roadLimit,
                    distanceToCurrentRoadM: distFn,
                    skipCamera: skip)
                : newSvc.checkNearbyCamera();
            if (info != null) alertKey = '${info['lat']}_${info['lon']}';
          }

          // 真實位置已過相機（相機在身後）就不再計
          final dTrue = CameraAlgorithm.haversine(trueLat, trueLon, camLat, camLon) * 1000;
          final bTrue = CameraAlgorithm.calculateBearing(trueLat, trueLon, camLat, camLon);
          if (isTrue && CameraAlgorithm.angleDiff(bTrue, heading) > 90 && dTrue < 200) passed = true;
          if (isTrue && !passed && (dTrue - 150).abs() < bestD) {
            bestD = (dTrue - 150).abs();
            final off = CameraAlgorithm.angleDiff(
                CameraAlgorithm.calculateBearing(lat, lon, camLat, camLon), heading);
            why = 'd=${dTrue.round()} off=${off.round()} camH=${cam['heading']} h=${heading.round()} '
                'eff=${effective.name} surf=${sl.surfaceConfirmed} tracked=${tracked?.name} '
                'unc=${sl.isLevelUncertain} road=${sl.currentRoad?.name}/${sl.currentRoad?.ref}/${sl.currentRoad?.highway} '
                'distFn=${distFn?.call(camLat, camLon)?.round()} alert=$alertKey';
          }
          if (alertKey == targetKey) {
            if (!passed && !alerted) firstM = dTrue;
            if (!passed) alerted = true;
            alertSec++;
          }
        }
        final dbg = Platform.environment['CAM_DEBUG'];
        if (isTrue && c == 'D' && dbg != null && (Platform.environment['CAM_REF'] == 'D' ? alerted : alertedBy['A'] == true) && alertedBy[dbg] == false) {
          // ignore: avoid_print
          print('MISS $group $dbg ${cam['row']} | ${whyBy[dbg]}');
        }
        final s = stats[group]![c]!;
        alertedBy[c] = alerted;
        whyBy[c] = why;
        if (isTrue) {
          s.trueDrives++;
          if (alerted) {
            s.trueAlerted++;
            s.firstAlertM.add(firstM!);
            s.warnSec.add(firstM / ((pts.first[3] as num).toDouble() / 3.6));
          }
        } else {
          s.parDrives++;
          if (alertSec > 0) s.parAlerted++;
          s.parAlertSec += alertSec;
        }
      }
    }

    final out = StringBuffer('\n$tracesPath\n');
    const names = {'speed': '平面固定測速', 'redlight': '闖紅燈', 'highway': '國道固定測速'};
    for (final g in stats.keys) {
      out.writeln('【${names[g]}】');
      out.writeln('  設定  有提示/真實接近  提示距離 中位(p10)  預警秒數 中位  | 平行道路誤報  誤報秒數');
      for (final c in _configs) {
        final s = stats[g]![c]!;
        out.writeln('  $c     ${_pct(s.trueAlerted, s.trueDrives).padLeft(6)} (${s.trueAlerted}/${s.trueDrives})'
            '   ${_median(s.firstAlertM).toStringAsFixed(0).padLeft(5)} m (${_pctile(s.firstAlertM, .1).toStringAsFixed(0)})'
            '   ${_median(s.warnSec).toStringAsFixed(1).padLeft(5)} s'
            '       | ${_pct(s.parAlerted, s.parDrives).padLeft(6)} (${s.parAlerted}/${s.parDrives})  ${s.parAlertSec}');
      }
    }
    // ignore: avoid_print
    print(out);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 60)));
}
