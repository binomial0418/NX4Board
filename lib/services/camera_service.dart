import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:csv/csv.dart';
import 'package:geolocator/geolocator.dart';
import 'road_type_service.dart' show RoadType;

/// overpass：國道天橋上的移動式測速點（圖資的國道移動式中，位於跨越
/// 國道的天橋旁的那些；其餘移動式點不收，見 tools/edog_convert.py）
enum CameraKind { speed, redLight, zoneStart, zoneEnd, overpass }

class SpeedCamera {
  final String address;
  final double longitude;
  final double latitude;
  final String direct;
  final int? limit;
  final RoadType roadType;
  final CameraKind kind;

  /// 受測車行方位角（0-359）。有值時以它比對行進方向，不看 [direct] 文字。
  final double? heading;

  /// 類型碼（圖資第 3 碼，見 [CameraRules.typeOf]），決定提示距離。
  /// 政府資料沒有，依 [kind] 補一個對應的碼。
  final int typeCode;

  /// 圖資第 12 欄：方向容許角代碼（'1'..'7' 放寬前方錐角），'0' 為預設
  final String angleTol;

  SpeedCamera({
    required this.address,
    required this.longitude,
    required this.latitude,
    required this.direct,
    this.limit,
    this.roadType = RoadType.none,
    this.kind = CameraKind.speed,
    this.heading,
    int? typeCode,
    this.angleTol = '0',
  }) : typeCode = typeCode ?? CameraRules.defaultTypeFor(kind);

  /// tools/edog_convert.py 輸出的格式：
  /// Latitude(0), Longitude(1), Heading(2), Limit(3), Kind(4), RoadType(5), ZoneLengthM(6),
  /// Code(7), AngleTol(8)。後兩欄是後來加的，舊檔沒有時依 kind 補預設。
  factory SpeedCamera.fromEdogCsv(List<dynamic> row) {
    final kind = switch (row[4].toString()) {
      'redlight' => CameraKind.redLight,
      'zone_start' => CameraKind.zoneStart,
      'zone_end' => CameraKind.zoneEnd,
      'overpass' => CameraKind.overpass,
      _ => CameraKind.speed,
    };
    final roadType = switch (row[5].toString()) {
      'highway' => RoadType.highway,
      'expressway' => RoadType.expressway,
      _ => RoadType.none,
    };
    return SpeedCamera(
      address: '',
      latitude: double.tryParse(row[0].toString()) ?? 0.0,
      longitude: double.tryParse(row[1].toString()) ?? 0.0,
      heading: double.tryParse(row[2].toString()),
      limit: int.tryParse(row[3].toString()),
      // 方向已由 heading 精確過濾，語音不需再唸方向
      direct: '',
      kind: kind,
      roadType: roadType,
      typeCode: row.length > 7 ? CameraRules.typeOf(row[7].toString()) : null,
      angleTol: row.length > 8 && row[8].toString().isNotEmpty ? row[8].toString() : '0',
    );
  }

  bool get isZone => kind == CameraKind.zoneStart || direct.contains('區間');

  factory SpeedCamera.fromCsv(List<dynamic> row) {
    // CSV Format: CityName(0), RegionName(1), Address(2), DeptNm(3), BranchNm(4), Longitude(5), Latitude(6), direct(7), limit(8)
    final String cityName = row[0]?.toString() ?? '';
    final String address  = row[2]?.toString() ?? '未知地點';
    final double lon = double.tryParse(row[5]?.toString() ?? '') ?? 0.0;
    final double lat = double.tryParse(row[6]?.toString() ?? '') ?? 0.0;
    final int? lim = int.tryParse(row[8]?.toString() ?? '');

    return SpeedCamera(
      address: address,
      longitude: lon,
      latitude: lat,
      direct: row[7]?.toString() ?? '',
      limit: lim,
      roadType: _classifyCamera(cityName, address),
    );
  }

  /// 依城市名稱與地址關鍵字判斷相機所在道路類型
  static RoadType _classifyCamera(String cityName, String address) {
    // 國道：CityName 欄位含「國道」最可靠；地址備援（含「國道」別名）
    if (cityName.contains('國道') ||
        address.contains('國道') ||
        address.contains('中山高') ||
        address.contains('福爾摩沙高速') ||
        address.contains('福高')) {
      return RoadType.highway;
    }
    // 快速道路：
    //   1. 地址含明確關鍵字
    //   2. 符合台灣快速公路編號：台/臺 61-68, 72-78, 82-88 線
    //      （6x: 61,62,64,65,66,68；7x: 72,74,76,78；8x: 82,84,86,88）
    if (address.contains('快速道路') ||
        address.contains('快速公路') ||
        address.contains('快速路') ||
        RegExp(r'[台臺](?:6[1-8]|7[2-8]|8[2-8])線').hasMatch(address)) {
      return RoadType.expressway;
    }
    return RoadType.none;
  }
}

