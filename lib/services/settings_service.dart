import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  SharedPreferences? _prefs;

  String get wsIp => _prefs?.getString('ws_ip') ?? '192.168.4.1';
  String get wsPort => _prefs?.getString('ws_port') ?? '81';
  String get obdMac => _prefs?.getString('obd_mac') ?? '';

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  Future<void> setWsIp(String ip) async {
    await _prefs?.setString('ws_ip', ip);
  }

  Future<void> setWsPort(String port) async {
    await _prefs?.setString('ws_port', port);
  }

  Future<void> setObdMac(String mac) async {
    await _prefs?.setString('obd_mac', mac);
  }
}
