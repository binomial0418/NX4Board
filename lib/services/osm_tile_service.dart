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
  static const int _magic = 0x32544C53; // "SLT2" 小端序
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

  /// LRU 快取：Dart 的 Map 保留插入順序，命中時重新插入即移到最新，
  /// 淘汰時移除最舊的一筆。值為 null 代表該格不在圖資範圍內。
  final Map<int, List<OsmRoad>?> _cache = {};

  /// 讀取中的 tile，同一格同時被要求時共用同一次讀取
  final Map<int, Future<List<OsmRoad>?>> _pending = {};

  /// RandomAccessFile 不允許並行的非同步操作（會拋出
  /// "An async operation is currently pending"），所有讀取都排進這條佇列依序執行。
  Future<void> _ioQueue = Future<void>.value();

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
    _cache.remove(key);
    _cache[key] = roads;
    while (_cache.length > _cacheMax) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// 快取查詢；命中時更新為最近使用。回傳 (是否命中, 值)。
  (bool, List<OsmRoad>?) _lookup(int key) {
    if (!_cache.containsKey(key)) return (false, null);
    final v = _cache.remove(key);
    _cache[key] = v;
    return (true, v);
  }

  /// 取得該座標所在 tile 的道路；範圍外或該格無道路回傳 null。
  Future<List<OsmRoad>?> tileAt(double lat, double lon) {
    if (!_initialized) return Future.value(null);
    return _load(lonToTileX(lon), latToTileY(lat));
  }

  /// 同步取用已快取的 tile，未快取回傳 null。
  ///
  /// GPS 回呼是同步的，所以比對一律走這條；未命中時由
  /// [prefetchAround] 在背景補上，下一個定位點就能用。
  List<OsmRoad>? cachedTileAt(double lat, double lon) {
    if (!_initialized) return null;
    return _lookup(_cacheKey(lonToTileX(lon), latToTileY(lat))).$2;
  }

  /// 所在格與周圍 8 格中已快取的道路。匝道常跨 tile 邊界，
  /// 沿匝道追到主線要用這個範圍（搭配 [prefetchAround] 預先載入）。
  List<OsmRoad> cachedRoadsAround(double lat, double lon) {
    if (!_initialized) return const [];
    final cx = lonToTileX(lon);
    final cy = latToTileY(lat);
    final out = <OsmRoad>[];
    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
        final key = _cacheKey(cx + dx, cy + dy);
        final roads = _cache[key];
        if (roads != null) out.addAll(roads);
      }
    }
    return out;
  }

  /// 該座標是否已載入（含「範圍外」的否定結果）
  bool hasTileAt(double lat, double lon) {
    if (!_initialized) return false;
    return _cache.containsKey(_cacheKey(lonToTileX(lon), latToTileY(lat)));
  }

  /// 背景載入所在格與周圍 8 格，讓跨越 tile 邊界時不中斷。
  /// 所在格排在最前面，已在快取或讀取中的格會被略過。
  void prefetchAround(double lat, double lon) {
    if (!_initialized) return;
    final cx = lonToTileX(lon);
    final cy = latToTileY(lat);

    _load(cx, cy);
    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
        if (dx == 0 && dy == 0) continue;
        _load(cx + dx, cy + dy);
      }
    }
  }

  /// 讀取單一 tile：先查快取，再共用進行中的讀取，最後才排進 I/O 佇列。
  Future<List<OsmRoad>?> _load(int x, int y) {
    final key = _cacheKey(x, y);
    final (hit, value) = _lookup(key);
    if (hit) return Future.value(value);

    final inFlight = _pending[key];
    if (inFlight != null) return inFlight;

    final i = _findIndex(x, y);
    if (i < 0) {
      _remember(key, null); // 範圍外，記住避免重複搜尋
      return Future.value(null);
    }

    final future = _enqueueRead(_dataStart + _idxOffset![i], _idxLength![i])
        .then<List<OsmRoad>?>((blob) {
      final roads = OsmRoad.decodeTile(zlib.decode(blob));
      _remember(key, roads);
      return roads;
    }).catchError((Object e) {
      // 不寫入快取，下次會重試
      debugPrint('❌ 讀取 tile $x/$y 失敗: $e');
      return null;
    }).whenComplete(() {
      // 必須用區塊寫法：箭頭函式會回傳 remove() 的結果，也就是這個 future 自己，
      // whenComplete 會等待回傳的 future，形成自己等自己的死結。
      _pending.remove(key);
    });

    _pending[key] = future;
    return future;
  }

  /// 把一次 seek + read 排進佇列，確保同一時間只有一個檔案操作
  Future<List<int>> _enqueueRead(int position, int length) {
    final result = _ioQueue.then((_) async {
      await _file!.setPosition(position);
      return _file!.read(length);
    });
    // 佇列本身不能因為單次失敗而中斷
    _ioQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> dispose() async {
    await _file?.close();
    _file = null;
    _cache.clear();
    _pending.clear();
    _initialized = false;
  }
}