class CameraService {
  static final CameraService _instance = CameraService._internal();
  factory CameraService() => _instance;
  CameraService._internal();

  List<SpeedCamera> _cameras = [];
  final List<Position> _trajectory = [];
  static const int _maxTrajectorySize = 5;

  /// 搜尋範圍：20～2000 m 的點
  static const double _searchBoxDeg = 0.02;
  static const double _maxSearchM = 2000;

  /// 20 m 內視為已經通過
  static const double _passedM = 20;

  /// 車速到這個值以上才用 GNSS 晶片的航向（都卜勒測得，比軌跡連線穩）；
  /// 低速時它會亂跳，改用軌跡推算
  static const double _gnssHeadingMinKmh = 10;

  /// 平面相機離目前道路超過這個距離，就是在別條路上。相機座標與道路線形的誤差
  /// 加上路寬約 10～20 m；平行道路多半相隔 40 m 以上（中位 97 m）。
  static const double _offRoadM = 30;

  /// 正在提示的相機，錐角至少放寬到這個值。原本只有 +20°（20 m 內 +35°），
  /// 換車道或準備轉彎時車頭偏個二、三十度就掉出錐外，下一筆回正又被當成新的
  /// 提示，板子再念一次（10-04 西濱路二段：航向 201→167° 中斷，226 m 處重念）。
  /// 真的轉進路口（約 90°）仍會結束提示。
  static const double _alertedConeDeg = 60;

  /// 相機圖資（tools/edog_convert.py 產生，不進 git）。沒有時退回政府資料。
  static const String _edogAsset = 'assets/private/edog_cameras.csv';

  bool _isInitialized = false;

  /// 最後一次算得出來的行進方向。停車或龜速時軌跡太短算不出方向，
  /// 沿用它才不會讓方向過濾失效——否則下閘道停紅燈時，身後高架上的
  /// 相機會重新被當成「前方」。
  double? _lastHeading;

  /// 上一個定位點的航向，用來判斷是否正在轉彎（航向變化 ≥15° 時錐角收窄）
  double? _prevFixHeading;

  /// 正在提示的相機與它上次的距離：提示中的相機錐角放寬，GPS 晃一下不會斷掉
  String? _alertKey;
  double _alertLastM = 0;
  Map<String, dynamic>? _lastResult;

  /// 在國道／快速道路上時，速限比所在道路低這麼多的相機視為高架下的平面道路
  static const int _underpassLimitGap = 20;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      String source = 'edog';
      try {
        final String csvData = await rootBundle.loadString(_edogAsset);
        final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(csvData);
        for (int i = 1; i < rows.length; i++) {
          if (rows[i].length < 7) continue;
          _cameras.add(SpeedCamera.fromEdogCsv(rows[i]));
        }
      } catch (_) {
        _cameras.clear();
      }

      if (_cameras.isEmpty) {
        source = '政府';
        final String csvData = await rootBundle.loadString('assets/camera_data.csv');
        final List<List<dynamic>> rows = const CsvToListConverter().convert(csvData);

        // Skip header and sub-header (row 0 and 1)
        for (int i = 2; i < rows.length; i++) {
          if (rows[i].length < 9) continue;
          _cameras.add(SpeedCamera.fromCsv(rows[i]));
        }
      }
      _isInitialized = true;

