import 'dart:convert';
import 'dart:typed_data';

/// OSM 圖資中的一條道路（已裁切到單一 tile 範圍內）。
///
/// 欄位名稱對應打包時的縮寫，見 `tools/build_tiles.py`：
/// n=name, r=ref, h=highway, s=maxspeed, o=oneway, b=bridge, u=tunnel, l=layer
class OsmRoad {
  final String? name;
  final String? ref;
  final String highway;
  final String? maxspeed;
  final String? oneway;
  final String? bridge;
  final String? tunnel;
  final String? layer;

  /// 折線集合，每條折線是扁平的 [lon, lat, lon, lat, ...]
  final List<Float64List> lines;

  const OsmRoad({
    required this.name,
    required this.ref,
    required this.highway,
    required this.maxspeed,
    required this.oneway,
    required this.bridge,
    required this.tunnel,
    required this.layer,
    required this.lines,
  });

  static final RegExp _sectionSuffix = RegExp(r'[一二三四五六七八九十]+段$');

  /// 「同一條路」的鍵：去掉「X段」的路名加上 ref。中央路一段接中央路二段算同一條路。
  /// 沒有路名也沒有 ref 的道路回傳 null——無從判斷是不是同一條路。
  String? get routeKey {
    final base = name?.replaceAll(_sectionSuffix, '');
    final hasName = base != null && base.isNotEmpty;
    final hasRef = ref != null && ref!.isNotEmpty;
    if (!hasName && !hasRef) return null;
    return '${hasName ? base : ''}|${hasRef ? ref : ''}';
  }

  /// 解碼 SLT2 圖資中一個已解壓的 tile，格式見 `tools/pack_tiles.py`：
  /// 字串表、道路屬性、折線數、點數，最後是經度與緯度各一串 zigzag 差值。
  static List<OsmRoad> decodeTile(List<int> bytes) {
    int pos = 0;
    int readVarint() {
      int result = 0;
      int shift = 0;
      while (true) {
        final b = bytes[pos++];
        result |= (b & 0x7f) << shift;
        if (b < 0x80) return result;
        shift += 7;
      }
    }

    // 參照 0 代表 null
    final strings = List<String?>.filled(readVarint() + 1, null);
    for (int i = 1; i < strings.length; i++) {
      final len = readVarint();
      strings[i] = utf8.decode(bytes.sublist(pos, pos + len));
      pos += len;
    }

    final roadCount = readVarint();
    final attrs = List<int>.generate(roadCount * 8, (_) => readVarint());
    final lineCounts = List<int>.generate(roadCount, (_) => readVarint());
    final totalLines = lineCounts.fold<int>(0, (a, b) => a + b);
    final pointCounts = List<int>.generate(totalLines, (_) => readVarint());

    // 先讀完整串經度填入偶數位，再讀緯度填入奇數位；差值跨折線連續累加
    final allLines = [for (final n in pointCounts) Float64List(n * 2)];
    for (int axis = 0; axis < 2; axis++) {
      int acc = 0;
      for (final line in allLines) {
        for (int i = axis; i < line.length; i += 2) {
          final z = readVarint();
          acc += (z >> 1) ^ -(z & 1);
          line[i] = acc / 100000;
        }
      }
    }

    final roads = <OsmRoad>[];
    int lineIdx = 0;
    for (int r = 0; r < roadCount; r++) {
      final a = r * 8;
      roads.add(OsmRoad(
        name: strings[attrs[a]],
        ref: strings[attrs[a + 1]],
        highway: strings[attrs[a + 2]] ?? '',
        maxspeed: strings[attrs[a + 3]],
        oneway: strings[attrs[a + 4]],
        bridge: strings[attrs[a + 5]],
        tunnel: strings[attrs[a + 6]],
        layer: strings[attrs[a + 7]],
        lines: allLines.sublist(lineIdx, lineIdx + lineCounts[r]),
      ));
      lineIdx += lineCounts[r];
    }
    return roads;
  }

  /// 是否為高架或隧道等與平面分層的路段。
  /// 目前僅供顯示與除錯，尚未用於比對。
  int get level {
    final l = layer;
    if (l != null) {
      final parsed = int.tryParse(l);
      if (parsed != null) return parsed;
    }
    if (bridge != null) return 1;
    if (tunnel != null) return -1;
    return 0;
  }

  /// 顯示用名稱：優先路名，其次省道編號
  String get displayName {
    if (name != null && name!.isNotEmpty) return name!;
    if (ref != null && ref!.isNotEmpty) return '台$ref';
    return '';
  }

  @override
  String toString() => 'OsmRoad($displayName, $highway, maxspeed=$maxspeed)';
}
