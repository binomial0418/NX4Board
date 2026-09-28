import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/osm_road.dart';
import '../models/tdx_section.dart';
import 'settings_service.dart';
import 'tdx_client.dart';
import 'traffic_matcher.dart';
import 'tts_service.dart';

/// 路況等級
class TrafficLevel {
  static const unknown = -1;
  static const smooth = 0;
  static const busy = 1;
  static const slow = 2;
  static const jammed = 3;
}

/// 前方一個路段的路況
class TrafficSegment {
  final String id;
  final double distanceM;
  final double lengthM;

  /// 旅行速率 km/h，尚未取得或無資料為 null
  final double? speed;
  final int level;

  const TrafficSegment(this.id, this.distanceM, this.lengthM, this.speed, this.level);
}

/// 前方第一段連續的緩慢／壅塞
class CongestionAhead {
  final double distanceM;
  final double lengthM;

  /// 區間內最低的旅行速率
  final double speed;

  /// 區間內最嚴重的等級
  final int level;

  /// 區間起點的里程，用來判斷是不是已經播報過的同一段壅塞
  final double startKm;

  const CongestionAhead(this.distanceM, this.lengthM, this.speed, this.level, this.startKm);
}

class TrafficState {
  final String roadName;
  final String system;
  final String ref;
  final String direction;
  final double km;

  /// 國道或快速公路。壅塞語音只在這類道路播報，平面省道的旅行速率含號誌等候，偏低是常態
  final bool isFastRoad;

  final List<TrafficSegment> segments;
  final CongestionAhead? congestion;

  const TrafficState({
    required this.roadName,
    required this.system,
    required this.ref,
    required this.direction,
    required this.km,
    required this.isFastRoad,
    required this.segments,
    required this.congestion,
  });
}

class _Live {
  final double? speed;
  final DateTime fetchedAt;
  const _Live(this.speed, this.fetchedAt);
}

/// 前方路況：以 TDX 路段比對所在位置，按段查詢即時旅行速率。
///
/// 流程：
///   1. [TrafficMatcher] 依追蹤器判定的道路與航向找出所在路段與里程
///   2. 列出同路線前方 [scanKm] 公里的路段
///   3. 每 [refreshInterval] 只查這幾段的車速（國道 Live/Freeway、省道 Live/Highway，
///      省道沒有路段車速時改查對應 VD 的同向鏈路）
///   4. 找出前方第一段連續的緩慢／壅塞，國道與快速公路上以語音提醒
///
/// TDX 憑證放在 `assets/private/tdx.json`（{"client_id": ..., "client_secret": ...}），
/// 已被 .gitignore 排除。沒有這個檔案時路況功能停用，其餘功能不受影響。
class TrafficService {
  static final TrafficService _instance = TrafficService._internal();
  factory TrafficService() => _instance;
  TrafficService._internal();

  static const double scanKm = 10;

  /// TDX 路段與 VD 資料都是每 60 秒更新
  static const Duration refreshInterval = Duration(seconds: 60);

  /// 請求失敗或正在切換路段時，兩次請求的最短間隔
  static const Duration minRetry = Duration(seconds: 20);

  /// 超過這個時間的車速不再採用
  static const Duration staleAfter = Duration(minutes: 5);

  /// 暫時比對不到路段（匝道、GPS 飄移）時保留上一次結果的時間
  static const Duration holdOnLoss = Duration(seconds: 10);

  /// 同一段壅塞不重複播報的時間，以及判定為同一段的里程差
  static const Duration announceCooldown = Duration(minutes: 10);
  static const double sameCongestionKm = 2;

  TdxSectionIndex? _index;
  TrafficMatcher? _matcher;
  TdxClient? _client;

  final Map<String, _Live> _live = {};
  List<AheadSection> _ahead = const [];
  int? _roadLimit;
  DateTime? _lostSince;
  bool _fetching = false;
  DateTime? _lastAttempt;

  double? _announcedKm;
  String? _announcedRoad;
  DateTime? _announcedAt;

  TrafficState? _state;
  TrafficState? get state => _state;

  /// 非同步取得車速後通知 UI
  VoidCallback? onChanged;

  /// 路段資料與憑證都已載入
  bool get isAvailable => _matcher != null && _client != null;

