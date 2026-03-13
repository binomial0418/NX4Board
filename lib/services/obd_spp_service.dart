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
  double? hevSoc;   // 保留一位小數
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

  /// 立即輪詢一次全部感測器（不等 Timer 排程）
  Future<void> pollAllNow() async {
    if (!_isConnected) return;
    _log('[OBD] pollAllNow() triggered');
    sendCommand('010C');
    sendCommand('010D');
    sendCommand('0105');
    sendCommand('015B');
    sendCommand('ATSH7C6');
    sendCommand('22B002');
    sendCommand('ATSH7A0');
    sendCommand('22C00B');
    sendCommand('ATSH7DF');
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

  void handleDisconnect(String reason) {
    if (!_isConnected &&
        connectionState == ObdConnectionState.disconnected) {
      return;
    }

    _log('[OBD] handleDisconnect ← $reason');

    _isConnected = false;
    connectionState = ObdConnectionState.disconnected;

    _fastPollTimer?.cancel();
    _fastPollTimer = null;
    _slowPollTimer?.cancel();
    _slowPollTimer = null;
    _minutePollTimer?.cancel();
    _minutePollTimer = null;

    _rxBuffer.clear();
    if (_pendingCompleter != null && !_pendingCompleter!.isCompleted) {
      _pendingCompleter!.complete('DISCONNECTED');
    }
    _pendingCompleter = null;

    _connectionEpoch++;
    _commandChain = Future.value();

    _dataSubscription?.cancel();
    _dataSubscription = null;

    _methodChannel.invokeMethod('disconnect').catchError((_) {});
  }

  // =========================================================================
  // 核心：發送指令並 await 回應
  // =========================================================================

  Future<String> sendCommand(String cmd, {int timeoutMs = 3000}) {
    final Completer<String> resultCompleter = Completer<String>();

    _commandChain = _commandChain.then((_) async {
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

      if (!_isConnected || _connectionEpoch != epoch) {
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete('DISCONNECTED');
        }
        _pendingCompleter = null;
        return;
      }

      try {
        // ── [Parser TX] 日誌 ────────────────────────────────────────────────
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
      _log('[OBD] ATZ  → ${await mustSend('ATZ', timeoutMs: 2000)}');
      _log('[OBD] ATE0 → ${await mustSend('ATE0')}');
      _log('[OBD] ATL0 → ${await mustSend('ATL0')}');
      _log('[OBD] ATSP0→ ${await mustSend('ATSP0')}');

      _log('[OBD] --- Init Complete ---');
      connectionState = ObdConnectionState.connected;
      _startPollingTasks();
      // 連線成功後立即輪詢一次所有感測器（不等 Timer 排程）
      pollAllNow();
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
        handleDisconnect('stream_error: $err');
      },
    );
  }

  void _onDataReceived(Uint8List data) {
    _rxBuffer.write(ascii.decode(data, allowInvalid: true));

    final String buf = _rxBuffer.toString();

    if (buf.endsWith('>')) {
      // ── [Parser RX Raw]：把 \r 替換為可見的 \r 字串，方便肉眼觀察 ────────
      final String rawVisible = buf
          .replaceAll('\r', '\\r')
          .replaceAll('\n', '\\n');
      _log('[Parser RX Raw] $rawVisible');

      // ── 清理：去掉提示符號、統一空白，保留空格以供特徵碼搜尋 ─────────────
      final String cleaned = buf
          .replaceAll('>', '')
          .replaceAll('\r', ' ')
          .replaceAll('\n', ' ')
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');

      _log('[Parser RX Cleaned] $cleaned');

      if (cleaned.isNotEmpty) {
        // ── 整行送入 Parser，不切碎，讓特徵碼搜尋正常運作 ──────────────────
        _parseObdResponse(cleaned, _lastSentCmd);
      }

      final completer = _pendingCompleter;
      _pendingCompleter = null;
      _rxBuffer.clear();

      if (completer != null && !completer.isCompleted) {
        completer.complete(cleaned);
      }
    }
  }

  // =========================================================================
  // OBD Response Parser — CAN Bus 容錯特徵碼搜尋
  // =========================================================================

  void _parseObdResponse(String response, String lastCmd) {
    // 無空格大寫版本，用於特徵碼搜尋
    final String compact = response.replaceAll(' ', '').toUpperCase();

    if (compact.isEmpty) return;

    // 過濾 AT 指令回應與錯誤訊息
    if (_isAtResponse(compact)) return;

    try {
      // ── Mode 01 (Standard OBD) ──────────────────────────────────────────

      // RPM (PID 0C)：搜尋特徵碼 410C，取後 4 個 Hex char
      final int i410C = compact.indexOf('410C');
      if (i410C != -1 && compact.length >= i410C + 8) {
        final String hex = compact.substring(i410C + 4, i410C + 8);
        final int a = int.parse(hex.substring(0, 2), radix: 16);
        final int b = int.parse(hex.substring(2, 4), radix: 16);
        rpm = ((a * 256) + b) ~/ 4;
        _log('[Parser Result] RPM=$rpm  (410C hex=$hex)');
        return;
      }

      // Speed (PID 0D)：搜尋特徵碼 410D，取後 2 個 Hex char
      final int i410D = compact.indexOf('410D');
      if (i410D != -1 && compact.length >= i410D + 6) {
        final String hex = compact.substring(i410D + 4, i410D + 6);
        speed = int.parse(hex, radix: 16);
        _log('[Parser Result] Speed=$speed km/h  (410D hex=$hex)');
        return;
      }

      // Coolant Temp (PID 05)：搜尋特徵碼 4105，取後 2 個 Hex char
      final int i4105 = compact.indexOf('4105');
      if (i4105 != -1 && compact.length >= i4105 + 6) {
        final String hex = compact.substring(i4105 + 4, i4105 + 6);
        coolantTemp = int.parse(hex, radix: 16) - 40;
        _log('[Parser Result] Coolant=$coolantTemp °C  (4105 hex=$hex)');
        return;
      }

      // HEV SOC (PID 5B)：搜尋特徵碼 415B，取後 2 個 Hex char
      final int i415B = compact.indexOf('415B');
      if (i415B != -1 && compact.length >= i415B + 6) {
        final String hex = compact.substring(i415B + 4, i415B + 6);
        final double rawSoc = int.parse(hex, radix: 16) * 100.0 / 255.0;
        hevSoc = double.parse(rawSoc.toStringAsFixed(1));
        _log('[Parser Result] HEV SOC=$hevSoc%  (415B hex=$hex)');
        return;
      }

      // Battery Voltage (PID 42)：搜尋特徵碼 4142，取後 4 個 Hex char
      final int i4142 = compact.indexOf('4142');
      if (i4142 != -1 && compact.length >= i4142 + 8) {
        final String hex = compact.substring(i4142 + 4, i4142 + 8);
        final int a = int.parse(hex.substring(0, 2), radix: 16);
        final int b = int.parse(hex.substring(2, 4), radix: 16);
        voltage = double.parse(((a * 256 + b) / 1000.0).toStringAsFixed(2));
        _log('[Parser Result] Voltage=$voltage V  (4142 hex=$hex)');
        return;
      }

      // ── Mode 22 (OEM / Hyundai 等廠牌) ─────────────────────────────────
      // 62C00B (TPMS)
      final int i62C00B = compact.indexOf('62C00B');
      if (i62C00B != -1) {
        _parseMode22Tpms(compact, i62C00B);
        return;
      }

      // 62B002 (Odometer / Fuel)
      final int i62B002 = compact.indexOf('62B002');
      if (i62B002 != -1) {
        _parseMode22OdoFuel(compact, i62B002);
        return;
      }

      // 無法識別的回應（印出供除錯，不算錯誤）
      _log('[Parser] Unrecognized: $compact');

    } catch (e) {
      _log('[Parser Error] $e | raw=$response');
    }
  }

  // ── Mode 22 解析輔助 ──────────────────────────────────────────────────────

  void _parseMode22Tpms(String compact, int startIdx) {
    // 62C00B 之後的資料（移除標頭）
    final String data = compact.substring(startIdx + 6);
    if (data.length >= 42) {
      tpmsFl = int.parse(data.substring(8, 10), radix: 16) / 5.0;
      tpmsFr = int.parse(data.substring(18, 20), radix: 16) / 5.0;
      tpmsRl = int.parse(data.substring(38, 40), radix: 16) / 5.0;
      tpmsRr = int.parse(data.substring(28, 30), radix: 16) / 5.0;
      _log('[Parser Result] TPMS FL=$tpmsFl FR=$tpmsFr RL=$tpmsRl RR=$tpmsRr bar');
    }
  }

  void _parseMode22OdoFuel(String compact, int startIdx) {
    final String data = compact.substring(startIdx + 6);
    if (data.length >= 18) {
      final int g = int.parse(data.substring(12, 14), radix: 16);
      final int h = int.parse(data.substring(14, 16), radix: 16);
      final int i = int.parse(data.substring(16, 18), radix: 16);
      final int odoRaw = (g << 16) | (h << 8) | i;
      if (odoRaw > 0) {
        odometer = odoRaw.toDouble();
        _log('[Parser Result] Odometer=$odometer km');
      }
    }
    if (data.length >= 10) {
      fuelLevel = int.parse(data.substring(8, 10), radix: 16);
      _log('[Parser Result] Fuel=$fuelLevel%');
    }
  }

  // ── AT 指令回應過濾器 ─────────────────────────────────────────────────────

  bool _isAtResponse(String compact) {
    const List<String> atKeywords = [
      'OK', 'ELM', 'ATZ', 'ATE', 'ATL', 'ATS', 'ATH', 'ATSP',
      'NODATA', 'UNABLETOCONNECT', 'BUSERROR', 'CANERROR',
      'DATAERROR', 'ERROR', 'SEARCHING', 'STOPPED', 'BUFFERFULL',
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

    _fastPollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isConnected) return;
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
