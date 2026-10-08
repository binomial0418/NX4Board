import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/services/traffic_service.dart';

TrafficSegment _seg(double dist, double len, double? speed, int level) =>
    TrafficSegment('x', dist, len, speed, level);

void main() {
  group('fetchMessage', () {
    TrafficState state(List<TrafficSegment> segs) => TrafficState(
          roadName: '西部濱海快速公路',
          system: 'P',
          ref: '61',
          direction: '1',
          km: 100.04,
          isFastRoad: true,
          segments: segs,
          congestion: TrafficService.findCongestion(segs, 100.04, 1),
        );

    test('本線順暢與壅塞', () {
      final smooth = [const TrafficSegment('a', 0, 500, 85, TrafficLevel.smooth)];
      expect(
          TrafficService.fetchMessage(
              state: state(smooth), cardinal: 'S', previews: const [], cms: null),
          '台61南下 暢通，車速85');
      final jam = [
        const TrafficSegment('a', 0, 500, 85, TrafficLevel.smooth),
        const TrafficSegment('b', 500, 1200, 25, TrafficLevel.jammed),
      ];
      expect(
          TrafficService.fetchMessage(
              state: state(jam), cardinal: 'S', previews: const [], cms: null),
          '台61南下 前方500公尺壅塞，長約1.2公里，車速25');
    });

    test('查詢失敗與看板事件', () {
      expect(
          TrafficService.fetchMessage(
              state: null, cardinal: null, previews: const [], cms: null, failed: true),
          '路況查詢失敗');
      expect(
          TrafficService.fetchMessage(
              state: null,
              cardinal: null,
              previews: const [],
              cms: const CmsNotice('CMS-1', '前方事故', 1234.4)),
          '無路況；前方看板：前方事故');
    });

    test('連同 JSON 外框塞得進中繼器的 MQTT 封包（payload 233 bytes）', () {
      final longCms = CmsNotice('CMS-1', '國1 高架北向27-25K壅塞 車速40以下 請改道台74 往台中市區請提早下交流道' * 2, 900);
      final jam = [
        const TrafficSegment('a', 0, 500, 85, TrafficLevel.smooth),
        const TrafficSegment('b', 500, 1200, 25, TrafficLevel.jammed),
      ];
      final msg = TrafficService.fetchMessage(
          state: state(jam), cardinal: 'S', previews: const [], cms: longCms);
      expect(utf8.encode(msg).length, lessThanOrEqualTo(TrafficService.messageMaxBytes));
      expect(msg, endsWith('…'));
      // 與 dashboard_screen.dart 的 _sendTrafficInfoViaWs 相同欄位、最長的數值
      final json = jsonEncode({
        "_type": "BVB-7980",
        "tid": "traffic-info",
        "tst": 1791101887,
        "lat": 24.198338,
        "lon": 120.519775,
        "msg": msg,
      });
      expect(utf8.encode(json).length, lessThanOrEqualTo(233));
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
