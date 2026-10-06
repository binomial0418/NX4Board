import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/models/tdx_section.dart';
import 'package:nx4board/services/traffic_service.dart';

TrafficSegment _seg(double dist, double len, double? speed, int level) =>
    TrafficSegment('x', dist, len, speed, level);

TdxSection _sec(String id) => TdxSection(
      id: id,
      liveApi: 'P',
      system: 'P',
      ref: '61',
      roadName: '西部濱海快速公路',
      direction: 'S',
      startKm: 100,
      endKm: 101.26,
      speedLimit: 0,
      vdLinks: const {},
      points: Float64List.fromList([120.5, 24.2, 120.5, 24.19]),
    );

void main() {
  group('fetchReport', () {
    test('列出查詢路段、車速來源與本線狀態', () {
      final segs = [
        const TrafficSegment('a', 0, 500, 85, TrafficLevel.smooth),
        const TrafficSegment('b', 500, 700, 30, TrafficLevel.jammed),
      ];
      final r = TrafficService.fetchReport(
        sections: [_sec('a'), _sec('b'), _sec('c')],
        speeds: {'a': 85.04, 'b': 30},
        fromVd: {'b'},
        state: TrafficState(
          roadName: '西部濱海快速公路',
          system: 'P',
          ref: '61',
          direction: 'S',
          km: 100.04,
          isFastRoad: true,
          segments: segs,
          congestion: TrafficService.findCongestion(segs, 100.04, 1),
        ),
        previews: const [],
        cms: const CmsNotice('CMS-1', '前方事故', 1234.4),
        elapsedMs: 420,
      );

      expect(r['ok'], isTrue);
      expect(r.containsKey('error'), isFalse);
      final sections = r['sections'] as List;
      expect(sections[0]['speed'], 85.0);
      expect(sections[0]['src'], 'live');
      expect(sections[1]['src'], 'vd');
      expect(sections[2]['speed'], isNull);
      expect(sections[2]['src'], isNull);
      expect(sections[0]['end_km'], 101.3);

      final main = r['main'] as Map;
      expect(main['km'], 100.0);
      expect(main['segs'][1], ['b', 500, 700, 30, TrafficLevel.jammed]);
      expect(main['jam']['dist'], 500);
      expect(r['ramps'], isEmpty);
      expect(r['cms'], {'id': 'CMS-1', 'text': '前方事故', 'dist': 1234});
    });

    test('查詢失敗時 ok 為 false 並帶錯誤', () {
      final r = TrafficService.fetchReport(
        sections: [_sec('a')],
        speeds: const {},
        fromVd: const {},
        state: null,
        previews: const [],
        cms: null,
        elapsedMs: 10,
        error: 'timeout',
      );
      expect(r['ok'], isFalse);
      expect(r['error'], 'timeout');
      expect(r['main'], isNull);
      expect(r['cms'], isNull);
    });
  });

  group('levelFor', () {
    test('國道門檻與 RoadRader 相同量級（速限 100：84/60/40）', () {
      int lv(double s) => TrafficService.levelFor(s, 100, fastRoad: true);
      expect(lv(85), TrafficLevel.smooth);
      expect(lv(70), TrafficLevel.busy);
      expect(lv(50), TrafficLevel.slow);
      expect(lv(30), TrafficLevel.jammed);
    });

    test('平面省道放寬，號誌等候不算壅塞', () {
      expect(TrafficService.levelFor(40, 60, fastRoad: false), TrafficLevel.smooth);
      expect(TrafficService.levelFor(40, 60, fastRoad: true), TrafficLevel.busy);
    });

    test('沒有車速就是未知', () {
      expect(TrafficService.levelFor(null, 90, fastRoad: true), TrafficLevel.unknown);
    });
  });

  group('findCongestion', () {
    test('合併相連的緩慢與壅塞路段', () {
      final segs = [
        _seg(0, 500, 85, TrafficLevel.smooth),
        _seg(500, 700, 45, TrafficLevel.slow),
        _seg(1200, 800, 20, TrafficLevel.jammed),
        _seg(2000, 600, 80, TrafficLevel.smooth),
        _seg(2600, 600, 20, TrafficLevel.jammed),
      ];
      final c = TrafficService.findCongestion(segs, 100.0, 1)!;
      expect(c.distanceM, 500);
      expect(c.lengthM, 1500);
      expect(c.speed, 20);
      expect(c.level, TrafficLevel.jammed);
      expect(c.startKm, closeTo(100.5, 1e-9));
    });

    test('里程遞減方向的起點里程', () {
      final segs = [_seg(0, 300, 85, 0), _seg(300, 700, 30, TrafficLevel.jammed)];
      expect(TrafficService.findCongestion(segs, 100.0, -1)!.startKm, closeTo(99.7, 1e-9));
    });

    test('中間缺段就不合併', () {
      final segs = [
        _seg(0, 500, 30, TrafficLevel.jammed),
        _seg(1500, 500, 30, TrafficLevel.jammed),
      ];
      expect(TrafficService.findCongestion(segs, 0, 1)!.lengthM, 500);
    });

    test('沒有資料或全部順暢時為 null', () {
      expect(TrafficService.findCongestion([_seg(0, 500, null, TrafficLevel.unknown)], 0, 1), isNull);
      expect(TrafficService.findCongestion([_seg(0, 500, 90, TrafficLevel.smooth)], 0, 1), isNull);
    });
  });

  test('播報文字', () {
    expect(
      TrafficService.announcementFor(
          const CongestionAhead(1230, 3000, 24.6, TrafficLevel.jammed, 0)),
      '前方1.2公里壅塞，長約3公里，車速25',
    );
    expect(
      TrafficService.announcementFor(
          const CongestionAhead(640, 800, 45, TrafficLevel.slow, 0)),
      '前方600公尺車流緩慢，長約800公尺，車速45',
    );
  });

  test('閘道前預知的播報文字', () {
    RampPreview preview(String sys, String ref, String dir) => RampPreview(
          roadName: '',
          system: sys,
          ref: ref,
          cardinal: dir,
          mergeDistanceM: 600,
          segments: const [],
          congestion: null,
        );
    expect(
      TrafficService.rampAnnouncementFor(preview('P', '61', 'S'),
          const CongestionAhead(2000, 3000, 18, TrafficLevel.jammed, 0)),
      '上台61南下，前方2公里壅塞，長約3公里，車速18',
    );
    expect(
      TrafficService.rampAnnouncementFor(preview('F', '1', 'N'),
          const CongestionAhead(0, 1500, 35, TrafficLevel.slow, 0)),
      '上國道1號北上即車流緩慢，長約1.5公里，車速35',
    );
  });
}
