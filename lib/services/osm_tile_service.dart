import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/osm_road.dart';

/// 讀取打包後的 OSM 道路圖資（`assets/speed_tiles.bin`）。
///
/// 圖資是 z14 網格，每格約 2 公里見方，切檔時已含 150 公尺緩衝，
/// 因此只要讀取所在的那一格就夠，不必為了邊界多讀鄰格。
///
/// 資產無法隨機存取，首次啟動會複製到 App 私有目錄，
/// 之後以 [RandomAccessFile] 依索引 seek 讀取單一 tile，記憶體佔用極低。
class OsmTileService {
  static final OsmTileService _instance = OsmTileService._internal();
  factory OsmTileService() => _instance;
  OsmTileService._internal();

  static const String _assetPath = 'assets/speed_tiles.bin';
  static const String _fileName = 'speed_tiles.bin';
  static const int _magic = 0x31544C53; // "SLT1" 小端序
  static const int _headerBytes = 12;
  static const int _indexEntryBytes = 16;

  /// 記憶體中保留的 tile 數。實測台中市區連續 64 格約佔 8.6 MB。
  static const int _cacheMax = 48;

  int _zoom = 14;
  int get zoom => _zoom;

  RandomAccessFile? _file;
  int _dataStart = 0;

  // 索引拆成平行陣列，避免為數千個 tile 建立物件
  Int32List? _idxX;
  Int32List? _idxY;
  Int32List? _idxOffset;
  Int32List? _idxLength;

  bool _initialized = false;
  bool get isInitialized => _initialized;

  final Map<int, List<OsmRoad>?> _cache = {};
  final List<int> _cacheOrder = [];

  int get tileCount => _idxX?.length ?? 0;

  /// 準備圖資：必要時從資產複製到私有目錄，然後載入索引。
  Future<void> init() async {
    if (_initialized) return;
    await _openAt(await _ensureLocalCopy());
  }

  /// 直接開啟指定路徑的圖資檔，供測試使用（不經過 rootBundle）。
  @visibleForTesting
  Future<void> initFromFile(String path) async {
    if (_initialized) return;
    await _openAt(path);
  }

  Future<void> _openAt(String path) async {
    try {
      _file = await File(path).open();

      final header = await _file!.read(_headerBytes);
      final hv = ByteData.sublistView(header);
      if (hv.getUint32(0, Endian.little) != _magic) {
        throw StateError('speed_tiles.bin 檔頭不符');
      }
      _zoom = hv.getUint8(4);
      final count = hv.getUint32(8, Endian.little);

      final indexBytes = await _file!.read(count * _indexEntryBytes);
      final iv = ByteData.sublistView(indexBytes);
      _idxX = Int32List(count);
      _idxY = Int32List(count);
      _idxOffset = Int32List(count);
      _idxLength = Int32List(count);
      for (int i = 0; i < count; i++) {
        final base = i * _indexEntryBytes;
        _idxX![i] = iv.getUint32(base, Endian.little);
        _idxY![i] = iv.getUint32(base + 4, Endian.little);
        _idxOffset![i] = iv.getUint32(base + 8, Endian.little);
        _idxLength![i] = iv.getUint32(base + 12, Endian.little);
      }

      _dataStart = _headerBytes + count * _indexEntryBytes;
      _initialized = true;
      debugPrint('✅ OsmTileService initialized: $count tiles, zoom $_zoom');
    } catch (e) {
      debugPrint('❌ OsmTileService init failed: $e');
      _initialized = false;
    }
  }

