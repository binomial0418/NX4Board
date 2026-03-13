import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'settings_service.dart';

enum ObdConnectionState {
  disconnected,
  scanning,
  connecting,
  initializing,
  connected
}

class ObdSppService {
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

  void _log(String msg) {
    debugPrint(msg);
    _logController.add(msg);
  }

  // ── RX Buffer + Completer (半雙工核心) ────────────────────────────────────
  final StringBuffer _rxBuffer = StringBuffer();
  Completer<String>? _pendingCompleter;

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
  int? hevSoc;
  double? odometer;
  int? fuelLevel;

  // TPMS (FL, FR, RL, RR)
  double? tpmsFl;
  double? tpmsFr;
  double? tpmsRl;
  double? tpmsRr;

  // ── Polling Timers ────────────────────────────────────────────────────────
  Timer? _fastPollTimer;
  Timer? _slowPollTimer;
  Timer? _minutePollTimer;

  // =========================================================================
  // Public API
  // =========================================================================

  Future<void> init() async {
    final String savedMac = SettingsService().obdMac;
    if (savedMac.isNotEmpty) {
      _log('[OBD] Auto-connecting to: $savedMac');
      connectToDevice(savedMac);
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
        _isConnected = true; // ← 成功連線後才設旗標
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

  void dispose() {
    handleDisconnect('dispose');
    _logController.close();
  }

  // =========================================================================
  // 統一斷線處理器 (Centralized Disconnect Handler)
  // =========================================================================

  /// 所有斷線情境的唯一出口。呼叫後保證：
  /// 1. _isConnected = false
  /// 2. 所有 Timer 取消
  /// 3. Buffer / Completer / CommandChain 清空
  /// 4. 觸發 native disconnect
  void handleDisconnect(String reason) {
    // 防止重入：已經是 disconnected 且旗標已清除，直接跳過
    if (!_isConnected &&
        connectionState == ObdConnectionState.disconnected) {
      return;
    }

    _log('[OBD] handleDisconnect ← $reason');

    // 1. 設定旗標與狀態
    _isConnected = false;
    connectionState = ObdConnectionState.disconnected;

    // 2. 取消所有輪詢 Timer
    _fastPollTimer?.cancel();
    _fastPollTimer = null;
    _slowPollTimer?.cancel();
    _slowPollTimer = null;
    _minutePollTimer?.cancel();
    _minutePollTimer = null;

    // 3. 清空 Buffer & 解除等待中的 Completer
    _rxBuffer.clear();
    if (_pendingCompleter != null && !_pendingCompleter!.isCompleted) {
      _pendingCompleter!.complete('DISCONNECTED');
    }
    _pendingCompleter = null;

    // 4. Epoch +1：使所有已排入 microtask queue 的舊 chain closure 失效
    _connectionEpoch++;
    // 重置 command chain，防止新指令繼續接在舊 chain 後面
    _commandChain = Future.value();

    // 5. 停止 Stream 監聽
    _dataSubscription?.cancel();
    _dataSubscription = null;

    // 6. 呼叫 native disconnect（fire-and-forget）
    _methodChannel.invokeMethod('disconnect').catchError((_) {});
  }

  // =========================================================================
  // 核心：發送指令並 await 回應（isConnected 守門員 + Mutex + Timeout）
  // =========================================================================

  Future<String> sendCommand(String cmd, {int timeoutMs = 3000}) {
    final Completer<String> resultCompleter = Completer<String>();

    _commandChain = _commandChain.then((_) async {
      // ── 守門員 1：進入 chain 時 snapshot epoch ────────────────────────
      final int epoch = _connectionEpoch;

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

      // ── 守門員 2：write 前再次比對 epoch（防 Race Condition）────────────
      if (!_isConnected || _connectionEpoch != epoch) {
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete('DISCONNECTED');
        }
        _pendingCompleter = null;
        return;
      }

      try {
        _log('[TX] ${cmd.trim()}');
        await _methodChannel.invokeMethod('write', {'data': bytes});
      } catch (e) {
        _log('[OBD] Write error: $e');
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete('WRITE_ERROR');
        }
        _pendingCompleter = null;
        // Broken pipe / socket closed → 觸發統一斷線處理
        handleDisconnect('write_failed: $e');
        return;
      }

      try {
        await resultCompleter.future
            .timeout(Duration(milliseconds: timeoutMs));
      } on TimeoutException {
        _log('[OBD] Timeout waiting for: ${cmd.trim()}');
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete('TIMEOUT');
        }
        _pendingCompleter = null;
      }
    });