      final hwCount = _cameras.where((c) => c.roadType == RoadType.highway).length;
      final ewCount = _cameras.where((c) => c.roadType == RoadType.expressway).length;
      debugPrint('✅ CameraService: $source ${_cameras.length} cameras (國道 $hwCount, 快速 $ewCount, 其他 ${_cameras.length - hwCount - ewCount})');
    } catch (e) {
      debugPrint('CameraService init error: $e');
    }
  }

  List<Position> get trajectory => List.unmodifiable(_trajectory);

  /// 最後一次算得出來的行進方向（度），尚未移動過為 null
  double? get lastHeading => _lastHeading;

  /// 供測試注入相機資料，略過 rootBundle
  @visibleForTesting
  void setCamerasForTest(List<SpeedCamera> cameras) {
    _cameras = cameras;
    _trajectory.clear();
    _lastHeading = null;
    _prevFixHeading = null;
    _alertKey = null;
    _lastResult = null;
    _isInitialized = true;
  }

  void addPosition(Position pos) {
    _trajectory.add(pos);
    if (_trajectory.length > _maxTrajectorySize) {
      _trajectory.removeAt(0);
    }
  }

  /// 偵測需要提示的測速照相，沒有就回傳 null。
  ///
  /// 核心判斷（規則在 [CameraRules]）：
  ///   1. 20 m < 距離 < 2 km
  ///   2. 相機在前方錐內：|方位(車→相機) − 航向| ≤ 20°（轉彎時 10°；圖資第 12 欄
  ///      可放寬到 30～90°；正在提示的那支再放寬 20°）
  ///   3. 相機受測方向與「車→相機方位」相差 ≤ 20°（第 12 欄可放寬到 45°）
  ///   4. 取最近一支，距離在該類型的提示距離內才提示（[CameraRules.alertDistanceM]；
  ///      國道／快速道路的固定測速例外，保留 1 km）
  /// 航向優先用 GNSS 晶片給的 `Position.heading`（≥10 km/h），低速時用軌跡推算。
  ///
  /// 以下是依道路追蹤多加的關卡，只會排掉「追蹤器確認在別條路上」的相機：
  ///
  /// [currentRoadType] 有把握在國道／快速道路上時不看平面相機。國道與快速道路不分：
  /// 轉檔依地標距離分類，快速道路靠近國道交流道的相機常被算成國道（台72/74/88），
  /// 只看同類會漏掉它們（模擬：國道類相機漏 8%）。
  ///
  /// [surfaceConfirmed] 為 true 代表道路追蹤有把握目前在平面道路上，
  /// 此時排除國道/快速道路的相機——行駛在高架正下方時，上方高架的相機
  /// 水平距離很近、方向也相同，錐角分不開。
  ///
  /// [roadLimit] 是有把握在國道／快速道路上、且速限來自實測（OSM 標註）時
  /// 的所在道路速限。速限低了 [_underpassLimitGap] 以上的相機必定屬於別條路
  /// ——典型是西濱高架（90）正下方的平面道路（70）。速限是推定值時不套用。
  ///
  /// [skipCamera] 由呼叫端額外排除相機（重疊道路有把握在哪一層時排除另一層）。
  ///
  /// [distanceToCurrentRoadM] 回傳某個位置離「目前所在道路」多遠（公尺），
  /// 無法判斷時回傳 null。有提供時，平面相機離目前道路超過 [_offRoadM] 就不提示。
  /// 模擬（全台平面相機抽樣）：20° 錐角單獨擋掉平行道路誤報約 8 成，
  /// 加上這道再從剩下的 21% 降到約 1%，提示距離與漏報不變。
  Map<String, dynamic>? checkNearbyCamera({
    RoadType currentRoadType = RoadType.none,
    bool surfaceConfirmed = false,
    int? roadLimit,
    double? Function(double lat, double lon)? distanceToCurrentRoadM,
    bool Function(SpeedCamera cam)? skipCamera,
  }) {
    if (_trajectory.isEmpty) return null;
    final first = _trajectory.first;
    final last = _trajectory.last;
    final double speedKmh = max(0.0, last.speed * 3.6);
    final double moveM = CameraAlgorithm.haversine(
            first.latitude, first.longitude, last.latitude, last.longitude) *
        1000;

    // 航向：GNSS 晶片的都卜勒航向 > 軌跡連線 > 沿用上一次
    final bool stationary = moveM < 5 && speedKmh < _gnssHeadingMinKmh;
    if (speedKmh >= _gnssHeadingMinKmh && last.heading >= 0) {
      _lastHeading = last.heading % 360;
    } else if (moveM >= 5) {
      _lastHeading = CameraAlgorithm.calculateBearing(
          first.latitude, first.longitude, last.latitude, last.longitude);
    }
    final double? userHeading = _lastHeading;
    if (userHeading == null) return null;

    // 停住不動：不更新，提示狀態維持原樣（停紅燈時不會忽亮忽滅）
    if (stationary && _lastResult != null) return _lastResult;

    final bool turning = _prevFixHeading != null &&
        CameraAlgorithm.angleDiff(userHeading, _prevFixHeading!) >= 15;
    _prevFixHeading = userHeading;

    SpeedCamera? nearest;
    double nearestM = double.infinity;
    double? nearestOff;
    for (final cam in _cameras) {
      if ((cam.latitude - last.latitude).abs() > _searchBoxDeg ||
          (cam.longitude - last.longitude).abs() > _searchBoxDeg) { continue; }
      final double d = CameraAlgorithm.haversine(
              last.latitude, last.longitude, cam.latitude, cam.longitude) *
          1000;
      if (d <= _passedM || d >= _maxSearchM || d >= nearestM) continue;

      // 我們加的道路關卡（確認在高速路系統就排除平面相機；確認在平面排除高速路相機）
      if (currentRoadType != RoadType.none && cam.roadType == RoadType.none) continue;
      if (surfaceConfirmed && cam.roadType != RoadType.none) continue;
      if (roadLimit != null && cam.limit != null &&
          cam.limit! <= roadLimit - _underpassLimitGap) { continue; }

      // 前方錐
      final double bearing = CameraAlgorithm.calculateBearing(
          last.latitude, last.longitude, cam.latitude, cam.longitude);
      final double off = CameraAlgorithm.angleDiff(bearing, userHeading);
      final String key = '${cam.latitude}_${cam.longitude}';
      double cone = CameraRules.coneDeg(cam.angleTol, turning: turning);
      if (key == _alertKey) {
        cone = max(cone + (_alertLastM < 20 ? 35 : 20), _alertedConeDeg);
      }
      if (off > cone) continue;

      // 受測方向：有方位角的圖資比對「車→相機方位」；政府資料只有文字方向，比對航向
      if (cam.heading != null) {
        if (CameraAlgorithm.angleDiff(cam.heading!, bearing) >
            CameraRules.headingTolDeg(cam.angleTol)) { continue; }
      } else if (CameraAlgorithm.matchDirection(cam.direct, userHeading) == false) {
        continue;
      }

      // 平行道路：相機不在目前這條路上就不提示
      if (cam.roadType == RoadType.none && distanceToCurrentRoadM != null) {
        final dr = distanceToCurrentRoadM(cam.latitude, cam.longitude);
        if (dr != null && dr > _offRoadM) continue;
      }

      // 呼叫端的額外排除（重疊道路有把握在哪一層時，排除另一層的相機）。
      // 要在挑最近一支之前做，否則另一層較近的相機會擋掉本層前方的相機
      if (skipCamera != null && skipCamera(cam)) continue;

      nearest = cam;
      nearestM = d;
      nearestOff = off;
    }

    // 取最近一支，再看它是否進入該類型的提示距離
    final double? alertM =
        nearest == null
            ? null
            : CameraRules.alertDistanceM(nearest.typeCode, speedKmh,
                fastRoad: nearest.roadType != RoadType.none);
    if (nearest == null || alertM == null || nearestM > alertM) {
      _alertKey = null;
      _lastResult = null;
      return null;
    }
    _alertKey = '${nearest.latitude}_${nearest.longitude}';
    _alertLastM = nearestM;

    final String label = switch (nearest.kind) {
      CameraKind.redLight => '前有闖紅燈照相',
      CameraKind.zoneStart => '進入區間測速路段',
      CameraKind.zoneEnd => '區間測速終點',
      CameraKind.overpass => '注意天橋偷拍',
      CameraKind.speed => '前有測速照相',
    };
    final String msg = [
      label,
      if (nearest.limit != null) '速限 ${nearest.limit}',
      if (nearest.direct.isNotEmpty) nearest.direct,
    ].join('，');

    return _lastResult = {
      "name": nearest.address,
      "address": nearest.address,
      "limit": nearest.limit,
      "dist_m": nearestM.round(),
      "alert_m": alertM.round(),
      "lat": nearest.latitude,
      "lon": nearest.longitude,
      "direct": nearest.direct,
      "is_zone": nearest.isZone,
      "heading": nearest.heading,
      "road_type": nearest.roadType.name,
      "kind": nearest.kind.name,
      "type_code": nearest.typeCode,
      "message": msg,
      "debug_heading": userHeading,
      "debug_angle": nearestOff,
    };
  }
}

