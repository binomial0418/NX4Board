import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/settings_service.dart';
import '../services/obd_spp_service.dart';
import '../services/tts_service.dart';
import '../services/screen_recorder_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _ipController = TextEditingController();
  final _portController = TextEditingController();

  // ESP32-P4 儀表顯示器（第二通道）
  final _esp32IpController = TextEditingController();
  final _esp32PortController = TextEditingController();
  bool _esp32Enabled = false;

  // ESP32 模擬推送（設定頁的連續測試）
  Timer? _esp32SimTimer;
  WebSocketChannel? _esp32SimChannel;
  StreamSubscription? _esp32SimSub;
  bool _esp32SimRunning = false;
  int _esp32SimTick = 0;
  String _esp32SimStatus = '';

  // ESP32 螢幕亮度（依大燈狀態切換）
  int _brightnessDay = 100;
  int _brightnessLow = 40;
  int _brightnessHigh = 25;

  bool _enableOcr = true;
  double _ttsVolume = 1.0;
  String _appVersion = 'Loading...';

  StreamSubscription? _logSub;
  StreamSubscription? _volumeSub;
  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;

  List<Map<String, String>> _bondedDevices = [];
  bool _isScanning = false;

  bool _scrollPending = false;

  bool _isRecording = false;
  int _remainingSeconds = 0;
  Timer? _recordingCountdownTimer;

  @override
  void initState() {
    super.initState();
    _ipController.text = SettingsService().wsIp;
    _portController.text = SettingsService().wsPort;
    _esp32IpController.text = SettingsService().esp32Ip;
    _esp32PortController.text = SettingsService().esp32Port;
    _esp32Enabled = SettingsService().esp32Enabled;
    _brightnessDay = SettingsService().esp32BrightnessDay;
    _brightnessLow = SettingsService().esp32BrightnessLowBeam;
    _brightnessHigh = SettingsService().esp32BrightnessHighBeam;
    _enableOcr = SettingsService().enableOcr;
    _ttsVolume = SettingsService().ttsVolume;

    _initPackageInfo();
    _initSystemVolume();

    // Load initial logs from service history
    _logs.addAll(ObdSppService().logHistory);

    _logSub = ObdSppService().logStream.listen((log) {
      if (mounted) {
        setState(() {
          _logs.add(log);
          if (_logs.length > 500) _logs.removeAt(0);
        });
        if (_autoScroll && !_scrollPending) {
          _scrollPending = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollPending = false;
            if (_autoScroll && _scrollController.hasClients) {
              _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
            }
          });
        }
      }
    });

    _refreshBondedDevices();
  }

  /// 初始化系統音量並監聽變化
  Future<void> _initSystemVolume() async {
    // 從系統讀取初始音量值
    final initialVolume = await SettingsService().getSystemVolume();
    if (mounted) {
      setState(() => _ttsVolume = initialVolume);
    }

    // 監聽系統音量變化（硬體按鍵或其他來源改變時）
    _volumeSub = SettingsService().volumeChangeStream.listen((volume) {
      if (mounted) {
        setState(() => _ttsVolume = volume);
      }
    });
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    _esp32IpController.dispose();
    _esp32PortController.dispose();
    // 一定要停：否則 esp32SimulationActive 會卡在 true，
    // 回到儀表頁後第二通道就永遠不再推送
    _stopEsp32Simulation(null);
    _logSub?.cancel();
    _volumeSub?.cancel();
    _scrollController.dispose();
    _recordingCountdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _initPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _appVersion = '${info.version}+${info.buildNumber}';
      });
    }
  }

  Future<void> _refreshBondedDevices() async {
    setState(() => _isScanning = true);
    final devices = await ObdSppService().getBondedDevices();
    if (mounted) {
      setState(() {
        _bondedDevices = devices;
        _isScanning = false;
      });
    }
  }

  void _saveWifiSettings() {
    SettingsService().setWsIp(_ipController.text.trim());
    SettingsService().setWsPort(_portController.text.trim());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('WiFi Settings Saved')),
    );
  }

  void _sendTestWsData() async {
    final ip = _ipController.text.trim();
    final port = _portController.text.trim();
    
    if (ip.isEmpty || port.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('請先輸入 IP 與 Port')),
        );
        return;
    }

    try {
        final channel = WebSocketChannel.connect(Uri.parse('ws://$ip:$port'));
        
        final testData = {
            "_type": "location",
            "tid": "obd",
            "fuel": 66,
            "mileage": 23456,
            "tires": {
                "fl": 33,
                "fr": 34,
                "rl": 35,
                "rr": 36
            },
            "speed": 80,
            "rpm": 1200,
            "temperature": 85,
            "battery": 60.5
        };
        
        final jsonString = jsonEncode(testData);
        channel.sink.add(jsonString);
        
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('測試資料已發送: $jsonString')),
        );
        
        // 發送後短暫延遲後關閉，避免 server 端來不及處理
        await Future.delayed(const Duration(seconds: 1));
        await channel.sink.close();
        
    } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('發送失敗: $e')),
        );
    }
  }

  // ── ESP32-P4 儀表顯示器（第二通道）─────────────────────────────────────
  void _saveEsp32Settings() {
    SettingsService().setEsp32Ip(_esp32IpController.text.trim());
    SettingsService().setEsp32Port(_esp32PortController.text.trim());
    SettingsService().setEsp32Enabled(_esp32Enabled);
    SettingsService().setEsp32BrightnessDay(_brightnessDay);
    SettingsService().setEsp32BrightnessLowBeam(_brightnessLow);
    SettingsService().setEsp32BrightnessHighBeam(_brightnessHigh);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('ESP32 儀表設定已儲存')),
    );
  }

  // ── ESP32 模擬推送 ───────────────────────────────────────────────────
  // 連續送出一段 40 秒的模擬行程（每 200ms 一筆，跑完自動循環），
  // 方便在沒有接 OBD 的情況下驗證 ESP32 儀表的動態表現。
  //
  // 時序（tick，每秒 5 tick）：
  //   0- 25  怠速          25-100  加速 0→120     100-125 定速 120
  // 125-150  減速 120→60   150-175 定速 60        175-200 減速至停止
  // 速限 60 → 90 → 50；100 tick 起開近燈、130-150 開遠燈；
  // 130-165 tick 出現測速照相警示。
  static const int _simCycleTicks = 200;
  static const Duration _simInterval = Duration(milliseconds: 200);

  int _simSpeed(int t) {
    if (t < 0) return 0;
    t %= _simCycleTicks;
    if (t < 25) return 0;
    if (t < 100) return ((t - 25) * 120 / 75).round();
    if (t < 125) return 120;
    if (t < 150) return (120 - (t - 125) * 60 / 25).round();
    if (t < 175) return 60;
    return (60 - (t - 175) * 60 / 25).round().clamp(0, 60);
  }

  /// 依車速推算轉速，並用檔位造出換檔的鋸齒感
  int _simRpm(int speed) {
    if (speed == 0) return 780;
    final gear = (speed ~/ 30).clamp(0, 3);
    return 1000 + ((speed - gear * 30) * 95).round();
  }

  Map<String, dynamic> _buildSimFrame(int t) {
    final cycle = t % _simCycleTicks;
    final speed = _simSpeed(t);
    // 增壓由加速度推得（加速為正壓、減速為真空）。
    // 取 1 秒（5 tick）的位移再平均，逐 tick 相減會因四捨五入
    // 在 1/2 km/h 之間跳動，畫面上的增壓值會抖。
    final turbo =
        ((speed - _simSpeed(t - 5)) / 5 * 0.35).clamp(-1.0, 1.0);
    final speedLimit = cycle < 100 ? 60 : (cycle < 150 ? 90 : 50);
    final lowBeam = cycle >= 100 && cycle < 180;
    final highBeam = cycle >= 130 && cycle < 150;
    final cameraActive = cycle >= 130 && cycle < 165;
    final now = DateTime.now();

    return {
      "_type": "esp32_dash",
      "speed": speed,
      "rpm": _simRpm(speed),
      "coolant": (70 + cycle * 0.11).clamp(70, 92).round(),
      "soc": double.parse((65.5 - cycle * 0.05).toStringAsFixed(1)),
      "fuel": 50 - cycle ~/ 100,
      "speed_limit": speedLimit,
      // 用絕對 tick 而非 cycle，否則每跑完一圈里程會倒退
      "odo": 33676 + t ~/ 40,
      "turbo": double.parse(turbo.toStringAsFixed(2)),
      "time": DateFormat('HH:mm:ss').format(now),
      "date": '${DateFormat('MM/dd').format(now)} ${_weekdayZh(now)}',
      "tires": {
        "fl": 34 + (cycle ~/ 60) % 2,
        "fr": 34,
        "rl": 33,
        "rr": 33,
      },
      "camera": {"active": cameraActive, "limit": 50},
      "lights": {"low": lowBeam, "high": highBeam},
      "brightness": SettingsService()
          .esp32BrightnessFor(lowBeam: lowBeam, highBeam: highBeam),
    };
  }

  static String _weekdayZh(DateTime t) {
    const names = ['週一', '週二', '週三', '週四', '週五', '週六', '週日'];
    return names[t.weekday - 1];
  }

  Future<void> _toggleEsp32Simulation() async {
    if (_esp32SimRunning) {
      _stopEsp32Simulation('模擬已停止');
      return;
    }

    final ip = _esp32IpController.text.trim();
    final port = _esp32PortController.text.trim();
    if (ip.isEmpty || port.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('請先輸入 ESP32 IP 與 Port')),
      );
      return;
    }

    try {
      _esp32SimChannel = WebSocketChannel.connect(Uri.parse('ws://$ip:$port'));
      _esp32SimSub = _esp32SimChannel!.stream.listen(
        (_) {},
        onDone: () => _stopEsp32Simulation('ESP32 連線中斷'),
        onError: (e) => _stopEsp32Simulation('連線錯誤: $e'),
        cancelOnError: true,
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('連線失敗: $e')),
      );
      return;
    }

    // 模擬期間讓儀表頁暫停推送，否則兩邊會互相覆蓋
    SettingsService().esp32SimulationActive = true;
    _esp32SimTick = 0;

    setState(() {
      _esp32SimRunning = true;
      _esp32SimStatus = '模擬中…';
    });

    _esp32SimTimer = Timer.periodic(_simInterval, (_) => _pushSimFrame());
    _pushSimFrame();
  }

  void _pushSimFrame() {
    if (!_esp32SimRunning || _esp32SimChannel == null) return;

    final frame = _buildSimFrame(_esp32SimTick);
    try {
      _esp32SimChannel!.sink.add(jsonEncode(frame));
    } catch (e) {
      _stopEsp32Simulation('發送失敗: $e');
      return;
    }

    _esp32SimTick++;

    // 狀態文字每秒才更新一次。每 200ms setState 會讓整個設定頁
    // （含底下的日誌列表）每秒重建 5 次，沒必要。
    if (_esp32SimTick % 5 != 0 || !mounted) return;
    final cycle = _esp32SimTick % _simCycleTicks;
    final cam = (frame["camera"] as Map)["active"] == true;
    setState(() {
      _esp32SimStatus = '模擬中 ${cycle ~/ 5}/40s — '
          '${frame["speed"]} km/h  ${frame["rpm"]} rpm  '
          '${frame["turbo"]} bar${cam ? "  ⚠ 測速照相" : ""}';
    });
  }

  /// 停止模擬。reason 為 null 時不更新 UI（供 dispose 呼叫）。
  void _stopEsp32Simulation(String? reason) {
    _esp32SimTimer?.cancel();
    _esp32SimTimer = null;
    _esp32SimSub?.cancel();
    _esp32SimSub = null;
    _esp32SimChannel?.sink.close();
    _esp32SimChannel = null;
    SettingsService().esp32SimulationActive = false;

    if (reason == null) {
      _esp32SimRunning = false;
      return;
    }
    if (!mounted) {
      _esp32SimRunning = false;
      return;
    }
    setState(() {
      _esp32SimRunning = false;
      _esp32SimStatus = reason;
    });
  }

  /// 立即把指定亮度推送到 ESP32 供實機確認。
  ///
  /// 帶上 brightness_hold_ms，讓 ESP32 在該期間忽略儀表資料裡的亮度欄位，
  /// 否則儀表畫面每 200ms 的推送會立刻把測試值蓋掉。
  Future<void> _sendBrightnessTest(int percent) async {
    final ip = _esp32IpController.text.trim();
    final port = _esp32PortController.text.trim();

    if (ip.isEmpty || port.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('請先輸入 ESP32 IP 與 Port')),
      );
      return;
    }

    try {
      final channel = WebSocketChannel.connect(Uri.parse('ws://$ip:$port'));
      channel.sink.add(jsonEncode({
        "_type": "esp32_dash",
        "brightness": percent,
        "brightness_hold_ms": 5000,
      }));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已送出亮度 $percent%（保持 5 秒）')),
      );

      await Future.delayed(const Duration(seconds: 1));
      await channel.sink.close();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('亮度發送失敗: $e')),
      );
    }
  }

  /// 單列亮度設定：說明文字 + 滑桿 + 百分比 + 測試按鈕
  Widget _buildBrightnessRow({
    required IconData icon,
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
    required Future<void> Function(int) onSave,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 108,
          child: Row(
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
        Expanded(
          child: Slider(
            value: value.toDouble(),
            min: 0,
            max: 100,
            divisions: 20,
            label: '$value%',
            onChanged: (v) => onChanged(v.round()),
            onChangeEnd: (v) async => await onSave(v.round()),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text('$value%',
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500)),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: () => _sendBrightnessTest(value),
          child: const Text('測試'),
        ),
      ],
    );
  }

  Future<void> _exportLogs() async {
    try {
      if (_logs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('無日誌可供匯出')),
        );
        return;
      }

      final String timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final String fileName = 'NX4Board_log_$timestamp.txt';
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/$fileName');

      final String content = _logs.join('\n');
      await file.writeAsString(content);

      final result = await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'NX4Board Log Export',
      );

      if (result.status == ShareResultStatus.success) {
        debugPrint('Log shared successfully');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('匯出失敗: $e')),
      );
    }
  }

  void _connectDevice(String address, String name) async {
    await SettingsService().setObdMac(address);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Connecting to $name...')),
    );
    ObdSppService().connectToDevice(address);
  }

  Future<void> _startScreenRecording() async {
    if (_isRecording) return;

    setState(() {
      _isRecording = true;
      _remainingSeconds = 180;
    });

    // 啟動倒數計時
    _recordingCountdownTimer?.cancel();
    _recordingCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() => _remainingSeconds--);
      }
      if (_remainingSeconds <= 0) {
        timer.cancel();
        _stopScreenRecording();
      }
    });

    // 呼叫原生開始錄影
    final result = await ScreenRecorderService().startRecording();
    if (!result && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('錄影啟動失敗，請確認權限')),
      );
      setState(() => _isRecording = false);
      _recordingCountdownTimer?.cancel();
    } else if (result && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('錄影已開始，180 秒後自動停止')),
      );
    }
  }

  Future<void> _stopScreenRecording() async {
    if (!_isRecording) return;

    _recordingCountdownTimer?.cancel();
    final result = await ScreenRecorderService().stopRecording();

    if (mounted) {
      setState(() => _isRecording = false);
      if (result) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('錄影已保存至相簿')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('錄影停止失敗')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Colors.blueGrey,
      ),
      body: SingleChildScrollView(
        child: Center(
          child: FractionallySizedBox(
            widthFactor: 0.8,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.videocam, size: 24),
                              SizedBox(width: 8),
                              Text('螢幕錄影',
                                  style: TextStyle(
                                      fontSize: 16, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text('錄製 App 執行畫面 3 分鐘，1080P 30FPS，自動儲存至相簿'),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              ElevatedButton.icon(
                                onPressed: _isRecording ? null : _startScreenRecording,
                                icon: Icon(_isRecording ? Icons.stop_circle : Icons.circle),
                                label: Text(_isRecording ? '錄影中...' : '開始錄影'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _isRecording ? Colors.redAccent : Colors.blueAccent,
                                ),
                              ),
                              if (_isRecording) ...[
                                const SizedBox(width: 16),
                                Text(
                                  '剩餘: $_remainingSeconds 秒',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.redAccent,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: SwitchListTile(
                      title: const Text('啟用速限辨識',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: const Text('關閉時測速點偵測功能將停止運作，且儀表板隱藏速限指示。'),
                      value: _enableOcr,
                      onChanged: (val) async {
                        setState(() => _enableOcr = val);
                        await SettingsService().setEnableOcr(val);
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Consumer<AppProvider>(
                      builder: (context, provider, child) => SwitchListTile(
                        title: const Text('UI 模擬模式 (Demo Mode)',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: const Text('啟動後將使用模擬數據測試 UI 效果，離線狀態亦可預覽三位數時速。'),
                        secondary: const Icon(Icons.speed, color: Colors.blueAccent),
                        value: provider.isDemoEnabled,
                        onChanged: (val) {
                          provider.toggleDemoMode();
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.volume_up, size: 24),
                              const SizedBox(width: 8),
                              const Text('TTS 音量控制',
                                  style: TextStyle(
                                      fontSize: 16, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: Slider(
                                  value: _ttsVolume,
                                  min: 0.0,
                                  max: 1.0,
                                  divisions: 10,
                                  label: '${(_ttsVolume * 100).toStringAsFixed(0)}%',
                                  onChanged: (value) {
                                    setState(() => _ttsVolume = value);
                                  },
                                  onChangeEnd: (value) async {
                                    // 同步到系統音量，只需調用一次
                                    await TtsService().setVolumeAndPreview(value);
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${(_ttsVolume * 100).toStringAsFixed(0)}%',
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('WebSocket (ESP32) Settings',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: TextField(
                                  controller: _ipController,
                                  decoration: const InputDecoration(
                                    labelText: 'WS IP Address',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 1,
                                child: TextField(
                                  controller: _portController,
                                  decoration: const InputDecoration(
                                    labelText: 'Port',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Column(
                                children: [
                                  ElevatedButton(
                                    onPressed: _saveWifiSettings,
                                    child: const Text('Save'),
                                  ),
                                  const SizedBox(height: 4),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.blue[100]),
                                    onPressed: _sendTestWsData,
                                    child: const Text('WS Test'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // ── ESP32-P4 儀表顯示器（第二通道，高頻即時推送）──────────
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('ESP32-P4 儀表顯示器 (第二通道)',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                          const Text(
                            '獨立於上方 MQTT 後送通道，OBD 每次輪詢即時推送儀表資料。'
                            '「模擬」會連續送出 40 秒的行程（加速→定速→測速照相→減速）'
                            '並循環，期間儀表頁暫停推送',
                            style:
                                TextStyle(fontSize: 12, color: Colors.black54),
                          ),
                          const SizedBox(height: 8),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('啟用 ESP32 儀表推送'),
                            value: _esp32Enabled,
                            onChanged: (val) async {
                              setState(() => _esp32Enabled = val);
                              await SettingsService().setEsp32Enabled(val);
                            },
                          ),
                          Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: TextField(
                                  controller: _esp32IpController,
                                  keyboardType: TextInputType.text,
                                  decoration: const InputDecoration(
                                    labelText: 'ESP32 IP Address',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 1,
                                child: TextField(
                                  controller: _esp32PortController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Port',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Column(
                                children: [
                                  ElevatedButton(
                                    onPressed: _saveEsp32Settings,
                                    child: const Text('Save'),
                                  ),
                                  const SizedBox(height: 4),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _esp32SimRunning
                                          ? Colors.red[100]
                                          : Colors.green[100],
                                    ),
                                    onPressed: _toggleEsp32Simulation,
                                    child:
                                        Text(_esp32SimRunning ? '停止' : '模擬'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          if (_esp32SimStatus.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                _esp32SimStatus,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _esp32SimRunning
                                      ? Colors.green[800]
                                      : Colors.black54,
                                ),
                              ),
                            ),
                          const Divider(height: 24),
                          // ── 螢幕亮度：依 OBD 大燈狀態自動切換 ──────────
                          const Text('螢幕亮度 (依大燈狀態切換)',
                              style: TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.bold)),
                          const Text(
                            'OBD PID 22BC09 讀取近燈/遠燈，遠燈優先於近燈；'
                            '按「測試」立即推送該亮度至 ESP32 並保持 5 秒',
                            style:
                                TextStyle(fontSize: 12, color: Colors.black54),
                          ),
                          const SizedBox(height: 4),
                          _buildBrightnessRow(
                            icon: Icons.wb_sunny_outlined,
                            label: '大燈關閉',
                            value: _brightnessDay,
                            onChanged: (v) =>
                                setState(() => _brightnessDay = v),
                            onSave: SettingsService().setEsp32BrightnessDay,
                          ),
                          _buildBrightnessRow(
                            icon: Icons.light_mode_outlined,
                            label: '近燈開啟',
                            value: _brightnessLow,
                            onChanged: (v) =>
                                setState(() => _brightnessLow = v),
                            onSave: SettingsService().setEsp32BrightnessLowBeam,
                          ),
                          _buildBrightnessRow(
                            icon: Icons.highlight_outlined,
                            label: '遠燈開啟',
                            value: _brightnessHigh,
                            onChanged: (v) =>
                                setState(() => _brightnessHigh = v),
                            onSave:
                                SettingsService().setEsp32BrightnessHighBeam,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Bluetooth OBD2 (Bonded)',
                                  style: TextStyle(
                                      fontSize: 16, fontWeight: FontWeight.bold)),
                              ElevatedButton.icon(
                                onPressed:
                                    _isScanning ? null : _refreshBondedDevices,
                                icon: _isScanning
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white))
                                    : const Icon(Icons.refresh),
                                label: const Text('Refresh'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text('Select a paired ELM327 device to connect.'),
                          const SizedBox(height: 8),
                          Container(
                            height: 150,
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: _bondedDevices.isEmpty
                                ? const Center(
                                    child: Text('No paired devices found'))
                                : ListView.builder(
                                    itemCount: _bondedDevices.length,
                                    itemBuilder: (context, index) {
                                      final device = _bondedDevices[index];
                                      final name = device['name'] ?? 'Unknown';
                                      final mac = device['address'] ?? '';
                                      final savedMac = SettingsService().obdMac;

                                      return ListTile(
                                        title: Text(name),
                                        subtitle: Text(mac),
                                        trailing: savedMac == mac
                                            ? const Icon(Icons.check_circle,
                                                color: Colors.green)
                                            : ElevatedButton(
                                                onPressed: () =>
                                                    _connectDevice(mac, name),
                                                child: const Text('Connect'),
                                              ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Container(
                      height: 300,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('OBD Terminal Logs',
                                  style: TextStyle(
                                      color: Colors.green,
                                      fontWeight: FontWeight.bold)),
                              Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.download,
                                        color: Colors.green),
                                    tooltip: '匯出日誌',
                                    onPressed: _exportLogs,
                                  ),
                                  GestureDetector(
                                    onTap: () =>
                                        setState(() => _autoScroll = !_autoScroll),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: _autoScroll
                                            ? Colors.green.withValues(alpha: 0.2)
                                            : Colors.grey.withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: _autoScroll
                                              ? Colors.green
                                              : Colors.grey,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            _autoScroll
                                                ? Icons.pause
                                                : Icons.play_arrow,
                                            color: _autoScroll
                                                ? Colors.green
                                                : Colors.grey,
                                            size: 14,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            _autoScroll ? '自動捲動 ON' : '自動捲動 OFF',
                                            style: TextStyle(
                                              color: _autoScroll
                                                  ? Colors.green
                                                  : Colors.grey,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const Divider(color: Colors.green),
                          Expanded(
                            child: ListView.builder(
                              controller: _scrollController,
                              itemCount: _logs.length,
                              itemBuilder: (context, index) {
                                final log = _logs[index];
                                Color textColor = Colors.greenAccent;
                                if (log.contains('[Parser Error]')) {
                                  textColor = Colors.redAccent;
                                } else if (log.contains('[Parser Result]')) {
                                  textColor = Colors.lightGreenAccent;
                                } else if (log.contains('[Parser TX]')) {
                                  textColor = Colors.cyanAccent;
                                } else if (log.contains('[Parser RX Raw]')) {
                                  textColor = Colors.yellowAccent;
                                }
                                return Text(
                                  log,
                                  style: TextStyle(
                                    color: textColor,
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: Text(
                        'Version $_appVersion',
                        style: TextStyle(
                          color: Colors.grey.withValues(alpha: 0.6),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
