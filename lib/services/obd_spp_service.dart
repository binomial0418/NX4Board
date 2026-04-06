import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:intl/intl.dart';
import 'settings_service.dart';

enum ObdConnectionState {
  disconnected,
  scanning,
  connecting,
  initializing,
  connected
}

class ObdSppService with ChangeNotifier {
  static final ObdSppService _instance = ObdSppService._internal();
  factory ObdSppService() => _instance;
  ObdSppService._internal();

  static const _methodChannel = MethodChannel('classic_bt');
  static const _eventChannel = EventChannel('classic_bt/data');

  StreamSubscription? _dataSubscription;

  ObdConnectionState connectionState = ObdConnectionState.disconnected;

  // ── 全域連線狀態旗標（唯一真相來源）────────────────────────────────────
  bool _isConnected = false;

  // ── Log Stream ────────────────────────────────────────────────────────────
  final _logController = StreamController<String>.broadcast();
  Stream<String> get logStream => _logController.stream;
  final List<String> _logHistory = [];
  List<String> get logHistory => List.unmodifiable(_logHistory);

  // ── Maintenance Log Stream ───────────────────────────────────────────────
  final _maintenanceLogController = StreamController<String>.broadcast();
  Stream<String> get maintenanceLogStream => _maintenanceLogController.stream;
  final List<String> _maintenanceLogHistory = [];
  List<String> get maintenanceLogHistory =>
      List.unmodifiable(_maintenanceLogHistory);

  void _log(String msg) {
    final String timestamp = DateFormat('HH:mm:ss').format(DateTime.now());
    final String fullMsg = '[$timestamp] $msg';
    debugPrint(fullMsg);
    _logHistory.add(fullMsg);
    if (_logHistory.length > 1000) _logHistory.removeAt(0);
    _logController.add(fullMsg);
  }

  void logWsSend(String json) {
    _log('[WS-TX] $json');
  }

  void _logMaintenance(String msg) {
    final String timestamp = DateFormat('HH:mm:ss').format(DateTime.now());
    final String fullMsg = '[$timestamp] $msg';
    _maintenanceLogHistory.add(fullMsg);
    if (_maintenanceLogHistory.length > 500) _maintenanceLogHistory.removeAt(0);
    _maintenanceLogController.add(fullMsg);
    // 移除重複輸出至主日誌的行為，以符合「拿掉保養資訊log區」的要求
    // _log('[CLU-Service] $msg');
  }

  // ── RX Buffer + Completer (半雙工核心) ────────────────────────────────────
  final StringBuffer _rxBuffer = StringBuffer();
  Completer<String>? _pendingCompleter;

  // ── 記錄最後發送的指令，供 Parser 判斷特徵碼 ─────────────────────────────
  String _lastSentCmd = '';

  // ── 連線 Mutex：防止 Dart 端併發發起連線 ─────────────────────────────────
  bool _isConnecting = false;

  // ── Epoch 計數器：每次斷線 +1，用於使舊 chain closure 失效 ────────────────
  int _connectionEpoch = 0;

  // ── Mutex: Future chain 確保指令串行 ──────────────────────────────────────
  Future<void> _commandChain = Future.value();

  // ── OBD Data ──────────────────────────────────────────────────────────────
  int? rpm;
  int? speed;
  int? coolantTemp;
  double? voltage;
  double? hevSoc; // 保留一位小數
  double? odometer;
  int? fuelLevel;
  double? turbo; // 渦輪壓力 (Bar)
  double currentBaroKpa = 101.0;
  double turboBoostBar = 0.0;
  double? referenceGpsAltitude;
  int serviceDistanceRemaining = 0;
  int serviceDaysRemaining = 0;

  // TPMS (FL, FR, RL, RR)
  double? tpmsFl;
  double? tpmsFr;
  double? tpmsRl;
  double? tpmsRr;

  // ── 啟動訊號：用於通知 UI 觸發掃跡動畫 ───────────────────────────────────
  bool _shouldTriggerWakeup = false;
  bool get shouldTriggerWakeup => _shouldTriggerWakeup;

  /// 安全性掃跡鎖定：記錄此電源週期是否為首次連線
  bool _isFirstConnectOfSession = true;

