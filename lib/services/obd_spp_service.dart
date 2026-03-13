import 'dart:async';
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

  // Log Stream For Dashboard
  final _logController = StreamController<String>.broadcast();
  Stream<String> get logStream => _logController.stream;

  void _log(String msg) {
    debugPrint(msg);
    _logController.add(msg);
  }

  // A string buffer to accumulate chunked responses
  String _rxBuffer = '';

  // Data mapping
  int? rpm;
  int? speed;
  int? coolantTemp;
  double? voltage;
  int? hevSoc;

  // Odometer and Fuel
  double? odometer;
  int? fuelLevel;

  // TPMS (FL, FR, RL, RR)
  double? tpmsFl;
  double? tpmsFr;
  double? tpmsRl;
  double? tpmsRr;

  // Timers and Tasks
  Timer? _fastPollTimer;
  Timer? _slowPollTimer;
  Timer? _minutePollTimer;
  bool _isWaitingForResponse = false;

  // Simple queue for AT/PID commands
  final List<String> _commandQueue = [];

  Future<void> init() async {
    // 傳統藍牙不需要特殊的 Adapter State Listen (Android 層已處理)
    // 直接嘗試自動連線已儲存的 MAC
    String savedMac = SettingsService().obdMac;
    if (savedMac.isNotEmpty) {
      _log('[OBD] Auto-connecting to saved device: $savedMac');
      connectToDevice(savedMac);
    }
  }

  Future<List<Map<String, String>>> getBondedDevices() async {
    try {
      final List<dynamic> result = await _methodChannel.invokeMethod('getBondedDevices');
      return result.map((e) => Map<String, String>.from(e)).toList();
    } catch (e) {
      _log('[OBD] Failed to get bonded devices: $e');
      return [];
    }
  }

  Future<void> connectToDevice(String address) async {
    connectionState = ObdConnectionState.connecting;
    _log('[OBD] Connecting to $address...');

    try {
      final bool success = await _methodChannel.invokeMethod('connect', {'address': address});
      if (success) {
        _log('[OBD] Socket Connected!');
        _setupDataListener();
        _startObdInitSequence();
      } else {
        _cleanup();
      }
    } catch (e) {
      _log('[OBD] Connection failed: $e');
      _cleanup();
    }
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
        _log('[OBD] Data stream error: $err');
        _cleanup();
      },
    );
  }

  void _startObdInitSequence() {
    connectionState = ObdConnectionState.initializing;

    _commandQueue.clear();
    // ELM327 Initialization Sequence
    _enqueueCmd('ATZ'); // Reset
    _enqueueCmd('ATE0'); // Echo off
    _enqueueCmd('ATL0'); // Linefeeds off
    _enqueueCmd('ATSP0'); // Auto Protocol

    _processQueue();
  }

  void _enqueueCmd(String cmd) {
    if (!cmd.endsWith('\r')) cmd += '\r';
    _commandQueue.add(cmd);
  }

  Future<void> _processQueue() async {
    if (_commandQueue.isEmpty) {
      if (connectionState == ObdConnectionState.initializing) {
        _log('[OBD] Initialization Complete!');
        connectionState = ObdConnectionState.connected;
        _startPollingTasks();
      }
      return;
    }

    if (_isWaitingForResponse) return;

    _isWaitingForResponse = true;
    String cmd = _commandQueue.removeAt(0);
    _rxBuffer = '';

    await Future.delayed(const Duration(milliseconds: 50));

    try {
      _log('[OBD TX] ${cmd.trim()}');
      await _methodChannel.invokeMethod('write', {'data': cmd});
    } catch (e) {
      _log('[OBD] Write error: $e');
      _isWaitingForResponse = false;
    }

    Timer(const Duration(seconds: 3), () {
      if (_isWaitingForResponse) {
        _log('[OBD] Response Timeout. Unblocking queue.');
        _isWaitingForResponse = false;
        _processQueue();
      }
    });
  }

  void _onDataReceived(Uint8List data) {
    String chunk = String.fromCharCodes(data);
    _rxBuffer += chunk;

    if (_rxBuffer.contains('>')) {
      String responseStr = _rxBuffer
          .replaceAll('>', '')
          .trim()
          .replaceAll('\r', '')
          .replaceAll('\n', '');
      
      if (responseStr.isNotEmpty) {
        // Multi-line response handling (ELM327 can send multiple lines before '>')
        List<String> lines = responseStr.split(RegExp(r'[\r\n]+'));
        for (var line in lines) {
          _log('[OBD RX] ${line.trim()}');
          _parseObdResponse(line.trim());
        }
      }

      _isWaitingForResponse = false;
      _processQueue();
    }
  }

  void _parseObdResponse(String hexStr) {
    String raw = hexStr.replaceAll(' ', '');
    if (raw.contains('NODATA') || raw.contains('ERROR') || raw.contains('?')) return;
    if (raw.startsWith('41')) return _parseMode01(raw);
    if (raw.startsWith('62')) return _parseMode22(raw);
  }

  void _parseMode01(String raw) {
    if (raw.length < 6) return;
    String pid = raw.substring(2, 4);
    try {
      switch (pid) {
        case '0C': // RPM
          if (raw.length >= 8) {
            int a = int.parse(raw.substring(4, 6), radix: 16);
            int b = int.parse(raw.substring(6, 8), radix: 16);
            rpm = ((a * 256) + b) ~/ 4;
          }
          break;
        case '0D': // Speed
          if (raw.length >= 6) {
            speed = int.parse(raw.substring(4, 6), radix: 16);
          }
          break;
        case '05': // Coolant
          if (raw.length >= 6) {
            int a = int.parse(raw.substring(4, 6), radix: 16);
            coolantTemp = a - 40;
          }
          break;
        case '5B': // HEV SOC
          if (raw.length >= 6) {
            int a = int.parse(raw.substring(4, 6), radix: 16);
            hevSoc = (a * 100) ~/ 255;
          }
          break;
      }
    } catch (e) {
      _log('[OBD] Parse Error: $e');
    }
  }

  void _parseMode22(String raw) {
    if (raw.length < 8) return;
    String pid = raw.substring(2, 6);
    try {
      switch (pid) {
        case 'C00B':
          if (raw.length >= 48) {
            int e = int.parse(raw.substring(14, 16), radix: 16);
            int j = int.parse(raw.substring(24, 26), radix: 16);
            int t = int.parse(raw.substring(44, 46), radix: 16);
            int o = int.parse(raw.substring(34, 36), radix: 16);
            tpmsFl = e / 5.0;
            tpmsFr = j / 5.0;
            tpmsRl = t / 5.0;
            tpmsRr = o / 5.0;
          }
          break;
        case 'B002':
          if (raw.length >= 24) {
            int g = int.parse(raw.substring(18, 20), radix: 16);
            int h = int.parse(raw.substring(20, 22), radix: 16);
            int i = int.parse(raw.substring(22, 24), radix: 16);
            int odoRaw = (g << 16) | (h << 8) | i;
            if (odoRaw > 0) odometer = odoRaw.toDouble();
            if (raw.length >= 16) {
              fuelLevel = int.parse(raw.substring(14, 16), radix: 16);
            }
          }
          break;
      }
    } catch (e) {
      _log('[OBD] Parse Error (Mode 22): $e');
    }
  }

  void _startPollingTasks() {
    _fastPollTimer?.cancel();
    _slowPollTimer?.cancel();
    _minutePollTimer?.cancel();

    _fastPollTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (connectionState == ObdConnectionState.connected) {
        _enqueueCmd('010C');
        _enqueueCmd('010D');
        _processQueue();
      }
    });

    _slowPollTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (connectionState == ObdConnectionState.connected) {
        _enqueueCmd('015B');
      }
    });

    _minutePollTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      if (connectionState == ObdConnectionState.connected) {
        _enqueueCmd('0105');
        _enqueueCmd('ATSH7C6');
        _enqueueCmd('22B002');
        _enqueueCmd('ATSH7A0');
        _enqueueCmd('22C00B');
        _enqueueCmd('ATSH7DF');
      }
    });
  }

  void _cleanup() {
    connectionState = ObdConnectionState.disconnected;
    _dataSubscription?.cancel();
    _fastPollTimer?.cancel();
    _slowPollTimer?.cancel();
    _minutePollTimer?.cancel();
    _isWaitingForResponse = false;
    _commandQueue.clear();
    _methodChannel.invokeMethod('disconnect');
  }

  void dispose() {
    _cleanup();
    _logController.close();
  }
}
