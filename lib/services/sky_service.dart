import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import 'road_tracker.dart' show SkyView, RoadTracker;
import 'speed_limit_service.dart';

/// 頭頂天空的判定本身（不碰平台串流與檔案），App 與重播測試（test/sky_replay_test.dart）共用。
///
/// 依據：高架橋面擋住頭頂。開進橋下，用於定位的衛星數會掉一半以上，出來立刻恢復；
/// 在橋上頭頂一定是開的。每秒一筆摘要（原生端 GnssSkyMonitor 在背景執行緒算好）：
///   - 頭頂被擋：用於定位的衛星 ≤ 最近 [refWindowMs] 內最多時的 [blockedRatio]；
///     或絕對門檻 ≤ [blockedMaxUsed] 且頭頂強訊號 ≤ [blockedMaxHiStrong]。
///     頭頂該有 ≥ [minHiTotal] 顆
///   - 頭頂開闊：用於定位的衛星 ≥ [openMinUsed]，且 ≥ 最近最多時的 [openRatio]
///     （參考值不足 [minRefUsed] 時改用頭頂強訊號 ≥ [openHiStrong]）
///   - 條件連續成立 [persistMs] 才改變判定，其他為 unknown
///
/// 相對門檻的由來（2026-10-04～08 台61 梧棲—龍井實車，標記路段 825 筆）：衛星總數每天、
/// 每個時段差很多，高架上中位 35 顆的日子，橋下也有 13 顆，原本的絕對門檻 ≤ 10 抓不到；
/// 相對比（目前／最近最多）在高架上中位 0.92、橋下 0.32。頭頂強訊號太不穩（高架上整分鐘
/// 為 0、橋下 2～4 都出現過），相對門檻成立時就不看它。高架邊緣的平面道路（早上北上
/// 西濱路）相對比約 0.7，開闊門檻要高到 0.85 才不會把它當成在橋上。
/// 參考窗 10 分鐘：在橋下開了 5 分鐘以後，5 分鐘的窗只剩橋下的低數值，會把橋下當開闊。
class SkyClassifier {
  static const int minHiTotal = 3;
  static const int blockedMaxUsed = 10;
  static const int blockedMaxHiStrong = 1;
  static const int openMinUsed = 15;
  static const int openHiStrong = 2;
  static const int persistMs = 2000;

  /// 相對門檻：和最近 [refWindowMs] 內用於定位的衛星最多時比較。
  /// 衛星總數每天、每個時段差很多，絕對門檻只在衛星少的時候抓得到橋下。
  static const int refWindowMs = 10 * 60 * 1000;
  static const int minRefUsed = 20;
  static const double blockedRatio = 0.5;
  static const double openRatio = 0.85;

  int? _blockedSince, _openSince;
  SkyView _view = SkyView.unknown;
  final List<(int, int)> _history = [];

  SkyView get view => _view;

  void reset() {
    _blockedSince = _openSince = null;
    _view = SkyView.unknown;
    _history.clear();
  }

  SkyView add(int tMs, {required int used, required int hiTotal, required int hiStrong}) {
    _history.add((tMs, used));
    while (_history.isNotEmpty && tMs - _history.first.$1 > refWindowMs) {
      _history.removeAt(0);
    }
    var ref = 0;
    for (final h in _history) {
      if (h.$2 > ref) ref = h.$2;
    }
    final relative = ref >= minRefUsed;
    final blocked = hiTotal >= minHiTotal &&
        ((used <= blockedMaxUsed && hiStrong <= blockedMaxHiStrong) ||
            (relative && used <= ref * blockedRatio));
    final open = used >= openMinUsed &&
        (relative ? used >= ref * openRatio : hiStrong >= openHiStrong);
    if (blocked) {
      _blockedSince ??= tMs;
      _openSince = null;
    } else if (open) {
      _openSince ??= tMs;
      _blockedSince = null;
    } else {
      _blockedSince = _openSince = null;
    }
    _view = _blockedSince != null && tMs - _blockedSince! >= persistMs
        ? SkyView.blocked
        : (_openSince != null && tMs - _openSince! >= persistMs ? SkyView.open : SkyView.unknown);
    return _view;
  }
}

