import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/settings_service.dart';
import '../services/obd_spp_service.dart';
import '../services/tts_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _ipController = TextEditingController();
  final _portController = TextEditingController();

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

  @override
  void initState() {
    super.initState();
    _ipController.text = SettingsService().wsIp;
    _portController.text = SettingsService().wsPort;
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
    _logSub?.cancel();
    _volumeSub?.cancel();
    _scrollController.dispose();
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
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('發送失敗: $e')),
        );
    }
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
                                            ? Colors.green.withOpacity(0.2)
                                            : Colors.grey.withOpacity(0.2),
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
                          color: Colors.grey.withOpacity(0.6),
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
