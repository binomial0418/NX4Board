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

  factory OsmRoad.fromJson(Map<String, dynamic> json) {
    final rawLines = json['g'] as List<dynamic>;
    final lines = <Float64List>[];
    for (final line in rawLines) {
      final coords = line as List<dynamic>;
      final buf = Float64List(coords.length);
      for (int i = 0; i < coords.length; i++) {
        buf[i] = (coords[i] as num).toDouble();
      }
      lines.add(buf);
    }

    return OsmRoad(
      name: json['n'] as String?,
      ref: json['r'] as String?,
      highway: json['h'] as String? ?? '',
      maxspeed: json['s'] as String?,
      oneway: json['o'] as String?,
      bridge: json['b'] as String?,
      tunnel: json['u'] as String?,
      layer: json['l'] as String?,
      lines: lines,
    );
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
