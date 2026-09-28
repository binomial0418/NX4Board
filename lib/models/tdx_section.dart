import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math' as math;
import 'dart:typed_data';

/// TDX 發布即時路況的一個路段，由 `tools/tdx_sections.py` 打包。
///
/// 每段有固定方向：折線的點序就是行車方向，[startKm] → [endKm] 是沿行車方向的里程。
/// 雙向路段的折線中位數只相距 11 公尺，所以比對時一定要看航向。
class TdxSection {
  final String id;

  /// 查即時路況用的 API：'F' → Live/Freeway，'P' → Live/Highway
  final String liveApi;

  /// 'F' 國道、'P' 省道，對應 OSM 的 motorway 與其他分級
  final String system;

  /// 路線編號，與 OSM ref 相同寫法（"1"、"61"、"3甲"）
  final String ref;

  /// 路名。同編號的平行路線（國1 與汐五高架）靠它分開，前方路段只沿同名路線找
  final String roadName;

  /// TDX 標示的方向（N、NE、…），僅供顯示
  final String direction;

  final double startKm;
  final double endKm;

  /// 國道路段的速限，省道為 0
  final int speedLimit;

  /// 對應的 VD 與其偵測鏈路；Live/Highway 沒有這段的車速時改查 VD
  final Map<String, List<String>> vdLinks;

  /// 扁平的 [lon, lat, lon, lat, ...]
  final Float64List points;

  /// 每個頂點沿折線的累積長度（公尺）
  final Float64List cumulativeM;

  TdxSection({
    required this.id,
    required this.liveApi,
    required this.system,
    required this.ref,
    required this.roadName,
    required this.direction,
    required this.startKm,
    required this.endKm,
    required this.speedLimit,
    required this.vdLinks,
    required this.points,
  }) : cumulativeM = _cumulative(points);

  /// 里程沿行車方向遞增為 +1，遞減為 -1
  int get kmSign => endKm >= startKm ? 1 : -1;

  double get lengthM => cumulativeM.isEmpty ? 0 : cumulativeM.last;

  /// 沿折線走了 [alongM] 公尺時的里程
  double kmAt(double alongM) {
    if (lengthM <= 0) return startKm;
    final t = (alongM / lengthM).clamp(0.0, 1.0);
    return startKm + (endKm - startKm) * t;
  }

  factory TdxSection.fromJson(Map<String, dynamic> j) {
    final deltas = (j['p'] as List).cast<int>();
    final pts = Float64List(deltas.length);
    int x = 0, y = 0;
    for (int i = 0; i + 1 < deltas.length; i += 2) {
      x += deltas[i];
      y += deltas[i + 1];
      pts[i] = x / 1e5;
      pts[i + 1] = y / 1e5;
    }
    final vd = <String, List<String>>{};
    (j['v'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      vd[k] = (v as List).cast<String>();
    });
    return TdxSection(
      id: j['i'] as String,
      liveApi: j['q'] as String,
      system: j['s'] as String,
      ref: j['r'] as String,
      roadName: j['n'] as String,
      direction: j['d'] as String? ?? '',
      startKm: (j['a'] as num).toDouble(),
      endKm: (j['b'] as num).toDouble(),
      speedLimit: (j['l'] as num?)?.toInt() ?? 0,
      vdLinks: vd,
      points: pts,
    );
  }

  static Float64List _cumulative(Float64List pts) {
    final n = pts.length ~/ 2;
    final out = Float64List(n);
    for (int i = 1; i < n; i++) {
      out[i] = out[i - 1] +
          _distanceM(pts[2 * i - 1], pts[2 * i - 2], pts[2 * i + 1], pts[2 * i]);
    }
    return out;
  }

  static double _distanceM(double lat1, double lon1, double lat2, double lon2) {
    final kx = 111320.0 * math.cos(lat1 * math.pi / 180.0);
    final dx = (lon2 - lon1) * kx;
    final dy = (lat2 - lat1) * 110574.0;
    return math.sqrt(dx * dx + dy * dy);
  }
}

/// 全部路段與網格索引。網格 0.01°（約 1 公里），每格記錄折線經過的路段。
class TdxSectionIndex {
  static const double _cellDeg = 0.01;

  final List<TdxSection> sections;
  final Map<int, List<int>> _grid = {};

  /// 同一路名、同一行車方向（里程遞增或遞減）的路段，依行車方向排序
  final Map<String, List<TdxSection>> _lines = {};