  // ── Data Validity Flags (本次連線是否已成功解析過) ─────────────────────
  bool hasRpm = false;
  bool hasSpeed = false;
  bool hasCoolant = false;
  bool hasVoltage = false;
  bool hasHevSoc = false;
  bool hasOdometer = false;
  bool hasFuel = false;
  bool hasTurbo = false;
  bool hasServiceDistanceRemaining = false;
  bool hasServiceDaysRemaining = false;
  bool hasTpms = false;

  // ── GPS Speed Tracking ───────────────────────────────────────────────────
  double? _lastGpsSpeedKmh;
  DateTime? _lastGpsSpeedTime;

  void onGpsSpeedChanged(double speedMps) {
    if (speedMps >= 0) {
      _lastGpsSpeedKmh = speedMps * 3.6;
      _lastGpsSpeedTime = DateTime.now();
      // GPS speed is stored for OBD sanity check only; display speed comes from OBD
    }
  }

  // ── Polling Timers ────────────────────────────────────────────────────────
  Timer? _fastPollTimer;
  Timer? _slowPollTimer;
  Timer? _minutePollTimer;
  Timer? _longPollTimer;
  
  // ── Moving Window Buffers ────────────────────────────────────────────────
  final List<int> _fuelBuffer = [];

  // =========================================================================
  // 模組一：電源狀態感知 (Power State Listener)
  // =========================================================================

  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _batterySubscription;

  /// 電源連線總開關：true = 外部電源在線，false = 僅靠手機電池
  bool _isPowerConnected = true;

  /// 啟動電源監聽，應在 App 啟動時呼叫
  void startPowerListener() {
    _batterySubscription?.cancel();
    _batterySubscription =
        _battery.onBatteryStateChanged.listen((BatteryState state) {
      if (state == BatteryState.charging || state == BatteryState.full) {
        if (!_isPowerConnected) {
          _log('[Power] 外部電源已接上，喚醒並嘗試連線...');
          _isPowerConnected = true;
          final String savedMac = SettingsService().obdMac;
          if (savedMac.isNotEmpty) {
            connectToDevice(savedMac);
          }
        }
      } else {
        // BatteryState.discharging：斷開外部電源（停車熄火）
        if (_isPowerConnected) {
          _log('[Power] 外部電源斷開，進入深度休眠...');
          _isPowerConnected = false;
          handleDisconnect('power_disconnected');
        }
      }
    });
    _log('[Power] 電源監聽已啟動');
  }

  // =========================================================================
  // 模組二：看門狗連續超時偵測 (Watchdog Mechanism)
  // =========================================================================

  /// 連續逾時計數器，達到閾值時觸發強制斷線
  int _consecutiveTimeouts = 0;

  /// 連續逾時觸發閾值（預設 3 次 = 約 9 秒）
  static const int _watchdogThreshold = 3;

  // =========================================================================
  // 模組三：背景自動重連迴圈 (Auto-Reconnect Loop)
  // =========================================================================

  bool _isAutoReconnecting = false;
  Timer? _reconnectTimer;

