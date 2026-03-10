import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:convert';
import '../providers/app_provider.dart';
import '../services/ocr_service.dart';
import '../services/location_service.dart';
import '../services/settings_service.dart';
import '../services/obd_ble_service.dart';
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
  // --- Camera & OCR ---
  CameraController? _cameraController;
  OcrService? _ocrService;
  bool _isProcessing = false;
  bool _isCameraStreaming = false;
  bool _isOcrActive = false; // OCR 狀態指示
  DateTime? _lastOcrTime;

  // --- 動畫 ---
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // --- WebView & WebSocket ---
  InAppWebViewController? _webViewController;
  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  bool _isWsConnected = false; // WebSocket 連線狀態
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
    // 請求定位權限
    await LocationService.requestLocationPermission();
    _startLocationTracking();

    // 強制橫向 + 隱藏 Status Bar
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _ocrService = OcrService();
    await _initializeCamera();
    _connectWebSocket();
    _startObdToWebviewSync();
    _startWsUploadSync();
    _initForegroundTask();
    _startBatteryMonitoring();
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
      notificationTitle: '速限查詢',
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

          // 全時偵測：只要正在充電，就持續啟動鏡頭
          if (_isCharging) {
            _startFrameProcessing();
          }
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

      // 恢復 WebSocket 連線
      if (!_isWsConnected) {
        _connectWebSocket();
      }

      _startObdToWebviewSync();
      _startWsUploadSync();

      // 啟動全時影像辨識
      if (mounted) {
        _startFrameProcessing();
      }
    } else if (!charging && _isCharging) {
      // 切換到未充電狀態：立即關閉高耗能鏡頭，啟動睡眠倒數
      _isCharging = false;
      debugPrint('[電源] 偵測到外部電源中斷，停止影像辨識，10 秒後進入深度睡眠');
      _stopFrameProcessing();
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

  void _enterSleepMode() {
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

    // 暫停 GPS 定位以省電
    _positionSubscription?.pause();
  }

  // ──────────────────────────────────────────────
  // 相機初始化
  // ──────────────────────────────────────────────
  Future<void> _initializeCamera() async {
    try {
      final status = await Permission.camera.request();
      if (status.isDenied) return;

      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      _cameraController = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _cameraController!.initialize();
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      debugPrint('Camera error: $e');
    }
  }

  // ──────────────────────────────────────────────
  // 影像辨識串流啟停
  // ──────────────────────────────────────────────
  void _startFrameProcessing() {
    if (_isCameraStreaming) return;
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    try {
      _cameraController!.startImageStream((CameraImage image) async {
        if (_isProcessing) return;

        // --- 頻率控制：每秒 5 張 (200ms) ---
        final now = DateTime.now();
        if (_lastOcrTime != null &&
            now.difference(_lastOcrTime!).inMilliseconds < 200) {
          return;
        }
        _lastOcrTime = now;

        final appProvider = context.read<AppProvider>();

        // 開啟 OCR 綠燈閃爍
        if (!_isOcrActive && mounted) {
          setState(() => _isOcrActive = true);
        }

        _isProcessing = true;
        try {
          final detectedSpeed = await _ocrService?.recognizeSpeedLimit(image);
          if (mounted) {
            // 這會檢查是否與圖資相符且連續 3 幀
            appProvider.updateDetectedSpeed(detectedSpeed);

            // 只有當 AppProvider 真正確認拿到正確數值時，才送去更新 JS
            if (appProvider.detectedSpeedLimit != null) {
              final finalSpeed = appProvider.detectedSpeedLimit;
              final jsonString = '{"limit": $finalSpeed}';
              _webViewController?.evaluateJavascript(
                source:
                    "if(window.updateDashboard) updateDashboard('$jsonString');",
              );
              // 傳送成功後，如果想清空避免一直送相同數值，可選呼叫 resetDetectedSpeed()
              // appProvider.resetDetectedSpeed();
            }
          }
        } catch (e) {
          debugPrint('OCR error: $e');
        } finally {
          _isProcessing = false;
        }
      });
      _isCameraStreaming = true;
      debugPrint('[相機] 影像辨識串流已啟動（目前於圖資範圍內）');
    } catch (e) {
      debugPrint('Start image stream error: $e');
    }
  }

  void _stopFrameProcessing() {
    if (!_isCameraStreaming) return;
    try {
      _cameraController?.stopImageStream();
      _isCameraStreaming = false;
      _isProcessing = false;
      if (mounted) setState(() => _isOcrActive = false);
      debugPrint('[相機] 影像辨識串流已停止');
    } catch (e) {
      debugPrint('Stop image stream error: $e');
    }
  }

  // ──────────────────────────────────────────────
  // WebSocket 連線
  // ──────────────────────────────────────────────
  void _connectWebSocket() {
    try {
      final ip = SettingsService().wsIp;
      final port = SettingsService().wsPort;
      _channel = WebSocketChannel.connect(Uri.parse('ws://$ip:$port'));
      _channel!.stream.listen(
        (message) {
          // 收到訊息即確認連線成功
          if (!_isWsConnected && mounted) {
            setState(() => _isWsConnected = true);
          }
          _webViewController?.evaluateJavascript(
              source:
                  "if(window.updateDashboard) updateDashboard('$message');");
        },
        onDone: () {
          if (mounted) setState(() => _isWsConnected = false);
          _scheduleReconnect();
        },
        onError: (error) {
          debugPrint('WebSocket Error: $error');
          if (mounted) setState(() => _isWsConnected = false);
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('WebSocket connection failed: $e');
      if (mounted) setState(() => _isWsConnected = false);
      _scheduleReconnect();
    }
  }

  void _startWsUploadSync() {
    _wsUploadTimer?.cancel();
    _wsUploadTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      if (!mounted || !_isWsConnected || _channel == null) return;
      final provider = context.read<AppProvider>();

      final Map<String, dynamic> uploadData = {};
      if (provider.tpmsFl != null) uploadData["tpmsFl"] = provider.tpmsFl;
      if (provider.tpmsFr != null) uploadData["tpmsFr"] = provider.tpmsFr;
      if (provider.tpmsRl != null) uploadData["tpmsRl"] = provider.tpmsRl;
      if (provider.tpmsRr != null) uploadData["tpmsRr"] = provider.tpmsRr;
      if (provider.obdOdometer != null)
        uploadData["odo"] = provider.obdOdometer;
      if (provider.obdFuel != null) uploadData["fuel"] = provider.obdFuel;

      if (uploadData.isNotEmpty) {
        final jsonString = jsonEncode(uploadData);
        try {
          _channel!.sink.add(jsonString);
          debugPrint('[WS-TX] Uploaded to Relay: $jsonString');
        } catch (e) {
          debugPrint('[WS-TX] Send error: $e');
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

      if (provider.obdSpeed != null) jsonMap["speed"] = provider.obdSpeed;
      if (provider.obdRpm != null) jsonMap["rpm"] = provider.obdRpm;
      if (provider.obdCoolant != null)
        jsonMap["temperature"] = provider.obdCoolant;
      if (provider.tpmsFl != null) jsonMap["fl_pressure"] = provider.tpmsFl;
      if (provider.tpmsFr != null) jsonMap["fr_pressure"] = provider.tpmsFr;
      if (provider.tpmsRl != null) jsonMap["rl_pressure"] = provider.tpmsRl;
      if (provider.tpmsRr != null) jsonMap["rr_pressure"] = provider.tpmsRr;
      if (provider.obdHevSoc != null) jsonMap["battery"] = provider.obdHevSoc;
      // if (provider.obdVoltage != null) jsonMap["batteryVol"] = provider.obdVoltage;
      // if (provider.obdOdometer != null) jsonMap["mileage"] = provider.obdOdometer;
      // if (provider.obdFuel != null) jsonMap["fuelVolume"] = provider.obdFuel;

      if (jsonMap.isNotEmpty) {
        final jsonString = jsonEncode(jsonMap);
        _webViewController?.evaluateJavascript(
            source:
                "if(window.updateDashboard) updateDashboard('$jsonString');");
      }
    });
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
    _stopFrameProcessing();
    _cameraController?.dispose();
    _ocrService?.dispose();
    _channel?.sink.close();
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
            // 底層：1x1 隱藏相機 Preview（維持影像串流）
            if (_cameraController != null &&
                _cameraController!.value.isInitialized)
              Positioned(
                left: 0,
                top: 0,
                width: 1,
                height: 1,
                child: CameraPreview(_cameraController!),
              ),

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
                  // WS 連線狀態
                  _StatusBadge(
                    isActive: _isWsConnected,
                    activeLabel: 'WS 已連',
                    inactiveLabel: 'WS 未連',
                    activeColor: Colors.lightBlueAccent,
                    inactiveColor: Colors.redAccent,
                    pulseAnimation: _pulseAnimation,
                  ),
                  const SizedBox(height: 10),
                  // OCR 狀態
                  _StatusBadge(
                    isActive: _isOcrActive,
                    activeLabel: '相機運作',
                    inactiveLabel: '相機關閉',
                    activeColor: Colors.greenAccent,
                    inactiveColor: Colors.orange,
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
                    ).then((_) {
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
                    // 清理並強制關閉程式
                    FlutterForegroundTask.stopService();
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

// ──────────────────────────────────────────────
// 通用狀態指示器 Widget
// ──────────────────────────────────────────────
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
    final color = isActive ? activeColor : inactiveColor;
    return AnimatedBuilder(
      animation: pulseAnimation,
      builder: (context, child) {
        return Opacity(
          opacity: isActive ? pulseAnimation.value : 0.65,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.55),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: color.withOpacity(0.7),
                width: 1.2,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                    boxShadow: [
                      BoxShadow(
                        color: color.withOpacity(isActive ? 0.8 : 0.4),
                        blurRadius: isActive ? 8 : 3,
                        spreadRadius: isActive ? 2 : 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  isActive ? activeLabel : inactiveLabel,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
