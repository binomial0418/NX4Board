import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:convert';
import '../providers/app_provider.dart';
import '../services/device_status_service.dart';
import '../services/location_service.dart';
import '../services/settings_service.dart';
import '../services/obd_spp_service.dart';
import '../services/wifi_service.dart';
import '../services/screen_recorder_service.dart';
import 'settings_screen.dart';
import '../widgets/native_dashboard.dart';

// Foreground Task Handler（必須為 top-level function）
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(DashboardTaskHandler());
}

class DashboardTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({Key? key}) : super(key: key);

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  // --- 動畫 ---
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // --- WebSocket ---
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _wsSubscription;
  Timer? _reconnectTimer;
  bool _isWsConnected = false; // WebSocket 連線狀態
  bool _isWsConnecting = false; // 防止重複連線
  Timer? _wsUploadTimer;

  // --- 電源管理 ---
  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _batterySubscription;
  Timer? _sleepCountdownTimer;
  bool? _isCharging; // null 代表尚未偵測到初始狀態

  // --- GPS 定位管理 ---
  StreamSubscription<Position>? _positionSubscription;

  // --- 測速照相 WS 後送冷卻 (與 TTS 同樣以座標為 ID，300 秒內不重送) ---
  final Map<String, DateTime> _cameraWsSentMap = {};
  static const Duration _cameraWsCooldown = Duration(seconds: 300);

  // --- Screen Recording ---
  late ScreenRecorderService _screenRecorder;
  Timer? _recordingStateTimer;
  RecordingState _lastRecordingState = RecordingState.idle;
  int _lastRemainingSeconds = 0;

  // --- 散熱管理 ---
  // 記錄 GPS 串流目前使用的 distanceFilter，與 _thermalDistanceFilter 比對
  // 即可判斷是否需重啟，不在 DashboardScreen 重複維護 ThermalMode 狀態
  int _currentGpsDistanceFilter = 5;

  // --- AppProvider 參考（dispose 時不可依賴 BuildContext）---
  late AppProvider _appProvider;

  @override
  void initState() {
    super.initState();
    // 初始化脈衝動畫
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _screenRecorder = ScreenRecorderService();
    _appProvider = context.read<AppProvider>();
    _initializeWidgets();
    // 註冊 OBD 數據更新監聽器 (事件驅動)
    ObdSppService().addListener(_handleUiUpdate);
    // 註冊 AppProvider 資料更新監聽器 (GPS/測速)
    _appProvider.addListener(_handleUiUpdate);
    // 監聽並傳送標準格式 GPS 定位資料 (tid: gps)
    _appProvider.gpsDataStream.listen((data) {
      if (_isWsConnected && _channel != null) {
        final jsonString = jsonEncode(data);
        try {
          _channel!.sink.add(jsonString);
          debugPrint('[WS-TX] Standard GPS Upload: $jsonString');
          ObdSppService().logWsSend(jsonString);
        } catch (e) {
          debugPrint('[WS-TX] Standard GPS Send error: $e');
        }
      }
    });
    // 監聽錄影狀態變化
    _startRecordingStateMonitoring();
  }

  Future<void> _initializeWidgets() async {
    // 集中請求所有必要權限 (啟動時必須)
    await _requestAllPermissions();

    // 強制橫向 + 隱藏 Status Bar
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // 初始化背景服務配置
    _initForegroundTask();

    // 啟動電源監控 (這會觸發首次 _handleBatteryStateChange 並決定是否進入睡眠)
    _startBatteryMonitoring();
  }

  // ──────────────────────────────────────────────
  // 集中式權限請求（啟動時全部一次詢問）
  // ──────────────────────────────────────────────
  Future<void> _requestAllPermissions() async {
    // 1. 第一階段：請求基礎必要權限
    final basePermissions = [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.notification,
      Permission.microphone, // 螢幕錄影所需
    ];

    Map<Permission, PermissionStatus> statuses =
        await basePermissions.request();

    // 檢查是否有權限被拒絕（非永久）
    bool hasDenied = statuses.values.any((s) => s.isDenied);
    if (hasDenied && mounted) {
      await _showPermissionExplanationDialog(
        '需要權限',
        '此 App 需要定位、藍牙、通知及錄音權限才能完整運作（錄影功能涉及麥克風）。請授予權限以繼續。',
        () async {
          statuses = await basePermissions.request();
        },
      );
    }

    // 2. 第二階段：若基礎定位已過，請求「始終允許」定位權限 (Android 10+ 背景定位)
    if (await Permission.location.isGranted) {
      final statusAlways = await Permission.locationAlways.request();
      if (statusAlways.isDenied && mounted) {
        await _showPermissionExplanationDialog(
          '需要背景定位',
          '為了在螢幕關閉或切換後台時持續偵測測速照相，建議將定位權限設為「始終允許」。',
          () async => await Permission.locationAlways.request(),
        );
      }
    }

    // 3. 檢查是否有永久拒絕的情況
    final allStatuses = await Future.wait([
      Permission.location,
      Permission.locationAlways,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.notification,
    ].map((p) async => MapEntry(p, await p.status)));

    bool hasPermanentlyDenied = false;
    for (var entry in allStatuses) {
      if (entry.value.isPermanentlyDenied) {
        hasPermanentlyDenied = true;
        break;
      }
    }

    if (hasPermanentlyDenied && mounted) {
      await _showPermanentDeniedDialog();
    }
  }

  Future<void> _showPermissionExplanationDialog(
      String title, String content, VoidCallback onRetry) async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('稍後'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              onRetry();
            },
            child: const Text('再次嘗試'),
          ),
        ],
      ),
    );
  }

  Future<void> _showPermanentDeniedDialog() async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('權限已被永久拒絕'),
        content:
            const Text('部分必要權限（定位、藍牙、通知）被設定為「不再詢問」。\n請前往系統設定手動開啟，否則部分功能將無法運作。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              openAppSettings();
            },
            child: const Text('前往設定'),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────
  // Foreground Service 初始化（防後台被砍）
  // ──────────────────────────────────────────────
  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'dashboard_channel',
        channelName: '儀表板服務',
        channelDescription: '行車儀表板持續運行中',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    FlutterForegroundTask.startService(
      notificationTitle: 'NX4Board',
      notificationText: '行車儀表板持續運行中',
      callback: startCallback,
    );
  }

  // ──────────────────────────────────────────────
  // GPS 定位追蹤
  // ──────────────────────────────────────────────
  void _startLocationTracking({int distanceFilter = 5}) {
    _currentGpsDistanceFilter = distanceFilter;
    _positionSubscription?.cancel();
    _positionSubscription =
        LocationService.getPositionStream(distanceFilter: distanceFilter)
            .listen(
      (Position position) {
        if (mounted) {
          final appProvider = context.read<AppProvider>();
          appProvider.updatePosition(position);
          ObdSppService().onGpsAltitudeChanged(position.altitude);
          ObdSppService().onGpsSpeedChanged(position.speed);
        }
      },
      onError: (e) {
        debugPrint('Location stream error: $e — 2 秒後自動重啟 GPS 串流');
        _positionSubscription?.cancel();
        _positionSubscription = null;
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && _isCharging == true) {
            _startLocationTracking(distanceFilter: _thermalDistanceFilter);
          }
        });
      },
    );
  }

  /// 以當前散熱等級對應的 distanceFilter 重啟 GPS 串流
  void _restartLocationForThermal() {
    if (_positionSubscription == null) return; // GPS 未運行，不需重啟
    final filter = _thermalDistanceFilter;
    debugPrint('[Thermal] GPS distanceFilter → ${filter}m');
    _startLocationTracking(distanceFilter: filter);
  }

  // ──────────────────────────────────────────────
  // 電源狀態監控
  // ──────────────────────────────────────────────
  void _startBatteryMonitoring() async {
    // 先取得目前充電狀態
    try {
      final initialState = await _battery.batteryState;
      _handleBatteryStateChange(initialState);
    } catch (e) {
      debugPrint('Battery initial state error: $e');
    }

    // 監聽後續狀態變化
    _batterySubscription = _battery.onBatteryStateChanged.listen(
      (BatteryState state) {
        _handleBatteryStateChange(state);
      },
      onError: (e) => debugPrint('Battery stream error: $e'),
    );
  }

  void _handleBatteryStateChange(BatteryState state) {
    final bool charging =
        state == BatteryState.charging || state == BatteryState.full;

    // ── 初始狀態處理 ──
    if (_isCharging == null) {
      _isCharging = charging;
      if (charging) {
        debugPrint('[電源] 初始狀態：已連接外部電源');
        _wakeUp();
      } else {
        debugPrint('[電源] 初始狀態：無外部電源，立即進入睡眠');
        _enterSleepMode();
      }
      return;
    }

    // ── 狀態切換處理 ──
    if (charging && !_isCharging!) {
      _isCharging = true;
      debugPrint('[電源] 偵測到外部電源連接，喚醒系統資源');
      _sleepCountdownTimer?.cancel();
      _sleepCountdownTimer = null;
      _wakeUp();
    } else if (!charging && _isCharging!) {
      _isCharging = false;
      debugPrint('[電源] 偵測到外部電源中斷，10 秒後進入深度睡眠');
      _startSleepCountdown();
    }
  }

  void _wakeUp() {
    ObdSppService().resetData(); // 喚醒當下立即重置數據緩存，確保 UI 顯示 --
    WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // 啟動/恢復 GPS（若串流已終止則重建，使用當前散熱等級對應的 distanceFilter）
    if (_positionSubscription == null) {
      _startLocationTracking(distanceFilter: _thermalDistanceFilter);
    } else if (_positionSubscription!.isPaused) {
      _positionSubscription!.resume();
    } else {
      // 串流可能已因錯誤終止（done），強制重建
      _startLocationTracking(distanceFilter: _thermalDistanceFilter);
    }

    // 重連 OBD
    final obdService = ObdSppService();
    if (obdService.connectionState == ObdConnectionState.disconnected) {
      debugPrint('[電源] 重新連接 OBD 藍牙');
      obdService.init();
    }

    // 恢復 WebSocket 連線
    if (!_isWsConnected) {
      _connectWebSocket();
    }
    _startWsUploadSync();

    // 喚醒後短暫延遲傳送一次資料
    Future.delayed(const Duration(seconds: 2), () {
      if (_isCharging == true) {
        _sendObdDataViaWsOnce();
        _handleUiUpdate(); // 強制刷一次 UI

        // Wakeup animation is handled by NativeDashboard's OBD listener
      }
    });
  }

  void _startSleepCountdown() {
    _sleepCountdownTimer?.cancel();
    int countdown = 10;
    _sleepCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      countdown--;
      debugPrint('[電源] 進入睡眠倒數：$countdown 秒');
      if (countdown <= 0) {
        timer.cancel();
        _enterSleepMode();
      }
    });
  }

  Future<void> _enterSleepMode() async {
    debugPrint('[電源] 進入深度睡眠模式，關閉背景高耗電資源');

    // 關閉螢幕常亮與沉浸模式
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );

    // 切斷 WebSocket 以省電
    _channel?.sink.close();
    if (mounted) setState(() => _isWsConnected = false);

    _wsUploadTimer?.cancel();

    // 停止 GPS 定位以省電 (不再進行任何測速偵測)
    _positionSubscription?.cancel();
    _positionSubscription = null;
    debugPrint('[電源] GPS 定位已停止，停止一切測速偵測');

    // 斷開藍牙 OBD（關閉輪詢 + 釋放 SPP 連線）
    ObdSppService().handleDisconnect('power_disconnected');
    debugPrint('[電源] OBD 藍牙已斷線');

    if (mounted) setState(() {});
    debugPrint('[電源] 系統資源已釋放，進入深度睡眠');
  }

  // ──────────────────────────────────────────────
  // WebSocket 連線
  // ──────────────────────────────────────────────
  void _connectWebSocket() {
    // 防衛鎖：避免重複發起連線
    if (_isWsConnecting) return;
    _isWsConnecting = true;

    _doConnectWebSocket();
  }

  void _doConnectWebSocket() {
    try {
      final ip = SettingsService().wsIp;
      final port = SettingsService().wsPort;

      // 先取消舊訂閱、關閉舊 channel，防止 StreamSubscription 洩漏
      _wsSubscription?.cancel();
      _wsSubscription = null;
      _channel?.sink.close();
      _channel = null;

      _channel = WebSocketChannel.connect(Uri.parse('ws://$ip:$port'));

      // 連線建立後立即標記為 connected（不等收到訊息）
      // 因為本 app 是主動推送方，可能永遠不會收到回傳訊息
      if (mounted) setState(() => _isWsConnected = true);
      debugPrint('[WS] 已連接: ws://$ip:$port');

      _wsSubscription = _channel!.stream.listen(
        (message) {
          // 伺服器下推訊息（保留供未來擴充）
          debugPrint('[WS] server push: $message');
        },
        onDone: () {
          debugPrint('[WS] 連線中斷 (onDone)');
          if (mounted) setState(() => _isWsConnected = false);
          _isWsConnecting = false;
          _scheduleReconnect();
        },
        onError: (error) {
          debugPrint('[WS] 連線錯誤: $error');
          if (mounted) setState(() => _isWsConnected = false);
          _isWsConnecting = false;
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
      _isWsConnecting = false;
    } catch (e) {
      debugPrint('[WS] 連線失敗: $e');
      if (mounted) setState(() => _isWsConnected = false);
      _isWsConnecting = false;
      _scheduleReconnect();
    }
  }

  void _startWsUploadSync() {
    _wsUploadTimer?.cancel();
    _wsUploadTimer = Timer.periodic(const Duration(seconds: 60), (timer) async {
      if (!mounted) return;

      // 若未連線且正在充電，立即觸發重連（不等下次斷線事件）
      if (!_isWsConnected || _channel == null) {
        if (_isCharging == true) _scheduleReconnect();
        return;
      }

      final provider = context.read<AppProvider>();

      // 檢查 OBD 是否連線
      if (provider.obdConnectionState != ObdConnectionState.connected) {
        debugPrint('[WS-TX] OBD 未連線，跳過定期同步');
        return;
      }

      final Map<String, dynamic> uploadData = {
        "_type": "BVB-7980",
        "tid": "obd",
      };

      // 新增 GPS 資料
      if (provider.currentPosition != null) {
        uploadData["lat"] = provider.currentPosition!.latitude;
        uploadData["lon"] = provider.currentPosition!.longitude;
        uploadData["alt"] = provider.currentPosition!.altitude;
      }

      final Map<String, dynamic> tires = {};
      final obd = ObdSppService();
      if (obd.hasTpms) {
        if (provider.tpmsFl != null) tires["fl"] = provider.tpmsFl;
        if (provider.tpmsFr != null) tires["fr"] = provider.tpmsFr;
        if (provider.tpmsRl != null) tires["rl"] = provider.tpmsRl;
        if (provider.tpmsRr != null) tires["rr"] = provider.tpmsRr;
      }
      if (tires.isNotEmpty) uploadData["tires"] = tires;

      if (obd.hasOdometer && provider.obdOdometer != null)
        uploadData["mileage"] = provider.obdOdometer;
      if (obd.hasFuel && provider.obdFuel != null)
        uploadData["fuel"] = provider.obdFuel;

      // 新增：保養維護資訊
      if (obd.hasServiceDistanceRemaining)
        uploadData["serviceDistance"] = provider.serviceDistanceRemaining;
      if (obd.hasServiceDaysRemaining)
        uploadData["serviceDays"] = provider.serviceDaysRemaining;

      // 同時保留儀表板需要的原始屬性
      if (obd.hasSpeed && provider.obdSpeed != null)
        uploadData["speed"] = provider.obdSpeed;
      if (obd.hasRpm && provider.obdRpm != null)
        uploadData["rpm"] = provider.obdRpm;
      if (obd.hasCoolant && provider.obdCoolant != null)
        uploadData["temperature"] = provider.obdCoolant;
      if (obd.hasHevSoc && provider.obdHevSoc != null)
        uploadData["battery"] = provider.obdHevSoc;
      uploadData["speed_limit"] = provider.roadSpeedLimit;
      if (provider.deviceBatteryTemp != null) {
        uploadData["device_temp"] = provider.deviceBatteryTemp;
      }

      if (uploadData.length > 2) {
        // 除了 _type, tid 之外還有其他資料 — 發送前確認 WiFi 狀態
        final wifiOk = await WifiService.isConnected();
        if (!wifiOk) {
          debugPrint('[WS-TX] WiFi 未連線，取消本次上傳');
          return;
        }
        final jsonString = jsonEncode(uploadData);
        try {
          _channel!.sink.add(jsonString);
          debugPrint('[WS-TX] Uploaded to Relay: $jsonString');
          ObdSppService().logWsSend(jsonString);
        } catch (e) {
          debugPrint('[WS-TX] Send error: $e');
          // 發送失敗視為斷線，立即觸發重連
          if (mounted) setState(() => _isWsConnected = false);
          _scheduleReconnect();
        }
      }
    });
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    // 如果不在充電狀態（睡眠或準備睡眠）就不主動重連
    if (_isCharging != true) return;

    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _isCharging == true) _connectWebSocket();
    });
  }

  // ──────────────────────────────────────────────
  // 同步 BLE 資料至 WebView
  // ──────────────────────────────────────────────
  /// 速度來源：OBD 優先，GPS 備援（低於 1.5 m/s 視為靜止歸零）
  double get _currentDisplaySpeed {
    final provider = context.read<AppProvider>();
    if (provider.obdSpeed != null) return provider.obdSpeed!.toDouble();
    final position = provider.currentPosition;
    if (position != null) {
      final gpsSpeed = position.speed * 3.6;
      return gpsSpeed > 1.5 ? gpsSpeed : 0.0;
    }
    return 0.0;
  }

  /// 散熱等級對應的 GPS distanceFilter（公尺）
  int get _thermalDistanceFilter {
    switch (context.read<AppProvider>().thermalMode) {
      case ThermalMode.hot:
        return 20; // 降低熱天位移門檻
      case ThermalMode.warm:
        return 10;
      default:
        return 5; // 正常模式 5m，確保護轉彎靈敏度
    }
  }

  void _handleUiUpdate() {
    if (!mounted) return;

    // ── 散熱模式變化偵測：distanceFilter 與目前 GPS 串流不同時重啟 ──
    if (_isCharging == true &&
        _thermalDistanceFilter != _currentGpsDistanceFilter) {
      _restartLocationForThermal();
    }

    // 偵測到測速照相時立即後送 WS
    final provider = context.read<AppProvider>();
    if (provider.nearestCameraInfo != null) {
      _sendCameraAlertViaWs(provider.nearestCameraInfo!);
    }
  }

  // ──────────────────────────────────────────────
  // 測速照相偵測時立即後送 WS
  // ──────────────────────────────────────────────
  Future<void> _sendCameraAlertViaWs(Map<String, dynamic> camInfo) async {
    if (!mounted || !_isWsConnected || _channel == null) return;

    // 以座標為唯一 ID，遵循 300 秒冷卻機制
    final String id = "${camInfo['lat']}_${camInfo['lon']}";
    final now = DateTime.now();
    if (_cameraWsSentMap.containsKey(id) &&
        now.difference(_cameraWsSentMap[id]!) < _cameraWsCooldown) {
      return; // 冷卻中，不重送
    }
    _cameraWsSentMap[id] = now;

    final provider = context.read<AppProvider>();

    final Map<String, dynamic> alertData = {
      "_type": "BVB-7980",
      "tid": "camera-info",
      "speed": _currentDisplaySpeed.round(),
      "camera_limit": camInfo['limit'],
      "speed_limit": provider.roadSpeedLimit,
      "address": camInfo['address'],
    };

    final jsonString = jsonEncode(alertData);
    try {
      _channel!.sink.add(jsonString);
      debugPrint('[WS-TX] 測速照相警報後送: $jsonString');
      ObdSppService().logWsSend(jsonString);
    } catch (e) {
      debugPrint('[WS-TX] 測速照相後送錯誤: $e');
      if (mounted) setState(() => _isWsConnected = false);
      _scheduleReconnect();
    }
  }

  // ──────────────────────────────────────────────
  // 立即傳送一次 OBD 資料至 WS（輪詢回來後呼叫）
  // ──────────────────────────────────────────────
  Future<void> _sendObdDataViaWsOnce() async {
    if (!mounted || !_isWsConnected || _channel == null) return;
    if (_isCharging != true) return; // 沒供電時不主動發送

    final provider = context.read<AppProvider>();

    // 檢查 OBD 是否連線
    if (provider.obdConnectionState != ObdConnectionState.connected) {
      debugPrint('[WS-TX] OBD 未連線，跳過立即傳送');
      return;
    }

    final Map<String, dynamic> uploadData = {
      "_type": "BVB-7980",
      "tid": "obd",
    };

    // 新增 GPS 資料
    if (provider.currentPosition != null) {
      uploadData["lat"] = provider.currentPosition!.latitude;
      uploadData["lon"] = provider.currentPosition!.longitude;
      uploadData["alt"] = provider.currentPosition!.altitude;
    }

    final Map<String, dynamic> tires = {};
    final obd = ObdSppService();
    if (obd.hasTpms) {
      if (provider.tpmsFl != null) tires["fl"] = provider.tpmsFl;
      if (provider.tpmsFr != null) tires["fr"] = provider.tpmsFr;
      if (provider.tpmsRl != null) tires["rl"] = provider.tpmsRl;
      if (provider.tpmsRr != null) tires["rr"] = provider.tpmsRr;
    }
    if (tires.isNotEmpty) uploadData["tires"] = tires;

    if (obd.hasOdometer && provider.obdOdometer != null)
      uploadData["odo"] = provider.obdOdometer;
    if (obd.hasFuel && provider.obdFuel != null)
      uploadData["fuel"] = provider.obdFuel;

    // 新增：保養維護資訊
    if (obd.hasServiceDistanceRemaining)
      uploadData["serviceDistance"] = provider.serviceDistanceRemaining;
    if (obd.hasServiceDaysRemaining)
      uploadData["serviceDays"] = provider.serviceDaysRemaining;

    if (obd.hasSpeed && provider.obdSpeed != null)
      uploadData["speed"] = provider.obdSpeed;
    if (obd.hasRpm && provider.obdRpm != null)
      uploadData["rpm"] = provider.obdRpm;
    if (obd.hasCoolant && provider.obdCoolant != null)
      uploadData["temperature"] = provider.obdCoolant;
    if (obd.hasHevSoc && provider.obdHevSoc != null)
      uploadData["battery"] = provider.obdHevSoc;
    uploadData["speed_limit"] = provider.roadSpeedLimit;

    if (uploadData.length > 2) {
      // 發送前確認 WiFi 狀態
      final wifiOk = await WifiService.isConnected();
      if (!wifiOk) {
        debugPrint('[WS-TX] WiFi 未連線，取消立即傳送');
        return;
      }
      final jsonString = jsonEncode(uploadData);
      try {
        _channel!.sink.add(jsonString);
        debugPrint('[WS-TX] 輪詢後立即傳送: $jsonString');
        ObdSppService().logWsSend(jsonString);
      } catch (e) {
        debugPrint('[WS-TX] 立即傳送錯誤: $e');
        if (mounted) setState(() => _isWsConnected = false);
        _scheduleReconnect();
      }
    }
  }

  // ──────────────────────────────────────────────
  // 清理
  // ──────────────────────────────────────────────
  @override
  void dispose() {
    _positionSubscription?.cancel();
    _batterySubscription?.cancel();
    _wsSubscription?.cancel();
    _sleepCountdownTimer?.cancel();
    _reconnectTimer?.cancel();
    _wsUploadTimer?.cancel();
    _recordingStateTimer?.cancel();
    // 移除 OBD 數據監聽器
    ObdSppService().removeListener(_handleUiUpdate);
    // 移除 AppProvider 數據監聽器
    _appProvider.removeListener(_handleUiUpdate);
    _pulseController.dispose();
    _channel?.sink.close();
    // OBD 斷線（釋放藍牙連線與停止輪詢）
    ObdSppService().handleDisconnect('dispose');
    FlutterForegroundTask.stopService();
    WakelockPlus.disable();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    super.dispose();
  }

  void _startRecordingStateMonitoring() {
    _lastRecordingState = _screenRecorder.recordingState;
    _scheduleRecordingCheck();
  }

  void _scheduleRecordingCheck() {
    _recordingStateTimer?.cancel();
    final isRecording =
        _screenRecorder.recordingState == RecordingState.recording;
    // 錄影中每 1 秒更新倒數；非錄影時 5 秒檢查一次即可
    final interval =
        isRecording ? const Duration(seconds: 1) : const Duration(seconds: 5);
    _recordingStateTimer = Timer(interval, () {
      if (!mounted) return;
      final current = _screenRecorder.recordingState;
      final remaining = _screenRecorder.remainingSeconds;
      final stateChanged = current != _lastRecordingState;
      final secondsChanged = current == RecordingState.recording &&
          remaining != _lastRemainingSeconds;
      if (stateChanged || secondsChanged) {
        _lastRecordingState = current;
        _lastRemainingSeconds = remaining;
        setState(() {});
      }
      _scheduleRecordingCheck();
    });
  }

  // ──────────────────────────────────────────────
  // UI
  // ──────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // 原生儀表板
            const Positioned.fill(child: NativeDashboard()),

            // 狀態指示區塊（右側）
            Positioned(
              bottom: 24,
              right: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 錄影指示燈 (整合至右下角並縮小)
                  if (_screenRecorder.recordingState ==
                      RecordingState.recording)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'REC ${_screenRecorder.remainingSeconds}s',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  // OBD BLE 連線狀態
                  Consumer<AppProvider>(
                    builder: (context, provider, child) {
                      bool isObdConn = provider.obdConnectionState ==
                          ObdConnectionState.connected;
                      return _StatusBadge(
                        isActive: isObdConn,
                        activeLabel: 'ECU ',
                        inactiveLabel: 'ECU ',
                        activeColor: Colors.deepPurpleAccent,
                        inactiveColor: Colors.redAccent,
                        pulseAnimation: _pulseAnimation,
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  // WiFi 連線狀態 (link)
                  Consumer<AppProvider>(
                    builder: (context, provider, child) {
                      return _StatusBadge(
                        isActive: provider.isWifiConnected,
                        activeLabel: 'Sync',
                        inactiveLabel: 'Sync',
                        activeColor: Colors.greenAccent,
                        inactiveColor: Colors.redAccent,
                        pulseAnimation: _pulseAnimation,
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  // 測速點偵測狀態
                  Consumer<AppProvider>(
                    builder: (context, provider, child) {
                      bool ocrEnabled = SettingsService().enableOcr;
                      bool isPowerOk = _isCharging ?? true;

                      String label = ocrEnabled ? '測速 ' : '測速 ';
                      Color color =
                          ocrEnabled ? Colors.greenAccent : Colors.grey;

                      if (provider.isSimulating) {
                        label = '模擬中';
                        color = Colors.orangeAccent;
                      } else if (ocrEnabled && !isPowerOk) {
                        label = '暫停';
                        color = Colors.amber.withValues(alpha: 0.6);
                      }

                      return GestureDetector(
                        onLongPress: () {
                          if (ocrEnabled) {
                            provider.simulateSpeedCameraPath();
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('請先在設定中開啟「速限辨識」才能執行模擬測試')));
                          }
                        },
                        child: _StatusBadge(
                          isActive: ocrEnabled &&
                              (isPowerOk || provider.isSimulating),
                          activeLabel: label,
                          inactiveLabel: label,
                          activeColor: color,
                          inactiveColor: Colors.grey,
                          pulseAnimation: _pulseAnimation,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),

            // 功能按鈕區塊（右上角垂直排列）
            Positioned(
              top: 16,
              right: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 關閉程式按鈕
                  Material(
                    color: Colors.transparent,
                    child: IconButton(
                      icon: const Icon(Icons.power_settings_new),
                      color: Colors.redAccent.withValues(alpha: 0.8),
                      iconSize: 32,
                      splashRadius: 28,
                      onPressed: () {
                        SystemNavigator.pop();
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 設定按鈕
                  Material(
                    color: Colors.transparent,
                    child: IconButton(
                      icon: const Icon(Icons.settings),
                      color: Colors.white70,
                      iconSize: 32,
                      splashRadius: 28,
                      onPressed: () async {
                        // 在 async gap 前先取好 provider，避免跨 async 使用 BuildContext
                        final provider = context.read<AppProvider>();
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (context) => const SettingsScreen()),
                        );
                        // Settings changed, reconnect WebSocket if needed
                        _channel?.sink.close();
                        if (!mounted) return;
                        setState(() => _isWsConnected = false);
                        _connectWebSocket();

                        // 強制觸發一次 Provider 更新，確保速限顯示依開關狀態立即消失/出現
                        if (provider.currentPosition != null) {
                          provider.updatePosition(provider.currentPosition!);
                        }

                        // 設定變更後立即觸發一次 UI 同步
                        _handleUiUpdate();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final bool isActive;
  final String activeLabel;
  final String inactiveLabel;
  final Color activeColor;
  final Color inactiveColor;
  final Animation<double> pulseAnimation;

  const _StatusBadge({
    required this.isActive,
    required this.activeLabel,
    required this.inactiveLabel,
    required this.activeColor,
    required this.inactiveColor,
    required this.pulseAnimation,
  });

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: isActive ? pulseAnimation : const AlwaysStoppedAnimation(1.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color:
              (isActive ? activeColor : inactiveColor).withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color:
                (isActive ? activeColor : inactiveColor).withValues(alpha: 0.5),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isActive ? activeLabel : inactiveLabel,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
