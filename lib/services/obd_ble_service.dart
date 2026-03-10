import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'settings_service.dart';

enum ObdConnectionState {
  disconnected,
  scanning,
  connecting,
  initializing,
  connected
}

class ObdBleService {
  static final ObdBleService _instance = ObdBleService._internal();
  factory ObdBleService() => _instance;
  ObdBleService._internal();

  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _readChar;
  StreamSubscription? _deviceConnectionSub;
  StreamSubscription? _rxSub;

  ObdConnectionState connectionState = ObdConnectionState.disconnected;

  // Log Stream For Dashboard
  final _logController = StreamController<String>.broadcast();
  Stream<String> get logStream => _logController.stream;

  void _log(String msg) {
    debugPrint(msg);
    _logController.add(msg);
  }

  // A string buffer to accumulate chunked BLE responses
  String _rxBuffer = '';

  // Data mapping
  int? rpm;
  int? speed;
  int? coolantTemp;
  double? voltage;
  int? hevSoc;

  // New Additions: Odometer and Fuel
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

  // Simple queue for AT/PID commands to avoid MTU overlaps
  final List<String> _commandQueue = [];

  // Initialize service
  Future<void> init() async {
    FlutterBluePlus.setLogLevel(LogLevel.info);

    // Listen to adapter state
    FlutterBluePlus.adapterState.listen((BluetoothAdapterState state) {
      if (state == BluetoothAdapterState.on) {
        startScan();
      } else {
        _cleanup();
      }
    });
  }