  /// 每條路線的主要方向：'N'、'S'、'E'、'W'
  final Map<String, String> _cardinal = {};

  TdxSectionIndex(this.sections) {
    for (int s = 0; s < sections.length; s++) {
      final p = sections[s].points;
      for (int i = 0; i + 3 < p.length; i += 2) {
        final x0 = (math.min(p[i], p[i + 2]) / _cellDeg).floor();
        final x1 = (math.max(p[i], p[i + 2]) / _cellDeg).floor();
        final y0 = (math.min(p[i + 1], p[i + 3]) / _cellDeg).floor();
        final y1 = (math.max(p[i + 1], p[i + 3]) / _cellDeg).floor();
        for (int x = x0; x <= x1; x++) {
          for (int y = y0; y <= y1; y++) {
            final cell = _grid.putIfAbsent(_key(x, y), () => []);
            if (cell.isEmpty || cell.last != s) cell.add(s);
          }
        }
      }
    }
    for (final sec in sections) {
      _lines.putIfAbsent(_lineKey(sec), () => []).add(sec);
    }
    for (final line in _lines.values) {
      // 沿行車方向排序：遞增方向依起點由小到大，遞減方向由大到小
      line.sort((a, b) => (a.startKm - b.startKm).sign.toInt() * a.kmSign);
    }
    _lines.forEach((key, line) => _cardinal[key] = _dominantCardinal(line));
  }

  /// 路線的主要方向。軸向依台灣的編號慣例：奇數為南北向（國1、台61）、偶數為東西向
  /// （國4、台64），國3甲 是唯一例外（東西向）。只看路段 RoadDirection 的多數不可靠——
  /// 台64 里程遞增方向偏南的路段比偏東的多，會被判成「南下」，但路牌是東行。
  /// 軸向決定後，再取該軸上路段方向的多數（台61 北上有 N 也有 NE）。
  static String _dominantCardinal(List<TdxSection> line) {
    final count = {'N': 0, 'S': 0, 'E': 0, 'W': 0};
    for (final s in line) {
      for (final c in s.direction.split('')) {
        if (count.containsKey(c)) count[c] = count[c]! + 1;
      }
    }
    final ref = line.first.ref;
    final n = int.tryParse(RegExp(r'^\d+').stringMatch(ref) ?? '');
    final bool northSouth;
    if (line.first.system == 'F' && ref == '3甲') {
      northSouth = false;
    } else if (n != null) {
      northSouth = n.isOdd;
    } else {
      northSouth = count['N']! + count['S']! >= count['E']! + count['W']!;
    }
    if (northSouth) return count['N']! >= count['S']! ? 'N' : 'S';
    return count['E']! >= count['W']! ? 'E' : 'W';
  }

  /// [section] 所屬路線的主要方向：'N'、'S'、'E'、'W'
  String cardinalOf(TdxSection section) => _cardinal[_lineKey(section)] ?? 'N';

  static String _lineKey(TdxSection s) => '${s.roadName}|${s.kmSign}';

  static int _key(int x, int y) => x * 100000 + y;

  /// 與 [section] 同路名、同方向的路段，依行車方向排序
  List<TdxSection> lineOf(TdxSection section) => _lines[_lineKey(section)] ?? const [];

  /// 可能在 [radiusM] 公尺內的路段（僅以網格粗篩）
  Iterable<TdxSection> near(double lat, double lon, double radiusM) sync* {
    final d = radiusM / 111000.0;
    final x0 = ((lon - d) / _cellDeg).floor();
    final x1 = ((lon + d) / _cellDeg).floor();
    final y0 = ((lat - d) / _cellDeg).floor();
    final y1 = ((lat + d) / _cellDeg).floor();
    final seen = <int>{};
    for (int x = x0; x <= x1; x++) {
      for (int y = y0; y <= y1; y++) {
        for (final s in _grid[_key(x, y)] ?? const <int>[]) {
          if (seen.add(s)) yield sections[s];
        }
      }
    }
  }

  static TdxSectionIndex decode(List<int> gzBytes) {
    final json = jsonDecode(utf8.decode(gzip.decode(gzBytes))) as Map<String, dynamic>;
    final list = (json['sections'] as List)
        .map((e) => TdxSection.fromJson(e as Map<String, dynamic>))
        .toList();
    return TdxSectionIndex(list);
  }
}
