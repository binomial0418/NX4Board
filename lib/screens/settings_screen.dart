import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/obd_spp_service.dart';
import '../providers/app_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _ipController = TextEditingController();
  final _portController = TextEditingController();

  bool _enableOcr = true;

  StreamSubscription? _logSub;
  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;

  List<Map<String, String>> _bondedDevices = [];
  bool _isScanning = false;

  // --- Maintenance Log ---
  StreamSubscription? _maintenanceLogSub;
  final List<String> _maintenanceLogs = [];
  final ScrollController _maintenanceScrollController = ScrollController();
  bool _maintenanceAutoScroll = true;

  @override
  void initState() {
    super.initState();
    _ipController.text = SettingsService().wsIp;
    _portController.text = SettingsService().wsPort;
    _enableOcr = SettingsService().enableOcr;

    // Load initial logs from service history
    _logs.addAll(ObdSppService().logHistory);

    _logSub = ObdSppService().logStream.listen((log) {
      if (mounted) {
        setState(() {
          _logs.add(log);
          if (_logs.length > 500) _logs.removeAt(0);
        });
        if (_autoScroll) {
          Future.delayed(const Duration(milliseconds: 100), () {
            if (_scrollController.hasClients) {
              _scrollController.animateTo(
                _scrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            }
          });
        }
      }
    });

    _refreshBondedDevices();

    // Maintenance logs
    _maintenanceLogs.addAll(ObdSppService().maintenanceLogHistory);
    _maintenanceLogSub = ObdSppService().maintenanceLogStream.listen((log) {
      if (mounted) {
        setState(() {
          _maintenanceLogs.add(log);
          if (_maintenanceLogs.length > 500) _maintenanceLogs.removeAt(0);
        });
        if (_maintenanceAutoScroll) {
          Future.delayed(const Duration(milliseconds: 100), () {
            if (_maintenanceScrollController.hasClients) {
              _maintenanceScrollController.animateTo(
                _maintenanceScrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            }
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    _logSub?.cancel();
    _maintenanceLogSub?.cancel();
    _scrollController.dispose();
    _maintenanceScrollController.dispose();
    super.dispose();
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

  Future<void> _exportMaintenanceLogs() async {
    try {
      if (_maintenanceLogs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('無維護日誌可供匯出')),
        );
        return;
      }

      final String timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final String fileName = 'NX4Board_MaintenanceLog_$timestamp.txt';
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/$fileName');

      final String content = _maintenanceLogs.join('\n');
      await file.writeAsString(content);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'NX4Board Maintenance Log Export',
      );
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
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blue[100]),
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
                          onPressed: _isScanning ? null : _refreshBondedDevices,
                          icon: _isScanning
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
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
                          ? const Center(child: Text('No paired devices found'))
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
            SizedBox(
              height: 300,
              child: Container(
                width: double.infinity,
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
                              icon: const Icon(Icons.download, color: Colors.green),
                              tooltip: '匯出日誌',
                              onPressed: _exportLogs,
                            ),
                            GestureDetector(
                              onTap: () => setState(() => _autoScroll = !_autoScroll),
                              child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: _autoScroll
                                  ? Colors.green.withOpacity(0.2)
                                  : Colors.grey.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: _autoScroll ? Colors.green : Colors.grey,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _autoScroll ? Icons.pause : Icons.play_arrow,
                                  color:
                                      _autoScroll ? Colors.green : Colors.grey,
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
            const SizedBox(height: 16),
            // --- 維護資訊獨立 LOG 區 ---
            Card(
              color: Colors.grey[900],
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('保養維護資訊 (CLU Raw/Parsed)',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.orangeAccent)),
                        Row(
                          children: [
                            Consumer<AppProvider>(
                              builder: (context, provider, child) {
                                return IconButton(
                                  icon: const Icon(Icons.search,
                                      color: Colors.orangeAccent),
                                  tooltip: '手動查詢保養資訊',
                                  onPressed: provider.obdConnectionState ==
                                          ObdConnectionState.connected
                                      ? () => provider.queryMaintenanceInfo()
                                      : null,
                                );
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.download,
                                  color: Colors.orangeAccent),
                              tooltip: '匯出維護日誌',
                              onPressed: _exportMaintenanceLogs,
                            ),
                            GestureDetector(
                                onTap: () => setState(() =>
                                    _maintenanceAutoScroll =
                                        !_maintenanceAutoScroll),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _maintenanceAutoScroll
                                        ? Colors.orange.withOpacity(0.2)
                                        : Colors.grey.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: _maintenanceAutoScroll
                                          ? Colors.orange
                                          : Colors.grey,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _maintenanceAutoScroll
                                            ? Icons.pause
                                            : Icons.play_arrow,
                                        color: _maintenanceAutoScroll
                                            ? Colors.orange
                                            : Colors.grey,
                                        size: 14,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        _maintenanceAutoScroll
                                            ? '自動捲動 ON'
                                            : '自動捲動 OFF',
                                        style: TextStyle(
                                          color: _maintenanceAutoScroll
                                              ? Colors.orange
                                              : Colors.grey,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                )),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 200,
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: _maintenanceLogs.isEmpty
                          ? const Center(
                              child: Text('目前尚無維護資料。',
                                  style: TextStyle(color: Colors.grey)))
                          : ListView.builder(
                              controller: _maintenanceScrollController,
                              itemCount: _maintenanceLogs.length,
                              itemBuilder: (context, index) {
                                final log = _maintenanceLogs[index];
                                Color textColor = Colors.white;
                                if (log.contains('Parsed:')) {
                                  textColor = Colors.orangeAccent;
                                } else if (log.contains('Raw:')) {
                                  textColor = Colors.grey;
                                }
                                return Text(
                                  log,
                                  style: TextStyle(
                                      color: textColor,
                                      fontFamily: 'monospace',
                                      fontSize: 12),
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
                  'Version 1.0.1+1',
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
    );
  }
}
