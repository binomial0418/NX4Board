import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:convert';
import '../providers/app_provider.dart';
import '../services/location_service.dart';
import '../services/settings_service.dart';
import '../services/obd_spp_service.dart';
import '../services/wifi_service.dart';
import 'settings_screen.dart';

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

  // --- WebView & WebSocket ---
  InAppWebViewController? _webViewController;
  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  bool _isWsConnected = false; // WebSocket 連線狀態
  bool _isWsConnecting = false; // 防止重複連線
  Timer? _obdSyncTimer;
  Timer? _wsUploadTimer;

  // --- 電源管理 ---
  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _batterySubscription;
  Timer? _sleepCountdownTimer;
  bool _isCharging = false;

  // --- GPS 定位管理 ---
  StreamSubscription<Position>? _positionSubscription;

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
    _initializeWidgets();
  }

  Future<void> _initializeWidgets() async {
    // 保底先啟用 WakeLock，避免電源狀態讀取失敗時仍能維持常亮
    await WakelockPlus.enable();

    // 集中請求所有必要權限
    await _requestAllPermissions();

    _startLocationTracking();

    // 強制橫向 + 隱藏 Status Bar
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _connectWebSocket();
    _startObdToWebviewSync();
    _startWsUploadSync();
    _initForegroundTask();
    _startBatteryMonitoring();

    // 啟動後 15 秒（等 OBD 連線+初始輪詢回應），立即傳送一次 WS 資料
    Future.delayed(const Duration(seconds: 15), () {
      _sendObdDataViaWsOnce();
    });
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
    ];

    Map<Permission, PermissionStatus> statuses = await basePermissions.request();

    // 檢查是否有權限被拒絕（非永久）
    bool hasDenied = statuses.values.any((s) => s.isDenied);
    if (hasDenied && mounted) {
      await _showPermissionExplanationDialog(
        '需要基本權限',
        '此 App 需要定位（偵測測速）、藍牙（連接 OBD）及通知功能才能正常運作。請授予權限以繼續。',
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
    final allStatuses = await [
      Permission.location,
      Permission.locationAlways,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.notification,
    ].map((p) async => MapEntry(p, await p.status)).toList();

    bool hasPermanentlyDenied = false;
    for (var entry in allStatuses) {
      if ((await entry).value.isPermanentlyDenied) {
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
        content: const Text('部分必要權限（定位、藍牙、通知）被設定為「不再詢問」。\n請前往系統設定手動開啟，否則部分功能將無法運作。'),
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
  void _startLocationTracking() {
    _positionSubscription = LocationService.getPositionStream().listen(
      (Position position) {
        if (mounted) {
          final appProvider = context.read<AppProvider>();
          appProvider.updatePosition(position);
        }
      },
      onError: (e) => debugPrint('Location stream error: $e'),
    );
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
    final charging =
        state == BatteryState.charging || state == BatteryState.full;

    if (charging && !_isCharging) {
      // 切換到充電狀態：喚醒所有資源
      _isCharging = true;
      debugPrint('[電源] 偵測到外部電源連接，喚醒系統資源');
      _sleepCountdownTimer?.cancel();
      _sleepCountdownTimer = null;
      WakelockPlus.enable();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

      // 恢復 GPS
      if (_positionSubscription != null && _positionSubscription!.isPaused) {
        _positionSubscription!.resume();
      }

      // 重連 OBD（若已因睡眠斷線）
      final obdService = ObdSppService();
      if (obdService.connectionState == ObdConnectionState.disconnected) {
        debugPrint('[電源] 重新連接 OBD 藍牙');
        obdService.init();
      }

      // 恢復 WebSocket 連線
      if (!_isWsConnected) {
        _connectWebSocket();
      }

      _startObdToWebviewSync();
      _startWsUploadSync();

      // 插電後 15 秒（等 OBD 重連+輪詢完成），立即傳送一次 WS 資料
      Future.delayed(const Duration(seconds: 15), () {
        _sendObdDataViaWsOnce();
      });

    } else if (!charging && _isCharging) {
      // 切換到未充電狀態：啟動睡眠倒數
      _isCharging = false;
      debugPrint('[電源] 偵測到外部電源中斷，10 秒後進入深度睡眠');
      _startSleepCountdown();
    }
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

    _obdSyncTimer?.cancel();
    _wsUploadTimer?.cancel();

    // 暫停 GPS 定位以省電 (不再進行任何測速偵測)
    _positionSubscription?.pause();
    debugPrint('[電源] GPS 定位已暫停，停止一切測速偵測');

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

    if (!_isCharging) {
      // 未接外部電源：跳過 WiFi 切換，直接嘗試建立連線
      debugPrint('[WS] 未充電，跳過 WiFi 切換');
      _doConnectWebSocket();
      return;
    }

    // 充電中：先靜默確保 WiFi 已連上 nx4_obd_relay，再建立 WebSocket
    WifiService.ensureConnected().then((wifiOk) {
      if (!wifiOk) {
        debugPrint('[WS] WiFi 未連上 nx4_obd_relay，取消本次連線');
        _isWsConnecting = false;
        _scheduleReconnect();
        return;
      }
      _doConnectWebSocket();
    });
  }

  void _doConnectWebSocket() {
    try {
      final ip = SettingsService().wsIp;
      final port = SettingsService().wsPort;

      // 先關閉舊 channel，防止 channel 洩漏
      _channel?.sink.close();
      _channel = null;

      _channel = WebSocketChannel.connect(Uri.parse('ws://$ip:$port'));

      // 連線建立後立即標記為 connected（不等收到訊息）
      // 因為本 app 是主動推送方，可能永遠不會收到回傳訊息
      if (mounted) setState(() => _isWsConnected = true);
      debugPrint('[WS] 已連接: ws://$ip:$port');

      _channel!.stream.listen(
        (message) {
          // 收到伺服器下推的訊息，轉發到 WebView
          _webViewController?.evaluateJavascript(
              source:
                  "if(window.updateDashboard) updateDashboard('$message');");
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
    _wsUploadTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      if (!mounted) return;

      // 若未連線且正在充電，立即觸發重連（不等下次斷線事件）
      if (!_isWsConnected || _channel == null) {
        if (_isCharging) _scheduleReconnect();
        return;
      }

      final provider = context.read<AppProvider>();

      // 檢查 OBD 是否連線
      if (provider.obdConnectionState != ObdConnectionState.connected) {
        debugPrint('[WS-TX] OBD 未連線，跳過定期同步');
        return;
      }

      final Map<String, dynamic> uploadData = {
        "_type": "location",
        "tid": "obd",
      };
      
      final Map<String, dynamic> tires = {};
      final obd = ObdSppService();
      if (obd.hasTpms) {
        if (provider.tpmsFl != null) tires["fl"] = provider.tpmsFl;
        if (provider.tpmsFr != null) tires["fr"] = provider.tpmsFr;
        if (provider.tpmsRl != null) tires["rl"] = provider.tpmsRl;
        if (provider.tpmsRr != null) tires["rr"] = provider.tpmsRr;
      }
      if (tires.isNotEmpty) uploadData["tires"] = tires;

      if (obd.hasOdometer && provider.obdOdometer != null) uploadData["mileage"] = provider.obdOdometer;
      if (obd.hasFuel && provider.obdFuel != null) uploadData["fuel"] = provider.obdFuel;

      // 同時保留儀表板需要的原始屬性
      if (obd.hasSpeed && provider.obdSpeed != null) uploadData["speed"] = provider.obdSpeed;
      if (obd.hasRpm && provider.obdRpm != null) uploadData["rpm"] = provider.obdRpm;
      if (obd.hasCoolant && provider.obdCoolant != null) uploadData["temperature"] = provider.obdCoolant;
      if (obd.hasHevSoc && provider.obdHevSoc != null) uploadData["battery"] = provider.obdHevSoc;

      if (uploadData.length > 2) { // 除了 _type, tid 之外還有其他資料
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
    if (!_isCharging) return;

    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _isCharging) _connectWebSocket();
    });
  }

  // ──────────────────────────────────────────────
  // 同步 BLE 資料至 WebView
  // ──────────────────────────────────────────────
  void _startObdToWebviewSync() {
    _obdSyncTimer?.cancel();
    _obdSyncTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted) return;
      final provider = context.read<AppProvider>();

      final Map<String, dynamic> jsonMap = {};
      jsonMap["enableOcr"] = SettingsService().enableOcr;

      if (provider.obdSpeed != null) jsonMap["speed"] = provider.obdSpeed;
      if (provider.obdRpm != null) jsonMap["rpm"] = provider.obdRpm;
      if (provider.obdCoolant != null)
        jsonMap["temperature"] = provider.obdCoolant;
      if (provider.tpmsFl != null) jsonMap["fl_pressure"] = provider.tpmsFl;
      if (provider.tpmsFr != null) jsonMap["fr_pressure"] = provider.tpmsFr;
      if (provider.tpmsRl != null) jsonMap["rl_pressure"] = provider.tpmsRl;
      if (provider.tpmsRr != null) jsonMap["rr_pressure"] = provider.tpmsRr;
      if (provider.obdHevSoc != null) jsonMap["battery"] = provider.obdHevSoc;
      if (provider.obdOdometer != null) jsonMap["odometer"] = provider.obdOdometer;
      if (provider.obdFuel != null) jsonMap["fuelLevel"] = provider.obdFuel;

      // 測速照相
      if (provider.nearestCameraInfo != null) {
        jsonMap["cameraInfo"] = provider.nearestCameraInfo;
      }
      
      if (provider.currentSpeedLimit != null) {
        jsonMap["limit"] = provider.currentSpeedLimit;
      }

      if (jsonMap.isNotEmpty) {
        final jsonString = jsonEncode(jsonMap);
        _webViewController?.evaluateJavascript(
            source:
                "if(window.updateDashboard) updateDashboard('$jsonString');");
      }
    });
  }

  // ──────────────────────────────────────────────
  // 立即傳送一次 OBD 資料至 WS（輪詢回來後呼叫）
  // ──────────────────────────────────────────────
  void _sendObdDataViaWsOnce() {
    if (!mounted || !_isWsConnected || _channel == null) return;
    final provider = context.read<AppProvider>();

    // 檢查 OBD 是否連線
    if (provider.obdConnectionState != ObdConnectionState.connected) {
      debugPrint('[WS-TX] OBD 未連線，跳過立即傳送');
      return;
    }

    final Map<String, dynamic> uploadData = {
      "_type": "location",
      "tid": "obd",
    };

    final Map<String, dynamic> tires = {};
    final obd = ObdSppService();
    if (obd.hasTpms) {
      if (provider.tpmsFl != null) tires["fl"] = provider.tpmsFl;
      if (provider.tpmsFr != null) tires["fr"] = provider.tpmsFr;
      if (provider.tpmsRl != null) tires["rl"] = provider.tpmsRl;
      if (provider.tpmsRr != null) tires["rr"] = provider.tpmsRr;
    }
    if (tires.isNotEmpty) uploadData["tires"] = tires;

    if (obd.hasOdometer && provider.obdOdometer != null) uploadData["mileage"] = provider.obdOdometer;
    if (obd.hasFuel && provider.obdFuel != null) uploadData["fuel"] = provider.obdFuel;
    if (obd.hasSpeed && provider.obdSpeed != null) uploadData["speed"] = provider.obdSpeed;
    if (obd.hasRpm && provider.obdRpm != null) uploadData["rpm"] = provider.obdRpm;
    if (obd.hasCoolant && provider.obdCoolant != null) uploadData["temperature"] = provider.obdCoolant;
    if (obd.hasHevSoc && provider.obdHevSoc != null) uploadData["battery"] = provider.obdHevSoc;

    if (uploadData.length > 2) {
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
    _sleepCountdownTimer?.cancel();
    _reconnectTimer?.cancel();
    _obdSyncTimer?.cancel();
    _wsUploadTimer?.cancel();
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
            // 上層：全螢幕 Dashboard HTML
            Positioned.fill(
              child: InAppWebView(
                initialFile: "assets/cd.html",
                initialSettings: InAppWebViewSettings(
                  transparentBackground: true,
                  disableHorizontalScroll: true,
                  disableVerticalScroll: true,
                  supportZoom: false,
                  allowFileAccessFromFileURLs: true,
                  allowUniversalAccessFromFileURLs: true,
                ),
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                },
                onConsoleMessage: (controller, consoleMessage) {
                  debugPrint(
                      "WebView [${consoleMessage.messageLevel}]: ${consoleMessage.message}");
                },
              ),
            ),

            // 狀態指示區塊（右下角時間旁邊）
            Positioned(
              bottom: 24,
              right: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // OBD BLE 連線狀態
                  Consumer<AppProvider>(
                    builder: (context, provider, child) {
                      bool isObdConn = provider.obdConnectionState ==
                          ObdConnectionState.connected;
                      return _StatusBadge(
                        isActive: isObdConn,
                        activeLabel: 'OBD 連接',
                        inactiveLabel: 'OBD 中斷',
                        activeColor: Colors.deepPurpleAccent,
                        inactiveColor: Colors.redAccent,
                        pulseAnimation: _pulseAnimation,
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  // WiFi 連線狀態 (原 WS 狀態)
                  Consumer<AppProvider>(
                    builder: (context, provider, child) {
                      return _StatusBadge(
                        isActive: provider.isWifiConnected,
                        activeLabel: 'WiFi 已連',
                        inactiveLabel: 'WiFi 未連',
                        activeColor: Colors.lightBlueAccent,
                        inactiveColor: Colors.redAccent,
                        pulseAnimation: _pulseAnimation,
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  // 測速點偵測狀態
                  _StatusBadge(
                    isActive: SettingsService().enableOcr,
                    activeLabel: '偵測運作',
                    inactiveLabel: '偵測關閉',
                    activeColor: Colors.greenAccent,
                    inactiveColor: Colors.grey,
                    pulseAnimation: _pulseAnimation,
                  ),
                ],
              ),
            ),

            // 設定按鈕（右側浮動）
            Positioned(
              top: 16,
              right: 64, // 在電源按鈕旁邊
              child: Material(
                color: Colors.transparent,
                child: IconButton(
                  icon: const Icon(Icons.settings),
                  color: Colors.white70,
                  iconSize: 32,
                  splashRadius: 28,
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const SettingsScreen()),
                    ).then((_) async {
                      // Settings changed, reconnect WebSocket if needed
                      _channel?.sink.close();
                      if (mounted) setState(() => _isWsConnected = false);
                      _connectWebSocket();
                    });
                  },
                ),
              ),
            ),

            // 關閉程式按鈕（右上角浮動）
            Positioned(
              top: 16,
              right: 16,
              child: Material(
                color: Colors.transparent,
                child: IconButton(
                  icon: const Icon(Icons.power_settings_new),
                  color: Colors.redAccent.withOpacity(0.8),
                  iconSize: 32,
                  splashRadius: 28,
                  onPressed: () {
                    SystemNavigator.pop();
                  },
                ),
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
          color: (isActive ? activeColor : inactiveColor).withOpacity(0.2),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: (isActive ? activeColor : inactiveColor).withOpacity(0.5),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: isActive ? activeColor : inactiveColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: (isActive ? activeColor : inactiveColor)
                        .withOpacity(0.5),
                    blurRadius: 4,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              isActive ? activeLabel : inactiveLabel,
              style: TextStyle(
                color: Colors.white.withOpacity(0.9),
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
