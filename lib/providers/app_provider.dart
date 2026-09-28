import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../models/speed_sign.dart';
import '../services/csv_parser.dart';
import '../services/obd_spp_service.dart';
import '../services/wifi_service.dart';
import '../services/camera_service.dart';
import '../services/settings_service.dart';
import '../services/tts_service.dart';
import '../services/speed_limit_service.dart';
import '../services/traffic_service.dart';
import '../services/road_type_service.dart';
import '../services/device_status_service.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:intl/intl.dart';

class AppProvider extends ChangeNotifier {
  List<SpeedSign> _allSpeedSigns = [];
  Position? _currentPosition;
  List<SpeedSign> _nearbySpeedSigns = [];
  int? _currentSpeedLimit;
  int _roadSpeedLimit = 40; // 新增：道路速限 (SpeedLimitCard 專用)
  bool _isLoading = true;
  String _status = 'Initializing...';
  Map<String, dynamic>? _nearestCameraInfo;
  Map<String, dynamic>? _activeZoneCameraInfo;
  DateTime? _zoneCameraActiveUntil;
  static const Duration _zoneCameraDisplayDuration = Duration(seconds: 60);

  /// 已進入提示距離的相機（lat_lon）。語音、畫面與 ESP 都以「進入提示距離」
  /// 為準；之後直到相機消失（通過或離開路線）都維持提示，距離抖動不會閃爍。
  String? _alertedCameraId;
  Map<String, dynamic>? _alertedCameraInfo;

  /// 通過相機的累計次數。送給 ESP 當事件用：200ms 一筆的狀態封包可能掉包，
  /// 單次旗標會漏；ESP 只要看到數字變大就念「通過」。
  int _cameraPassedCount = 0;
  int get cameraPassedCount => _cameraPassedCount;

  /// 提示中的相機從偵測結果消失時，若它在身後且距離在這之內，視為「通過」。
  /// 下閘道或轉彎離開時相機多半還在前方、或已離很遠，不會誤報。
  static const double _passedMaxDistKm = 0.25;

  // Obd State Properties
  final ObdSppService _obdService = ObdSppService();
  Timer? _obdStatusTimer;
  bool _isWifiConnected = false;
  ThermalMode _lastThermalMode = ThermalMode.normal;

  // ── UI Demo Mode ────────────────────────────────────────────────────────
  bool _isDemoEnabled = false;
  Timer? _demoTimer;
  double _demoSpeed = 0;
  double _demoRpm = 0;
  double _demoTurbo = 0;
  double _demoSoc = 65.5;
  int _demoCoolant = 88;
  bool _demoIsReversing = false;
  bool _demoIsLowBeamOn = false;
  bool _demoIsHighBeamOn = false;
  bool _demoIsAnyDoorOpen = false;
  bool _demoIsDoorUnlocked = false;
  bool _demoIsTrunkOpen = false;
  int _demoTicks = 0;

  // ── 遠燈語音提示 ────────────────────────────────────────────────────────
  /// 最後播報過的遠燈狀態。null = 尚未取得有效資料，此時只記錄不播報，
  /// 避免連線當下或斷線歸零時誤報一句「遠燈關閉」。
  bool? _lastAnnouncedHighBeam;

  /// 最後一次「看到」的遠燈狀態，用來偵測邊緣。
  /// 必須與 _lastAnnouncedHighBeam 分開：去抖計時器只能在狀態真的變化時
  /// 重啟，若每次收到 OBD 通知都重啟（快輪詢每 300ms 一次），計時器
  /// 永遠撐不到設定的秒數，就再也不會播報。
  bool? _lastObservedHighBeam;
  Timer? _highBeamDebounce;

  /// 上一次看到的車速，用來抓「由 0 變成大於 0」的起步瞬間。
  /// null 代表還沒有車速資料，起步判斷要等拿到第一筆 0 之後才成立。
  int? _lastSpeedForDoorWarn;
  DateTime? _lastDoorWarnAt;

