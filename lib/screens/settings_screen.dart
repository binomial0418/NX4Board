import 'dart:async';
import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../services/obd_spp_service.dart';

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

  List<Map<String, String>> _bondedDevices = [];
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _ipController.text = SettingsService().wsIp;
    _portController.text = SettingsService().wsPort;
    _enableOcr = SettingsService().enableOcr;

    _logSub = ObdSppService().logStream.listen((log) {
      if (mounted) {
        setState(() {
          _logs.add(log);
          if (_logs.length > 200) _logs.removeAt(0);
        });
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
    });

    _refreshBondedDevices();
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    _logSub?.cancel();
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
                subtitle: const Text('關閉時相機將不會運作，且儀表板隱藏速限指示。'),
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
                        ElevatedButton(
                          onPressed: _saveWifiSettings,
                          child: const Text('Save'),
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
                    const Text('OBD Terminal Logs',
                        style: TextStyle(
                            color: Colors.green, fontWeight: FontWeight.bold)),
                    const Divider(color: Colors.green),
                    Expanded(
                      child: ListView.builder(
                        controller: _scrollController,
                        itemCount: _logs.length,
                        itemBuilder: (context, index) {
                          return Text(
                            _logs[index],
                            style: const TextStyle(
                              color: Colors.greenAccent,
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
          ],
        ),
      ),
    );
  }
}
