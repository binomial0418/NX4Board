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
import '../providers/app_provider.dart';
import '../services/ocr_service.dart';

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

  // --- 動畫 ---
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // --- WebView & WebSocket ---
  InAppWebViewController? _webViewController;
  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  bool _isWsConnected = false; // WebSocket 連線狀態

  // --- 電源管理 ---
  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _batterySubscription;
  Timer? _sleepCountdownTimer;
  bool _isCharging = false;

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
    // 強制橫向 + 隱藏 Status Bar
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _ocrService = OcrService();
    await _initializeCamera();
    _connectWebSocket();
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
      // 切換到充電狀態
      _isCharging = true;
      debugPrint('[電源] 偵測到外部電源連接，啟用螢幕常亮與影像辨識');
      _sleepCountdownTimer?.cancel();
      _sleepCountdownTimer = null;
      WakelockPlus.enable();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _startFrameProcessing();
    } else if (!charging && _isCharging) {
      // 切換到未充電狀態
      _isCharging = false;
      debugPrint('[電源] 偵測到外部電源中斷，停止影像辨識，10 秒後進入睡眠');
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
    debugPrint('[電源] 進入睡眠模式，關閉螢幕常亮');
    WakelockPlus.disable();
    // 解除沉浸模式後系統將在閒置後自動息屏
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
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
        _isProcessing = true;
        try {
          final detectedSpeed = await _ocrService?.recognizeSpeedLimit(image);
          if (mounted && detectedSpeed != null) {
            context.read<AppProvider>().updateDetectedSpeed(detectedSpeed);
            final jsonString = '{"limit": $detectedSpeed}';
            _webViewController?.evaluateJavascript(
              source:
                  "if(window.updateDashboard) updateDashboard('$jsonString');",
            );
          }
        } catch (e) {
          debugPrint('OCR error: $e');
        } finally {
          _isProcessing = false;
        }
      });
      _isCameraStreaming = true;
      if (mounted) setState(() => _isOcrActive = true);
      debugPrint('[相機] 影像辨識串流已啟動');
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
      _channel = WebSocketChannel.connect(Uri.parse('ws://192.168.4.1:81'));
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

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _connectWebSocket();
    });
  }

  // ──────────────────────────────────────────────
  // 清理
  // ──────────────────────────────────────────────
  @override
  void dispose() {
    _batterySubscription?.cancel();
    _sleepCountdownTimer?.cancel();
    _reconnectTimer?.cancel();
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

            // 狀態指示區塊（右上角浮動）
            Positioned(
              top: 16,
              right: 16,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // WS 連線狀態
                  _StatusBadge(
                    isActive: _isWsConnected,
                    activeLabel: 'ESP32 已連線',
                    inactiveLabel: 'ESP32 未連線',
                    activeColor: Colors.lightBlueAccent,
                    inactiveColor: Colors.redAccent,
                    pulseAnimation: _pulseAnimation,
                  ),
                  const SizedBox(width: 8),
                  // OCR 狀態
                  _StatusBadge(
                    isActive: _isOcrActive,
                    activeLabel: 'OCR 辨識中',
                    inactiveLabel: '待機中',
                    activeColor: Colors.greenAccent,
                    inactiveColor: Colors.orange,
                    pulseAnimation: _pulseAnimation,
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
