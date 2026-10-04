import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/osm_road.dart';
import '../models/tdx_section.dart';
import 'osm_tile_service.dart';
import 'ramp_finder.dart';
import 'settings_service.dart';
import 'speed_limit_service.dart';
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

/// 閘道前預知：上了某條主線某個方向之後的前方路況
class RampPreview {
  final String roadName;
  final String system;
  final String ref;

  /// 該方向的主要方位：'N' 北上、'S' 南下、'E' 東行、'W' 西行
  final String cardinal;

  /// 從目前位置到匯入點的距離（入口直線距離 + 匝道長度）
  final double mergeDistanceM;

  /// 距離都從匯入點起算
  final List<TrafficSegment> segments;
  final CongestionAhead? congestion;

  /// 上去之後最先有車速資料的路段（匯入點附近）的車速；還沒查到時為 null
  double? get firstSpeed {
    for (final s in segments) {
      if (s.speed != null) return s.speed;
    }
    return null;
  }

  /// 有資料的路段中最嚴重的等級；全部沒資料時為 [TrafficLevel.unknown]
  int get worstLevel => segments.fold(TrafficLevel.unknown, (a, s) => math.max(a, s.level));

  const RampPreview({
    required this.roadName,
    required this.system,
    required this.ref,
    required this.cardinal,
    required this.mergeDistanceM,
    required this.segments,
    required this.congestion,
  });
}

/// 前方資訊可變標誌（路上的文字看板）上的事件訊息
class CmsNotice {
  final String cmsId;

  /// 看板文字（空白已正規化）
  final String text;

  /// 從目前位置到看板的距離（公尺）
  final double distanceM;

  const CmsNotice(this.cmsId, this.text, this.distanceM);
}

class _Live {
  final double? speed;
  final DateTime fetchedAt;
  const _Live(this.speed, this.fetchedAt);
}

class _RampTrack {
  final RampTarget target;
  final SectionPosition pos;
  final List<AheadSection> ahead;
  const _RampTrack(this.target, this.pos, this.ahead);
}

/// 前方路況：以 TDX 路段比對所在位置，按段查詢即時旅行速率。
/// 只做國道與快速公路（台61～88），平面省道不查。
///
/// 流程：
///   1. [TrafficMatcher] 依追蹤器判定的道路與航向找出所在路段與里程
///   2. 列出同路線前方 [scanKm] 公里的路段
///   3. 每 [refreshInterval] 只查這幾段的車速（國道 Live/Freeway、省道 Live/Highway，
///      省道沒有路段車速時改查對應 VD 的同向鏈路）
///   4. 找出前方第一段連續的緩慢／壅塞，國道與快速公路上以語音提醒
///
/// 不在主線上時改做閘道前預知：[RampFinder] 找出前方的入口匝道並追到主線匯入點，
/// 從匯入點起算列出上去之後的路段（見 [rampPreviews]）。
///
/// TDX 憑證放在 `assets/private/tdx.json`（{"client_id": ..., "client_secret": ...}），
/// 已被 .gitignore 排除。沒有這個檔案時路況功能停用，其餘功能不受影響。
class TrafficService {
  static final TrafficService _instance = TrafficService._internal();
  factory TrafficService() => _instance;
  TrafficService._internal();

  static const double scanKm = 10;

  /// 車速多查這麼遠。每分鐘只查一批，行駛中一分鐘會前進 1.5～2 公里，
  /// 下一批之前會進入 [scanKm] 的路段都已經查過，不必為了新進來的路段補查。
  static const double prefetchKm = 5;

  /// TDX 路段與 VD 資料都是每 60 秒更新
  static const Duration refreshInterval = Duration(seconds: 60);

  /// 畫面上（本線前方 [scanKm] 內與閘道預知）有從沒查過的路段時，只補查那幾段的
  /// 最短間隔。剛上主線、剛偵測到閘道或系統交流道時路況才能馬上出現；追蹤器的
  /// 車流佐證（RoadTracker.fastFlowKmh）也要靠它，誤判到高架上時頭上那段通常還沒查過。
  /// 基礎會員時期（每分鐘 5 次）這要等 10～20 秒並記帳保留額度，銅級每秒 5 次後放寬。
  static const Duration earlyRetry = Duration(seconds: 3);

  /// 超過這個時間的車速不再採用
  static const Duration staleAfter = Duration(minutes: 5);

