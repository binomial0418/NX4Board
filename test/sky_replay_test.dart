// 實車紀錄重播：把設定頁匯出的 sky_YYYYMMDD.jsonl（位置＋衛星摘要）餵給真正的
// SkyClassifier 與 SpeedLimitService，量已知路段的高架／平面判錯比例。
//
// 紀錄含行車位置，不進 git。標記檔格式：
//   {"dir": "...", "files": ["sky_20261005.jsonl", ...],
//    "windows": [["20261005", "07:20:31", "07:22:40", "surface"|"viaduct", "說明"], ...]}
// 執行：SKY_REPLAY=/path/labels.json flutter test test/sky_replay_test.dart
// 另外把每個定位點的判定（高架快速路 1／其他 0）寫到 SKY_REPLAY_OUT，方便比較改前改後。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/services/camera_service.dart' show CameraAlgorithm;
import 'package:nx4board/services/osm_tile_service.dart';
import 'package:nx4board/services/road_tracker.dart';
import 'package:nx4board/services/sky_service.dart';
import 'package:nx4board/services/speed_limit_service.dart';

String _hms(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final labelsPath = Platform.environment['SKY_REPLAY'];
  final skip = labelsPath == null || !File(labelsPath).existsSync();

  test('replay real drives: elevated vs surface', () async {
    final labels = jsonDecode(File(labelsPath!).readAsStringSync()) as Map;
    final dir = labels['dir'] as String;
    final windows = (labels['windows'] as List).cast<List>();
    final tiles = OsmTileService();
    await tiles.initFromFile('assets/speed_tiles.bin');
    final sl = SpeedLimitService()..setSignsForTest(const []);
    final out = StringBuffer();
    final wrong = <String, int>{}, total = <String, int>{};

    for (final f in (labels['files'] as List).cast<String>()) {
      final day = f.replaceAll(RegExp(r'[^0-9]'), '');
      final sky = SkyClassifier();
      sl.resetTrackingForTest();
      int? lastT;
      double? lastLat, lastLon;
      for (final line in File('$dir/$f').readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        final Map r;
        try {
          r = jsonDecode(line) as Map;
        } catch (_) {
          continue;
        }
        final t = r['t'] as int;
        final g = (r['gps'] as List).cast<num>();
        // 中斷超過 30 秒，App 會重設追蹤（SpeedLimitService._trackerResetGap）。
        // 天空判定不重設：App 裡衛星摘要每秒持續進來，停車沒有定位點時也一樣
        final lat = g[0].toDouble(), lon = g[1].toDouble();
        if (lastT != null &&
            SpeedLimitService.shouldResetTracking(Duration(milliseconds: t - lastT),
                CameraAlgorithm.haversine(lastLat!, lastLon!, lat, lon) * 1000)) {
          sl.resetTrackingForTest();
        }
        lastT = t;
        lastLat = lat;
        lastLon = lon;
        final s = r['sky'] as List?;
        final view = s == null
            ? SkyView.unknown
            : sky.add(t,
                used: (s[2] as num).toInt(),
                hiTotal: (s[0] as num).toInt(),
                hiStrong: (s[1] as num).toInt());
        await tiles.tileAt(lat, lon);
        sl.detectNearbyLimit(lat, lon,
            headingDeg: g[3].toDouble(),
            speedKmh: g[2].toDouble(),
            accuracyM: g[4] > 0 ? g[4].toDouble() : null,
            sky: view);
        final road = sl.currentRoad;
        final onViaduct = road != null &&
            RoadTracker.isElevated(road) &&
            (road.highway == 'trunk' || road.highway == 'motorway');
        final hms = _hms(DateTime.fromMillisecondsSinceEpoch(t));
        final dbg = Platform.environment['SKY_REPLAY_DEBUG']?.split(' ');
        if (dbg != null && dbg[0] == day && hms.compareTo(dbg[1]) >= 0 && hms.compareTo(dbg[2]) <= 0) {
          final b = sl.trackerForTest.beliefForTest.entries.toList()
            ..sort((x, y) => y.value.compareTo(x.value));
          // ignore: avoid_print
          print('$hms v=${g[2]} sky=${view.name} '
              '${b.take(4).map((e) => '${e.key}=${e.value.toStringAsFixed(3)}').join('  ')}');
        }
        out.writeln('$day $hms ${onViaduct ? 1 : 0} ${view.name} ${road?.name ?? '-'}');
        for (final w in windows) {
          if (w[0] != day || hms.compareTo(w[1]) < 0 || hms.compareTo(w[2]) > 0) continue;
          final key = '${w[4]}（${w[3] == 'surface' ? '平面' : '高架'}）';
          total[key] = (total[key] ?? 0) + 1;
          if (onViaduct != (w[3] == 'viaduct')) wrong[key] = (wrong[key] ?? 0) + 1;
        }
      }
    }

    final report = StringBuffer('\n路段                              判錯/總筆數\n');
    int ws = 0, ts = 0, wv = 0, tv = 0;
    for (final k in total.keys) {
      final w = wrong[k] ?? 0;
      report.writeln('${k.padRight(28)} ${w.toString().padLeft(4)}/${total[k]}');
      if (k.endsWith('（平面）')) { ws += w; ts += total[k]!; } else { wv += w; tv += total[k]!; }
    }
    report.writeln('平面合計 $ws/$ts（${(ws * 100 / ts).toStringAsFixed(1)}%）  '
        '高架合計 $wv/$tv（${(wv * 100 / tv).toStringAsFixed(1)}%）');
    // ignore: avoid_print
    print(report);
    final outPath = Platform.environment['SKY_REPLAY_OUT'];
    if (outPath != null) File(outPath).writeAsStringSync(out.toString());
  }, skip: skip, timeout: const Timeout(Duration(minutes: 20)));
}