  void startScan() async {
    if (connectionState != ObdConnectionState.disconnected) return;

    connectionState = ObdConnectionState.scanning;
    _log('[OBD] Starting BLE scan...');

    String savedMac = SettingsService().obdMac;

    // Setup scan listener
    var subscription = FlutterBluePlus.onScanResults.listen((results) {
      if (results.isNotEmpty) {
        ScanResult r = results.last;
        bool shouldConnect = false;

        if (savedMac.isNotEmpty && r.device.remoteId.str == savedMac) {
          shouldConnect = true;
        } else if (savedMac.isEmpty &&
            (r.device.platformName.toUpperCase().contains('OBD') ||
                r.device.platformName.toUpperCase().contains('V-LINK'))) {
          shouldConnect = true;
        }

        if (shouldConnect) {
          _log(
              '[OBD] Found target device: ${r.device.platformName} (${r.device.remoteId})');
          FlutterBluePlus.stopScan();
          connectToDevice(r.device);
        }
      }
    });

    // Stop scanning after 15 seconds if not found
    FlutterBluePlus.cancelWhenScanComplete(subscription);
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

    if (connectionState == ObdConnectionState.scanning) {
      connectionState = ObdConnectionState.disconnected;
      _log('[OBD] Scan timeout, no device found.');
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    _device = device;
    connectionState = ObdConnectionState.connecting;

    _deviceConnectionSub =
        _device!.connectionState.listen((BluetoothConnectionState state) async {
      if (state == BluetoothConnectionState.connected) {
        _log('[OBD] Connected directly! Discovering services...');
        await _discoverServices();
      } else if (state == BluetoothConnectionState.disconnected) {
        _log('[OBD] Disconnected.');
        _cleanup();
        // Wait and reconnect
        Future.delayed(const Duration(seconds: 5), () => startScan());
      }
    });

    try {
      await _device!
          .connect(license: License.free, timeout: const Duration(seconds: 10));
    } catch (e) {
      _log('[OBD] Connect exception: $e');
      _cleanup();
    }
  }

  Future<void> _discoverServices() async {
    if (_device == null) return;

    List<BluetoothService> services = await _device!.discoverServices();

    // Typically BLE SPP modules use FFE0 for service and FFE1 for RX/TX
    // Or sometimes custom UUIDs.
    for (BluetoothService service in services) {
      for (BluetoothCharacteristic c in service.characteristics) {
        // Find a characteristic that supports Both Notify/Read AND Write
        if ((c.properties.notify || c.properties.read) &&
            (c.properties.write || c.properties.writeWithoutResponse)) {
          _readChar = c;
          _writeChar = c;
          _log('[OBD] Found TX/RX Characteristic: ${c.uuid}');
          break;
        }
      }
      if (_writeChar != null) break;
    }

    if (_writeChar != null && _readChar != null) {
      await _readChar!.setNotifyValue(true);
      _rxSub = _readChar!.onValueReceived.listen(_onDataReceived);

      _startObdInitSequence();
    } else {
      _log('[OBD] Failed to find suitable TX/RX characteristic.');
      _device!.disconnect();
    }
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

  // Enqueue AT command
  void _enqueueCmd(String cmd) {
    if (!cmd.endsWith('\r')) cmd += '\r';
    _commandQueue.add(cmd);
  }

  Future<void> _processQueue() async {
    if (_commandQueue.isEmpty) {
      // If queue is empty and we were initializing, we are done!
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
    _rxBuffer = ''; // clear buffer before send

    // Add small delay between commands
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      _log('[OBD TX] ${cmd.trim()}');
      await _writeChar!.write(cmd.codeUnits, withoutResponse: true);
    } catch (e) {
      _log('[OBD] Write error: $e');
      _isWaitingForResponse = false;
    }

    // The timeout for receiving response (handled heuristically in _onDataReceived by listening to '>')
    // We can set a fallback timer to unblock queue if ELM327 drops the ball.
    Timer(const Duration(seconds: 3), () {
      if (_isWaitingForResponse) {
        _log('[OBD] Timeout waiting for ">". Unblocking queue.');
        _isWaitingForResponse = false;
        _processQueue();
      }
    });
  }

  void _onDataReceived(List<int> value) {
    String chunk = String.fromCharCodes(value);
    _rxBuffer += chunk;

    // ELM327 prompt indicates end of response message
    if (_rxBuffer.contains('>')) {
      String responseStr = _rxBuffer
          .replaceAll('>', '')
          .trim()
          .replaceAll('\r', '')
          .replaceAll('\n', '');
      if (responseStr.isNotEmpty) {
        _log('[OBD RX] $responseStr');
        _parseObdResponse(responseStr);
      }

      _isWaitingForResponse = false;
      _processQueue();
    }
  }

  void _parseObdResponse(String hexStr) {
    // ELM327 usually returns "41 0C 1A F8" with spaces, remove spaces
    String raw = hexStr.replaceAll(' ', '');

    if (raw.contains('NODATA') || raw.contains('ERROR') || raw.contains('?')) {
      return;
    }

    // Try finding mode 41 response (Current Data - Mode 01)
    if (raw.startsWith('41')) {
      return _parseMode01(raw);
    }

    // Try finding mode 62 response (Enhanced Data - Mode 22)
    if (raw.startsWith('62')) {
      return _parseMode22(raw);
    }
  }

  void _parseMode01(String raw) {
    if (raw.length < 6) return;
    String pid = raw.substring(2, 4);

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
  }

  void _parseMode22(String raw) {
    if (raw.length < 8) return;
    String pid = raw.substring(2, 6);

    switch (pid) {
      case 'C00B': // TPMS
        // 確保有足夠長度的資料來擷取 E, J, T, O (根據 index)
        if (raw.length >= 48) {
          int e = int.parse(raw.substring(14, 16), radix: 16); // index 7
          int j = int.parse(raw.substring(24, 26), radix: 16); // index 12
          int t = int.parse(raw.substring(44, 46), radix: 16); // index 22
          int o = int.parse(raw.substring(34, 36), radix: 16); // index 17

          tpmsFl = e / 5.0;
          tpmsFr = j / 5.0;
          tpmsRl = t / 5.0;
          tpmsRr = o / 5.0;
        }
        break;
      case 'B002': // Odometer & Fuel Level
        if (raw.length >= 24) {
          // Needs at least index 11 (24 hex characters)
          // Odometer is bytes G:H:I -> index 9,10,11
          int g = int.parse(raw.substring(18, 20), radix: 16);
          int h = int.parse(raw.substring(20, 22), radix: 16);
          int i = int.parse(raw.substring(22, 24), radix: 16);
          int odoRaw = (g << 16) | (h << 8) | i;

          if (odoRaw > 0) {
            odometer = odoRaw.toDouble();
          }

          // Fuel is byte E -> index 7
          if (raw.length >= 16) {
            fuelLevel = int.parse(raw.substring(14, 16), radix: 16);
          }
        }
        break;
    }
  }

  void _startPollingTasks() {
    _fastPollTimer?.cancel();
    _slowPollTimer?.cancel();
    _minutePollTimer?.cancel();

    // 1 Hz Polling Task (RPM, Speed)
    _fastPollTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (connectionState == ObdConnectionState.connected) {
        _enqueueCmd('010C'); // RPM
        _enqueueCmd('010D'); // Speed
        _processQueue();
      }
    });

    // 10 Sec Polling Task (Battery SOC Only)
    _slowPollTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (connectionState == ObdConnectionState.connected) {
        _enqueueCmd('015B'); // HEV SOC
      }
    });

    // 60 Sec Polling Task (Advanced PID and Others)
    _minutePollTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      if (connectionState == ObdConnectionState.connected) {
        _enqueueCmd('0105'); // Coolant (Moved to 60s)

        // --- Mode 22: Odometer & Fuel ---
        _enqueueCmd('ATSH7C6'); // Header for Dashboard/Cluster
        _enqueueCmd('22B002');

        // --- Mode 22: TPMS ---
        _enqueueCmd('ATSH7A0'); // Header for TPMS Module
        _enqueueCmd('22C00B');

        // Reset Header back to standard OBD (0x7DF) for 1Hz PID
        _enqueueCmd('ATSH7DF');
      }
    });
  }

  void _cleanup() {
    connectionState = ObdConnectionState.disconnected;
    _rxSub?.cancel();
    _deviceConnectionSub?.cancel();
    _fastPollTimer?.cancel();
    _slowPollTimer?.cancel();
    _minutePollTimer?.cancel();
    _isWaitingForResponse = false;
    _commandQueue.clear();
  }
}