  /// 暫時比對不到路段（匝道、GPS 飄移）時保留上一次結果的時間
  static const Duration holdOnLoss = Duration(seconds: 10);

  /// 同一段壅塞不重複播報的時間，以及判定為同一段的里程差
  static const Duration announceCooldown = Duration(minutes: 10);
  static const double sameCongestionKm = 2;

  /// 通過入口後預知保留的額外距離。追蹤器在匝道緊貼平面道路時可能一直判成平面道路
  /// （台61 梧棲實測整段匝道 35 秒），入口一落到後方預知就會消失；保留到走完
  /// 匝道長度再加這段距離。代價是路過入口沒有上去時，預知會多顯示約一段匝道長。
  static const double rampHoldExtraM = 150;

  /// 離入口這麼近才開始計算保留距離
  static const double rampHoldArmM = 60;

  /// 保留期間離匝道路線超過這個距離，就是路過入口沒有上去，立刻取消。
  /// 梧棲那種追蹤器判錯的情況，車子其實就在匝道上，離匝道路線只有 GPS 誤差那麼遠；
  /// 國3 龍井交流道的匝道長 1 公里，沒有這個判斷時路過後提示會多掛 85 秒。
  static const double rampHoldOffPathM = 40;

  /// 兩次匝道播報的最短間隔（交流道兩個方向可能先後都偵測到壅塞）
  static const Duration rampAnnounceGap = Duration(seconds: 60);

  TdxSectionIndex? _index;
  TrafficMatcher? _matcher;
  TdxApi? _client;

  final Map<String, _Live> _live = {};

  /// 資訊可變標誌的即時訊息：CMSID → (訊息, 查詢時間)
  final Map<String, (List<CmsMessage>, DateTime)> _cms = {};

  /// 看板只列前方這麼遠的。比路況的 [scanKm] 短：看板內容多半講的是它附近的事
  static const double cmsScanKm = 8;

  /// 同一則看板文字在這段時間內只念一次（同一訊息常連續出現在好幾面看板上）
  static const Duration cmsAnnounceCooldown = Duration(minutes: 30);
  final Map<String, DateTime> _cmsAnnounced = {};

  CmsNotice? _cmsAhead;

  /// 前方最近一面顯示事件訊息（事故、壅塞、施工、封閉…）的看板；沒有為 null
  CmsNotice? get cmsAhead => _cmsAhead;

  /// 主線：目前所在路段（比對不到時保留 [holdOnLoss]）與前方路段
  SectionPosition? _pos;
  List<AheadSection> _ahead = const [];
  int? _roadLimit;
  DateTime? _lostSince;

  List<_RampTrack> _ramps = const [];
  double _odometerM = 0;
  DateTime? _lastUpdate;
  double? _holdUntilM;

  /// 保留啟動時通過的那幾條匝道。之後找到的入口可能換成別條（追蹤器還把車子當成在
  /// 平面道路上時，會找到前方另一個入口），判斷有沒有上匝道要用當初通過的這幾條
  List<RampTarget> _holdTargets = const [];
  DateTime? _lastRampAnnounce;

  bool _fetching = false;
  DateTime? _lastAttempt;

  /// 上一次補查沒資料路段的時間；不影響每分鐘一批的節奏
  DateTime? _lastEarly;

  /// 決定播報壅塞的累計次數。隨 esp32_dash 送給板子，數字變大時板子念
  /// 「注意前方路況」。用累計而不是旗標，200ms 一筆的推送掉包也不會漏念或重念
  int _alertCount = 0;
  int get alertCount => _alertCount;

  /// 已播報的壅塞：(路名, 起點里程, 時間)
  final List<(String, double, DateTime)> _announced = [];

  TrafficState? _state;
  TrafficState? get state => _state;

  List<RampPreview> _previews = const [];

  /// 不在主線上時，前方入口匝道各自上去之後的路況
  List<RampPreview> get rampPreviews => _previews;

  /// 目前所在快速路路段的即時車流（km/h），供 RoadTracker 當車流佐證；
  /// 不在主線上、比對暫時中斷、或這段還沒有新的資料時為 null。
  /// 只取已經查到的資料，不會為此多發請求。
  double? get currentFlowKmh {
    final pos = _pos;
    if (pos == null || _lostSince != null) return null;
    final live = _live[pos.section.id];
    if (live == null || _now().difference(live.fetchedAt) >= staleAfter) return null;
    return live.speed;
  }

