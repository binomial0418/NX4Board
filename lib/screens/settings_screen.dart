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
import '../services/traffic_service.dart';
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
  bool _trafficEnabled = true;
  bool _trafficVoice = true;
  double _ttsVolume = 1.0;
  String _appVersion = 'Loading...';

  StreamSubscription? _logSub;

  // 日誌過濾。大燈已驗證可用，預設回到全部日誌；
  // 切換鈕保留，日後要診斷大燈時仍可一鍵只看那條路徑。
  // _logs 永遠保留全部，過濾只在顯示與匯出時套用。
  bool _logIgmpOnly = false;
  // IGMP 模組（大燈、倒車、未來的車門）共用同一組 Header 切換，
  // 出問題時通常是彼此踩到 Header，所以要一起看才判斷得出來。
  static const List<String> _igmpKeywords = [
    'BC03',      // 車門開啟 PID
    'BC04',      // 倒車 / 門鎖 / 安全帶 PID
    'BC09',      // 大燈 PID（TX / RX / NoData 都會帶到）
    'Headlights',
    'Reversing',
    'ATSH302',   // 切到 IGMP 模組的 Header（候選一）
    'ATSH770',   // OBD.csv 標註的 Header（候選二）
    'ATSH7DF',   // 切回標準 Header
    'Timeout',   // 送出後沒回應
  ];

  bool _matchesFilter(String log) {
    if (!_logIgmpOnly) return true;
    return _igmpKeywords.any(log.contains);
  }

  List<String> get _visibleLogs =>
      _logIgmpOnly ? _logs.where(_matchesFilter).toList() : _logs;
  StreamSubscription? _volumeSub;
  final List<String> _logs = [];

  // 暫停自動捲動期間收到的日誌先擱在這裡，恢復後才併入 _logs。
  // 不能像以前那樣照常 add + removeAt(0)：ListView.builder 的子項沒有 key，
  // 從頭移除會讓每一列往上位移一行，捲動位置沒變畫面卻一直在動，
  // 看起來就是「暫停失效、日誌自己一直刷」。
  final List<String> _pendingLogs = [];

  /// 只給暫停徽章用，避免每筆日誌都 setState 整頁重建
  final ValueNotifier<int> _pendingCount = ValueNotifier<int>(0);

  static const int _logCap = 500;
  static const int _pendingCap = 2000;

  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;

  // ── 檔位觀察 ────────────────────────────────────────────────────────────
  // 走 ObdSppService 的獨立 gearLogStream，不跟主日誌混在一起：
  // 探測期間主日誌每秒幾十行時速/轉速，檔位樣本會被沖掉。
  StreamSubscription? _gearLogSub;
  final List<String> _gearLogs = [];
  final ScrollController _gearScrollController = ScrollController();
  bool _gearAutoScroll = true;
  bool _gearProbeOn = false;
  bool _gearScrollPending = false;
  static const int _gearLogCap = 2000;

  // 鑰匙訊號是目前的主線目標。
  //
  // 做法從「走遠」改成「把鑰匙放進金屬盒」。金屬盒就是法拉第籠，擋掉鑰匙
  // 回覆用的 315/433MHz，車子就會判定沒有鑰匙。這樣人可以留在車上、車門
  // 全程關著，開門與解鎖那五個位元根本不會動，對照組比「兩邊都開著門」
  // 乾淨得多，而且狀態能在幾秒內來回切換、重複很多次。
  static const String _kKeyIn = '鑰匙在車內';
  static const String _kKeyOut = '鑰匙在鐵盒';

  /// 走遠法的備援標籤。金屬盒屏蔽不足時才用，留在進階那一列。
  static const String _kKeyAway = '鑰匙走遠';

  /// 「鑰匙離開」快照的倒數秒數。要夠你走出感應範圍並等車子發出警示。
  static const int _keyOutDelay = 60;

  /// 同一個狀態拍第幾張。同標籤拍兩張，比對才能濾掉會自己慢慢飄的 byte；
  /// 只拍一張的那次實測出 247 個候選，等於沒有結論。
  int _shotCount(String label) =>
      ObdSppService().gearSnapshotLabels.where((String e) => e == label).length;

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
    _trafficEnabled = SettingsService().trafficEnabled;
    _trafficVoice = SettingsService().trafficVoice;
    _ttsVolume = SettingsService().ttsVolume;

    _initPackageInfo();
    _initSystemVolume();

    // Load initial logs from service history
    _logs.addAll(ObdSppService().logHistory);

    _logSub = ObdSppService().logStream.listen((log) {
      if (!mounted) return;

      // 暫停中：完全不動已顯示的清單，畫面才會真的停住
      if (!_autoScroll) {
        _pendingLogs.add(log);
        if (_pendingLogs.length > _pendingCap) _pendingLogs.removeAt(0);
        _pendingCount.value = _pendingLogs.length;
        return;
      }

      setState(() {
        _logs.add(log);
        if (_logs.length > _logCap) _logs.removeAt(0);
      });
      if (!_scrollPending) {
        _scrollPending = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollPending = false;
          if (_autoScroll && _scrollController.hasClients) {
            _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
          }
        });
      }
    });

    _gearProbeOn = SettingsService().gearProbeEnabled;
    _gearLogs.addAll(ObdSppService().gearLogHistory);
    _gearLogSub = ObdSppService().gearLogStream.listen((log) {
      if (!mounted) return;
      setState(() {
        _gearLogs.add(log);
        if (_gearLogs.length > _gearLogCap) _gearLogs.removeAt(0);
        // 探測可能被服務端自行收工（候選全滅），開關要跟著實際狀態走
        _gearProbeOn = SettingsService().gearProbeEnabled;
      });
      if (_gearAutoScroll && !_gearScrollPending) {
        _gearScrollPending = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _gearScrollPending = false;
          if (_gearAutoScroll && _gearScrollController.hasClients) {
            _gearScrollController
                .jumpTo(_gearScrollController.position.maxScrollExtent);
          }
        });
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
    _gearLogSub?.cancel();
    _volumeSub?.cancel();
    _scrollController.dispose();
    _gearScrollController.dispose();
    _pendingCount.dispose();
    _recordingCountdownTimer?.cancel();
    super.dispose();
  }

  /// 切換自動捲動。恢復時把暫停期間累積的日誌一次併入並捲到底。
  void _toggleAutoScroll() {
    final bool resuming = !_autoScroll;
    setState(() {
      _autoScroll = resuming;
      if (resuming && _pendingLogs.isNotEmpty) {
        _logs.addAll(_pendingLogs);
        _pendingLogs.clear();
        _pendingCount.value = 0;
        if (_logs.length > _logCap) {
          _logs.removeRange(0, _logs.length - _logCap);
        }
      }
    });
    if (resuming) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
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
    // 小燈比近燈早亮、晚熄，前後各露出一段只有小燈的畫面
    final positionLamp = cycle >= 80 && cycle < 190;
    final rearFog = cycle >= 160 && cycle < 185;
    final cameraActive = cycle >= 130 && cycle < 165;
    // 前方路況紅條：由 2.4 公里外逐漸接近，前段「緩慢」、後段「壅塞」，
    // 距離歸零後切成「壅塞中 剩…」，三種文字都看得到
    final jamActive = cycle >= 20 && cycle < 140;
    final jamDist = (2400 - (cycle - 20) * 30).clamp(0, 2400);
    // 接著模擬閘道前預知：還在平面道路上，上台61南下之後前方壅塞
    final rampJam = cycle >= 150 && cycle < 175;
    // 再來是閘道前預知、上去之後路況正常：一律顯示（綠底）
    final rampOk = cycle >= 175;
    final now = DateTime.now();

    return {
      "_type": "esp32_dash",
      "speed": speed,
      "rpm": _simRpm(speed),
      "coolant": (70 + cycle * 0.11).clamp(70, 92).round(),
      "soc": double.parse((65.5 - cycle * 0.05).toStringAsFixed(1)),
      "fuel": 50 - cycle ~/ 100,
      "speed_limit": speedLimit,
      // 週期中段模擬「高架與平面判別不出來」與「推定速限」，用來驗證 ESP32 的
      // ALT / EST 兩個標記；測速照相警示期間兩者應自動隱藏
      "limit_alt": cycle >= 60 && cycle < 120 ? 60 : 0,
      // 前半段模擬「另一條在下面」、後半段「在上面」
      "limit_alt_above": cycle >= 90,
      // 雙速限前半段有傾向（紅線）、後半段沒有
      "limit_lean": cycle < 90,
      "limit_inferred": cycle >= 30 && cycle < 120,
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
      "traffic": {
        "active": true,
        // 每一輪在主線壅塞（cycle 60）與閘道壅塞（cycle 150）開始時各加一，板子念「注意前方路況」
        "alerts": t ~/ _simCycleTicks * 2 + (cycle >= 60 ? 1 : 0) + (cycle >= 150 ? 1 : 0),
        "sys": "P",
        "ref": "61",
        "km": 150.0,
        "segs": const [],
        if (jamActive)
          "jam": {
            "dist": jamDist,
            "len": jamDist > 0 ? 1400 : 1400 - (cycle - 100) * 30,
            "speed": cycle < 60 ? 45 : 22,
            "level": cycle < 60 ? 2 : 3,
          }
        else if (rampJam)
          "jam": {
            "dist": cycle < 163 ? 2000 : 0,
            "len": 3000,
            "speed": 18,
            "level": 3,
            "via": const {"sys": "P", "ref": "61", "dir": "S"},
          },
        if (rampOk)
          "ramp": const {
            "sys": "F",
            "ref": "1",
            "dirs": [
              {"dir": "N", "level": 0, "speed": 95},
              {"dir": "S", "level": 1, "speed": 62},
            ],
          },
      },
      "lights": {
        "low": lowBeam,
        "high": highBeam,
        "position": positionLamp,
        "rear_fog": rearFog,
      },
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

  Future<void> _exportLogs() => _shareLogFile(
        _visibleLogs,
        'NX4Board_log',
        'NX4Board Log Export',
      );

  Future<void> _exportGearLogs() => _shareLogFile(
        _gearLogs,
        'NX4Board_gear',
        'NX4Board 檔位觀察日誌',
      );

  /// 寫暫存檔再交給系統分享（雲端硬碟、郵件、聊天室都吃這個入口）
  Future<void> _shareLogFile(
      List<String> lines, String prefix, String subject) async {
    try {
      if (lines.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('無日誌可供匯出')),
        );
        return;
      }

      final String timestamp =
          DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final String fileName = '${prefix}_$timestamp.txt';
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/$fileName');

      await file.writeAsString(lines.join('\n'));

      final result = await Share.shareXFiles(
        [XFile(file.path)],
        subject: subject,
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

  Future<void> _toggleGearProbe() async {
    final bool turningOn = !_gearProbeOn;
    setState(() => _gearProbeOn = turningOn);
    if (turningOn) {
      await ObdSppService().startGearProbe();
    } else {
      await ObdSppService().stopGearProbe();
    }
    if (!mounted) return;
    setState(() => _gearProbeOn = SettingsService().gearProbeEnabled);
  }

  Future<void> _captureSnapshot(String label, {int delay = 0}) async {
    setState(() {});
    await ObdSppService().captureSnapshot(label, delaySeconds: delay);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _toggleTcuFamilyScan() async {
    final ObdSppService obd = ObdSppService();
    if (obd.isDidSweepRunning) {
      obd.stopDidSweep();
      setState(() {});
      return;
    }
    setState(() {});
    await obd.startTcuFamilyScan();
    if (!mounted) return;
    setState(() {});
  }

  void _clearGearLogs() {
    ObdSppService().clearGearLog();
    setState(() => _gearLogs.clear());
  }

  void _toggleGearAutoScroll() {
    setState(() => _gearAutoScroll = !_gearAutoScroll);
    if (_gearAutoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_gearScrollController.hasClients) {
          _gearScrollController
              .jumpTo(_gearScrollController.position.maxScrollExtent);
        }
      });
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
                    child: Column(
                      children: [
                        SwitchListTile(
                          title: const Text('前方路況 (TDX)',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(TrafficService().isAvailable
                              ? '國道與快速公路前方 10 公里的即時車速，以及閘道前預知，推送至 ESP32 面板。'
                              : '缺少 assets/private/tdx.json 憑證，目前無法使用。'),
                          value: _trafficEnabled,
                          onChanged: (val) async {
                            setState(() => _trafficEnabled = val);
                            await SettingsService().setTrafficEnabled(val);
                          },
                        ),
                        SwitchListTile(
                          title: const Text('壅塞語音提醒'),
                          subtitle: const Text('國道與快速公路前方緩慢或壅塞時播報距離、長度與車速。'),
                          value: _trafficVoice,
                          onChanged: _trafficEnabled
                              ? (val) async {
                                  setState(() => _trafficVoice = val);
                                  await SettingsService().setTrafficVoice(val);
                                }
                              : null,
                        ),
                      ],
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
                                    onTap: () => setState(
                                        () => _logIgmpOnly = !_logIgmpOnly),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: _logIgmpOnly
                                            ? Colors.orange.withValues(alpha: 0.2)
                                            : Colors.grey.withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: _logIgmpOnly
                                              ? Colors.orange
                                              : Colors.grey,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            _logIgmpOnly
                                                ? Icons.lightbulb
                                                : Icons.list,
                                            color: _logIgmpOnly
                                                ? Colors.orange
                                                : Colors.grey,
                                            size: 14,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            _logIgmpOnly ? '只看 IGMP' : '全部日誌',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: _logIgmpOnly
                                                  ? Colors.orange
                                                  : Colors.grey,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  GestureDetector(
                                    onTap: _toggleAutoScroll,
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
                                          ValueListenableBuilder<int>(
                                            valueListenable: _pendingCount,
                                            builder: (context, pending, _) => Text(
                                              _autoScroll
                                                  ? '自動捲動 ON'
                                                  : pending > 0
                                                      ? '自動捲動 OFF +$pending'
                                                      : '自動捲動 OFF',
                                              style: TextStyle(
                                                color: _autoScroll
                                                    ? Colors.green
                                                    : Colors.grey,
                                                fontSize: 12,
                                              ),
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
                              itemCount: _visibleLogs.length,
                              itemBuilder: (context, index) {
                                final log = _visibleLogs[index];
                                Color textColor = Colors.greenAccent;
                                if (log.contains('[Parser Error]') ||
                                    log.contains('[Parser NoData]')) {
                                  textColor = Colors.redAccent;
                                } else if (log.contains('[Headlights]')) {
                                  textColor = Colors.orangeAccent;
                                } else if (log.contains('[Parser Result]')) {
                                  textColor = Colors.lightGreenAccent;
                                } else if (log.contains('[Parser TX]')) {
                                  textColor = Colors.cyanAccent;
                                } else if (log.contains('[Parser RX]')) {
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
                  _buildGearProbeCard(),
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

  /// 探勘區的按鈕群。
  ///
  /// 主線是找出「鑰匙在不在感應範圍」的訊號，所以版面照那個流程排成三步，
  /// 其餘工具收進「進階」那一列。先前十三顆按鈕平鋪，主線被淹沒在裡面。
  Widget _buildGearButtons() {
    final ObdSppService obd = ObdSppService();
    final bool busy = obd.isDidSweepRunning || obd.isSnapshotRunning;
    final List<String> shots = obd.gearSnapshotLabels;

    Widget btn(String label, IconData icon, Color color, VoidCallback? onTap,
        {bool small = false}) {
      return SizedBox(
        height: small ? 30 : 36,
        child: ElevatedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: small ? 14 : 16),
          label: Text(label, style: TextStyle(fontSize: small ? 11 : 12.5)),
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.black,
            padding: EdgeInsets.symmetric(horizontal: small ? 8 : 12),
            visualDensity: VisualDensity.compact,
          ),
        ),
      );
    }

    Widget step(String text) => Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(text,
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.bold)),
        );

    final int nIn = _shotCount(_kKeyIn);
    final int nOut = _shotCount(_kKeyOut);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 主線：找鑰匙訊號 ────────────────────────────────────────
        step('① 建立已知位址清單（只需做一次，約 10 分鐘）'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          btn(
            obd.isDidSweepRunning ? '中止探索' : '探索模組',
            obd.isDidSweepRunning ? Icons.stop : Icons.travel_explore,
            obd.isDidSweepRunning ? Colors.redAccent : Colors.tealAccent,
            obd.isSnapshotRunning ? null : _toggleTcuFamilyScan,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('已知 ${obd.discoveredDidCount} 個 DID',
                style: const TextStyle(color: Colors.white54, fontSize: 11)),
          ),
        ]),

        step('② 坐在車上、車門關著，兩種狀態各拍兩張'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          btn(
            '鑰匙在車內 ($nIn/2)',
            Icons.vpn_key,
            nIn >= 2 ? Colors.green : Colors.amber,
            busy ? null : () => _captureSnapshot(_kKeyIn),
          ),
          btn(
            '鑰匙在鐵盒 ($nOut/2)',
            Icons.key_off,
            nOut >= 2 ? Colors.green : Colors.amber,
            busy ? null : () => _captureSnapshot(_kKeyOut),
          ),
          if (obd.isSnapshotRunning)
            btn('中止', Icons.stop, Colors.redAccent, () {
              ObdSppService().abortSnapshot();
              setState(() {});
            }),
        ]),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            '先驗證屏蔽：鑰匙放進金屬盒蓋緊，確認儀表真的跳出無鑰匙警示。'
            '沒跳就換盒子或多包幾層鋁箔，不要直接拍。\n'
            '驗證過就坐在車上、門關著，兩種狀態各拍兩張。同狀態兩張才濾得掉'
            '會自己慢慢飄的 byte。全程不用下車，約 8 分鐘。',
            style: TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ),

        step('③ 比對，然後用即時監看複驗'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          btn(
            '比對快照',
            Icons.compare_arrows,
            Colors.pinkAccent,
            busy
                ? null
                : () {
                    ObdSppService().analyzeGearSnapshots();
                    setState(() {});
                  },
          ),
          btn(
            '清除快照${shots.isEmpty ? '' : '（${shots.length}）'}',
            Icons.layers_clear,
            Colors.grey,
            busy
                ? null
                : () {
                    ObdSppService().clearGearSnapshots();
                    setState(() {});
                  },
          ),
        ]),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            '比對後候選會自動填進監看清單，只剩幾個、一輪幾秒。開「專注」'
            '按「即時監看」，然後按「事件」標記、鑰匙進盒、等一下、再按標記、'
            '鑰匙出盒，來回五次。跟得上全部轉換的那個位元就是答案。',
            style: TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ),

        // ── 進階 ────────────────────────────────────────────────────
        step('進階'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          btn(
            _gearProbeOn ? '停止監看' : '即時監看',
            _gearProbeOn ? Icons.stop : Icons.play_arrow,
            _gearProbeOn ? Colors.redAccent : Colors.orangeAccent,
            busy ? null : _toggleGearProbe,
            small: true,
          ),
          btn(
            obd.isGearFocusMode ? '專注 ON' : '專注 OFF',
            obd.isGearFocusMode ? Icons.bolt : Icons.bolt_outlined,
            obd.isGearFocusMode ? Colors.yellowAccent : Colors.grey,
            busy
                ? null
                : () {
                    ObdSppService().gearFocusMode = !obd.isGearFocusMode;
                    setState(() {});
                  },
            small: true,
          ),
          for (final String g in ['P', 'R', 'N', 'D'])
            btn('拍 $g', Icons.camera_alt,
                shots.contains(g) ? Colors.green : Colors.white24,
                busy ? null : () => _captureSnapshot(g),
                small: true),
          btn('鑰匙走遠(延遲$_keyOutDelay秒)', Icons.directions_walk, Colors.white24,
              busy
                  ? null
                  : () => _captureSnapshot(_kKeyAway, delay: _keyOutDelay),
              small: true),
          btn('標準 PID', Icons.fact_check, Colors.white24,
              busy
                  ? null
                  : () async {
                      await ObdSppService().scanStandardPids();
                      if (mounted) setState(() {});
                    },
              small: true),
          btn('車身監看組', Icons.sensor_door, Colors.white24,
              busy
                  ? null
                  : () {
                      ObdSppService().loadBodyWatchSet();
                      setState(() {});
                    },
              small: true),
          btn('D 檔驗證組', Icons.playlist_add_check, Colors.white24,
              busy
                  ? null
                  : () {
                      ObdSppService().loadDriveVerifySet();
                      setState(() {});
                    },
              small: true),
        ]),

        // ── 事件標記：要在車上邊操作邊按，所以放大並自成一列 ──────────
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(
            children: [
              const Text('動作前先按 ▼',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(width: 8),
              for (final String g in ['P', 'R', 'N', 'D', '事件'])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: SizedBox(
                      height: 40,
                      child: ElevatedButton(
                        onPressed: () => g == '事件'
                            ? ObdSppService().logEventMark('事件')
                            : ObdSppService().logGearMark(g),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white12,
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.zero,
                          side: const BorderSide(color: Colors.white38),
                        ),
                        child: Text(g,
                            style: TextStyle(
                                fontSize: g.length > 1 ? 12 : 17,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 檔位觀察區。獨立於主日誌，專門收 startGearProbe() 的取樣，
  /// 顯示、匯出、清除都在這一張卡片裡完成。
  Widget _buildGearProbeCard() {
    return Card(
      child: Container(
        height: 620,
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
                const Expanded(
                  child: Text('車輛訊號探勘',
                      style: TextStyle(
                          color: Colors.amber, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  icon: const Icon(Icons.download, color: Colors.amber),
                  tooltip: '匯出探勘日誌',
                  onPressed: _exportGearLogs,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.grey),
                  tooltip: '清除探勘日誌',
                  onPressed: _clearGearLogs,
                ),
                GestureDetector(
                  onTap: _toggleGearAutoScroll,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _gearAutoScroll
                          ? Colors.green.withValues(alpha: 0.2)
                          : Colors.grey.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: _gearAutoScroll ? Colors.green : Colors.grey,
                      ),
                    ),
                    child: Icon(
                      _gearAutoScroll ? Icons.pause : Icons.play_arrow,
                      color: _gearAutoScroll ? Colors.green : Colors.grey,
                      size: 16,
                    ),
                  ),
                ),
              ],
            ),
            _buildGearButtons(),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '目標：找出「鑰匙在不在感應範圍」的訊號。車輛維持 READY。'
                '已確認不在 770 車身模組，7A5 智慧鑰匙位址也確實不存在，'
                '所以要比對全部已知 DID。用金屬盒屏蔽鑰匙來製造對照狀態。',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
            const Divider(color: Colors.amber),
            Expanded(
              child: _gearLogs.isEmpty
                  ? const Center(
                      child: Text('尚無取樣。連上 OBD 後按「開始探測」。',
                          style:
                              TextStyle(color: Colors.white38, fontSize: 12)),
                    )
                  : ListView.builder(
                      controller: _gearScrollController,
                      itemCount: _gearLogs.length,
                      itemBuilder: (context, index) {
                        final String log = _gearLogs[index];
                        // ★ 是有變動的取樣，也就是真正要看的那幾行
                        final bool changed =
                            log.contains('★') || log.contains('▼');
                        Color textColor = Colors.greenAccent;
                        if (log.contains('▼')) {
                          textColor = Colors.white;
                        } else if (log.contains('[Diff★]')) {
                          textColor = Colors.pinkAccent;
                        } else if (log.contains('[Sweep✓]') ||
                            log.contains('[Family✓]')) {
                          textColor = Colors.lightBlueAccent;
                        } else if (changed) {
                          textColor = Colors.amberAccent;
                        } else if (log.contains('[Probe]') ||
                            log.contains('[Sweep]') ||
                            log.contains('[Snap]') ||
                            log.contains('[Diff]') ||
                            log.contains('[Family]')) {
                          textColor = Colors.cyanAccent;
                        }
                        return Text(
                          log,
                          style: TextStyle(
                            color: textColor,
                            fontFamily: 'monospace',
                            fontSize: 12,
                            fontWeight: changed
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
