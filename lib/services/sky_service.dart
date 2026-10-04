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

/// 頭頂天空狀態：由衛星訊號判斷是否在高架橋面下（[SkyView]），給道路追蹤器當證據。
///
/// 依據：高架橋面擋住的是頭頂、高仰角的衛星。實測（台61 下的港埠路二段）開進橋下
/// 幾秒內，仰角 ≥ 60° 的強訊號衛星從 2~3 顆掉到 0，出來立刻恢復；在橋上則一定看得到。
/// 衛星總數本身會隨時段與手機位置浮動，不拿來當門檻。
///
/// 判定（每秒一筆，原生端 GnssSkyMonitor 在背景執行緒算好摘要）：
///   - 頭頂被擋：用於定位的衛星 ≤ [blockedMaxUsed] 且頭頂強訊號 ≤ [blockedMaxHiStrong]
///     （頭頂該有 ≥ [minHiTotal] 顆），連續 [persistS] 秒
///   - 頭頂開闊：用於定位的衛星 ≥ [openMinUsed] 且頭頂強訊號 ≥ [openHiStrong]，連續 [persistS] 秒
///   - 其他、資料超過 [staleMs] 沒更新：unknown
///
/// 門檻依 2026-10-03/04 兩天實車（1,440 筆）：高架上用於定位的衛星 p5 17 顆、中位 23；
/// 已知在台61 下的港埠路 6~8 顆、頭頂強訊號 0~2（其中 1、2 交替出現，原本「連續 3 秒為 0」
/// 幾乎判不到，還把兩秒的 2 當成開闊、把車推上高架）。一般道路 8~25，只在重疊路段才用，
/// 所以市區衛星少不會誤判。衛星幾乎全失（< 4 顆）也算被擋——那正是橋下最深處。
///
/// 另外每個定位點記一行到 sky_YYYYMMDD.jsonl（設定頁可匯出），之後用實際行車
/// 資料調門檻。
class SkyService {
  SkyService._();
  static final SkyService _instance = SkyService._();
  factory SkyService() => _instance;

  static const _channel = EventChannel('com.duckegg.nx4board/gnss_sky');

  static const int minHiTotal = 3;
  static const int blockedMaxUsed = 10;
  static const int blockedMaxHiStrong = 1;
  static const int openMinUsed = 15;
  static const int openHiStrong = 2;
  static const int persistS = 3;
  static const int staleMs = 3000;
  static const int _maxLogBytes = 100 * 1024 * 1024;

  StreamSubscription<dynamic>? _sub;
  Map<dynamic, dynamic>? _last;
  int _lastAtMs = 0;
  int _blockedRun = 0, _openRun = 0;
  SkyView _view = SkyView.unknown;

  IOSink? _log;
  String? _logDay;
  int _logLines = 0;

  /// 目前的頭頂天空狀態；資料過舊時為 unknown
  SkyView get view =>
      DateTime.now().millisecondsSinceEpoch - _lastAtMs > staleMs ? SkyView.unknown : _view;

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
    final used = (e['used'] as num?)?.toInt() ?? 0;
    final hiTotal = (e['hiTotal'] as num?)?.toInt() ?? 0;
    final hiStrong = (e['hiStrong'] as num?)?.toInt() ?? 0;
    if (hiTotal >= minHiTotal && used <= blockedMaxUsed && hiStrong <= blockedMaxHiStrong) {
      _blockedRun++;
      _openRun = 0;
    } else if (used >= openMinUsed && hiStrong >= openHiStrong) {
      _openRun++;
      _blockedRun = 0;
    } else {
      _blockedRun = _openRun = 0;
    }
    _view = _blockedRun >= persistS
        ? SkyView.blocked
        : (_openRun >= persistS ? SkyView.open : SkyView.unknown);
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