  /// 目前路型：道路追蹤有結果時以它為準（能分辨高架與正下方的平面道路），
  /// 圖資無法判定時退回 RoadTypeService 的地標判定。
  RoadType get effectiveRoadType =>
      SpeedLimitService().trackedRoadType ?? RoadTypeService().currentRoadType;

  bool get isOnHighway => effectiveRoadType == RoadType.highway;
  bool get isOnExpressway => effectiveRoadType == RoadType.expressway;

  // GPS upload tracking (Standardized tid: gps)
  DateTime? _lastGpsSentTime;
  double _lastGpsSentHeading = 0;
  final _gpsDataController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get gpsDataStream => _gpsDataController.stream;

  bool get isDemoEnabled => _isDemoEnabled;

  // Getters
  List<SpeedSign> get allSpeedSigns => _allSpeedSigns;
  Position? get currentPosition => _currentPosition;
  List<SpeedSign> get nearbySpeedSigns => _nearbySpeedSigns;
  int? get currentSpeedLimit => _currentSpeedLimit;
  int get roadSpeedLimit => _roadSpeedLimit;

  /// 目前比對到的路名（OSM 圖資），無法判定時為空字串
  String get currentRoadName => SpeedLimitService().currentRoadName;

  /// 速限來源，供 UI 區分實測值與推定值
  LimitSource get speedLimitSource => SpeedLimitService().source;

  /// 速限是否為依道路分級推定，而非實際標註
  bool get isSpeedLimitInferred => SpeedLimitService().isInferred;

  /// 高架與平面判定沒把握時為 true，此時下面幾個值是另一種可能
  bool get isLevelAmbiguous => SpeedLimitService().isLevelAmbiguous;

  /// 所在道路與另一可能道路的層級（來自 OSM 的 layer / bridge / tunnel），
  /// 數值大的在上。兩者不同時，UI 用上下箭頭標示哪個是高架。
  int get currentRoadLevel => SpeedLimitService().currentRoad?.level ?? 0;
  int get alternativeRoadLevel => SpeedLimitService().alternativeRoad?.level ?? 0;
  String get alternativeRoadName => SpeedLimitService().alternativeRoadName;
  int? get alternativeSpeedLimit => SpeedLimitService().alternativeLimit;

  /// 前方路況；不在 TDX 路段上、沒有憑證或功能關閉時為 null
  TrafficState? get trafficState => TrafficService().state;
  bool get isLoading => _isLoading;
  String get status => _status;
  Map<String, dynamic>? get nearestCameraInfo => _nearestCameraInfo;

  // Obd getters (Modified for Demo Mode)
  ObdConnectionState get obdConnectionState => _isDemoEnabled
      ? ObdConnectionState.connected
      : _obdService.connectionState;

  int? get obdRpm => _isDemoEnabled ? _demoRpm.toInt() : _obdService.rpm;
  int? get obdSpeed {
    final rawSpeed = _isDemoEnabled ? _demoSpeed.toInt() : _obdService.speed;
    if (rawSpeed == null || rawSpeed <= 0) return rawSpeed;
    return rawSpeed + 3;
  }

  int? get obdCoolant =>
      _isDemoEnabled ? _demoCoolant : _obdService.coolantTemp;
  double? get obdVoltage => _isDemoEnabled ? 14.2 : _obdService.voltage;
  double? get obdHevSoc => _isDemoEnabled ? _demoSoc : _obdService.hevSoc;
  double? get obdOdometer => _isDemoEnabled ? 33610.0 : _obdService.odometer;
  int? get obdFuel => _isDemoEnabled ? 75 : _obdService.fuelLevel;
  double? get obdTurbo => _isDemoEnabled ? _demoTurbo : _obdService.turbo;

  /// 相對節氣門開度（%，PID 0145）。放在增壓旁邊，用來判讀增壓數值。
  int? get obdThrottle =>
      _isDemoEnabled ? 0 : _obdService.throttlePercent;
  bool get isReversing => _isDemoEnabled ? _demoIsReversing : _obdService.isReversing;