  void _startAutoReconnect() {
    if (_isAutoReconnecting) return;
    _isAutoReconnecting = true;

    final String savedMac = SettingsService().obdMac;
    if (savedMac.isEmpty) {
      _log('[AutoReconnect] 無已儲存的 MAC，取消自動重連');
      _isAutoReconnecting = false;
      return;
    }

    _log('[AutoReconnect] 啟動自動重連迴圈（每 5 秒）...');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_isPowerConnected) {
        _log('[AutoReconnect] 電源已斷開，停止重連迴圈');
        _stopAutoReconnect();
        return;
      }
      if (_isConnected ||
          connectionState == ObdConnectionState.connecting ||
          connectionState == ObdConnectionState.initializing) {
        _log('[AutoReconnect] 已連線或連線中，停止迴圈');
        _stopAutoReconnect();
        return;
      }
      _log('[AutoReconnect] 嘗試重新連線...');
      await connectToDevice(savedMac);
    });
  }

  void _stopAutoReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _isAutoReconnecting = false;
    _log('[AutoReconnect] 自動重連迴圈已停止');
  }

  // =========================================================================
  // Public API
  // =========================================================================
  // 模組四：初始化與連線控管
  // =========================================================================

  /// 強制重置所有緩存數據（供外部喚醒時使用）
  void resetData() {
    _resetDataFlags();
  }

  Future<void> init() async {
    startPowerListener();
    final String savedMac = SettingsService().obdMac;
    if (savedMac.isNotEmpty) {
      _log('[OBD] Auto-connecting to: $savedMac');
      connectToDevice(savedMac);
    }
  }

  /// 立即輪詢一次全部感測器（不等 Timer 排程）
  Future<void> pollAllNow() async {
    if (!_isConnected) return;
    _log('[OBD] pollAllNow() triggered');
    sendCommand('010B0C0D'); // Turbo + RPM + Speed
    sendCommand('015B');     // HEV SOC
    sendCommand('0167');     // Coolant
    sendCommand('ATSH7C6');
    sendCommand('22B002');   // Odo, Fuel, Maintenance
    sendCommand('ATSH7A0');
    sendCommand('22C00B');   // TPMS
    sendCommand('ATSH7DF');
  }

  /// 手動觸發查詢保養資訊 (Header 7C6, PID 22B002)
  Future<void> queryMaintenanceInfo() async {
    if (!_isConnected) return;
    _log('[OBD] Manual queryMaintenanceInfo() triggered');
    await sendCommand('ATSH7C6');
    await sendCommand('22B002');
    await sendCommand('ATSH7DF');
  }

  void _enqueueBarometricPressureQuery() {
    if (!_isConnected) return;
    sendCommand('0133');
  }

  void onGpsAltitudeChanged(double newAltitude) {
    if (referenceGpsAltitude == null) {
      referenceGpsAltitude = newAltitude;
      _log('[GPS] 初始化基準高度：$newAltitude m，請求大氣壓');
      _enqueueBarometricPressureQuery();
      return;
    }

    final double delta = (newAltitude - referenceGpsAltitude!).abs();
    if (delta > 50.0) {
      referenceGpsAltitude = newAltitude;
      _log('[GPS] 高度變化 $delta m > 50 m，更新大氣壓');
      _enqueueBarometricPressureQuery();
    }
  }

  Future<List<Map<String, String>>> getBondedDevices() async {
    try {
      final List<dynamic> result =
          await _methodChannel.invokeMethod('getBondedDevices');
      return result.map((e) => Map<String, String>.from(e)).toList();
    } catch (e) {
      _log('[OBD] getBondedDevices error: $e');
      return [];
    }
  }

  Future<void> connectToDevice(String address) async {
    if (_isConnecting ||
        connectionState == ObdConnectionState.connecting ||
        connectionState == ObdConnectionState.initializing ||
        connectionState == ObdConnectionState.connected) {
      _log('[OBD] Already connecting/connected, ignoring duplicate request.');
      return;
    }

    _isConnecting = true;
    connectionState = ObdConnectionState.connecting;
    _log('[OBD] Connecting to $address…');

    try {
      final bool success =
          await _methodChannel.invokeMethod('connect', {'address': address});
      if (success) {
        _log('[OBD] Socket connected!');
        _isConnected = true;

        // 連線成功：停止自動重連 + 看門狗計數歸零
        _stopAutoReconnect();
        _consecutiveTimeouts = 0;

        _setupDataListener();
        initializeELM327();
      } else {
        handleDisconnect('connect_failed');
      }
    } on PlatformException catch (e) {
      if (e.code == 'ALREADY_CONNECTING') {
        _log('[OBD] Native: already connecting, ignored.');
      } else {
        _log('[OBD] Connection failed: ${e.code} ${e.message}');
        handleDisconnect('platform_exception: ${e.code}');
      }
    } catch (e) {
      _log('[OBD] Connection failed: $e');
      handleDisconnect('connect_exception: $e');
    } finally {
      _isConnecting = false;
    }
  }

  @override
  void dispose() {
    _batterySubscription?.cancel();
    _batterySubscription = null;
    handleDisconnect('dispose');
    _logController.close();
    _maintenanceLogController.close();
    super.dispose();
  }

  // =========================================================================
  // 模組四：統一斷線處理器 (Centralized Disconnect Handler)
  // =========================================================================

  void handleDisconnect(String reason) {
    if (!_isConnected && connectionState == ObdConnectionState.disconnected) {
      return;
    }

    // 清空數據與旗標
    _resetDataFlags();
    _log('[OBD] --- Disconnected: $reason ---');

    _isConnected = false;
    connectionState = ObdConnectionState.disconnected;

    // 清理 Polling Timers
    _fastPollTimer?.cancel();
    _fastPollTimer = null;
    _slowPollTimer?.cancel();
    _slowPollTimer = null;
    _minutePollTimer?.cancel();
    _minutePollTimer = null;
    _longPollTimer?.cancel();
    _longPollTimer = null;

    // 清理 RX Buffer 與 Completer（打破死鎖）
    _rxBuffer.clear();
    if (_pendingCompleter != null && !_pendingCompleter!.isCompleted) {
      _pendingCompleter!.complete('DISCONNECTED');
    }
    _pendingCompleter = null;

    // 清空 Command Chain（打破舊 chain 的死鎖）
    _connectionEpoch++;
    _commandChain = Future.value();

    // 取消資料流訂閱
    _dataSubscription?.cancel();
    _dataSubscription = null;

    // 通知原生層斷線
    _methodChannel.invokeMethod('disconnect').catchError((_) {});

    // ── 核心重連判定（嚴格邊界條件）────────────────────────────────────────
    // 手動斷線、電源斷開、dispose、電源感知斷線 → 進入深度休眠，不重連
    const Set<String> noReconnectReasons = {
      'power_disconnected',
      'dispose',
      'manual_disconnect',
    };

    final bool shouldReconnect = _isPowerConnected &&
        !noReconnectReasons.any((r) => reason.startsWith(r));

    if (reason == 'power_disconnected') {
      _isFirstConnectOfSession = true;
      _log('[OBD] 電源斷開，重置首次連線旗標 (Safety Sweep Lock)');
    }

    if (shouldReconnect) {
      _log('[OBD] 將在 5 秒後嘗試自動重連...');
      _startAutoReconnect();
    } else {
      _log('[OBD] 進入深度休眠，不重連（reason=$reason）');
      _stopAutoReconnect();
    }
  }

  // =========================================================================
  // 核心：發送指令並 await 回應
  // =========================================================================

  Future<String> sendCommand(String cmd, {int timeoutMs = 3000}) {
    final Completer<String> resultCompleter = Completer<String>();

    _commandChain = _commandChain.then((_) async {
      final int epoch = _connectionEpoch;

      // ── 電源感知防呆：斷電時阻止所有無效發送 ─────────────────────────────
      if (!_isPowerConnected) {
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete('POWER_OFF');
        }
        return;
      }

      if (!_isConnected) {
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete('DISCONNECTED');
        }
        return;
      }

      _rxBuffer.clear();
      _pendingCompleter = resultCompleter;

      final String toSend = cmd.endsWith('\r') ? cmd : '$cmd\r';
      final Uint8List bytes = Uint8List.fromList(ascii.encode(toSend));

      if (!_isConnected || _connectionEpoch != epoch) {
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete('DISCONNECTED');
        }
        _pendingCompleter = null;
        return;
      }

      try {
        _log('[Parser TX] ${cmd.trim()}');
        _lastSentCmd = cmd.trim().toUpperCase().replaceAll(' ', '');
        await _methodChannel.invokeMethod('write', {'data': bytes});
      } catch (e) {
        _log('[OBD] Write error: $e');
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete('WRITE_ERROR');
        }
        _pendingCompleter = null;
        handleDisconnect('write_failed: $e');
        return;
      }

      try {
        await resultCompleter.future.timeout(Duration(milliseconds: timeoutMs));

        // ── 成功收到回應：看門狗計數歸零 ────────────────────────────────────
        _consecutiveTimeouts = 0;
      } on TimeoutException {
        _log('[OBD] Timeout waiting for: ${cmd.trim()}');

        // ── 看門狗累加 ───────────────────────────────────────────────────────
        _consecutiveTimeouts++;
        _log('[Watchdog] 連續逾時次數：$_consecutiveTimeouts / $_watchdogThreshold');

        if (!resultCompleter.isCompleted) {
          resultCompleter.complete('TIMEOUT');
        }
        _pendingCompleter = null;

        // ── 達到看門狗閾值：強制斷線打破死鎖 ───────────────────────────────
        if (_consecutiveTimeouts >= _watchdogThreshold) {
          _log('[Watchdog] 達到閾值，強制斷線！清空 command chain...');
          _consecutiveTimeouts = 0; // 重置後再斷線，防止下次重連後立即再觸發
          handleDisconnect('watchdog_timeout');
        }
      }
    });

    return resultCompleter.future;
  }

  // =========================================================================
  // 快速失敗的初始化序列
  // =========================================================================

  Future<void> initializeELM327() async {
    connectionState = ObdConnectionState.initializing;
    await Future.delayed(const Duration(milliseconds: 500));

    Future<String> mustSend(String cmd, {int timeoutMs = 3000}) async {
      if (!_isConnected) {
        throw Exception('Connection lost before sending: $cmd');
      }
      final String r = await sendCommand(cmd, timeoutMs: timeoutMs);
      if (r == 'WRITE_ERROR' || r == 'TIMEOUT' || r == 'DISCONNECTED') {
        throw Exception('Init failed at [$cmd]: $r');
      }
      return r;
    }

    _log('[OBD] --- Starting ELM327 Init ---');

    try {
      _log('[OBD] ATZ  → ${await mustSend('ATZ', timeoutMs: 3000)}');
      _log('[OBD] ATE0 → ${await mustSend('ATE0')}');
      _log('[OBD] ATL0 → ${await mustSend('ATL0')}');
      _log('[OBD] ATH0 → ${await mustSend('ATH0')}'); // Headers Off
      _log('[OBD] ATS0 → ${await mustSend('ATS0')}'); // Spaces Off
      _log(
          '[OBD] ATAL → ${await mustSend('ATAL')}'); // Allow Long messages（多幀合併輸出）
      _log(
          '[OBD] ATST32→ ${await mustSend('ATST32')}'); // Timeout = 0x32 * 4ms = ~200ms
      _log('[OBD] ATAT1 → ${await mustSend('ATAT1')}'); // 自動調整時序
      _log(
          '[OBD] ATSP6 → ${await mustSend('ATSP6')}'); // 直接鎖定 ISO 15765-4 CAN 11-bit 500K

      _log('[OBD] --- Init Complete ---');
      connectionState = ObdConnectionState.connected;

      // 1. 觸發掃跡動畫訊號 (僅在電源開啟後的第一次連線時觸發)
      if (_isFirstConnectOfSession) {
        _log('[OBD] 首次連線，觸發掃跡動畫 (WAKEUP)');
        _shouldTriggerWakeup = true;
        notifyListeners();
        _shouldTriggerWakeup = false;
        _isFirstConnectOfSession = false;
      } else {
        _log('[OBD] 靜默重連，跳過掃跡動畫');
      }

      _log('[OBD] --- Deep Sync Starting (Timeout: 1s per cmd) ---');

      // 2. 深度同步：一次性讀取核心靜態數據 (使用 await 確保順序)
      try {
        await sendCommand('015B', timeoutMs: 1000); // HEV 電量
        await sendCommand('ATSH7DF', timeoutMs: 1000);
        await sendCommand('0167', timeoutMs: 1000); // 水溫
        await sendCommand('ATSH7C6', timeoutMs: 1000);
        await sendCommand('22B002', timeoutMs: 1000); // 里程與油量
        await sendCommand('ATSH7A0', timeoutMs: 1000);
        await sendCommand('22C00B', timeoutMs: 1000); // 胎壓
        await sendCommand('ATSH7DF', timeoutMs: 1000); // 重置廣播 Header
      } catch (e) {
        _log('[OBD] Deep sync sequence interrupted: $e');
      }

      _log('[OBD] --- Deep Sync Done, starting real-time poll ---');

      // 3. 最後啟動即時輪詢任務
      _startPollingTasks();
    } catch (e) {
      _log('[OBD] Init FAILED: $e → triggering disconnect');
      handleDisconnect('init_failed: $e');
    }
  }

  // =========================================================================
  // RX: 資料到達處理
  // =========================================================================

  void _resetDataFlags() {
    rpm = null;
    speed = null;
    coolantTemp = null;
    voltage = null;
    hevSoc = null;
    odometer = null;
    fuelLevel = null;
    turbo = null;
    tpmsFl = null;
    tpmsFr = null;
    tpmsRl = null;
    tpmsRr = null;
    serviceDistanceRemaining = 0;
    serviceDaysRemaining = 0;

    hasRpm = false;
    hasSpeed = false;
    hasCoolant = false;
    hasVoltage = false;
    hasHevSoc = false;
    hasOdometer = false;
    hasFuel = false;
    hasTurbo = false;
    hasServiceDistanceRemaining = false;
    hasServiceDaysRemaining = false;
    hasTpms = false;
    _fuelBuffer.clear();
  }

  bool isDataReady() {
    return hasRpm &&
        hasSpeed &&
        hasCoolant &&
        hasVoltage &&
        hasHevSoc &&
        hasOdometer &&
        hasFuel &&
        hasTpms;
  }

  void _setupDataListener() {
    _dataSubscription?.cancel();
    _dataSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic data) {
        if (data is Uint8List) {
          _onDataReceived(data);
        }
      },
      onError: (err) {
        _log('[OBD] Stream error: $err');
        handleDisconnect('stream_error: $err');
      },
    );
  }

  void _onDataReceived(Uint8List data) {
    _rxBuffer.write(ascii.decode(data, allowInvalid: true));

    final String buf = _rxBuffer.toString();

    if (buf.endsWith('>')) {
      final String sanitized = buf
          .replaceAll(' ', '')
          .replaceAll('\r', '')
          .replaceAll('\n', '')
          .replaceAll('>', '')
          .toUpperCase()
          .replaceAll(RegExp(r'[0-9A-F]:'), '');

      if (sanitized.isNotEmpty) {
        _log('[Parser RX] cmd=$_lastSentCmd raw=$sanitized');
        _parseObdResponse(sanitized, _lastSentCmd);
      }

      final completer = _pendingCompleter;
      _pendingCompleter = null;
      _rxBuffer.clear();

      if (completer != null && !completer.isCompleted) {
        completer.complete(sanitized);
      }
    }
  }

  // =========================================================================
  // OBD Response Parser — 特徵碼定位提取 (Signature Indexing)
  // =========================================================================

  void _parseObdResponse(String sanitized, String lastCmd) {
    if (sanitized.isEmpty) return;

    if (_isAtResponse(sanitized)) {
      if (lastCmd == '0105') {
        _log('[Parser 0105] AT response (NODATA?): $sanitized');
      }
      return;
    }

    try {
      // ── 1. 01 系列：指令隔離 + 標籤搜尋 (Label Search) ──────────────────
      if (lastCmd.startsWith('01')) {
        final int idx41 = sanitized.indexOf('41');
        if (idx41 == -1) return; // 無效回應

        // ─── 合併指令 010B0C0D：僅解析 MAP/RPM/Speed ───────────
        if (lastCmd == '010B0C0D') {
          // MAP (0B)
          final int idx0B = sanitized.indexOf('0B', idx41);
          if (idx0B != -1 && sanitized.length >= idx0B + 4) {
            try {
              final String hexMap = sanitized.substring(idx0B + 2, idx0B + 4);
              final int mapKpa = int.parse(hexMap, radix: 16);
              turboBoostBar = (mapKpa - currentBaroKpa) / 100.0;
              turbo = double.parse(turboBoostBar.toStringAsFixed(2));
              hasTurbo = true;
              _log('[Parser Result] Turbo=$turbo Bar (MAP=$mapKpa kPa)');
            } catch (_) {}
          }

          // RPM (0C)
          final int idx0C = sanitized.indexOf('0C', idx41);
          if (idx0C != -1 && sanitized.length >= idx0C + 6) {
            try {
              final String hexRpm = sanitized.substring(idx0C + 2, idx0C + 6);
              final int a = int.parse(hexRpm.substring(0, 2), radix: 16);
              final int b = int.parse(hexRpm.substring(2, 4), radix: 16);
              final int valRpm = ((a * 256) + b) ~/ 4;
              if (valRpm <= 10000) {
                rpm = valRpm;
                hasRpm = true;
                _log('[Parser Result] RPM=$rpm');
              }
            } catch (_) {}
          }

          // Speed (0D)
          final int idx0D = sanitized.indexOf('0D', idx41);
          if (idx0D != -1 && sanitized.length >= idx0D + 4) {
            try {
              final String hexSpd = sanitized.substring(idx0D + 2, idx0D + 4);
              final int valSpeed = int.parse(hexSpd, radix: 16);
              if (valSpeed <= 250) {
                bool hasRecentGps = _lastGpsSpeedTime != null && 
                    DateTime.now().difference(_lastGpsSpeedTime!).inSeconds < 5;
                
                if (hasRecentGps) {
                  double diff = (valSpeed - _lastGpsSpeedKmh!).abs();
                  if (diff > 20) {
                    _log('[Parser Result] OBD速度($valSpeed)與GPS差距過大($diff km/h)，仍採用OBD值');
                  }
                }
                speed = valSpeed;
                hasSpeed = true;
                _log('[Parser Result] Speed=$speed (OBD)');
              }
            } catch (_) {}
          }
          notifyListeners();
          return;
        }

        // ─── 單一 PID 01 指令：嚴格指令隔離 ─────────

        // --- 0133 (Baro) ---
        if (lastCmd == '0133') {
          final int idx33 = sanitized.indexOf('33', idx41);
          if (idx33 != -1 && sanitized.length >= idx33 + 4) {
            final String hex = sanitized.substring(idx33 + 2, idx33 + 4);
            currentBaroKpa = int.parse(hex, radix: 16).toDouble();
            _log('[Parser Result] Baro=$currentBaroKpa kPa');
          }
          notifyListeners();
          return;
        }

        // --- 015B (HEV SOC) ---
        if (lastCmd == '015B') {
          final int idx5B = sanitized.indexOf('5B', idx41);
          if (idx5B != -1 && sanitized.length >= idx5B + 4) {
            final String hex = sanitized.substring(idx5B + 2, idx5B + 4);
            final double rawSoc = int.parse(hex, radix: 16) * 100.0 / 255.0;
            hevSoc = double.parse(rawSoc.toStringAsFixed(1));
            hasHevSoc = true;
            _log('[Parser Result] HEV SOC=$hevSoc%');
          }
          notifyListeners();
          return;
        }

        // --- 0167 (Coolant) ─── 水溫僅在此指令下更新 ---
        if (lastCmd == '0167') {
          final int idx67 = sanitized.indexOf('67', idx41);
          if (idx67 != -1 && sanitized.length >= idx67 + 8) {
            final String hexA = sanitized.substring(idx67 + 2 + 2, idx67 + 2 + 4); // 4167 CC AA
            final int raw = int.parse(hexA, radix: 16) - 40;
            if (raw >= -40 && raw <= 150) {
              coolantTemp = raw;
              hasCoolant = true;
              _log('[Parser Result] Coolant=$coolantTemp °C');
            }
          }
          notifyListeners();
          return;
        }

        return;
      }

      // ── 2. 22 系列：保留原邏輯但與 01 系列隔離 ────────────────────────
      if (lastCmd.startsWith('22')) {
        final String pid = lastCmd.substring(2);
        final String signature = '62$pid';
        final int index = sanitized.indexOf(signature);

        if (index != -1) {
          final int payloadStart = index + signature.length;
          final String data = sanitized.substring(payloadStart);

          if (pid == 'C00B') {
            if (data.length >= 42) {
              tpmsFl = int.parse(data.substring(8, 10), radix: 16) / 5.0;
              tpmsFr = int.parse(data.substring(18, 20), radix: 16) / 5.0;
              tpmsRl = int.parse(data.substring(28, 30), radix: 16) / 5.0;
              tpmsRr = int.parse(data.substring(38, 40), radix: 16) / 5.0;
              hasTpms = true;
              _log(
                  '[Parser Result] TPMS FL=$tpmsFl FR=$tpmsFr RL=$tpmsRl RR=$tpmsRr');
            }
          } else if (pid == 'B002') {
            if (data.length >= 18) {
              final int g = int.parse(data.substring(12, 14), radix: 16);
              final int h = int.parse(data.substring(14, 16), radix: 16);
              final int i = int.parse(data.substring(16, 18), radix: 16);
              final int odoRaw = (g << 16) | (h << 8) | i;
              if (odoRaw > 0) {
                odometer = odoRaw.toDouble();
                hasOdometer = true;
              }
              
              // ── Fuel Level Moving Window (Length 5) ──
              try {
                final int rawFuel = int.parse(data.substring(8, 10), radix: 16);
                _fuelBuffer.add(rawFuel);
                if (_fuelBuffer.length >= 5) {
                  final List<int> sorted = List.from(_fuelBuffer)..sort();
                  // 捨棄最大與最小值，取中間 3 筆平均
                  final int sum = sorted[1] + sorted[2] + sorted[3];
                  fuelLevel = sum ~/ 3;
                  hasFuel = true;
                  _log('[Parser Result] Filtered Fuel Level: $fuelLevel (avg of mid-3 from $_fuelBuffer)');
                  _fuelBuffer.clear();
                } else {
                  _log('[Parser] Fuel Buffer: ${_fuelBuffer.length}/5 (Current=$rawFuel)');
                }
              } catch (e) {
                _log('[Parser Error] Fuel parse error: $e');
              }

              final int f = int.parse(data.substring(10, 12), radix: 16);
              voltage = double.parse((f * 0.078125).toStringAsFixed(2));
              hasVoltage = true;

              if (data.length >= 26) {
                final int byteG = int.parse(data.substring(18, 20), radix: 16);
                final int byteH = int.parse(data.substring(20, 22), radix: 16);
                final int byteI = int.parse(data.substring(22, 24), radix: 16);
                final int byteJ = int.parse(data.substring(24, 26), radix: 16);
                serviceDistanceRemaining = (byteG * 256) + byteH;
                serviceDaysRemaining = (byteI * 256) + byteJ;
                hasServiceDistanceRemaining = true;
                hasServiceDaysRemaining = true;

                _logMaintenance('Raw Data: $data');
                _logMaintenance(
                    'Maintenance Info: Dist=$serviceDistanceRemaining km, Days=$serviceDaysRemaining days');
              }
              _log('[Parser Result] Heavy Data Parsed');
            }
          }
          notifyListeners(); // 22 系列解析完成，通知 UI
          return;
        }
      }
    } catch (e) {
      _log('[Parser Error] $e | sanitized=$sanitized');
    }
  }

  // ── AT 指令回應過濾器 ─────────────────────────────────────────────────────

  bool _isAtResponse(String compact) {
    const List<String> atKeywords = [
      'OK',
      'ELM',
      'ATZ',
      'ATE',
      'ATL',
      'ATS',
      'ATH',
      'ATSP',
      'NODATA',
      'UNABLETOCONNECT',
      'BUSERROR',
      'CANERROR',
      'DATAERROR',
      'ERROR',
      'SEARCHING',
      'STOPPED',
      'BUFFERFULL',
    ];
    return atKeywords.any((kw) => compact.contains(kw));
  }

  // =========================================================================
  // Polling Tasks
  // =========================================================================

  void _startPollingTasks() {
    _fastPollTimer?.cancel();
    _slowPollTimer?.cancel();
    _minutePollTimer?.cancel();
    _longPollTimer?.cancel();

    _scheduleFastPoll();

    // HEV SOC 每 5 秒：使用標準 OBD PID 015B（= 100/255*A），不需切換 Header
    _slowPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_isConnected) return;
      sendCommand('015B');
    });

    // 水溫每 30 秒：使用 PID 0167（SAE Coolant A/B）
    _minutePollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_isConnected) return;
      sendCommand('0167');
      sendCommand('ATSH7C6');
      sendCommand('22B002');
      sendCommand('ATSH7A0');
      sendCommand('22C00B');
      sendCommand('ATSH7DF');
    });

    // 維護資訊每 30 分鐘：使用 PID 22B002
    _longPollTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      if (!_isConnected) return;
      sendCommand('ATSH7C6');
      sendCommand('22B002');
      sendCommand('ATSH7DF');
    });
  }

  void _scheduleFastPoll() {
    const int intervalMs = 300;
    _fastPollTimer = Timer(const Duration(milliseconds: intervalMs), () {
      if (!_isConnected) return;
      // 合併請求：010B (Turbo), 010C (RPM), 010D (Speed)
      sendCommand('010B0C0D');
      _scheduleFastPoll();
    });
  }
}