    return resultCompleter.future;
  }

  // =========================================================================
  // 快速失敗的初始化序列 (Fail-fast Initialization)
  // =========================================================================

  Future<void> initializeELM327() async {
    connectionState = ObdConnectionState.initializing;
    await Future.delayed(const Duration(milliseconds: 500));

    // 快速失敗輔助：任何錯誤回應直接 throw
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
      _log('[OBD] ATZ  → ${await mustSend('ATZ', timeoutMs: 2000)}');
      _log('[OBD] ATE0 → ${await mustSend('ATE0')}');
      _log('[OBD] ATL0 → ${await mustSend('ATL0')}');
      _log('[OBD] ATSP0→ ${await mustSend('ATSP0')}');

      _log('[OBD] --- Init Complete ---');
      connectionState = ObdConnectionState.connected;
      _startPollingTasks();
    } catch (e) {
      _log('[OBD] Init FAILED: $e → triggering disconnect');
      handleDisconnect('init_failed: $e');
    }
  }

  // =========================================================================
  // RX: 資料到達處理
  // =========================================================================

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
        handleDisconnect('stream_error: $err'); // ← 改呼叫統一處理器
      },
    );
  }

  void _onDataReceived(Uint8List data) {
    _rxBuffer.write(ascii.decode(data, allowInvalid: true));

    final String buf = _rxBuffer.toString();

    if (buf.endsWith('>')) {
      final String response = buf
          .replaceAll('>', '')
          .replaceAll('\r', ' ')
          .replaceAll('\n', ' ')
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');

      _log('[RX] $response');

      if (response.isNotEmpty) {
        for (final line in response.split(' ')) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty) _parseObdResponse(trimmed);
        }
      }

      final completer = _pendingCompleter;
      _pendingCompleter = null;
      _rxBuffer.clear();

      if (completer != null && !completer.isCompleted) {
        completer.complete(response);
      }
    }
  }

  // =========================================================================
  // OBD Response Parser
  // =========================================================================

  void _parseObdResponse(String hexStr) {
    final String raw = hexStr.replaceAll(' ', '').toUpperCase();
    if (raw.isEmpty) return;
    if (raw == 'OK' || raw == '?' || raw.startsWith('ELM') ||
        raw.startsWith('ATZ') || raw.startsWith('ATE') ||
        raw.startsWith('ATL') || raw.startsWith('ATS') ||
        raw.startsWith('ATH') || raw.startsWith('ATSP') ||
        raw.contains('NODATA') || raw.contains('ERROR') ||
        raw.contains('SEARCHING') || raw.contains('STOPPED')) {
      return;
    }
    if (raw.startsWith('41')) return _parseMode01(raw);
    if (raw.startsWith('62')) return _parseMode22(raw);
  }

  void _parseMode01(String raw) {
    if (raw.length < 6) return;
    final String pid = raw.substring(2, 4);
    try {
      switch (pid) {
        case '0C':
          if (raw.length >= 8) {
            final int a = int.parse(raw.substring(4, 6), radix: 16);
            final int b = int.parse(raw.substring(6, 8), radix: 16);
            rpm = ((a * 256) + b) ~/ 4;
          }
          break;
        case '0D':
          if (raw.length >= 6) {
            speed = int.parse(raw.substring(4, 6), radix: 16);
          }
          break;
        case '05':
          if (raw.length >= 6) {
            final int a = int.parse(raw.substring(4, 6), radix: 16);
            coolantTemp = a - 40;
          }
          break;
        case '5B':
          if (raw.length >= 6) {
            final int a = int.parse(raw.substring(4, 6), radix: 16);
            hevSoc = (a * 100) ~/ 255;
          }
          break;
      }
    } catch (e) {
      _log('[OBD] Parse Mode01 error ($pid): $e');
    }
  }

  void _parseMode22(String raw) {
    if (raw.length < 8) return;
    final String pid = raw.substring(2, 6);
    try {
      switch (pid) {
        case 'C00B':
          if (raw.length >= 48) {
            tpmsFl = int.parse(raw.substring(14, 16), radix: 16) / 5.0;
            tpmsFr = int.parse(raw.substring(24, 26), radix: 16) / 5.0;
            tpmsRl = int.parse(raw.substring(44, 46), radix: 16) / 5.0;
            tpmsRr = int.parse(raw.substring(34, 36), radix: 16) / 5.0;
          }
          break;
        case 'B002':
          if (raw.length >= 24) {
            final int g = int.parse(raw.substring(18, 20), radix: 16);
            final int h = int.parse(raw.substring(20, 22), radix: 16);
            final int i = int.parse(raw.substring(22, 24), radix: 16);
            final int odoRaw = (g << 16) | (h << 8) | i;
            if (odoRaw > 0) odometer = odoRaw.toDouble();
          }
          if (raw.length >= 16) {
            fuelLevel = int.parse(raw.substring(14, 16), radix: 16);
          }
          break;
      }
    } catch (e) {
      _log('[OBD] Parse Mode22 error ($pid): $e');
    }
  }

  // =========================================================================
  // Polling Tasks
  // =========================================================================

  void _startPollingTasks() {
    _fastPollTimer?.cancel();
    _slowPollTimer?.cancel();
    _minutePollTimer?.cancel();

    _fastPollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isConnected) return; // ← 用旗標而非 connectionState 判斷
      sendCommand('010C');
      sendCommand('010D');
    });

    _slowPollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_isConnected) return;
      sendCommand('015B');
    });

    _minutePollTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!_isConnected) return;
      sendCommand('0105');
      sendCommand('ATSH7C6');
      sendCommand('22B002');
      sendCommand('ATSH7A0');
      sendCommand('22C00B');
      sendCommand('ATSH7DF');
    });
  }
}
