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
  double? hevSoc; // 保留一位小數
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
    sendCommand('0167');
    sendCommand('ATSH7E2');
    sendCommand('220105'); // Display SOC
    sendCommand('ATSH7C6');
    sendCommand('22B002'); // Odo, Fuel
    sendCommand('ATSH7A0');
    sendCommand('22C00B'); // TPMS
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
        // ── [Parser TX] 日誌（只記錄水溫與 HEV）────────────────────────────
        final String _trimCmd = cmd.trim().toUpperCase().replaceAll(' ', '');
        if (_trimCmd == '0167' || _trimCmd == '220105') {
          _log('[Parser TX] ${cmd.trim()}');
        }
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
      _log('[OBD] ATZ  → ${await mustSend('ATZ', timeoutMs: 3000)}');
      _log('[OBD] ATE0 → ${await mustSend('ATE0')}');
      _log('[OBD] ATL0 → ${await mustSend('ATL0')}');
      _log('[OBD] ATH0 → ${await mustSend('ATH0')}');   // Headers Off
      _log('[OBD] ATS0 → ${await mustSend('ATS0')}');   // Spaces Off
      _log('[OBD] ATAL → ${await mustSend('ATAL')}');   // Allow Long messages（多幀合併輸出）
      _log('[OBD] ATST64→ ${await mustSend('ATST64')}'); // Timeout = 0x64 * 4ms = ~400ms，等待 ECU 回應
      _log('[OBD] ATAT1 → ${await mustSend('ATAT1')}'); // 自動調整時序
      _log('[OBD] ATSP6 → ${await mustSend('ATSP6')}'); // 直接鎖定 ISO 15765-4 CAN 11-bit 500K，跳過 SEARCHING

      _log('[OBD] --- Init Complete ---');
      connectionState = ObdConnectionState.connected;
      _startPollingTasks();
      // 初始化完成後額外等待 1 秒，讓 CAN Bus 穩定
      await Future.delayed(const Duration(milliseconds: 1000));
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

      // 1. 絕對淨化字串 (String Sanitization)
      // 剔除所有的空格、歸位字元 \r、換行 \n 以及提示字元 >
      // 同時移除多幀序號（如 "0:", "1:" ... "F:"）以防 ATAL 未生效時的容錯
      final String sanitized = buf
          .replaceAll(' ', '')
          .replaceAll('\r', '')
          .replaceAll('\n', '')
          .replaceAll('>', '')
          .toUpperCase()
          .replaceAll(RegExp(r'[0-9A-F]:'), ''); // 移除多幀序號


      if (sanitized.isNotEmpty) {
        // 只針對 0167 / 220101 印 RX raw
        if (_lastSentCmd == '0167' || _lastSentCmd == '220105') {
          _log('[Parser RX] cmd=$_lastSentCmd raw=$sanitized');
        }
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
      // ── 2. 特徵碼定位提取 (Signature Indexing) ───────────────────────────
      // 根據最後發送的指令，動態尋找回應特徵碼

      // 處理 Mode 01
      if (lastCmd.startsWith('01')) {
        final String pid = lastCmd.substring(2); // 例如 0C
        final String signature = '41$pid'; // 例如 410C
        final int index = sanitized.indexOf(signature);

        if (index != -1) {
          // 3. 安全擷取資料載荷 (Payload Extraction)
          final int payloadStart = index + signature.length;

          if (pid == '0C') {
            // RPM: 擷取後面的 4 個字元
            if (sanitized.length >= payloadStart + 4) {
              final String hex = sanitized.substring(payloadStart, payloadStart + 4);
              final int a = int.parse(hex.substring(0, 2), radix: 16);
              final int b = int.parse(hex.substring(2, 4), radix: 16);
              rpm = ((a * 256) + b) ~/ 4;
            }
          } else if (pid == '0D') {
            // Speed: 擷取後面的 2 個字元
            if (sanitized.length >= payloadStart + 2) {
              final String hex = sanitized.substring(payloadStart, payloadStart + 2);
              speed = int.parse(hex, radix: 16);
            }
          } else if (pid == '67') {
            // Coolant A/B: PID 0167 回應 4167 + Byte A(count) + Byte B(CoolantA) + Byte C(CoolantB)
            // SAE_Coolant_A = Byte B - 40, SAE_Coolant_B = Byte C - 40
            if (sanitized.length >= payloadStart + 6) {
              // payloadStart+0~1 = Byte A（count byte，忽略）
              final String hexA = sanitized.substring(payloadStart + 2, payloadStart + 4);
              final String hexB = sanitized.substring(payloadStart + 4, payloadStart + 6);
              coolantTemp = int.parse(hexA, radix: 16) - 40; // Coolant A
              final int coolantB = int.parse(hexB, radix: 16) - 40;
              _log('[Parser Result] CoolantA=$coolantTemp °C CoolantB=$coolantB °C');
            }
          } else if (pid == '5B') {
            // HEV SOC: 擷取後面的 2 個字元
            if (sanitized.length >= payloadStart + 2) {
              final String hex = sanitized.substring(payloadStart, payloadStart + 2);
              final double rawSoc = int.parse(hex, radix: 16) * 100.0 / 255.0;
              hevSoc = double.parse(rawSoc.toStringAsFixed(1));
              _log('[Parser Result] HEV SOC=$hevSoc% (hex=$hex)');
            }
          }
          return;
        }
      }

      // 處理 Mode 22
      if (lastCmd.startsWith('22')) {
        final String pid = lastCmd.substring(2); // 例如 0101, B002, C00B
        final String signature = '62$pid'; // 例如 620101, 62B002
        final int index = sanitized.indexOf(signature);

        if (index != -1) {
          final int payloadStart = index + signature.length;

          if (pid == 'C00B') {
            // TPMS: 62C00B 之後需要足夠長度
            if (sanitized.length >= payloadStart + 42) {
              final String data = sanitized.substring(payloadStart);
              tpmsFl = int.parse(data.substring(8, 10), radix: 16) / 5.0;
              tpmsFr = int.parse(data.substring(18, 20), radix: 16) / 5.0;
              tpmsRl = int.parse(data.substring(38, 40), radix: 16) / 5.0;
              tpmsRr = int.parse(data.substring(28, 30), radix: 16) / 5.0;
            }
          } else if (pid == 'B002') {
            // Odo/Fuel/Voltage: 62B002 之後
            if (sanitized.length >= payloadStart + 18) {
              final String data = sanitized.substring(payloadStart);
              // Odometer: Byte G,H,I (Index 12, 14, 16)
              final int g = int.parse(data.substring(12, 14), radix: 16);
              final int h = int.parse(data.substring(14, 16), radix: 16);
              final int i = int.parse(data.substring(16, 18), radix: 16);
              final int odoRaw = (g << 16) | (h << 8) | i;
              if (odoRaw > 0) {
                odometer = odoRaw.toDouble();
                }
              // Fuel: Byte E (Index 8)
              fuelLevel = int.parse(data.substring(8, 10), radix: 16);
              // Voltage: Byte F (Index 10) * 0.078125
              final int f = int.parse(data.substring(10, 12), radix: 16);
              voltage = double.parse((f * 0.078125).toStringAsFixed(2));
            }
          } else if (pid == '0105') {
            // Display SOC = Byte E / 2
            // 620105 後：A=offset0~1, B=2~3, C=4~5, D=6~7, E=8~9
            if (sanitized.length >= payloadStart + 10) {
              final String data = sanitized.substring(payloadStart);
              final int byteE = int.parse(data.substring(8, 10), radix: 16);
              hevSoc = double.parse((byteE / 2.0).toStringAsFixed(1));
              _log('[Parser Result] Display SOC=$hevSoc%');
            }
          }
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

    // Display SOC 每 10 秒：切 7E2 → 220105 → 切回 7DF
    _slowPollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_isConnected) return;
      sendCommand('ATSH7E2');
      sendCommand('220105');
      sendCommand('ATSH7DF');
    });

    // 水溫每 60 秒：使用 PID 0167（SAE Coolant A/B）
    _minutePollTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!_isConnected) return;
      sendCommand('0167');
      sendCommand('ATSH7C6');
      sendCommand('22B002');
      sendCommand('ATSH7A0');
      sendCommand('22C00B');
      sendCommand('ATSH7DF');
    });
  }
}