  Future<void> init() async {
    if (_index != null) return;
    try {
      final data = await rootBundle.load('assets/tdx_sections.json.gz');
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      _index = await compute(TdxSectionIndex.decode, bytes);
      _matcher = TrafficMatcher(_index!);
      debugPrint('✅ TrafficService: ${_index!.sections.length} 個 TDX 路段');
    } catch (e) {
      debugPrint('❌ TrafficService: 路段資料載入失敗 $e');
      return;
    }
    try {
      final json = jsonDecode(await rootBundle.loadString('assets/private/tdx.json'))
          as Map<String, dynamic>;
      final id = (json['client_id'] as String? ?? '').trim();
      final secret = (json['client_secret'] as String? ?? '').trim();
      if (id.isEmpty || secret.isEmpty) {
        debugPrint('⚠️ TrafficService: assets/private/tdx.json 尚未填入憑證，路況停用');
        return;
      }
      _client = TdxClient(id, secret);
    } catch (e) {
      debugPrint('⚠️ TrafficService: 找不到 assets/private/tdx.json，路況停用');
    }
  }

  /// 每次定位呼叫。[road] 為追蹤器判定的道路；高架／平面沒把握時應傳 null，
  /// 否則高架下的側車道會拿到主線的路況。
  void update(
    double lat,
    double lon, {
    required OsmRoad? road,
    double? headingDeg,
    double speedKmh = 0,
    int? roadLimit,
  }) {
    final matcher = _matcher;
    if (matcher == null || _client == null || !SettingsService().trafficEnabled) {
      _clear();
      return;
    }

    final pos = matcher.update(lat, lon, road: road, headingDeg: headingDeg, speedKmh: speedKmh);
    final now = DateTime.now();
    if (pos == null) {
      _lostSince ??= now;
      if (now.difference(_lostSince!) > holdOnLoss) _clear();
      return;
    }
    _lostSince = null;
    _roadLimit = roadLimit;
    _ahead = matcher.ahead(scanKm);
    _rebuildState();
    _maybeRefresh();
    _maybeAnnounce(speedKmh);
  }

  void _clear() {
    _ahead = const [];
    _state = null;
    _lostSince = null;
  }

  static bool _isFastRoad(TdxSection s) =>
      s.system == 'F' || TrafficMatcher.isExpresswayRef(s.ref);

  /// 依旅行速率與參考速限換算等級。
  ///
  /// 國道與快速公路沿用 RoadRader 實際使用過的門檻（國道 84/60/40、台61 70/50/41，
  /// 換算成速限比例約 0.8/0.6/0.4）。平面省道的旅行速率含號誌等候，同樣比例會
  /// 滿街都是壅塞，所以放寬。
  @visibleForTesting
  static int levelFor(double? speed, int refLimit, {required bool fastRoad}) {
    if (speed == null || refLimit <= 0) return TrafficLevel.unknown;
    final r = speed / refLimit;
    final t = fastRoad ? const [0.8, 0.6, 0.4] : const [0.6, 0.4, 0.25];
    if (r >= t[0]) return TrafficLevel.smooth;
    if (r >= t[1]) return TrafficLevel.busy;
    if (r >= t[2]) return TrafficLevel.slow;
    return TrafficLevel.jammed;
  }

  int _refLimitFor(TdxSection s) {
    if (s.speedLimit > 0) return s.speedLimit;
    if (_roadLimit != null && _roadLimit! > 0) return _roadLimit!;
    return _isFastRoad(s) ? 90 : 50;
  }

  void _rebuildState() {
    final pos = _matcher?.current;
    if (pos == null || _ahead.isEmpty) {
      _state = null;
      return;
    }
    final now = DateTime.now();
    final fast = _isFastRoad(pos.section);
    final segments = <TrafficSegment>[];
    for (final a in _ahead) {
      final live = _live[a.section.id];
      final speed = (live != null && now.difference(live.fetchedAt) < staleAfter) ? live.speed : null;
      segments.add(TrafficSegment(a.section.id, a.distanceM, a.lengthM, speed,
          levelFor(speed, _refLimitFor(a.section), fastRoad: fast)));
    }
    _state = TrafficState(
      roadName: pos.section.roadName,
      system: pos.section.system,
      ref: pos.section.ref,
      direction: pos.section.direction,
      km: pos.km,
      isFastRoad: fast,
      segments: segments,
      congestion: findCongestion(segments, pos.km, pos.section.kmSign),
    );
  }