/// 相機提示規則。類型碼是圖資第 3 碼；兩字元以 16 進位解（A3 → 0xA3），單字元 = 字元 − '0'
/// （1 → 1、E → 0x15、G → 0x17）。
class CameraRules {
  static int typeOf(String code) {
    final c = code.trim().toUpperCase();
    int hex(int ch) => (ch >= 0x41 && ch <= 0x46) ? ch - 0x37 : ch - 0x30;
    if (c.length == 2) {
      final lo = hex(c.codeUnitAt(1));
      return (hex(c.codeUnitAt(0)) * 16 + (lo >= 0 && lo <= 15 ? lo : 0)) & 0xff;
    }
    if (c.length == 1) return (c.codeUnitAt(0) - 0x30) & 0xff;
    return 0;
  }

  /// 政府資料沒有類型碼，依種類補上對應的類型
  static int defaultTypeFor(CameraKind kind) => switch (kind) {
        CameraKind.speed => 0x01,
        CameraKind.redLight => 0xA4,
        CameraKind.zoneStart => 0x06,
        CameraKind.zoneEnd => 0x07,
        CameraKind.overpass => 0xA3,
      };

  /// 車速分段型（固定測速、闖紅燈、科技執法…）：<70 km/h 300 m，否則 500 m
  static const Set<int> _speedScaled = {
    0x01, 0x09, 0x12, 0x13, 0x14, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1D, 0x1E, 0x21, 0x23, 0x24,
    0xA2, 0xA3, 0xA4, 0xA5, 0xA7, 0xA8, 0xA9, 0xAC, 0xAD, 0xAE, 0xAF,
    0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB9,
    0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xCA, 0xCB, 0xCC, 0xCD,
  };