/// 頭頂天空狀態（[SkyView]）：接原生端的衛星摘要交給 [SkyClassifier] 判定，給道路追蹤器
/// 當證據。另外每個定位點記一行到 sky_YYYYMMDD.jsonl（設定頁可匯出），用實際行車資料
/// 調門檻、重播（test/sky_replay_test.dart）。
class SkyService {
  SkyService._();
  static final SkyService _instance = SkyService._();
  factory SkyService() => _instance;

  static const _channel = EventChannel('com.duckegg.nx4board/gnss_sky');

  static const int staleMs = 3000;
  static const int _maxLogBytes = 100 * 1024 * 1024;

  StreamSubscription<dynamic>? _sub;
  Map<dynamic, dynamic>? _last;
  int _lastAtMs = 0;
  final SkyClassifier _classifier = SkyClassifier();

  IOSink? _log;
  String? _logDay;
  int _logLines = 0;

  /// 目前的頭頂天空狀態；資料過舊時為 unknown
  SkyView get view =>
      DateTime.now().millisecondsSinceEpoch - _lastAtMs > staleMs
          ? SkyView.unknown
          : _classifier.view;

  void start() {
    if (_sub != null || !Platform.isAndroid) return;
    _sub = _channel.receiveBroadcastStream().listen(_onSample, onError: (e) {
      debugPrint('[Sky] 原生串流錯誤: $e');
    });
  }

  void _onSample(dynamic e) {
    if (e is! Map) return;
    _last = e;
    _lastAtMs = DateTime.now().millisecondsSinceEpoch;
    _classifier.add(_lastAtMs,
        used: (e['used'] as num?)?.toInt() ?? 0,
        hiTotal: (e['hiTotal'] as num?)?.toInt() ?? 0,
        hiStrong: (e['hiStrong'] as num?)?.toInt() ?? 0);
  }

  // ── 紀錄 ────────────────────────────────────────────────────────────

  Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/skylog');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 每個定位點呼叫一次（AppProvider.updatePosition，速限判斷之後）
  Future<void> logFix(Position p) async {
    if (!Platform.isAndroid) return;
    try {
      final day = DateFormat('yyyyMMdd').format(DateTime.now());
      if (_log == null || _logDay != day) {
        await _closeLog();
        final d = await _dir();
        _log = File('${d.path}/sky_$day.jsonl').openWrite(mode: FileMode.append);
        _logDay = day;
        await _enforceQuota();
      }
      final sl = SpeedLimitService();
      final road = sl.currentRoad;
      final s = _last;
      _log!.writeln(jsonEncode({
        't': DateTime.now().millisecondsSinceEpoch,
        'gps': [p.latitude, p.longitude, (p.speed * 3.6).round(), p.heading.round(), p.accuracy.round()],
        if (s != null)
          'sky': [s['hiTotal'], s['hiStrong'], s['used'], s['top6'], s['hi']],
        'view': view.name,
        'applied': sl.lastSkyApplied.name,
        'road': [road?.name, road?.ref, road?.highway, road != null && RoadTracker.isElevated(road)],
        'unc': sl.isLevelUncertain,
      }));
      if (++_logLines % 30 == 0) await _log!.flush();
    } catch (e) {
      debugPrint('[Sky] 紀錄失敗: $e');
    }
  }

  Future<void> _closeLog() async {
    final l = _log;
    _log = null;
    if (l != null) {
      try {
        await l.flush();
        await l.close();
      } catch (_) {}
    }
  }

  Future<void> _enforceQuota() async {
    final files = await listLogs();
    var total = files.fold<int>(0, (s, f) => s + f.lengthSync());
    for (final f in files.reversed) {
      if (total <= _maxLogBytes) break;
      if (f.path.endsWith('sky_$_logDay.jsonl')) continue;
      total -= f.lengthSync();
      f.deleteSync();
    }
  }

  /// 紀錄檔，由新到舊。匯出前先 flush 今天的檔案。
  Future<List<File>> listLogs() async {
    if (!Platform.isAndroid) return const [];
    await _log?.flush();
    final d = await _dir();
    return d.listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl')).toList()
      ..sort((a, b) => b.path.compareTo(a.path));
  }

  Future<void> clearLogs() async {
    await _closeLog();
    for (final f in await listLogs()) {
      f.deleteSync();
    }
  }
}