  /// 閘道前預知中，前方有緩慢／壅塞的方向裡最嚴重（同級取最近）的一個
  RampPreview? get congestedRamp {
    RampPreview? best;
    for (final p in _previews) {
      final c = p.congestion;
      if (c == null) continue;
      final b = best?.congestion;
      if (b == null || c.level > b.level || (c.level == b.level && c.distanceM < b.distanceM)) {
        best = p;
      }
    }
    return best;
  }

  DateTime Function() _now = DateTime.now;
  bool Function() _voiceEnabled = () => SettingsService().trafficVoice;
  void Function(String) _speak = (text) => TtsService().speak(text);

  /// 測試用：換成假的 API 與時鐘，略過 rootBundle。
  /// [speak] 有給就把播報交給它（記錄用），沒給就關掉語音
  @visibleForTesting
  void setUpForTest(TdxSectionIndex index, TdxApi api, DateTime Function() clock,
      {void Function(String)? speak}) {
    _index = index;
    _matcher = TrafficMatcher(index);
    _client = api;
    _now = clock;
    _voiceEnabled = () => speak != null;
    _speak = speak ?? (_) {};
    _announced.clear();
    _lastRampAnnounce = null;
    _live.clear();
    _clearMain();
    _clearRamps();
    _lastUpdate = null;
    _lastAttempt = null;
    _lastEarly = null;
    _fetching = false;
  }

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
      _clearMain();
      _clearRamps();
      return;
    }

    final now = _now();
    if (_lastUpdate != null) {
      final dt = now.difference(_lastUpdate!).inMilliseconds / 1000.0;
      // 定位中斷太久就不累計，避免一次跳一大段
      if (dt < 10) _odometerM += speedKmh / 3.6 * dt;
    }
    _lastUpdate = now;

    final matched = matcher.update(lat, lon, road: road, headingDeg: headingDeg, speedKmh: speedKmh);
    // 只有國道與快速公路才查路況。平面省道（台1、台3…）的旅行速率含號誌等候，
    // 紅條與語音都不用，查了只是白白消耗 TDX 基礎會員每月約 4,300 次的額度。
    // 平面省道一律當作「不在主線上」，也因此能在台1 上預知前方國1 入口的路況。
    final pos = (matched != null && _isFastRoad(matched.section)) ? matched : null;
    if (pos != null) {
      // 剛從匝道上了主線：閘道前的預知功成身退，保留中的也不要（它指的就是這條主線）
      if (_pos == null) _clearRamps();
      _pos = pos;
      _lostSince = null;
      _roadLimit = roadLimit;
      _ahead = matcher.ahead(scanKm + prefetchKm);
      // 主線上照樣找前方的系統交流道，預知交會道路的路況；本身這條路不算
      _updateRamps(matcher, lat, lon, road, headingDeg, speedKmh,
          excludeRoad: pos.section.roadName);
    } else {
      _lostSince ??= now;
      if (now.difference(_lostSince!) > holdOnLoss) _clearMain();
      _updateRamps(matcher, lat, lon, road, headingDeg, speedKmh);
    }

    _rebuildState();
    _maybeRefresh();
    _maybeAnnounce(speedKmh);
  }

  void _clearMain() {
    _pos = null;
    _ahead = const [];
    _state = null;
    _cmsAhead = null;
    _lostSince = null;
  }

  void _clearRamps() {
    _ramps = const [];
    _previews = const [];
    _holdUntilM = null;
    _holdTargets = const [];
  }

  void _updateRamps(TrafficMatcher matcher, double lat, double lon, OsmRoad? road,
      double? headingDeg, double speedKmh, {String? excludeRoad}) {
    // 停車等紅燈時航向不可靠，維持原本的預知
    if (speedKmh < 5) return;
    if (road == null || headingDeg == null || headingDeg < 0) {
      if (!_holding || _offHeldRamps(lat, lon)) _clearRamps();
      return;
    }

    final roads = OsmTileService().cachedRoadsAround(lat, lon);
    final targets = RampFinder.find(roads, lat, lon, tracked: road, headingDeg: headingDeg);

    // 同一路線同一方向只留最近的匯入點
    final byLine = <String, _RampTrack>{};
    for (final t in targets) {
      final pos = matcher.locate(t.lat, t.lon, t.mainRoad, t.headingDeg);
      // 匝道也可能接到 trunk 分級的平面省道（台1 部分路段），同樣不查
      if (pos == null || !_isFastRoad(pos.section)) continue;
      if (pos.section.roadName == excludeRoad) continue;
      final key = '${pos.section.roadName}|${pos.section.kmSign}';
      final old = byLine[key];
      if (old == null ||
          t.entryDistanceM + t.rampLengthM < old.target.entryDistanceM + old.target.rampLengthM) {
        byLine[key] = _RampTrack(t, pos, matcher.aheadFrom(pos, scanKm));
      }
    }

    if (byLine.isNotEmpty) {
      _ramps = byLine.values.toList();
      // 到了入口（或已在匝道上）才開始算保留距離
      final near = _ramps.where((r) => r.target.entryDistanceM <= rampHoldArmM);
      if (near.isNotEmpty) {
        final ramp = near.map((r) => r.target.rampLengthM).reduce(math.max);
        _holdUntilM = _odometerM + ramp + rampHoldExtraM;
        _holdTargets = [for (final r in near) r.target];
      }
    } else if (!_holding || _offHeldRamps(lat, lon)) {
      _clearRamps();
    }
  }

  /// 保留中的預知是否已經離匝道路線太遠（路過入口沒有上去）
  bool _offHeldRamps(double lat, double lon) =>
      _holdTargets.every((t) => t.distanceToPathM(lat, lon) > rampHoldOffPathM);

  bool get _holding => _holdUntilM != null && _odometerM < _holdUntilM!;

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

  /// 路段的參考速限：國道路段自帶；省道路段沒有，用 [fallback]（所在或要上去的道路）
  static int _refLimitFor(TdxSection s, int? fallback) {
    if (s.speedLimit > 0) return s.speedLimit;
    if (fallback != null && fallback > 0) return fallback;
    return _isFastRoad(s) ? 90 : 50;
  }

  /// [offsetM] 加在每段的距離上：閘道預知時，匯入點到第一個路段之間若有缺口，
  /// 距離仍要從匯入點算起
  List<TrafficSegment> _segmentsFor(List<AheadSection> ahead, int? fallbackLimit, bool fast,
      {double offsetM = 0}) {
    final now = _now();
    return [
      for (final a in ahead)
        () {
          final live = _live[a.section.id];
          final speed =
              (live != null && now.difference(live.fetchedAt) < staleAfter) ? live.speed : null;
          return TrafficSegment(a.section.id, a.distanceM + offsetM, a.lengthM, speed,
              levelFor(speed, _refLimitFor(a.section, fallbackLimit), fastRoad: fast));
        }(),
    ];
  }

  void _rebuildState() {
    final pos = _pos;
    if (pos == null || _ahead.isEmpty) {
      _state = null;
    } else {
      final fast = _isFastRoad(pos.section);
      final shown = [for (final a in _ahead) if (a.distanceM <= scanKm * 1000) a];
      final segments = _segmentsFor(shown, _roadLimit, fast);
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
    _cmsAhead = _findCmsAhead();

    _previews = [
      for (final r in _ramps)
        () {
          final sec = r.pos.section;
          final main = r.target.mainRoad;
          // 省道路段沒有速限，用要上去的那條主線的 OSM 速限，不能用目前所在的平面道路
          final limit = SpeedLimitService.parseMaxspeed(main.maxspeed) ??
              SpeedLimitService.defaultLimitFor(main.highway);
          // distanceM 超過比對半徑表示匯入點落在路段缺口，是到第一個路段起點的距離
          final gap = r.pos.distanceM > _matcher!.matchRadiusM ? r.pos.distanceM : 0.0;
          final segments = _segmentsFor(r.ahead, limit, _isFastRoad(sec), offsetM: gap);
          return RampPreview(
            roadName: sec.roadName,
            system: sec.system,
            ref: sec.ref,
            cardinal: _index!.cardinalOf(sec),
            mergeDistanceM: r.target.entryDistanceM + r.target.rampLengthM,
            segments: segments,
            congestion: findCongestion(segments, r.pos.km, sec.kmSign),
          );
        }(),
    ];
  }

  /// 前方 [cmsScanKm] 內最近一面顯示事件訊息的看板
  CmsNotice? _findCmsAhead() {
    final pos = _pos;
    if (pos == null) return null;
    for (final a in _ahead) {
      if (a.distanceM > cmsScanKm * 1000) break;
      final current = identical(a.section, pos.section);
      for (final (id, along) in a.section.cms) {
        final d = current ? along - pos.alongM : a.distanceM + along;
        if (d <= 0 || d > cmsScanKm * 1000) continue;
        final live = _cms[id];
        if (live == null) continue;
        for (final m in live.$1) {
          final text = normalizeCms(m.text);
          if (isCmsEvent(text, m.type)) return CmsNotice(id, text, d);
        }
      }
    }
    return null;
  }

  static String normalizeCms(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

  static final RegExp _cmsEventWords =
      RegExp(r'事故|車禍|追撞|壅塞|擁塞|回堵|施工|封閉|封\(|改道|管制|落物|散落|濃霧|淹水|火警|故障車|事件');
  static final RegExp _cmsNotEvent =
      RegExp(r'請撥打|專線|0800|補助|備妥|應於後方|開罰|宣導|月車禍死亡|勿疲勞|-99');

  /// 看板訊息是不是事件（事故、壅塞、施工、封閉…），而不是宣導、收費或旅行時間。
  /// 國道看板有分類：Type 7 是事件／施工，Type 1 旅行時間一律不算；省道看板沒有分類，
  /// 只靠字詞。實測（2026-10-03）國道 977 則中事件 162 則、省道 1795 則中 465 則，
  /// 「散落物請撥打 0800…」「○○縣 9 月車禍死亡 4 人」這類宣導另外排除。
  @visibleForTesting
  static bool isCmsEvent(String text, int? type) {
    if (text.isEmpty || type == 1) return false;
    if (_cmsNotEvent.hasMatch(text)) return false;
    return type == 7 || _cmsEventWords.hasMatch(text);
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

  /// 每 [refreshInterval] 把前方所有路段（含預先查的部分與閘道預知）一次查完，
  /// 讓它們同時到期，下一批才不會因為到期時間錯開而拆成好幾次。
  /// 批次之間若畫面上出現從沒查過的路段，隔 [earlyRetry] 只補查那幾段。
  void _maybeRefresh() {
    final client = _client;
    if (client == null || _fetching) return;
    final now = _now();

    final wanted = <String, TdxSection>{
      for (final a in _ahead) a.section.id: a.section,
      for (final r in _ramps)
        for (final a in r.ahead) a.section.id: a.section,
    };
    if (wanted.isEmpty) return;
    final anyStale = wanted.values.any((s) {
      final live = _live[s.id];
      return live == null || now.difference(live.fetchedAt) >= refreshInterval;
    });
    if (!anyStale) return;

    final since = _lastAttempt == null ? null : now.difference(_lastAttempt!);
    if (since != null && since < refreshInterval) {
      final sinceEarly = _lastEarly == null ? null : now.difference(_lastEarly!);
      if (sinceEarly != null && sinceEarly < earlyRetry) return;
      // 查過但沒有資料的路段也記在 _live 裡，不會在這裡反覆補查
      final missing = <String, TdxSection>{
        for (final a in _ahead)
          if (a.distanceM <= scanKm * 1000 && _live[a.section.id] == null) a.section.id: a.section,
        for (final r in _ramps)
          for (final a in r.ahead)
            if (_live[a.section.id] == null) a.section.id: a.section,
      };
      if (missing.isEmpty) return;
      _fetching = true;
      _lastEarly = now;
      _fetch(client, missing.values.toList()).whenComplete(() => _fetching = false);
      return;
    }

    _fetching = true;
    _lastAttempt = now;
    _fetch(client, wanted.values.toList()).whenComplete(() => _fetching = false);
  }

  Future<void> _fetch(TdxApi client, List<TdxSection> sections) async {
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

      // 前方看板的即時訊息（只查主線前方 cmsScanKm 內的；閘道預知不查）
      final mainIds = {for (final a in _ahead) if (a.distanceM <= cmsScanKm * 1000) a.section.id};
      for (final api in const ['F', 'P']) {
        final ids = [
          for (final s in sections)
            if (s.liveApi == api && mainIds.contains(s.id))
              for (final c in s.cms) c.$1,
        ];
        if (ids.isEmpty) continue;
        final msgs = await client.cmsMessages(api == 'F' ? 'Freeway' : 'Highway', ids);
        final at = _now();
        for (final id in ids) {
          _cms[id] = (msgs[id] ?? const [], at);
        }
      }

      final now = _now();
      _cms.removeWhere((_, v) => now.difference(v.$2) > const Duration(minutes: 10));
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

  /// 同一段壅塞（同路名、起點里程相差 [sameCongestionKm] 內）在冷卻時間內只播一次。
  /// 閘道／交會道路預知與上了那條路之後共用這個判斷，上去之後不會把同一段再念一次。
  /// 主線上本線與交會道路的壅塞可能交替出現，所以記多筆而不是只記最後一筆。
  bool _alreadyAnnounced(String road, double startKm, DateTime now) => _announced.any((a) =>
      a.$1 == road &&
      now.difference(a.$3) < announceCooldown &&
      (startKm - a.$2).abs() < sameCongestionKm);

  void _markAnnounced(String road, double startKm, DateTime now) {
    _announced.removeWhere((a) => now.difference(a.$3) >= announceCooldown);
    _announced.add((road, startKm, now));
  }

  /// 播報順序與畫面相同：交會道路（或閘道前預知）有壅塞優先，其次本線前方。
  /// 一次只播一則，另一則留到下一個定位點再判斷。
  void _maybeAnnounce(double speedKmh) {
    if (!_voiceEnabled()) return;
    final now = _now();

    final p = congestedRamp;
    final rc = p?.congestion;
    if (p != null &&
        rc != null &&
        speedKmh >= 10 &&
        (_lastRampAnnounce == null || now.difference(_lastRampAnnounce!) >= rampAnnounceGap) &&
        !_alreadyAnnounced(p.roadName, rc.startKm, now)) {
      _markAnnounced(p.roadName, rc.startKm, now);
      _lastRampAnnounce = now;
      _alertCount++;
      _speak(rampAnnouncementFor(p, rc));
      return;
    }

    // 前方看板的事件訊息：同一則文字在冷卻時間內只念一次
    final cms = _cmsAhead;
    if (cms != null && speedKmh >= 10) {
      final last = _cmsAnnounced[cms.text];
      if (last == null || now.difference(last) >= cmsAnnounceCooldown) {
        _cmsAnnounced[cms.text] = now;
        _cmsAnnounced.removeWhere((_, t) => now.difference(t) >= cmsAnnounceCooldown);
        _speak(cmsAnnouncementFor(cms));
        return;
      }
    }

    final s = _state;
    final c = s?.congestion;
    if (s == null || c == null || !s.isFastRoad) return;
    // 已經在車陣裡或太近，播報沒有意義
    if (speedKmh < 40 || c.distanceM < 300) return;
    if (_alreadyAnnounced(s.roadName, c.startKm, now)) return;
    _markAnnounced(s.roadName, c.startKm, now);
    _alertCount++;
    _speak(announcementFor(c));
  }

  /// 例：「前方看板：國1 高架北向27-25K壅塞 車速40以下」
  @visibleForTesting
  static String cmsAnnouncementFor(CmsNotice n) => '前方看板：${n.text}';

  /// 例：「前方1.2公里壅塞，長約3公里，車速25」
  @visibleForTesting
  static String announcementFor(CongestionAhead c) {
    final what = c.level >= TrafficLevel.jammed ? '壅塞' : '車流緩慢';
    return '前方${_spokenDistance(c.distanceM)}$what，'
        '長約${_spokenDistance(c.lengthM)}，車速${c.speed.round()}';
  }

  /// 例：「上台61南下，前方2公里壅塞，長約3公里，車速25」；
  /// 壅塞從匯入點就開始時為「上台61南下即壅塞，…」
  @visibleForTesting
  static String rampAnnouncementFor(RampPreview p, CongestionAhead c) {
    final what = c.level >= TrafficLevel.jammed ? '壅塞' : '車流緩慢';
    final where = '上${spokenRoad(p.system, p.ref)}${cardinalZh(p.cardinal)}';
    final head = c.distanceM < 300 ? '$where即$what' : '$where，前方${_spokenDistance(c.distanceM)}$what';
    return '$head，長約${_spokenDistance(c.lengthM)}，車速${c.speed.round()}';
  }

  static String spokenRoad(String system, String ref) => system == 'F' ? '國道$ref號' : '台$ref';

  static String cardinalZh(String c) =>
      const {'N': '北上', 'S': '南下', 'E': '東行', 'W': '西行'}[c] ?? '';

  static String _spokenDistance(double m) {
    if (m < 1000) return '${(m / 100).round().clamp(1, 9) * 100}公尺';
    final km = (m / 100).round() / 10;
    return km == km.roundToDouble() ? '${km.round()}公里' : '$km公里';
  }

  /// ESP32 最多畫這麼多段前方路況
  static const int boardMaxSegs = 8;

  /// esp32_dash 的 traffic 欄位（見 dashboard_screen.dart 的 _sendEsp32DashData）。
  /// 路名只送系統與編號（F=國道、P=省道），
  /// ESP32 的中文字型沒有收錄路名用字。
  ///
  /// segs 每段為 [距起點公尺, 長度公尺, 車速 km/h（-1 無資料）, 等級]，
  /// 等級 -1 無資料、0 順暢、1 車多、2 緩慢、3 壅塞；第一段是目前所在路段。
  /// jam 是前方第一段連續的緩慢／壅塞，沒有時不送；只在國道與快速公路送，
  /// 平面省道的旅行速率含號誌等候，偏低是常態，每個路口都跳紅條只會是雜訊
  /// （與語音播報的條件相同）。
  ///
  /// 閘道前預知（平面接近閘道、或主線接近系統交流道）的路況不論好壞一律送。
  /// 提示條只有一條，依序取第一個成立的：
  ///   1. 閘道／交會道路有壅塞：jam 另帶 via，即要上的主線（sys/ref）與方向
  ///      （dir：N 北上、S 南下、E 東行、W 西行），距離從匯入點起算。
  ///      兩個方向時只送有壅塞的那一邊。匯入點就在眼前，所以優先於本線
  ///   2. 本線前方壅塞：jam（無 via）
  ///   3. 閘道／交會道路正常：ramp = {sys, ref, dirs: [{dir, level, speed}]}，
  ///      最近那條主線已查到車速的方向（最多兩個），level 0 順暢、1 車多；
  ///      板子顯示「閘道雙向暢通」或「閘道暢通」
  /// 不在主線上時 active 為 false。alerts 是壅塞提醒的累計次數（見 [alertCount]）。
  static Map<String, dynamic> boardPayload(TrafficState? t, List<RampPreview> previews,
      {int alerts = 0}) {
    final out = <String, dynamic>{"active": t != null, "alerts": alerts};
    if (t != null) {
      out.addAll({
        "sys": t.system,
        "ref": t.ref,
        "km": double.parse(t.km.toStringAsFixed(1)),
        "segs": [
          for (final s in t.segments.take(boardMaxSegs))
            [s.distanceM.round(), s.lengthM.round(), s.speed?.round() ?? -1, s.level],
        ],
      });
    }

    RampPreview? rampJam;
    for (final p in previews) {
      final c = p.congestion;
      if (c == null) continue;
      final b = rampJam?.congestion;
      if (b == null || c.level > b.level || (c.level == b.level && c.distanceM < b.distanceM)) {
        rampJam = p;
      }
    }
    final rc = rampJam?.congestion;
    if (rampJam != null && rc != null) {
      out["jam"] = {
        "dist": rc.distanceM.round(),
        "len": rc.lengthM.round(),
        "speed": rc.speed.round(),
        "level": rc.level,
        "via": {"sys": rampJam.system, "ref": rampJam.ref, "dir": rampJam.cardinal},
      };
      return out;
    }

    final c = t?.congestion;
    if (t != null && c != null && t.isFastRoad) {
      out["jam"] = {
        "dist": c.distanceM.round(),
        "len": c.lengthM.round(),
        "speed": c.speed.round(),
        "level": c.level,
      };
      return out;
    }

    final ready = [for (final p in previews) if (p.firstSpeed != null) p];
    if (ready.isNotEmpty) {
      ready.sort((a, b) => a.mergeDistanceM.compareTo(b.mergeDistanceM));
      final road = ready.first;
      final dirs = [
        for (final p in ready)
          if (p.system == road.system && p.ref == road.ref) p,
      ].take(2);
      out["ramp"] = {
        "sys": road.system,
        "ref": road.ref,
        "dirs": [
          for (final p in dirs)
            {"dir": p.cardinal, "level": p.worstLevel, "speed": p.firstSpeed!.round()},
        ],
      };
    }
    return out;
  }
}