  /// 區間測速起點：330 m
  static const Set<int> _zoneStart = {0x06, 0x15, 0x22, 0x6A, 0x6B, 0x6C, 0xE1};

  /// 國道／快速道路固定測速的提示距離：1 km（100 km/h 約 35 秒；500 m 只剩 18 秒）
  static const double fastRoadAlertM = 1000;

  /// 提示距離（公尺，直線距離）；null = 這一類不提示。
  /// [fastRoad]：相機在國道／快速道路上時，車速分段型改用 [fastRoadAlertM]。
  static double? alertDistanceM(int type, double speedKmh, {bool fastRoad = false}) {
    // 0：0/0/0 固定點對得到政府資料，照固定測速處理
    if (type == 0x00 || _speedScaled.contains(type)) {
      if (fastRoad) return fastRoadAlertM;
      return speedKmh < 70 ? 300 : 500;
    }
    if (_zoneStart.contains(type)) return 330;
    return switch (type) {
      0x07 => 40, // 區間終點
      0x7A => 60, // 區間相關（7A）
      0x6D => 170,
      0xA6 => speedKmh > 70 ? null : 300,
      _ => 120, // 其他（含 F 區間終點）
    };
  }

  /// 前方錐半角：第 12 欄 '1'..'7' → 30..90°；否則直行 20°、轉彎 10°
  static double coneDeg(String tol, {required bool turning}) {
    final n = int.tryParse(tol) ?? 0;
    if (n >= 1 && n <= 7) return 20.0 + 10 * n;
    return turning ? 10 : 20;
  }

  /// 受測方向容許角：第 12 欄 '2'..'7' → 20..45°，否則 20°
  static double headingTolDeg(String tol) {
    final n = int.tryParse(tol) ?? 0;
    if (n >= 2 && n <= 7) return 10.0 + 5 * n;
    return 20;
  }
}

class CameraAlgorithm {
  static const double earthRadiusKm = 6371.0;

  static double haversine(double lat1, double lon1, double lat2, double lon2) {
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    
    final a = sin(dLat / 2) * sin(dLat / 2) +
              cos(_toRadians(lat1)) * cos(_toRadians(lat2)) * 
              sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusKm * c;
  }

  static double calculateBearing(double lat1, double lon1, double lat2, double lon2) {
    final lat1Rad = _toRadians(lat1);
    final lat2Rad = _toRadians(lat2);
    final dLonRad = _toRadians(lon2 - lon1);

    final x = sin(dLonRad) * cos(lat2Rad);
    final y = cos(lat1Rad) * sin(lat2Rad) -
              sin(lat1Rad) * cos(lat2Rad) * cos(dLonRad);

    final bearingRad = atan2(x, y);
    return (bearingRad * 180 / pi + 360) % 360;
  }

  /// 兩個方位角的夾角（0～180）
  static double angleDiff(double a, double b) {
    final d = (a - b).abs() % 360;
    return d > 180 ? 360 - d : d;
  }