  /// 首次啟動把資產複製到可隨機存取的私有目錄；
  /// 已存在且大小相符就直接沿用。
  Future<String> _ensureLocalCopy() async {
    final dir = await getApplicationSupportDirectory();
    final target = File('${dir.path}/$_fileName');

    final data = await rootBundle.load(_assetPath);
    final expected = data.lengthInBytes;

    if (await target.exists() && await target.length() == expected) {
      return target.path;
    }

    await target.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, expected),
      flush: true,
    );
    debugPrint('📦 speed_tiles.bin 已展開至 ${target.path}'
        '（${(expected / 1048576).toStringAsFixed(1)} MB）');
    return target.path;
  }

  int lonToTileX(double lon) =>
      ((lon + 180.0) / 360.0 * (1 << _zoom)).floor();

  int latToTileY(double lat) {
    final rad = lat * math.pi / 180.0;
    final s = math.log(math.tan(rad) + 1 / math.cos(rad)); // asinh(tan(lat))
    return ((1.0 - s / math.pi) / 2.0 * (1 << _zoom)).floor();
  }

  /// 二分搜尋索引，找不到回傳 -1
  int _findIndex(int x, int y) {
    final xs = _idxX;
    final ys = _idxY;
    if (xs == null || ys == null) return -1;

    int lo = 0;
    int hi = xs.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final mx = xs[mid];
      final my = ys[mid];
      if (mx == x && my == y) return mid;
      if (mx < x || (mx == x && my < y)) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return -1;
  }

  int _cacheKey(int x, int y) => (x << 20) | y;

  void _remember(int key, List<OsmRoad>? roads) {
    _cache[key] = roads;
    _cacheOrder.add(key);
    while (_cacheOrder.length > _cacheMax) {
      _cache.remove(_cacheOrder.removeAt(0));
    }
  }

  /// 取得該座標所在 tile 的道路；範圍外或該格無道路回傳 null。
  Future<List<OsmRoad>?> tileAt(double lat, double lon) async {
    if (!_initialized) return null;
    final x = lonToTileX(lon);
    final y = latToTileY(lat);
    final key = _cacheKey(x, y);
    if (_cache.containsKey(key)) return _cache[key];

    final i = _findIndex(x, y);
    if (i < 0) {
      _remember(key, null); // 範圍外，記住避免重複搜尋
      return null;
    }

    try {
      await _file!.setPosition(_dataStart + _idxOffset![i]);
      final blob = await _file!.read(_idxLength![i]);
      final raw = gzip.decode(blob);
      final decoded = json.decode(utf8.decode(raw)) as List<dynamic>;
      final roads = decoded
          .map((e) => OsmRoad.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
      _remember(key, roads);
      return roads;
    } catch (e) {
      debugPrint('❌ 讀取 tile $x/$y 失敗: $e');
      return null;
    }
  }

  /// 同步取用已快取的 tile，未快取回傳 null。
  ///
  /// GPS 回呼是同步的，所以比對一律走這條；未命中時由
  /// [prefetchAround] 在背景補上，下一個定位點就能用。
  List<OsmRoad>? cachedTileAt(double lat, double lon) {
    if (!_initialized) return null;
    return _cache[_cacheKey(lonToTileX(lon), latToTileY(lat))];
  }

  /// 該座標是否已載入（含「範圍外」的否定結果）
  bool hasTileAt(double lat, double lon) {
    if (!_initialized) return false;
    return _cache.containsKey(_cacheKey(lonToTileX(lon), latToTileY(lat)));
  }

  /// 背景載入所在格與周圍 8 格，讓跨越 tile 邊界時不中斷。
  /// 重複呼叫不會重複讀檔，已在快取或處理中的格會被略過。
  void prefetchAround(double lat, double lon) {
    if (!_initialized) return;
    final cx = lonToTileX(lon);
    final cy = latToTileY(lat);

    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
        final x = cx + dx;
        final y = cy + dy;
        final key = _cacheKey(x, y);
        if (_cache.containsKey(key) || _pending.contains(key)) continue;
        _pending.add(key);
        _loadTile(x, y).whenComplete(() => _pending.remove(key));
      }
    }
  }

  final Set<int> _pending = <int>{};

  Future<void> _loadTile(int x, int y) async {
    final key = _cacheKey(x, y);
    final i = _findIndex(x, y);
    if (i < 0) {
      _remember(key, null);
      return;
    }
    try {
      await _file!.setPosition(_dataStart + _idxOffset![i]);
      final blob = await _file!.read(_idxLength![i]);
      final decoded =
          json.decode(utf8.decode(gzip.decode(blob))) as List<dynamic>;
      _remember(
        key,
        decoded
            .map((e) => OsmRoad.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );
    } catch (e) {
      debugPrint('❌ 讀取 tile $x/$y 失敗: $e');
    }
  }

  Future<void> dispose() async {
    await _file?.close();
    _file = null;
    _cache.clear();
    _cacheOrder.clear();
    _initialized = false;
  }
}