  /// 前方第一段連續的緩慢／壅塞。路段之間相隔超過 100 公尺（資料缺段）就視為中斷。
  @visibleForTesting
  static CongestionAhead? findCongestion(List<TrafficSegment> segs, double km, int kmSign) {
    int start = segs.indexWhere((s) => s.level >= TrafficLevel.slow);
    if (start < 0) return null;
    double end = segs[start].distanceM + segs[start].lengthM;
    double minSpeed = segs[start].speed!;
    int level = segs[start].level;
    for (int i = start + 1; i < segs.length; i++) {
      final s = segs[i];
      if (s.level < TrafficLevel.slow || s.distanceM > end + 100) break;
      end = math.max(end, s.distanceM + s.lengthM);
      minSpeed = math.min(minSpeed, s.speed!);
      level = math.max(level, s.level);
    }
    final from = segs[start].distanceM;
    return CongestionAhead(from, end - from, minSpeed, level, km + kmSign * from / 1000);
  }

  void _maybeRefresh() {
    final client = _client;
    if (client == null || _fetching || _ahead.isEmpty) return;
    final now = DateTime.now();
    if (_lastAttempt != null && now.difference(_lastAttempt!) < minRetry) return;

    final needed = _ahead
        .map((a) => a.section)
        .where((s) {
          final live = _live[s.id];
          return live == null || now.difference(live.fetchedAt) >= refreshInterval;
        })
        .toList();
    if (needed.isEmpty) return;

    _fetching = true;
    _lastAttempt = now;
    _fetch(client, needed).whenComplete(() => _fetching = false);
  }

  Future<void> _fetch(TdxClient client, List<TdxSection> sections) async {
    try {
      final speeds = <String, double>{};
      for (final api in const ['F', 'P']) {
        final ids = sections.where((s) => s.liveApi == api).map((s) => s.id).toList();
        if (ids.isEmpty) continue;
        speeds.addAll(await client.sectionSpeeds(api == 'F' ? 'Freeway' : 'Highway', ids));
      }

      // 台66～88 等路段在 Live/Highway 沒有車速，改用路段對應的 VD 同向鏈路
      final viaVd = sections.where((s) => !speeds.containsKey(s.id) && s.vdLinks.isNotEmpty).toList();
      if (viaVd.isNotEmpty) {
        final vdIds = viaVd.expand((s) => s.vdLinks.keys).toSet().toList();
        final vd = await client.vdLinkSpeeds(vdIds);
        for (final s in viaVd) {
          final values = <double>[];
          s.vdLinks.forEach((vdId, links) {
            for (final link in links) {
              final v = vd[vdId]?[link];
              if (v != null) values.add(v);
            }
          });
          if (values.isNotEmpty) {
            speeds[s.id] = values.reduce((a, b) => a + b) / values.length;
          }
        }
      }

      final now = DateTime.now();
      // 沒有資料的路段也記下，避免每 20 秒重查一次
      for (final s in sections) {
        _live[s.id] = _Live(speeds[s.id], now);
      }
      _live.removeWhere((_, v) => now.difference(v.fetchedAt) > const Duration(minutes: 10));

      _rebuildState();
      onChanged?.call();
    } catch (e) {
      debugPrint('[Traffic] 即時路況查詢失敗: $e');
    }
  }

  void _maybeAnnounce(double speedKmh) {
    final s = _state;
    final c = s?.congestion;
    if (s == null || c == null || !s.isFastRoad) return;
    if (!SettingsService().trafficVoice) return;
    // 已經在車陣裡或太近，播報沒有意義
    if (speedKmh < 40 || c.distanceM < 300) return;

    final now = DateTime.now();
    if (_announcedAt != null &&
        _announcedRoad == s.roadName &&
        now.difference(_announcedAt!) < announceCooldown &&
        (c.startKm - _announcedKm!).abs() < sameCongestionKm) {
      return;
    }
    _announcedAt = now;
    _announcedKm = c.startKm;
    _announcedRoad = s.roadName;
    TtsService().speak(announcementFor(c));
  }

  /// 例：「前方1.2公里壅塞，長約3公里，車速25」
  @visibleForTesting
  static String announcementFor(CongestionAhead c) {
    final what = c.level >= TrafficLevel.jammed ? '壅塞' : '車流緩慢';
    return '前方${_spokenDistance(c.distanceM)}$what，'
        '長約${_spokenDistance(c.lengthM)}，車速${c.speed.round()}';
  }

  static String _spokenDistance(double m) {
    if (m < 1000) return '${(m / 100).round().clamp(1, 9) * 100}公尺';
    final km = (m / 100).round() / 10;
    return km == km.roundToDouble() ? '${km.round()}公里' : '$km公里';
  }
}