  static String bearingToDirection(double bearing) {
    if (bearing >= 337.5 || bearing < 22.5) return 'N';
    if (bearing >= 22.5 && bearing < 67.5) return 'NE';
    if (bearing >= 67.5 && bearing < 112.5) return 'E';
    if (bearing >= 112.5 && bearing < 157.5) return 'SE';
    if (bearing >= 157.5 && bearing < 202.5) return 'S';
    if (bearing >= 202.5 && bearing < 247.5) return 'SW';
    if (bearing >= 247.5 && bearing < 292.5) return 'W';
    return 'NW';
  }

  /// 相機受測方位角與行進方向相差 45° 內才算同向
  static bool matchHeading(double camHeading, double userHeading) {
    double diff = (userHeading - camHeading).abs();
    if (diff > 180) diff = 360 - diff;
    return diff < 45;
  }

  /// 方向比對結果：
  ///   true  = 照相機方向與使用者行進方向相符 → 觸發警示
  ///   false = 方向不符 → 略過
  ///   null  = 方向模糊或無法判斷 → 僅以距離判斷（不過濾）
  static bool? matchDirection(String camDirect, double? userHeading) {
    final d = camDirect.trim();

    // 1. 數字方位角
    final camBearing = double.tryParse(d);
    if (camBearing != null) {
      if (userHeading == null) return null;
      double diff = (userHeading - camBearing).abs();
      if (diff > 180) diff = 360 - diff;
      return diff < 45;
    }

    // 2. 明確雙向 → 一律通過
    if (d.contains('雙向') || d.contains('both')) return true;

    // 3. 同一字串內含兩個方向（e.g. "南向60北向70", "南向北(區間) 北向南(區間)"）
    if (RegExp(r'南向\d+北向|北向\d+南向').hasMatch(d)) return true;
    if (d.contains('南向北') && d.contains('北向南')) return true;

    // 4. 軸向標記不含方向性 → 視為雙向
    if (d == '南北向' || d == '南北' || d == '東西向') return true;

    // 5. 模糊方向 → 略過方向判斷，僅看距離
    if (d == '單向' || d == '多向') return null;
    // "往X"：X 超過一個字（地名）才算模糊；單一基方位（往東/南/西/北）屬明確
    if (d.startsWith('往') && !RegExp(r'^往[東南西北](?:方向|車道)?$').hasMatch(d)) return null;
    // "X往Y"：往 的前一字不是基方位 → 跨區路線
    if (!d.startsWith('往') && d.contains('往')) {
      final idx = d.indexOf('往');
      if (idx > 0 && !'東南西北'.contains(d[idx - 1])) return null;
    }

    // 6. 無法取得行進方向 → 略過
    if (userHeading == null) return null;

    bool check(double expected) {
      double diff = (userHeading - expected).abs();
      if (diff > 180) diff = 360 - diff;
      return diff <= 60;
    }

    // 7. 斜向（先於基方位比對，避免子字串誤判）
    if (d.contains('西南向東北') || d.contains('西南往東北')) return check(45);
    if (d.contains('東北向西南') || d.contains('東北往西南')) return check(225);
    if (d.contains('西北向東南') || d.contains('西北往東南')) return check(135);
    if (d.contains('東南向西北') || d.contains('東南往西北')) return check(315);

    // 8. 複合基方位（先於單純基方位，避免子字串誤判）
    if (d.contains('北向南') || d.contains('北往南') || d.contains('北至南') ||
        d.contains('南下')) { return check(180); }
    if (d.contains('南向北') || d.contains('南往北') || d.contains('南至北') ||
        d.contains('北上')) { return check(0); }
    if (d.contains('東向西') || d.contains('東往西') || d.contains('東至西') ||
        d.contains('由東向西')) { return check(270); }
    if (d.contains('西向東') || d.contains('西往東') || d.contains('西至東')) return check(90);

    // 9. 單純基方位
    if (d.contains('往南') || d.contains('南向') || d.contains('南下方向')) return check(180);
    if (d.contains('往北') || d.contains('北向') || d.contains('北上方向')) return check(0);
    if (d.contains('往東') || d.contains('東向')) return check(90);
    if (d.contains('往西') || d.contains('西向')) return check(270);

    // 10. 無法識別 → 模糊，略過方向判斷
    return null;
  }

  static double _toRadians(double degrees) => degrees * pi / 180;
}