  /// D 檔（22E000 byte N bit3，實車驗證）
  bool get isDriveGear =>
      _isDemoEnabled ? !_demoIsReversing : _obdService.isDriveGear;

  /// 目前能判斷的檔位：R / D / P/N / -
  /// P 與 N 沒有已知訊號可以區分，合併回報。
  String get gearLabel => _isDemoEnabled
      ? (_demoIsReversing ? 'R' : 'D')
      : _obdService.gearLabel;

  // 大燈狀態（供 ESP32 儀表依日/夜切換螢幕亮度）
  bool get isLowBeamOn =>
      _isDemoEnabled ? _demoIsLowBeamOn : _obdService.isLowBeamOn;

  /// 小燈（示寬燈，22BC10 byte E bit4~7）。自動頭燈在天色轉暗時是先亮
  /// 小燈才亮近燈，所以它比近燈更早、更貼近實際光線。
  bool get isPositionLampOn =>
      _isDemoEnabled ? false : _obdService.isPositionLampOn;

  /// 後霧燈（22BC07 byte F bit1）
  bool get isRearFogOn => _isDemoEnabled ? false : _obdService.isRearFogOn;
  bool get isHighBeamOn =>
      _isDemoEnabled ? _demoIsHighBeamOn : _obdService.isHighBeamOn;

  // 車門 / 尾門 / 門鎖狀態（狀態區的四個指示燈）
  bool get isAnyDoorOpen =>
      _isDemoEnabled ? _demoIsAnyDoorOpen : _obdService.isAnyDoorOpen;
  bool get isDoorUnlocked =>
      _isDemoEnabled ? _demoIsDoorUnlocked : _obdService.isDoorUnlocked;
  bool get isTrunkOpen =>
      _isDemoEnabled ? _demoIsTrunkOpen : _obdService.isTrunkOpen;
  int? get tpmsFl => _isDemoEnabled ? 35 : _obdService.tpmsFl?.floor();
  int? get tpmsFr => _isDemoEnabled ? 36 : _obdService.tpmsFr?.floor();
  int? get tpmsRl => _isDemoEnabled ? 35 : _obdService.tpmsRl?.floor();
  int? get tpmsRr => _isDemoEnabled ? 35 : _obdService.tpmsRr?.floor();
  int get serviceDistanceRemaining => _obdService.serviceDistanceRemaining;
  int get serviceDaysRemaining => _obdService.serviceDaysRemaining;
  List<String> get maintenanceLogHistory => _obdService.maintenanceLogHistory;
  Stream<String> get maintenanceLogStream => _obdService.maintenanceLogStream;
  bool get isWifiConnected => _isWifiConnected;
  double? get deviceBatteryTemp => DeviceStatusService().batteryTemperature;
  ThermalMode get thermalMode => DeviceStatusService().thermalMode;

  /// Initialize app - load CSV data
  Future<void> initialize() async {
    try {
      _status = 'Loading speed signs data...';
      notifyListeners();

      _allSpeedSigns = await CsvParser.loadSpeedSigns();
      _status = 'Data loaded: ${_allSpeedSigns.length} signs';
      _isLoading = false;

      // Initialize Road Type Service (國道/快速道路偵測)
      await RoadTypeService().init();

      // Initialize Speed Limit Service
      await SpeedLimitService().init();

      // 前方路況（TDX 路段）。車速是非同步查回來的，查到時要刷新畫面與推送
      await TrafficService().init();
      TrafficService().onChanged = notifyListeners;

      // Initialize Camera Service
      await CameraService().init();

      // Initialize BLE Service
      await _obdService.init();
      _obdService.addListener(_onObdServiceUpdated);

      // Initialize TTS Service
      await TtsService().init();

      // Initialize Device Status Service (電池溫度等)
      await DeviceStatusService().init();

      // Poll OBD state to update UI globally
      _obdStatusTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        bool changed = false;

        final wifiOk = await WifiService.isConnected();
        if (wifiOk != _isWifiConnected) {
          _isWifiConnected = wifiOk;
          changed = true;
        }

        final currentMode = DeviceStatusService().thermalMode;
        if (currentMode != _lastThermalMode) {
          _lastThermalMode = currentMode;
          changed = true;
        }

        if (changed) notifyListeners();
      });

      notifyListeners();
    } catch (e) {
      _status = 'Error: $e';
      _isLoading = false;
      notifyListeners();
    }
  }

  void _onObdServiceUpdated() {
    _maybeAnnounceHighBeam();
    _maybeWarnDoorOpenOnDeparture();
    notifyListeners();
  }

  /// 遠燈開啟/關閉的語音提示。
  ///
  /// 用去抖而不是冷卻時間：對向來車時駕駛常會連續閃遠燈，若只做冷卻會被
  /// 連珠炮唸；要求狀態穩定 1.5 秒才播報，閃燈全程都不會出聲，真正切換
  /// 才會唸一次。
  void _maybeAnnounceHighBeam() {
    // 沒有有效資料就重置：斷線時 isHighBeamOn 會被歸零，
    // 不重置的話重連後會誤報一句「遠燈關閉」。
    final bool hasData = _isDemoEnabled || _obdService.hasHeadlights;
    if (!hasData) {
      _highBeamDebounce?.cancel();
      _lastAnnouncedHighBeam = null;
      _lastObservedHighBeam = null;
      return;
    }

    final bool current = isHighBeamOn;

    // 狀態沒變就什麼都不做 —— 尤其不能碰計時器（見 _lastObservedHighBeam）
    if (current == _lastObservedHighBeam) return;
    _lastObservedHighBeam = current;

    if (_lastAnnouncedHighBeam == null) {
      _lastAnnouncedHighBeam = current; // 首次取得狀態只記錄，不播報
      return;
    }

    _highBeamDebounce?.cancel();
    _highBeamDebounce = Timer(const Duration(milliseconds: 1500), () {
      final bool stable = isHighBeamOn;
      if (stable == _lastAnnouncedHighBeam) return; // 期間又切回去了
      _lastAnnouncedHighBeam = stable;
      TtsService().speak(stable ? '遠燈開啟' : '遠燈關閉');
    });
  }

  /// 車門沒關好就起步：車速由 0 變成大於 0 的那一刻，若有任一車門開著，
  /// 連念兩次「車門沒關好」。
  ///
  /// 只看起步的那一瞬間，行進中才打開的車門不在這裡管。停車場裡時速常在
  /// 0 與 1 之間跳，所以兩次警告至少隔 30 秒，避免一路念個不停。
  /// ESP32 板子端有同樣的邏輯（main.c 的 serviceVoice）。
  void _maybeWarnDoorOpenOnDeparture() {
    final bool hasData = _isDemoEnabled || _obdService.hasDoors;
    final int? speed = hasData ? obdSpeed : null;
    final int? prev = _lastSpeedForDoorWarn;
    _lastSpeedForDoorWarn = speed;

    if (speed == null || prev != 0 || speed <= 0) return;
    if (!isAnyDoorOpen) return;

    final now = DateTime.now();
    if (_lastDoorWarnAt != null &&
        now.difference(_lastDoorWarnAt!) < const Duration(seconds: 30)) {
      return;
    }
    _lastDoorWarnAt = now;
    // flutter_tts 預設是 QUEUE_FLUSH，連呼叫兩次 speak 第一句會被砍掉，
    // 所以兩次合成一句念
    TtsService().speak('車門沒關好，車門沒關好');
  }

  @override
  void dispose() {
    _obdService.removeListener(_onObdServiceUpdated);
    _obdStatusTimer?.cancel();
    _demoTimer?.cancel();
    _highBeamDebounce?.cancel();
    _gpsDataController.close();
    TtsService().dispose();
    DeviceStatusService().dispose();
    super.dispose();
  }

  // ── Demo Mode Logic ──────────────────────────────────────────────────────
  void toggleDemoMode() {
    _isDemoEnabled = !_isDemoEnabled;
    if (_isDemoEnabled) {
      _startDemoTimer();
      _status = 'Demo Mode: ON';
    } else {
      _demoTimer?.cancel();
      _status = 'Demo Mode: OFF';
    }
    notifyListeners();
  }

  void _startDemoTimer() {
    _demoTimer?.cancel();
    _demoTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      _demoTicks++;

      // 建立一個 10 秒（100 ticks）的大循環週期
      final cyclePos = _demoTicks % 100;

      // 1. 模擬轉速：前 20 步 (2秒) 設為 0 (觸發 EV)，之後在 1~1789 之間波動
      if (cyclePos < 20) {
        _demoRpm = 0;
      } else {
        // 利用正弦波在剩餘 80 步中產生 1.0 ~ 1789.0 的變化
        // (cyclePos - 20) / 80 會從 0 變到 1
        final wave = math.sin((cyclePos - 20) *
            (math.pi / 40)); // 半個正弦週期的話用 pi/80，這裡用 pi/40 跑完一個週期
        _demoRpm = 895 + 894 * wave;
      }

      // 2. 模擬時速：正弦波 60 ~ 130
      _demoSpeed = 95 + 35 * (math.sin(_demoTicks * 0.05));

      // 3. 模擬增壓：-0.4 ~ 0.7
      // 範圍 1.1, 中心 0.15, 振幅 0.55
      _demoTurbo = 0.15 + 0.55 * (math.sin(_demoTicks * 0.12));

      // 4. 模擬電池：60.0 ~ 80.0
      _demoSoc = 70.0 + 10.0 * (math.cos(_demoTicks * 0.02));

      // 5. 模擬水溫：88 與 101 之間循環切換 (每 3 秒切換一次)
      if (_demoTicks % 30 == 0) {
        _demoCoolant = (_demoCoolant == 88) ? 101 : 88;
      }

      // 6. 模擬倒車：每 2 秒切換一次
      if (_demoTicks % 20 == 0) {
        _demoIsReversing = !_demoIsReversing;
      }

      // 7. 模擬大燈：每 6 秒依 關 → 近燈 → 遠燈 循環，驗證亮度切換
      if (_demoTicks % 60 == 0) {
        if (!_demoIsLowBeamOn && !_demoIsHighBeamOn) {
          _demoIsLowBeamOn = true;
        } else if (_demoIsLowBeamOn && !_demoIsHighBeamOn) {
          _demoIsHighBeamOn = true;
        } else {
          _demoIsLowBeamOn = false;
          _demoIsHighBeamOn = false;
        }
      }

      // 8. 模擬車門 / 門鎖 / 尾門（狀態區的三個指示燈）。
      // 週期刻意取互質，四個指示燈才不會同步閃、能看遍各種組合。
      // tick = 100ms，所以是 3 / 5 / 7 秒各自翻轉一次。
      if (_demoTicks % 30 == 0) _demoIsAnyDoorOpen = !_demoIsAnyDoorOpen;
      if (_demoTicks % 50 == 0) _demoIsDoorUnlocked = !_demoIsDoorUnlocked;
      if (_demoTicks % 70 == 0) _demoIsTrunkOpen = !_demoIsTrunkOpen;

      _maybeAnnounceHighBeam();
      _maybeWarnDoorOpenOnDeparture();
      notifyListeners();
    });
  }

  /// Update current position and find nearby speed signs
  void updatePosition(Position position) {
    _currentPosition = position;
    final now = DateTime.now();

    // ── 檢查是否滿足標準 GPS 資料後送條件 (每 10s 或航向 > 30度) ──
    double headingDiff = (position.heading - _lastGpsSentHeading).abs();
    if (headingDiff > 180) headingDiff = 360 - headingDiff; // 處理 0/360 跨越

    bool shouldSendGps = false;
    if (_lastGpsSentTime == null) {
      shouldSendGps = true;
    } else {
      final int timeDiff = now.difference(_lastGpsSentTime!).inSeconds;
      if (timeDiff >= 10 || headingDiff >= 20) {
        shouldSendGps = true;
      }
    }

    if (shouldSendGps) {
      _lastGpsSentTime = now;
      _lastGpsSentHeading = position.heading;

      // 依照需求格式組裝 JSON
      final timestampSec = now.millisecondsSinceEpoch ~/ 1000;
      final gpsTimeStr =
          DateFormat('HHmmss.00').format(position.timestamp.toLocal());

      final Map<String, dynamic> gpsPayload = {
        "_type": "BVB-7980",
        "tid": "gps",
        "tst": timestampSec,
        "lat": position.latitude,
        "lon": position.longitude,
        "acc": position.accuracy > 0 ? position.accuracy : 15.0,
        "vel": double.parse((position.speed * 3.6).toStringAsFixed(2)),
        "cog": double.parse(position.heading.toStringAsFixed(1)),
        "satcnt": DeviceStatusService().satelliteCount,
        "gpstime": gpsTimeStr,
      };
      _gpsDataController.add(gpsPayload);
    }

    // ── 加入軌跡（測速照相與國道偵測共用） ──
    final camService = CameraService();
    camService.addPosition(position);

    // ── 更新國道/快速道路旗標（快取 + 滑動分數，封裝於 RoadTypeService） ──
    RoadTypeService().addPosition(position.latitude, position.longitude);

    // ── 道路速限偵測：OSM 圖資比對 → 省道牌面 → 分級推定 → 路型 ──
    final speedLimitService = SpeedLimitService();
    final detectedLimit = speedLimitService.detectNearbyLimit(
      position.latitude,
      position.longitude,
      roadType: RoadTypeService().currentRoadType,
      headingDeg: position.heading,
      speedKmh: position.speed * 3.6,
    );
    if (detectedLimit != null) {
      _roadSpeedLimit = detectedLimit;
    } else if (!speedLimitService.lastDetectedFromSign) {
      // 上次來源非牌面，且現在無法判定 → 退回預設 40
      _roadSpeedLimit = 40;
    }
    // 上次來源為省道牌面 → 保留最後牌面值，不更動

    // ── 前方路況：高架／平面沒把握時不比對，免得側車道拿到主線的路況 ──
    TrafficService().update(
      position.latitude,
      position.longitude,
      road: speedLimitService.isLevelUncertain ? null : speedLimitService.currentRoad,
      headingDeg: position.heading,
      speedKmh: position.speed * 3.6,
      roadLimit: _roadSpeedLimit,
    );

    // Find nearby signs within 500m (Legacy logic, keep for backward compatibility or other indicators)
    _nearbySpeedSigns = CsvParser.findNearby(
      _allSpeedSigns,
      position.latitude,
      position.longitude,
      500,
    );

    // Update current speed limit from nearest sign
    if (_nearbySpeedSigns.isNotEmpty) {
      _status = 'Nearby signs detected...';
      _currentSpeedLimit = _nearbySpeedSigns.first.speedLimit;
    } else {
      _currentSpeedLimit = null;
      _status = 'No speed signs nearby';
    }

    // ── 測速點偵測開關 ──
    if (!SettingsService().enableOcr) {
      _currentSpeedLimit = null;
      _nearestCameraInfo = null;
      notifyListeners();
      return;
    }

    // ── 測速照相偵測 ──
    final slService = SpeedLimitService();
    final trackedType = slService.trackedRoadType;
    // 有把握在國道／快速道路上、且速限是 OSM 實測值時才提供，
    // 用來排除高架正下方平面道路的相機（見 checkNearbyCamera）
    final bool onHighSpeedRoad = trackedType != null &&
        trackedType != RoadType.none &&
        !slService.isLevelUncertain;
    final camInfo = camService.checkNearbyCamera(
      currentRoadType: effectiveRoadType,
      surfaceConfirmed: slService.surfaceConfirmed,
      roadLimit: onHighSpeedRoad && slService.source == LimitSource.osm
          ? _roadSpeedLimit
          : null,
    );

    // 提示距離門檻：
    //   區間測速        → 100m
    //   平面道路固定測速  → 500m
    //   國道/快速道路    → 1000m
    // 搜尋半徑（1～2km）比門檻大，相機在半徑內但還沒到門檻時不算提示中——
    // 否則畫面與 ESP 會在兩公里外就亮起，比語音早了一大截。
    // 上一支提示中的相機不見了（或換成另一支）→ 判斷是不是剛通過
    final String? currentCamId =
        camInfo == null ? null : '${camInfo['lat']}_${camInfo['lon']}';
    if (_alertedCameraInfo != null && currentCamId != _alertedCameraId) {
      // 區間起點不念：那是區間的開始，要等區間終點才算通過
      if (_alertedCameraInfo!['kind'] != CameraKind.zoneStart.name &&
          _cameraBehindAndClose(_alertedCameraInfo!, position,
              camService.lastHeading)) {
        if (TtsService().speakCameraPassed(_alertedCameraInfo!)) {
          _cameraPassedCount++;
        }
      }
      _alertedCameraInfo = null;
    }

    bool alerting = false;
    if (camInfo != null) {
      final String camId = '${camInfo['lat']}_${camInfo['lon']}';
      final int distM = camInfo['dist_m'] ?? 9999;
      final bool isZone = camInfo['is_zone'] == true;
      final bool isNormalRoad = effectiveRoadType == RoadType.none;
      final int alertThresholdM = isZone ? 100 : (isNormalRoad ? 500 : 1000);
      if (distM <= alertThresholdM) _alertedCameraId = camId;
      alerting = _alertedCameraId == camId;
    }

    if (camInfo != null && alerting) {
      _alertedCameraInfo = camInfo;
      _nearestCameraInfo = camInfo;
      if (camInfo['limit'] != null) {
        _currentSpeedLimit = camInfo['limit'];
      }
      if (camInfo['is_zone'] == true) {
        _activeZoneCameraInfo = camInfo;
        _zoneCameraActiveUntil = DateTime.now().add(_zoneCameraDisplayDuration);
      } else {
        _activeZoneCameraInfo = null;
        _zoneCameraActiveUntil = null;
      }
      final double speedKmh = position.speed * 3.6;
      final int distM = camInfo['dist_m'] ?? 9999;
      final int? limit = camInfo['limit'];
      final bool isZone = camInfo['is_zone'] == true;

      TtsService().speakCameraAlert(camInfo, speedKmh);

      // 距離 300m 內且超速 10km/h 以上 → 額外播報超速警示（區間測速不適用）
      if (!isZone && distM <= 300 && limit != null && speedKmh > limit + 10) {
        TtsService().speakSpeedingAlert(camInfo);
      }
    } else {
      if (camInfo == null) _alertedCameraId = null;
      if (_zoneCameraActiveUntil != null &&
          DateTime.now().isBefore(_zoneCameraActiveUntil!) &&
          _stillInZone(camService.lastHeading, slService.surfaceConfirmed)) {
        _nearestCameraInfo = _activeZoneCameraInfo;
      } else {
        _nearestCameraInfo = null;
        _activeZoneCameraInfo = null;
        _zoneCameraActiveUntil = null;
      }
    }

    notifyListeners();
  }

  bool _cameraBehindAndClose(
      Map<String, dynamic> cam, Position pos, double? heading) {
    final double lat = (cam['lat'] as num).toDouble();
    final double lon = (cam['lon'] as num).toDouble();
    final double d = CameraAlgorithm.haversine(pos.latitude, pos.longitude, lat, lon);
    if (d > _passedMaxDistKm) return false;
    if (heading == null) return false;
    final double bearing =
        CameraAlgorithm.calculateBearing(pos.latitude, pos.longitude, lat, lon);
    double diff = (bearing - heading).abs();
    if (diff > 180) diff = 360 - diff;
    return diff > 90;
  }

  /// 通過區間起點後，區間提示會保留一段時間。下閘道或轉進別條路就立刻清掉，
  /// 不必等到逾時：追蹤器確認已在平面道路上，或行進方向偏離區間方向超過 60°。
  bool _stillInZone(double? heading, bool surfaceConfirmed) {
    final zone = _activeZoneCameraInfo;
    if (zone == null) return false;
    if (surfaceConfirmed && zone['road_type'] != RoadType.none.name) return false;
    final double? zoneHeading = (zone['heading'] as num?)?.toDouble();
    if (heading != null && zoneHeading != null) {
      double diff = (heading - zoneHeading).abs();
      if (diff > 180) diff = 360 - diff;
      if (diff > 60) return false;
    }
    return true;
  }

  /// Check if speeding
  bool isExceedingSpeedLimit(double currentSpeed) {
    if (_currentSpeedLimit == null) return false;
    return currentSpeed > _currentSpeedLimit!;
  }

  /// 手動查詢保養資訊
  Future<void> queryMaintenanceInfo() async {
    await _obdService.queryMaintenanceInfo();
    notifyListeners();
  }

  // ── 測速路徑模擬工具 ──
  bool _isSimulating = false;
  bool get isSimulating => _isSimulating;
  Timer? _simulationTimer;

  void simulateSpeedCameraPath() {
    if (_isSimulating) {
      _isSimulating = false;
      _simulationTimer?.cancel();
      _status = 'Simulation stopped';
      notifyListeners();
      return;
    }

    _isSimulating = true;
    _status = '模擬中...';
    TtsService().clearCooldown();
    notifyListeners();

    // 模擬座標序列：從北往南接近台中梧棲中華路一段 (24.236662, 120.548325)
    final List<Position> points = [
      Position(
          latitude: 24.2458,
          longitude: 120.5525,
          timestamp: DateTime.now(),
          accuracy: 1,
          altitude: 0,
          heading: 0,
          speed: 16.6,
          speedAccuracy: 1,
          floor: 0,
          isMocked: true,
          altitudeAccuracy: 0,
          headingAccuracy: 0),
      Position(
          latitude: 24.2439,
          longitude: 120.5517,
          timestamp: DateTime.now(),
          accuracy: 1,
          altitude: 0,
          heading: 0,
          speed: 16.6,
          speedAccuracy: 1,
          floor: 0,
          isMocked: true,
          altitudeAccuracy: 0,
          headingAccuracy: 0),
      Position(
          latitude: 24.2419,
          longitude: 120.5506,
          timestamp: DateTime.now(),
          accuracy: 1,
          altitude: 0,
          heading: 0,
          speed: 16.6,
          speedAccuracy: 1,
          floor: 0,
          isMocked: true,
          altitudeAccuracy: 0,
          headingAccuracy: 0),
      Position(
          latitude: 24.2396,
          longitude: 120.5496,
          timestamp: DateTime.now(),
          accuracy: 1,
          altitude: 0,
          heading: 0,
          speed: 16.6,
          speedAccuracy: 1,
          floor: 0,
          isMocked: true,
          altitudeAccuracy: 0,
          headingAccuracy: 0),
      Position(
          latitude: 24.2389,
          longitude: 120.5494,
          timestamp: DateTime.now(),
          accuracy: 1,
          altitude: 0,
          heading: 0,
          speed: 16.6,
          speedAccuracy: 1,
          floor: 0,
          isMocked: true,
          altitudeAccuracy: 0,
          headingAccuracy: 0),
      Position(
          latitude: 24.2383,
          longitude: 120.5492,
          timestamp: DateTime.now(),
          accuracy: 1,
          altitude: 0,
          heading: 0,
          speed: 16.6,
          speedAccuracy: 1,
          floor: 0,
          isMocked: true,
          altitudeAccuracy: 0,
          headingAccuracy: 0),
    ];

    int index = 0;
    _simulationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (index >= points.length) {
        _isSimulating = false;
        timer.cancel();
        _status = '模擬完成';
        notifyListeners();
        return;
      }
      updatePosition(points[index]);
      notifyListeners();
      index++;
    });
  }
}
