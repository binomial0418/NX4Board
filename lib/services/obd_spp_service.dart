import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:intl/intl.dart';
import 'settings_service.dart';

enum ObdConnectionState {
  disconnected,
  scanning,
  connecting,
  initializing,
  connected
}

/// 檔位探測的一個候選位址。
///
/// OBD.csv 的 137 條擴充 PID 全部落在 770 / 7E0 / 7A0 / 7D1 / 7D4 / 7C6，
/// 沒有任何一條來自變速箱 ECU，所以檔位只能靠實車輪詢這些候選、
/// 再比對哪個 byte 跟著 P/R/N/D 變動。
class GearProbeTarget {
  GearProbeTarget(this.header, this.cmd, this.sig, this.note);

  /// 送出查詢前要切到的 Header
  final String header;

  /// 查詢指令
  final String cmd;

  /// 判定「這個位址有回應」的簽章（01→41、21→61、22→62）
  final String sig;

  /// 顯示在日誌上的說明
  final String note;

  /// 連續沒回應的次數，達到 _kGearMaxMiss 就淘汰
  int miss = 0;

  /// 還在輪詢名單裡
  bool alive = true;

  /// 上一筆 payload，用來只記錄「有變動」的取樣
  String? lastPayload;
}

/// DID 掃描的一段區間：對某個模組把一個 DID 家族的 00~FF 全問一遍。
class DidSweepRange {
  DidSweepRange(this.header, this.prefix, this.note);

  /// 模組 Header
  final String header;

  /// DID 家族前綴，例如 'B0' 代表掃 22B000 ~ 22B0FF
  final String prefix;

  final String note;
}

/// 一次「某個檔位下的全 DID 取樣」。
///
/// 逐一監看許多 DID 在 ELM327 這種序列鏈路上太慢（實測一輪 16 個要 145 秒），
/// 切檔只停留幾秒根本取樣不到。改成「把檔位停在那裡，慢慢把全部 DID 拍一遍」，
/// 再拿不同檔位的快照互相比對，取樣速度就不再是問題。
/// 比對結果的一筆：某個 DID 的某個 byte 隨檔位變動
class _GearCandidate {
  _GearCandidate(
      this.did, this.byteIndex, this.distinct, this.perGear, this.payloadChars);
  final String did;
  final int byteIndex;

  /// payload 的十六進位字元數。長的是多幀傳輸，即時監看取樣會慢好幾倍。
  final int payloadChars;

  /// 這個 byte 在各檔位間出現了幾種不同的值。四檔四種最理想。
  final int distinct;
  final Map<String, String> perGear;
}

class GearSnapshot {
  GearSnapshot(this.gear, this.takenAt, this.payloads, this.payloadsB);

  /// 這張快照代表的狀態，例如「鑰匙在車內」「鑰匙離開」或 P / R / N / D
  final String gear;
  final DateTime takenAt;

  /// 'HEADER|CMD' → payload hex（第一次讀取）
  final Map<String, String> payloads;

  /// 同一個 DID 立刻再讀一次的結果。
  ///
  /// 檔位沒動的情況下兩次應該一模一樣，凡是對不起來的 byte 就是會自己飄的
  /// 雜訊（引擎的溫度、點火提前角、滾動計數器都屬於這類），比對時直接排除。
  /// 第一版沒有這道手續，14 個候選裡有 14 個是引擎雜訊。
  final Map<String, String> payloadsB;
}

class ObdSppService with ChangeNotifier {
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
  final List<String> _logHistory = [];
  List<String> get logHistory => List.unmodifiable(_logHistory);

  // ── Maintenance Log Stream ───────────────────────────────────────────────
  final _maintenanceLogController = StreamController<String>.broadcast();
  Stream<String> get maintenanceLogStream => _maintenanceLogController.stream;
  final List<String> _maintenanceLogHistory = [];
  List<String> get maintenanceLogHistory =>
      List.unmodifiable(_maintenanceLogHistory);

  // ── 檔位觀察日誌（獨立於主日誌）────────────────────────────────────────
  // 探測期間主日誌每秒有幾十行時速/轉速，檔位樣本會被沖掉，
  // 所以走自己的 stream 與自己的匯出。
  final _gearLogController = StreamController<String>.broadcast();
  Stream<String> get gearLogStream => _gearLogController.stream;
  final List<String> _gearLogHistory = [];
  List<String> get gearLogHistory => List.unmodifiable(_gearLogHistory);

  void _log(String msg) {
    final String timestamp = DateFormat('HH:mm:ss').format(DateTime.now());
    final String fullMsg = '[$timestamp] $msg';
    _logHistory.add(fullMsg);
    if (_logHistory.length > 1000) _logHistory.removeAt(0);
    _logController.add(fullMsg);
  }

  void logWsSend(String json, {String label = '[WS-TX]'}) {
    _log('$label $json');
  }

  /// 檔位日誌用毫秒時間戳。切檔的瞬間會有好幾個 byte 一起動，
  /// 秒級解析度分不出誰先誰後。
  void _logGear(String msg) {
    final String timestamp =
        DateFormat('HH:mm:ss.SSS').format(DateTime.now());
    final String fullMsg = '[$timestamp] $msg';
    _gearLogHistory.add(fullMsg);
    if (_gearLogHistory.length > 2000) _gearLogHistory.removeAt(0);
    _gearLogController.add(fullMsg);
  }

  /// 切檔前先按下的標記。日誌裡插一行醒目的分隔，之後對照時就知道
  /// 那個時間點之後的取樣屬於哪一檔，不用再靠回想。
  void logGearMark(String gear) {
    _logGear('══════ ▼ 即將切入 $gear 檔 ▼ ══════');
  }

  /// 載入 D 檔驗證組。
  ///
  /// 三輪快照比對後，值得盯的就這幾個，直接寫死省得每次重跑十分鐘的快照：
  ///   770/22BC08  byte F bit3  倒車，已確認 —— 當對照組用，它一定要跟著 R 動
  ///   7E0/22E000  byte N bit3  D 檔候選（P/R/N=21，D=29）
  ///   7E0/22E0F1  byte F、#26  另外兩個只在 D 檔變的位元組
  ///   7E0/22E017  byte Q       N 檔候選（P/R/D=11，N=10）
  /// 22E004 刻意不放：它通過了雜訊過濾但實測會自己飄，是已知的假陽性。
  void loadDriveVerifySet() {
    _gearTargets
      ..clear()
      ..add(GearProbeTarget('770', '22BC08', '62BC08', 'R 檔（已確認，對照組）'))
      ..add(GearProbeTarget('7E0', '22E000', '62E000', 'D 檔候選 byte N bit3'))
      ..add(GearProbeTarget('7E0', '22E0F1', '62E0F1', 'D 檔候選 byte F / #26'))
      ..add(GearProbeTarget('7E0', '22E017', '62E017', 'N 檔候選 byte Q'));
    _logGear('[Probe] 已載入 D 檔驗證組（${_gearTargets.length} 個 DID）');
    _logGear('[Probe] 建議開啟「專注監看」，否則長 payload 每 40 秒才取樣一次');
    notifyListeners();
  }

  /// 載入車身模組全家族監看，用來抓「鑰匙靠近」這類車身事件。
  ///
  /// 只放 BC01~BC10 這九個：payload 都只有 20 字元左右，開專注監看一輪
  /// 大約三到四秒，迎賓照明亮個十幾秒絕對取樣得到。
  /// BCFC 全是零、BCFD 是九十字元的感測器陣列、BCFF 是字串，
  /// 三個都放進來只會拖慢一輪，不放。
  void loadBodyWatchSet() {
    const List<String> dids = [
      '22BC01', '22BC03', '22BC04', '22BC05',
      '22BC06', '22BC07', '22BC08', '22BC09', '22BC10',
    ];
    _gearTargets.clear();
    for (final String cmd in dids) {
      _gearTargets.add(
          GearProbeTarget('770', cmd, '62${cmd.substring(2)}', '車身 IGMP'));
    }
    _logGear('[Probe] 已載入車身全家族監看（${_gearTargets.length} 個 DID）');
    _logGear('[Probe] 已解讀：BC03 車門、BC04 門鎖、BC08 倒車(bit3)與'
        '疑似室內燈(bit1)、BC09 大燈、BC09 bit2 與 BC10 bit5 疑似防盜設防。');
    _logGear('[Probe] 已知否定結果：鑰匙離開車輛約 4 分鐘的完整測試中，'
        '這九個位址一個 byte 都沒動。鑰匙在不在車內的旗標不在 770 這顆模組上。');
    _logGear('[Probe] 做實車動作前先確認沒有在跑掃描或快照，那期間監看是停的。'
        '每個動作前先按「事件」標記鈕。');
    notifyListeners();
  }

  // ── 標準 PID 支援表 ──────────────────────────────────────────────────────

  /// 值得標出來的標準 PID。增壓壓力（0x70）是這次的重點，
  /// 渦輪轉速（0x74）與進氣歧管壓力多感測器版（0x87）也順便看一下。
  static const Map<int, String> _notablePids = {
    0x0B: 'MAP 進氣歧管絕對壓力（目前算增壓用的來源）',
    0x0F: '進氣溫度',
    0x10: 'MAF 空氣流量',
    0x11: '節氣門位置',
    0x33: '大氣壓力（目前算增壓用的基準）',
    0x42: '控制模組電壓',
    0x43: '絕對負載',
    0x46: '環境溫度',
    0x5B: '混合動力電池 SOC（已在用）',
    0x5C: '機油溫度',
    0x5E: '引擎耗油率',
    0x61: '要求扭力百分比',
    0x62: '實際扭力百分比',
    0x63: '引擎參考扭力',
    0x67: '水溫，雙感測器（已在用）',
    0x68: '進氣溫度，多感測器',
    0x6D: '燃油壓力控制',
    0x6E: '噴射壓力控制',
    0x70: '★ 增壓壓力控制（專用增壓感測器就在這裡）',
    0x71: '可變幾何渦輪控制',
    0x73: '排氣壓力',
    0x74: '渦輪轉速',
    0x77: '中冷器溫度',
    0x87: '進氣歧管絕對壓力，多感測器',
  };

  /// 問出這台車到底支援哪些標準 PID。
  ///
  /// 支援表本身就是標準 PID：0100 回報 01~20 這段、0120 回報 21~40，
  /// 依此類推。每格回四個 byte 共 32 個位元，最高位元對應該區間第一個 PID，
  /// 最低位元代表「下一格也支援」。全部問完只要六道指令。
  ///
  /// 這台車已經證實吃 015B 與 0167 這種擴充區的 PID，所以很值得問清楚，
  /// 目前用 MAP 減大氣壓硬算的增壓，很可能有現成的專用訊號可以取代。
  Future<void> scanStandardPids() async {
    if (_scanBusy) return;
    if (!_isConnected) {
      _logGear('[PID] 尚未連線');
      return;
    }

    _snapshotRunning = true; // 借用同一個旗標把例行輪詢擋住
    notifyListeners();
    _logGear('[PID] ══ 標準 PID 支援表掃描 ══');

    final List<int> supported = [];
    try {
      sendCommand('ATSH7DF');
      for (int base = 0x00; base <= 0xA0; base += 0x20) {
        if (!_isConnected) break;

        final String pid = base.toRadixString(16).padLeft(2, '0').toUpperCase();
        _sweepCurrentCmd = '01$pid';
        final String resp = await sendCommand('01$pid', timeoutMs: 2000);

        final String hex =
            resp.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
        final int idx = hex.indexOf('41$pid');
        if (idx == -1 || hex.length < idx + 12) {
          _logGear('[PID] 01$pid 無回應，${pid == '00' ? '這台車連基本支援表都不給' : '後面的區間不支援'}');
          break;
        }

        // 這台是油電車，0100 這種廣播查詢會有好幾顆模組各自回自己的支援表。
        // 第一版只取第一個 41xx 就收工，等於只看到最先回應的那一顆，
        // 會漏掉其他模組支援的 PID。要把所有回應的點陣圖全部聯集起來。
        final List<int> bitmaps = [];
        int from = idx;
        while (from != -1 && from + 12 <= hex.length) {
          bitmaps.add(
              int.parse(hex.substring(from + 4, from + 12), radix: 16));
          from = hex.indexOf('41$pid', from + 4);
        }

        int bits = 0;
        for (final int b in bitmaps) {
          bits |= b;
        }

        int count = 0;
        for (int i = 0; i < 32; i++) {
          // 最高位元對應該區間第一個 PID
          if ((bits & (1 << (31 - i))) != 0) {
            supported.add(base + i + 1);
            count++;
          }
        }
        _logGear('[PID] 01$pid → ${bitmaps.length} 顆模組回應，'
            '聯集後本區間支援 $count 個');
        if (bitmaps.length > 1) {
          for (int i = 0; i < bitmaps.length; i++) {
            _logGear('[PID]   模組 ${i + 1} 點陣圖 '
                '0x${bitmaps[i].toRadixString(16).padLeft(8, '0').toUpperCase()}');
          }
        }

        if ((bits & 0x01) == 0) break; // 最低位元沒亮代表沒有下一格
      }
    } finally {
      _snapshotRunning = false;
      _sweepCurrentCmd = null;
      notifyListeners();
    }

    if (supported.isEmpty) {
      _logGear('[PID] 沒有取得任何支援資訊');
      return;
    }

    final String list = supported
        .map((int p) => p.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
    _logGear('[PID] 共支援 ${supported.length} 個標準 PID：$list');

    for (final int p in supported) {
      final String? note = _notablePids[p];
      if (note != null) {
        _logGear('[PID✓] 01${p.toRadixString(16).padLeft(2, '0').toUpperCase()}'
            '  $note');
      }
    }

    // App 目前實際在查的 PID 跟支援表對一次。第一版沒對，結果 010B 與 0133
    // 可能根本不被支援卻一直在查，增壓的數字也就一直是錯的。
    const Map<int, String> inUse = {
      0x0B: 'MAP，目前拿來算增壓',
      0x0C: '轉速',
      0x0D: '車速',
      0x33: '大氣壓，目前拿來當增壓基準',
      0x5B: '油電電量',
      0x67: '水溫',
    };
    for (final MapEntry<int, String> e in inUse.entries) {
      final String p = e.key.toRadixString(16).padLeft(2, '0').toUpperCase();
      if (!supported.contains(e.key)) {
        _logGear('[PID✗] 01$p 不在支援表裡，但 App 一直在查它（${e.value}）');
      }
    }

    // 把合併查詢的原始回應抓一筆，直接看 ECU 到底回了哪幾個 PID
    await _dumpPid('010B0C0D');
    await _dumpPid('010B');
    await _dumpPid('0133');

    if (supported.contains(0x70)) {
      _logGear('[PID] 支援 0170，直接抓一筆原始回應來看');
      await _dumpPid('0170');
    } else {
      _logGear('[PID] 不支援 0170，增壓得回頭從 7E0 的 E0xx 家族裡找');
    }
    if (supported.contains(0x74)) await _dumpPid('0174');
    if (supported.contains(0x87)) await _dumpPid('0187');
  }

  /// 抓一筆原始回應寫進日誌。合併查詢（例如 010B0C0D）不能用整個指令當簽章，
  /// 所以只對齊到 41，後面回了哪些 PID 原樣印出來自己看。
  Future<void> _dumpPid(String cmd) async {
    _sweepCurrentCmd = cmd;
    final String resp = await sendCommand(cmd, timeoutMs: 2000);
    _sweepCurrentCmd = null;
    final String hex =
        resp.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
    final int idx = hex.indexOf('41');
    if (idx == -1) {
      _logGear('[PID] $cmd 無有效回應 raw=$resp');
      return;
    }
    _logGear('[PID★] $cmd 回應=${hex.substring(idx)}  ${_gearContext()}');
  }

  /// 通用事件標記。不只切檔，任何「我現在要做某個動作」都能先按一下。
  void logEventMark(String label) {
    _logGear('══════ ▼ $label ▼ ══════');
  }

  void clearGearLog() {
    _gearLogHistory.clear();
  }

  void _logMaintenance(String msg) {
    final String timestamp = DateFormat('HH:mm:ss').format(DateTime.now());
    final String fullMsg = '[$timestamp] $msg';
    _maintenanceLogHistory.add(fullMsg);
    if (_maintenanceLogHistory.length > 500) _maintenanceLogHistory.removeAt(0);
    _maintenanceLogController.add(fullMsg);
    // 移除重複輸出至主日誌的行為，以符合「拿掉保養資訊log區」的要求
    // _log('[CLU-Service] $msg');
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
  double? turbo; // 渦輪壓力 (Bar)
  double currentBaroKpa = 101.0;

  /// 已經講過「本車不回報 MAP」了，避免每 300 毫秒洗一行
  bool _mapMissingLogged = false;
  double turboBoostBar = 0.0;
  double? referenceGpsAltitude;
  int serviceDistanceRemaining = 0;
  int serviceDaysRemaining = 0;

  bool isReversing = false;

  // 大燈狀態（OBD.csv: IGMP_Headlights_Low_Beam / High_Beam，PID 22BC09）
  bool isLowBeamOn = false;
  bool isHighBeamOn = false;

  // ── 22BC09 byte G 的位元對應 ────────────────────────────────────────────
  // OBD.csv 寫 High_Beam = G/12、Low_Beam = H/12，實車比對後**標註是反的**：
  // G（data[6]）是大燈總開關，H（data[7]）才是遠燈。兩者都是 bit field，
  // 不是 CSV 那種除以 12 的量值（車門那組訊號證實 ">N" 其實是位移 ">>N"）。
  //
  //   大燈關:          32 20 03 CC 40 00 00 00 AA AA
  //   大燈開、遠燈關:  32 20 03 CC 40 04 C0 00 AA AA
  //   大燈開、遠燈開:  32 20 03 CC 40 04 C0 03 AA AA
  //                                   ^^ ^^
  //                                    G  H
  // byte5 會在 0x00/0x04 之間變動，是別的訊號，與燈無關。

  /// 大燈開啟：G 的 bit7 + bit6（實車驗證）
  static const int _kBeamMaskOn = 0xC0;

  /// 遠燈：H 的 bit1 + bit0（實車驗證，兩個位元同進同出）
  static const int _kBeamMaskHigh = 0x03;

  /// D 檔：22E000（header 7E0）的 byte N，bit3。
  ///
  /// 實車以 P / D 來回兩趟的快照比對加即時監看確認。切檔前先按標記鈕，
  /// 三次切換全部命中，翻轉都落在標記後的 1.8 到 4.0 秒內。
  /// 同一趟還有另外兩個位元跟著一起動，可以互相佐證：
  ///   22E0F1 byte F  bit1（P=0x09 → D=0x0B）
  ///   22E0F1 byte AA bit1（P=0x00 → D=0x02）
  /// 選 22E000 是因為它的 payload 120 byte，比 22E0F1 的 350 byte 省得多。
  ///
  /// 注意：P 與 N 目前仍然分不出來，兩者這個位元都是 0。
  static const int _kDriveByteIndex = 13; // byte N
  static const int _kDriveMask = 0x08;

  bool isDriveGear = false;
  bool hasDriveGear = false;

  /// 目前能判斷的檔位。P 與 N 沒有已知訊號可以區分，合併回報。
  String get gearLabel {
    if (!hasReversing && !hasDriveGear) return '-';
    if (isReversing) return 'R';
    if (isDriveGear) return 'D';
    return 'P/N';
  }

  // ── 車身 IGMP 已解出的位元（實車以開關駕駛門的事件比對）────────────────
  //
  // 已確認的否定結果：車輛維持 READY、駕駛門開著，人帶著鑰匙走遠到車輛
  // 發出無鑰匙警示、再走回來，全程 236 秒。這九個位址在那段時間裡一個
  // byte 都沒有變動（一輪取樣約 2 秒，涵蓋上百輪）。
  // 也就是說「鑰匙在不在車內」不由 770 持有，不用再回頭查這裡。
  //
  // 開駕駛門那一刻，五個位元組同時變動：
  //   22BC03 byte E bit5 亮  駕駛座車門開（與既有的車門位元表相符）
  //   22BC04 byte E bit3 亮  解鎖（READY 狀態由內開門會解除自動上鎖）
  //   22BC08 byte F bit1 亮  跟著車門開關同進同出，關門即滅，疑似室內燈
  //   22BC09 byte F bit2 滅  上鎖時亮、解鎖後不再回來，疑似防盜設防
  //   22BC10 byte F bit5 滅  同上
  // 後三個都還沒單獨驗證，先記在這裡免得下次重查。

  /// 倒車：22BC08（header 770）的 byte F，bit3。
  ///
  /// 早期猜在 22BC04 的 byte E，實車證實那個 byte 從頭到尾不動，是門鎖不是檔位。
  /// 真正的來源是 P/R/N/D 四張快照比對出來的：22BC08 的 byte F
  /// 在 P、N、D 都是 0x00，只有 R 是 0x08，實車複驗過兩次進出 R 檔。
  static const int _kReverseMask = 0x08;

  /// 位元探勘：累計看過的 G / H 位元，出現沒看過的就明顯印一行
  int _beamBitsSeenG = 0;
  int _beamBitsSeenH = 0;

  // 車門與尾門開啟（OBD.csv: PID 22BC03，全部落在 byte E 的不同位元）
  //   RL=bit0  RR=bit2  FR=bit4  FL=bit5  Trunk=bit7
  // 空著的 bit1/bit3 用途不明，bit6 依 CSV 是手煞車。
  bool isDoorFlOpen = false;
  bool isDoorFrOpen = false;
  bool isDoorRlOpen = false;
  bool isDoorRrOpen = false;
  bool isTrunkOpen = false;
  bool hasDoors = false;

  bool get isAnyDoorOpen =>
      isDoorFlOpen || isDoorFrOpen || isDoorRlOpen || isDoorRrOpen;

  // 車門解鎖（OBD.csv: PID 22BC04 byte E，位元設起來代表「未上鎖」）
  // 只有前兩門有訊號，後門與尾門在 CSV 裡沒有對應項目。
  bool isDoorUnlocked = false;
  bool hasDoorLock = false;

  // TPMS (FL, FR, RL, RR)
  double? tpmsFl;
  double? tpmsFr;
  double? tpmsRl;
  double? tpmsRr;

  // ── 啟動訊號：用於通知 UI 觸發掃跡動畫 ───────────────────────────────────
  bool _shouldTriggerWakeup = false;
  bool get shouldTriggerWakeup => _shouldTriggerWakeup;

  /// 安全性掃跡鎖定：記錄此電源週期是否為首次連線
  bool _isFirstConnectOfSession = true;

  // ── Data Validity Flags (本次連線是否已成功解析過) ─────────────────────
  bool hasRpm = false;
  bool hasSpeed = false;
  bool hasCoolant = false;
  bool hasVoltage = false;
  bool hasHevSoc = false;
  bool hasOdometer = false;
  bool hasFuel = false;
  bool hasTurbo = false;
  bool hasServiceDistanceRemaining = false;
  bool hasServiceDaysRemaining = false;
  bool hasTpms = false;
  bool hasReversing = false;
  bool hasHeadlights = false;

  // ── GPS Speed Tracking ───────────────────────────────────────────────────
  double? _lastGpsSpeedKmh;
  DateTime? _lastGpsSpeedTime;

  void onGpsSpeedChanged(double speedMps) {
    if (speedMps >= 0) {
      _lastGpsSpeedKmh = speedMps * 3.6;
      _lastGpsSpeedTime = DateTime.now();
      // GPS speed is stored for OBD sanity check only; display speed comes from OBD
    }
  }

  // ── Polling Timers ────────────────────────────────────────────────────────
  Timer? _fastPollTimer;
  Timer? _slowPollTimer;
  Timer? _minutePollTimer;
  Timer? _longPollTimer;
  Timer? _igmpPollTimer;
  Timer? _drivePollTimer;
  int _lastDrivePollMs = 0;
  bool _drivePollBusy = false;

  /// 上次 IGMP 輪詢的時刻，用來依車速決定要不要跳過這一拍
  int _lastIgmpPollMs = 0;

  // 大燈 PID (22BC09) 的請求 Header 尚未確定：
  //   ATSH302 — 早期的猜測。實車 log 顯示它對 22BC04 一律回 NODATA，
  //              留著只是萬一 770 失效時的備援，正常情況第一次探測就會被淘汰。
  //   ATSH770 — OBD.csv 標註的 Header
  // 兩個都試，哪個拿得到 62BC09 就鎖定，之後只送那一個。
  static const List<String> _igmpHeaders = ['ATSH302', 'ATSH770'];
  String? _igmpHeaderLocked;

  // 22BC04 在兩個 Header 底下代表不同東西：302 是倒車、770 是門鎖/安全帶。
  // 解析時光看 PID 分不出來，所以記住送出當下生效的 Header。
  // 指令鏈是序列化的，回應抵達時這個值仍然是當初送出時的那一個。
  String _activeHeader = '7DF';
  bool _igmpPollBusy = false;
  int _igmpFailStreak = 0;
  // 兩個 Header 都試不出來時放棄，避免每 3 秒白跑 6 道指令、
  // 排擠到 300ms 的時速/轉速快輪詢。重新連線時會重置。
  bool _igmpGiveUp = false;
  static const int _igmpMaxProbes = 10;
  
  // ── 檔位探測 (Gear Probe) ────────────────────────────────────────────────
  // 目的是找出這台車回報檔位的來源。候選連續 _kGearMaxMiss 次沒回應就淘汰：
  // NODATA 要等滿 ELM 的逾時，單次成本是正常指令的 3~5 倍，
  // 放著不管會排擠 300ms 的時速/轉速快輪詢。
  Timer? _gearPollTimer;
  bool _gearProbeRunning = false;
  bool get isGearProbeRunning => _gearProbeRunning;
  bool _gearPollBusy = false;
  int _gearLastHeartbeatMs = 0;
  static const int _kGearMaxMiss = 3;

  /// 監看清單。一開始只有 SAE 標準的 01A4，其餘要靠 DID 掃描找出來再加進來。
  ///
  /// 第一版曾押 Mode 21（2101）的 TCU 資料流，實車全部無回應。
  /// 回頭數 OBD.csv 才確認這台車的 78 條擴充 PID 全是 Mode 22（UDS），
  /// 一條 Mode 21 都沒有 —— 現代 Hyundai/Kia 已經不吃 Mode 21，
  /// 所以改用 Mode 22 的 DID 掃描來找檔位。
  /// 一開始是空的：01A4 已經實車證實無回應（01A0 支援表也是 NODATA），
  /// 留著只是每輪白花三次未命中。清單由快照比對的結果填入。
  final List<GearProbeTarget> _gearTargets = [];

  /// 掃描或拍快照會把整條匯流排包下來，期間 _pollGear 直接跳過，
  /// 監看等於完全停擺。實車就吃過這個虧：一邊跑 15 分鐘的模組探索，
  /// 一邊在車外做鑰匙測試，結果那一分鐘一筆取樣都沒有。
  /// 所以只要監看是開著的，開始與結束都要明講盲區這件事。
  int _watchBlindStartMs = 0;

  void _noteWatchSuspended(String what) {
    if (!_gearProbeRunning) return;
    _watchBlindStartMs = DateTime.now().millisecondsSinceEpoch;
    _logGear('[Probe] ⚠ $what 期間監看完全停擺，這段時間車上發生的事一律抓不到。'
        '要做實車動作請先等它跑完。');
  }

  void _noteWatchResumed() {
    if (!_gearProbeRunning || _watchBlindStartMs == 0) return;
    final int secs =
        (DateTime.now().millisecondsSinceEpoch - _watchBlindStartMs) ~/ 1000;
    _watchBlindStartMs = 0;
    _logGear('[Probe] ⚠ 監看恢復，剛才有 $secs 秒的盲區。'
        '盲區前後如果有 byte 不一樣，只能知道它變過，無法知道何時變的。');
  }

  // ── DID 掃描 ─────────────────────────────────────────────────────────────
  // 每個模組只用固定的一個 DID 家族（下表由 OBD.csv 的 78 條 Mode 22 反推），
  // 所以掃描就是把該家族的 00~FF 逐一問過去，記下哪些有回應。
  // 排序按「最可能持有 PRND」由高到低：儀表本來就要把 P/R/N/D 畫在錶上。
  final List<DidSweepRange> _sweepRanges = [
    DidSweepRange('7C6', 'B0', '儀表 CLU（PRND 顯示在這裡，最有機會）'),
    DidSweepRange('770', 'BC', '車身 IGMP（倒車燈訊號在這裡）'),
    DidSweepRange('7E0', 'E0', '引擎 ECM'),
    DidSweepRange('7E1', 'F1', 'TCU 識別區（先確認這個位址活不活）'),
  ];

  bool _sweepRunning = false;
  bool _snapshotRunning = false;
  bool get isSnapshotRunning => _snapshotRunning;

  /// 掃描或拍快照期間佔用整條匯流排，其餘輪詢一律讓路
  /// 掃描或拍快照進行中。這兩者會把整條匯流排包下來。
  bool get _scanBusy => _sweepRunning || _snapshotRunning;

  /// 專注監看：即時監看時把例行輪詢也停掉，讓監看清單的取樣間隔壓到最短。
  ///
  /// 實測沒開的時候一輪 4 個目標要 40~70 秒，多幀的長 payload 更慢，
  /// 切檔停留幾秒根本對不上。代價是時速與轉速在監看期間不更新，
  /// 所以只適合停在原地驗證訊號，跑起來要記得關掉。
  bool _gearFocusMode = false;
  bool get isGearFocusMode => _gearFocusMode;
  set gearFocusMode(bool v) {
    _gearFocusMode = v;
    _logGear(v
        ? '[Probe] 專注監看已開啟：例行輪詢暫停，時速與轉速不再更新'
        : '[Probe] 專注監看已關閉，例行輪詢恢復');
    notifyListeners();
  }

  /// 例行輪詢要不要讓路。_pollGear 自己不看這個，否則專注模式會把自己鎖死。
  bool get _busReserved =>
      _scanBusy || (_gearProbeRunning && _gearFocusMode);

  /// 掃描找到的 DID，格式 'HEADER|CMD'。與監看清單分開：
  /// 監看有 16 個上限（跑得完一輪才有意義），快照則是全部都要拍。
  final List<String> _discoveredDids = [];
  bool _discoveredLoaded = false;
  int get discoveredDidCount {
    _ensureDiscoveredLoaded();
    return _discoveredDids.length;
  }

  int get watchTargetCount => _gearTargets.length;

  final List<GearSnapshot> _gearSnapshots = [];
  List<String> get gearSnapshotLabels =>
      _gearSnapshots.map((GearSnapshot e) => e.gear).toList();
  bool get isDidSweepRunning => _sweepRunning;
  int _sweepFound = 0;

  // ── Moving Window Buffers ────────────────────────────────────────────────
  final List<int> _fuelBuffer = [];

  // =========================================================================
  // 模組一：電源狀態感知 (Power State Listener)
  // =========================================================================

  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _batterySubscription;

  /// 電源連線總開關：true = 外部電源在線，false = 僅靠手機電池
  bool _isPowerConnected = true;

  /// 啟動電源監聽，應在 App 啟動時呼叫
  void startPowerListener() {
    _batterySubscription?.cancel();
    _batterySubscription =
        _battery.onBatteryStateChanged.listen((BatteryState state) {
      if (state == BatteryState.charging || state == BatteryState.full) {
        if (!_isPowerConnected) {
          _log('[Power] 外部電源已接上，喚醒並嘗試連線...');
          _isPowerConnected = true;
          final String savedMac = SettingsService().obdMac;
          if (savedMac.isNotEmpty) {
            connectToDevice(savedMac);
          }
        }
      } else {
        // BatteryState.discharging：斷開外部電源（停車熄火）
        if (_isPowerConnected) {
          _log('[Power] 外部電源斷開，進入深度休眠...');
          _isPowerConnected = false;
          handleDisconnect('power_disconnected');
        }
      }
    });
    _log('[Power] 電源監聽已啟動');
  }

  // =========================================================================
  // 模組二：看門狗連續超時偵測 (Watchdog Mechanism)
  // =========================================================================

  /// 連續逾時計數器，達到閾值時觸發強制斷線
  int _consecutiveTimeouts = 0;

  /// 連續逾時觸發閾值（預設 3 次 = 約 9 秒）
  static const int _watchdogThreshold = 3;

  // =========================================================================
  // 模組三：背景自動重連迴圈 (Auto-Reconnect Loop)
  // =========================================================================

  bool _isAutoReconnecting = false;
  Timer? _reconnectTimer;

  void _startAutoReconnect() {
    if (_isAutoReconnecting) return;
    _isAutoReconnecting = true;

    final String savedMac = SettingsService().obdMac;
    if (savedMac.isEmpty) {
      _log('[AutoReconnect] 無已儲存的 MAC，取消自動重連');
      _isAutoReconnecting = false;
      return;
    }

    _log('[AutoReconnect] 啟動自動重連迴圈（每 5 秒）...');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_isPowerConnected) {
        _log('[AutoReconnect] 電源已斷開，停止重連迴圈');
        _stopAutoReconnect();
        return;
      }
      if (_isConnected ||
          connectionState == ObdConnectionState.connecting ||
          connectionState == ObdConnectionState.initializing) {
        _log('[AutoReconnect] 已連線或連線中，停止迴圈');
        _stopAutoReconnect();
        return;
      }
      _log('[AutoReconnect] 嘗試重新連線...');
      await connectToDevice(savedMac);
    });
  }

  void _stopAutoReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _isAutoReconnecting = false;
    _log('[AutoReconnect] 自動重連迴圈已停止');
  }

  // =========================================================================
  // Public API
  // =========================================================================
  // 模組四：初始化與連線控管
  // =========================================================================

  /// 強制重置所有緩存數據（供外部喚醒時使用）
  void resetData() {
    _resetDataFlags();
  }

  Future<void> init() async {
    startPowerListener();
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
    sendCommand('010B0C0D'); // Turbo + RPM + Speed
    sendCommand('015B');     // HEV SOC
    sendCommand('0167');     // Coolant
    sendCommand('ATSH7C6');
    sendCommand('22B002');   // Odo, Fuel, Maintenance
    sendCommand('ATSH7A0');
    sendCommand('22C00B');   // TPMS
    sendCommand('ATSH7DF');
  }

  /// 手動觸發查詢保養資訊 (Header 7C6, PID 22B002)
  Future<void> queryMaintenanceInfo() async {
    if (!_isConnected) return;
    _log('[OBD] Manual queryMaintenanceInfo() triggered');
    await sendCommand('ATSH7C6');
    await sendCommand('22B002');
    await sendCommand('ATSH7DF');
  }

  // =========================================================================
  // 檔位探測
  // =========================================================================

  /// 開始探測。設定會存起來，之後每次連上 OBD 都自動接續。
  Future<void> startGearProbe() async {
    await SettingsService().setGearProbeEnabled(true);
    if (_gearProbeRunning) return;

    if (!_isConnected) {
      _logGear('[Probe] 尚未連線，連上 OBD 後會自動開始');
      notifyListeners();
      return;
    }

    for (final GearProbeTarget t in _gearTargets) {
      t.miss = 0;
      t.alive = true;
      t.lastPayload = null;
    }
    _gearLastHeartbeatMs = 0;
    _gearProbeRunning = true;
    notifyListeners();

    if (_gearTargets.isEmpty) {
      _gearProbeRunning = false;
      _logGear('[Probe] 監看清單是空的。即時監看只適合驗證少數幾個 DID，'
          '請先用「拍 P / R / N / D」四張快照再按「比對快照」，'
          '比對結果會自動填進監看清單。');
      notifyListeners();
      return;
    }

    _logGear('[Probe] ══ 檔位探測開始 ══');
    _logGear('[Probe] 監看 ${_gearTargets.length} 個候選 DID。'
        '切檔並觀察標 ★ 的變動行。');

    _gearPollTimer?.cancel();
    _gearPollTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _pollGear());
  }

  /// 停止探測。persist=false 用在「候選全滅」這種自動收工的情況，
  /// 設定頁的開關維持原樣，下次連線還會再試一輪。
  Future<void> stopGearProbe({bool persist = true}) async {
    if (persist) await SettingsService().setGearProbeEnabled(false);
    _gearPollTimer?.cancel();
    _gearPollTimer = null;
    if (_gearProbeRunning) {
      _gearProbeRunning = false;
      _logGear('[Probe] ══ 檔位探測停止 ══');
    }
    // 專注監看一定要跟著關掉，否則離開設定頁後時速與轉速會一直凍著
    if (_gearFocusMode) {
      _gearFocusMode = false;
      _logGear('[Probe] 專注監看已自動關閉，例行輪詢恢復');
    }
    notifyListeners();
  }

  /// 每秒輪詢一次還活著的候選。回應內容交給 _handleGearProbeResponse 記錄。
  Future<void> _pollGear() async {
    if (!_isConnected || !_gearProbeRunning) return;
    if (_scanBusy) return; // 掃描或拍快照期間讓出匯流排
    if (_gearPollBusy) return; // 上一輪還沒跑完，跳過避免疊在一起

    _gearPollBusy = true;
    try {
      final List<GearProbeTarget> alive =
          _gearTargets.where((GearProbeTarget t) => t.alive).toList();

      if (alive.isEmpty) {
        _logGear('[Probe] 所有候選位址都沒有回應，本輪收工。'
            '請把這份日誌匯出，之後改從 22BC04 的位元下手。');
        await stopGearProbe(persist: false);
        return;
      }

      for (final GearProbeTarget t in alive) {
        if (!_isConnected || !_gearProbeRunning) return;

        // Header 與查詢必須同步連續掛進 _commandChain，中間不能 await。
        // 一旦中途 await，別的輪詢會整包插進 Header 與查詢之間，
        // 查詢就在錯的 Header 底下送出、必然回 NODATA（見 _pollIgmp 的說明）。
        sendCommand('ATSH${t.header}');
        final Future<String> respFuture = sendCommand(t.cmd);
        sendCommand('ATSH7DF');
        final String resp = await respFuture;

        // 真正的逾時代表 ELM 連 NO DATA 都沒回，_parseObdResponse 根本不會被
        // 呼叫，未命中也就永遠累加不上去。第一版就是卡在這裡，日誌整片空白。
        if (resp == 'TIMEOUT' ||
            resp == 'DISCONNECTED' ||
            resp == 'WRITE_ERROR' ||
            resp == 'POWER_OFF') {
          t.miss++;
          if (t.miss == 1) {
            _logGear('[Probe] ${t.header}/${t.cmd} 無回應（$resp）');
          }
          if (t.miss >= _kGearMaxMiss) {
            t.alive = false;
            _logGear('[Probe] ${t.header}/${t.cmd} 連續 ${t.miss} 次無回應，淘汰');
          }
        }
      }
    } finally {
      _gearPollBusy = false;
    }
  }

  // ── DID 掃描 ─────────────────────────────────────────────────────────────

  /// 掃描期間正在等回應的那道指令，用來擋掉主日誌的 NoData 洪水
  String? _sweepCurrentCmd;

  void _ensureDiscoveredLoaded() {
    if (_discoveredLoaded) return;
    _discoveredLoaded = true;
    _discoveredDids.addAll(SettingsService().discoveredDids);
  }

  void _recordDiscovered(String header, String cmd) {
    final String key = '$header|$cmd';
    if (_discoveredDids.contains(key)) return;
    _discoveredDids.add(key);
  }

  // ── 檔位快照 ─────────────────────────────────────────────────────────────

  /// 把已發現的 DID 全部拍一遍，存成某個檔位的快照。
  ///
  /// 期間會停掉所有例行輪詢，整條匯流排都給快照用，一個 DID 約 0.35 秒。
  /// 這是刻意的取捨：拍照的幾十秒內檔位要停在原地不動。
  /// 拍一張快照。
  ///
  /// delaySeconds 是為了鑰匙測試而加的：手機要留在車上，人得帶著鑰匙走遠，
  /// 沒有人能在正確的時間點按下按鈕。設好延遲再按，就有時間離開車輛，
  /// 等車子真的偵測不到鑰匙時快照才開始跑。
  Future<void> captureSnapshot(String label, {int delaySeconds = 0}) async {
    if (_scanBusy) return;
    _ensureDiscoveredLoaded();

    if (_discoveredDids.isEmpty) {
      _logGear('[Snap] 還沒有任何已知 DID，請先按「探索模組」');
      return;
    }
    if (!_isConnected) {
      _logGear('[Snap] 尚未連線，無法拍快照');
      return;
    }

    _snapshotRunning = true;
    notifyListeners();
    _noteWatchSuspended('拍快照');

    final int total = _discoveredDids.length;

    if (delaySeconds > 0) {
      _logGear('[Snap] ══ $label：$delaySeconds 秒後開始拍攝 ══');
      _logGear('[Snap] 現在去做該做的動作。時間到才開始問，'
          '整段拍攝約 ${(total * 0.7).round()} 秒，期間狀態要維持住。');
      int left = delaySeconds;
      while (left > 0 && _snapshotRunning && _isConnected) {
        final int step = left >= 10 ? 10 : left;
        await Future.delayed(Duration(seconds: step));
        left -= step;
        if (left > 0) _logGear('[Snap] 還有 $left 秒');
      }
      if (!_snapshotRunning || !_isConnected) {
        _snapshotRunning = false;
        notifyListeners();
        _logGear('[Snap] 倒數中被中止，這張不算');
        return;
      }
    }

    _logGear('[Snap] ══ 開始拍攝「$label」（$total 個 DID）══');
    _logGear('[Snap] 拍攝期間請維持現狀不要動，'
        '約需 ${(total * 0.7).round()} 秒（每個 DID 連讀兩次以剔除雜訊）');

    final Map<String, String> payloads = {};
    final Map<String, String> payloadsB = {};
    int done = 0;

    try {
      for (final String key in List<String>.from(_discoveredDids)) {
        if (!_snapshotRunning || !_isConnected) break;

        final int bar = key.indexOf('|');
        final String header = key.substring(0, bar);
        final String cmd = key.substring(bar + 1);

        // 連讀兩次。Header 只切一次，兩道查詢夾在中間，成本比分兩輪低得多。
        _sweepCurrentCmd = cmd;
        sendCommand('ATSH$header');
        final Future<String> firstFuture = sendCommand(cmd, timeoutMs: 1500);
        final Future<String> secondFuture = sendCommand(cmd, timeoutMs: 1500);
        sendCommand('ATSH7DF');
        final String respA = await firstFuture;
        final String respB = await secondFuture;

        done++;
        if (done % 40 == 0) {
          _logGear('[Snap] 「$label」進度 $done/$total');
        }

        final String sig = '62${cmd.substring(2)}';
        final String? a = _extractPayload(respA, sig);
        final String? b = _extractPayload(respB, sig);
        if (a == null) continue;
        payloads[key] = a;
        if (b != null) payloadsB[key] = b;
      }
    } finally {
      _snapshotRunning = false;
      _sweepCurrentCmd = null;
      notifyListeners();
    }

    _noteWatchResumed();
    _gearSnapshots
        .add(GearSnapshot(label, DateTime.now(), payloads, payloadsB));
    _logGear('[Snap] 「$label」完成，取得 ${payloads.length}/$total 個 DID。'
        '目前已有：${gearSnapshotLabels.join(', ')}');
    notifyListeners();
  }

  /// 從回應裡取出簽章後面的 payload，沒有簽章就回 null
  String? _extractPayload(String resp, String sig) {
    final String hex =
        resp.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
    final int idx = hex.indexOf(sig);
    return idx == -1 ? null : hex.substring(idx + sig.length);
  }

  void abortSnapshot() {
    if (!_snapshotRunning) return;
    _snapshotRunning = false;
    _logGear('[Snap] 快照已中止（這一張不會存下來）');
    notifyListeners();
  }

  void clearGearSnapshots() {
    _gearSnapshots.clear();
    _logGear('[Snap] 已清除所有快照');
    notifyListeners();
  }

  /// 比對各檔位快照，找出「隨檔位改變、但同檔位下穩定」的 byte。
  ///
  /// 同一個檔位拍兩張（例如開頭與結尾各拍一次 P）就能濾掉雜訊：
  /// 引擎的滾動記錄區每次讀都不一樣，同檔位不穩定的 byte 一律排除。
  void analyzeGearSnapshots() {
    if (_gearSnapshots.length < 2) {
      _logGear('[Diff] 至少要兩張快照才能比對');
      return;
    }

    final Map<String, List<GearSnapshot>> byGear = {};
    for (final GearSnapshot snap in _gearSnapshots) {
      byGear.putIfAbsent(snap.gear, () => <GearSnapshot>[]).add(snap);
    }
    if (byGear.length < 2) {
      _logGear('[Diff] 只有 ${byGear.keys.first} 檔的快照，需要至少兩個不同檔位');
      return;
    }

    final List<String> gears = byGear.keys.toList();
    _logGear('[Diff] ══ 比對 ${gears.join(' / ')} ══');

    // 每個檔位至少兩張才有雜訊過濾能力，提醒一下但不擋
    final bool canFilterNoise =
        byGear.values.any((List<GearSnapshot> v) => v.length > 1);
    if (!canFilterNoise) {
      _logGear('[Diff] 提醒：每個檔位都只有一張快照，無法濾掉自己會飄的 byte。'
          '回到 P 再拍一張可大幅減少誤判。');
    }

    // 只比對每一張快照都取得到的 DID
    final Set<String> commonDids =
        _gearSnapshots.first.payloads.keys.toSet();
    for (final GearSnapshot snap in _gearSnapshots) {
      commonDids.retainAll(snap.payloads.keys);
    }

    int skippedLength = 0;
    int unstable = 0;
    int selfDrifting = 0;
    final List<_GearCandidate> candidates = [];

    for (final String did in commonDids) {
      // 長度不一致代表多幀組裝結果不同，直接跳過免得比錯 byte
      final Set<int> lengths = _gearSnapshots
          .map((GearSnapshot s) => s.payloads[did]!.length)
          .toSet();
      if (lengths.length != 1) {
        skippedLength++;
        continue;
      }

      final int byteCount = lengths.first ~/ 2;
      for (int i = 0; i < byteCount; i++) {
        // 雜訊遮罩：任何一張快照的兩次連讀對不起來，這個 byte 就是會自己飄的，
        // 不管跨檔位看起來多漂亮都不算數。
        bool noisy = false;
        for (final GearSnapshot snap in _gearSnapshots) {
          final String? b = snap.payloadsB[did];
          if (b == null || b.length != snap.payloads[did]!.length) continue;
          if (snap.payloads[did]!.substring(i * 2, i * 2 + 2) !=
              b.substring(i * 2, i * 2 + 2)) {
            noisy = true;
            break;
          }
        }
        if (noisy) {
          selfDrifting++;
          continue;
        }

        final Map<String, String> perGear = {};
        bool stable = true;

        for (final String gear in gears) {
          final Set<String> vals = byGear[gear]!
              .map((GearSnapshot s) =>
                  s.payloads[did]!.substring(i * 2, i * 2 + 2))
              .toSet();
          if (vals.length != 1) {
            stable = false;
            break;
          }
          perGear[gear] = vals.first;
        }

        if (!stable) {
          unstable++;
          continue;
        }
        final int distinct = perGear.values.toSet().length;
        if (distinct < 2) continue;

        candidates.add(
            _GearCandidate(did, i, distinct, perGear, lengths.first));
      }
    }

    candidates.sort((_GearCandidate a, _GearCandidate b) {
      final int byScore = b.distinct.compareTo(a.distinct);
      return byScore != 0 ? byScore : a.did.compareTo(b.did);
    });

    _logGear('[Diff] 比對 ${commonDids.length} 個 DID，'
        '略過長度不一致 $skippedLength 個、'
        '連讀兩次就自己飄的 byte $selfDrifting 個、'
        '同檔位跨快照不穩定的 byte $unstable 個');

    if (candidates.isEmpty) {
      _logGear('[Diff] 沒有任何 byte 隨檔位變動。'
          '請確認拍攝時引擎是發動的、而且每張快照的檔位真的不同。');
      return;
    }

    _logGear('[Diff] 找到 ${candidates.length} 個隨檔位變動的 byte，'
        '差異最多的排在前面：');

    final int show = candidates.length < 40 ? candidates.length : 40;
    for (int i = 0; i < show; i++) {
      final _GearCandidate c = candidates[i];
      final String detail = gears
          .map((String g) => '$g=${c.perGear[g]}')
          .join(' ');
      _logGear('[Diff★] ${c.did.replaceFirst('|', '/')} '
          'byte ${_gearByteLabel(c.byteIndex)} '
          '(${c.distinct}/${gears.length} 種) $detail');
    }
    if (candidates.length > show) {
      _logGear('[Diff] 其餘 ${candidates.length - show} 個未列出');
    }

    // 前幾名的 DID 直接換成監看清單，接著就能用「開始探測」即時驗證。
    //
    // 挑選要同時看兩件事：差異種類數，以及 payload 長度。
    // 長 payload 是多幀傳輸，實測 240 字元的 22E000 每 40~70 秒才取樣一次，
    // 20 字元的 22BC08 只要 4~17 秒 —— 前者慢到根本驗證不了切檔。
    // 所以同分時短的優先，並且直接排除過長的候選。
    _gearTargets.clear();

    // 長度只當排序偏好，不再硬性排除：開了專注監看之後長 payload 也跟得上，
    // 而且實測最有意思的 D 檔候選正好落在 240 字元的 22E000，排掉就看不到了。
    final List<_GearCandidate> pickable = List<_GearCandidate>.from(candidates)
      ..sort((_GearCandidate a, _GearCandidate b) {
        final int byScore = b.distinct.compareTo(a.distinct);
        if (byScore != 0) return byScore;
        return a.payloadChars.compareTo(b.payloadChars);
      });

    final Set<String> picked = {};
    for (final _GearCandidate c in pickable) {
      if (picked.length >= 4) break;
      if (!picked.add(c.did)) continue;
      final int bar = c.did.indexOf('|');
      final String header = c.did.substring(0, bar);
      final String cmd = c.did.substring(bar + 1);
      _gearTargets.add(
          GearProbeTarget(header, cmd, '62${cmd.substring(2)}', '檔位候選'));
    }

    if (_gearTargets.isEmpty) {
      _logGear('[Diff] 沒有可監看的候選');
    } else {
      _logGear('[Diff] 監看清單已換成 ${_gearTargets.length} 個候選 DID，'
          '開啟「專注監看」後按「開始監看」，切檔前先按對應的標記鈕。');
    }
    notifyListeners();
  }

  /// 把每個模組的 DID 家族 00~FF 逐一問過去，記下有回應的。
  ///
  /// 這是找檔位的主力手段：檔位一定在某個 Mode 22 的 DID 裡，
  /// 只是 OBD.csv 沒收錄，只能自己列舉。找到的 DID 會自動加進監看清單，
  /// 掃完再按「開始探測」切一次 P/R/N/D 就能比對。
  Future<void> startDidSweep() async {
    if (_sweepRunning) return;
    if (!_isConnected) {
      _logGear('[Sweep] 尚未連線，無法掃描');
      return;
    }

    _ensureDiscoveredLoaded();
    _sweepRunning = true;
    _sweepFound = 0;
    notifyListeners();
    _noteWatchSuspended('DID 掃描');

    _logGear('[Sweep] ══ DID 掃描開始 ══');
    _logGear('[Sweep] ${_sweepRanges.length} 個模組 × 256 個 DID。'
        '掃描期間會暫停時速/轉速輪詢，請停車怠速進行。');

    bool completed = false;
    try {
      for (final DidSweepRange range in _sweepRanges) {
        if (!_sweepRunning || !_isConnected) break;
        await _sweepOneRange(range);
      }
      completed = _sweepRunning;
    } finally {
      _sweepRunning = false;
      _sweepCurrentCmd = null;
      notifyListeners();

      if (!completed) {
        _logGear('[Sweep] ══ 掃描中止（本輪已找到 $_sweepFound 個）══');
      } else if (_sweepFound == 0) {
        _logGear('[Sweep] ══ 掃描結束，沒有任何 DID 有回應 ══');
        _logGear('[Sweep] 這代表連已知有效的 DID 都沒回，'
            '問題出在連線或 Header 切換，不是車上沒有檔位訊號。請匯出日誌。');
      } else {
        _logGear('[Sweep] ══ 掃描結束，找到 $_sweepFound 個有回應的 DID ══');
      }

      if (_discoveredDids.isNotEmpty) {
        SettingsService().setDiscoveredDids(_discoveredDids);
        _logGear('[Sweep] 已知 DID 共 ${_discoveredDids.length} 個，已存檔，'
            '重開 App 不用重掃。接著用「拍 P / R / N / D」四張快照比對。');
      }
      _noteWatchResumed();
    }
  }

  /// 動力系統模組探索。
  ///
  /// 實車確認 7E1 對 22F1xx（識別區）有回應，代表變速箱 ECU 活著、也講 UDS，
  /// 只是不知道它的資料 DID 落在哪個家族。這台是油電車，排檔訊號也可能落在
  /// 油電控制單元而不是變速箱，所以先用識別區把整排候選位址點名一遍，
  /// 活著的才花三分鐘做家族探索。點名很便宜，兩道指令就知道在不在。
  /// 點名用的模組位址，依「這一輪想找什麼」由重要到次要排列，
  /// 這樣看到目標活著就可以中止，不用等整輪跑完。
  /// 括號裡是實車點名與家族探索之後確認的身分。
  static const List<String> _moduleHeaders = [
    '7A5', // 智慧鑰匙 SMK —— 鑰匙偵測旗標的最佳候選，但第一輪誤判為不存在
    '7D4',
    '7D2',
    '7D0', // 前方雷達 FCA（22FD10 的字串自報 LogicRadar / FCA）
    '7B3', // 空調（2201xx 是溫度與風門資料）
    '7C4',
    '7A1',
    '7B1',
    '780',
    '7D6',
    '7E1', // 變速箱 TCU（活著，但資料家族只找到識別區 F1）
    '7E2', // 活著，同樣只有 F1
    '7E3', // 油電相關（22E0xx 有 21 個，字串自報 GNXDH22GAMS0）
    '7E4', // 電池管理 BMS（220102/220103 各 32 個 byte，像是電芯電壓）
    '7E5',
    '7D1',
    '7A0', // 胎壓
    '770', // 車身 IGMP（已整族掃過）
    '7C6', // 儀表 CLU（已整族掃過）
    '7E0', // 引擎 ECM（已整族掃過）
  ];

  /// 已知模組各自使用的 DID 家族（由 OBD.csv 的 78 條 Mode 22 反推）。
  /// 這幾顆不用花三分鐘做家族探索，直接掃那一族就好。
  static const Map<String, String> _knownFamilies = {
    '770': 'BC', // 車身 IGMP
    '7C6': 'B0', // 儀表 CLU
    '7E0': 'E0', // 引擎 ECM
  };

  /// 識別區 DID。任何講 UDS 的模組幾乎都會回其中一個。
  static const List<String> _livenessDids = ['22F190', '22F180'];

  Future<void> startTcuFamilyScan() async {
    if (_scanBusy) return;
    if (!_isConnected) {
      _logGear('[Family] 尚未連線，無法探索');
      return;
    }

    _ensureDiscoveredLoaded();
    _sweepRunning = true;
    _sweepFound = 0;
    notifyListeners();

    _noteWatchSuspended('模組探索');
    _logGear('[Family] ══ 模組探索開始 ══');
    _logGear('[Family] 先點名 ${_moduleHeaders.length} 個位址（約 20 秒），'
        '活著且家族還沒掃過的才進第二步');

    try {
      // ── 第一步：點名 ────────────────────────────────────────────────
      final List<String> alive = [];
      for (final String header in _moduleHeaders) {
        if (!_sweepRunning || !_isConnected) break;
        final String verdict = await _probeLiveness(header);
        if (verdict.isEmpty) {
          _logGear('[Family] $header 沒回應，跳過');
        } else {
          alive.add(header);
          _logGear('[Family✓] $header 活著（$verdict）');
        }
      }

      if (alive.isEmpty) {
        _logGear('[Family] 沒有任何模組有回應');
        return;
      }

      _logGear('[Family] 活著的位址：${alive.join(', ')}');

      // ── 第二步：逐一取得每顆模組的 DID ──────────────────────────────
      // 已經有資料的跳過；知道家族的直接掃那一族；其餘才做 256 格的家族探索。
      _logGear('[Family] 接著取得各模組的 DID。'
          '找到目標就可以按「中止探索」，前面掃到的都已存檔。');

      for (final String header in alive) {
        if (!_sweepRunning || !_isConnected) break;

        final bool haveData =
            _discoveredDids.any((String d) => d.startsWith('$header|'));
        final String? known = _knownFamilies[header];

        if (haveData && known != null) {
          _logGear('[Family] $header 的 22$known 家族先前已掃完，跳過');
          continue;
        }
        if (known != null) {
          _logGear('[Family] $header 已知家族是 22$known，直接掃這一族');
          await _sweepOneRange(
              DidSweepRange(header, known, '$header 家族 22$known'));
          continue;
        }
        await _scanFamiliesOf(header);
      }
    } finally {
      _sweepRunning = false;
      _sweepCurrentCmd = null;
      notifyListeners();

      if (_discoveredDids.isNotEmpty) {
        SettingsService().setDiscoveredDids(_discoveredDids);
      }
      _logGear('[Family] ══ 探索結束，本輪新增 $_sweepFound 個 DID，'
          '已知 DID 共 ${_discoveredDids.length} 個 ══');
      _noteWatchResumed();
    }
  }

  /// 對一個位址的 256 個家族各試 22XX00 / 22XX01，有回應的家族再整族掃完
  Future<void> _scanFamiliesOf(String header) async {
    _logGear('[Family] ── $header 家族探索（22XX00 / 22XX01）──');
    final List<String> families = [];

    for (int hi = 0; hi <= 0xFF; hi++) {
      if (!_sweepRunning || !_isConnected) return;

      final String fam = hi.toRadixString(16).padLeft(2, '0').toUpperCase();
      bool hit = false;
      for (final String lo in ['00', '01']) {
        if (await _probeOneDid(header, '22$fam$lo')) {
          hit = true;
          break;
        }
      }
      if (hit) {
        families.add(fam);
        _logGear('[Family✓] $header 家族 22$fam 有回應');
      }
      if ((hi + 1) % 64 == 0) {
        _logGear('[Family] $header 進度 ${hi + 1}/256，'
            '找到 ${families.length} 個家族');
      }
    }

    if (families.isEmpty) {
      _logGear('[Family] $header 沒有任何資料家族有回應');
      return;
    }

    _logGear('[Family] $header 找到家族：${families.join(', ')}，開始逐一掃完');
    for (final String fam in families) {
      if (!_sweepRunning || !_isConnected) break;
      // F1 是識別區，掃過也沒有檔位，跳過省三分鐘
      if (fam == 'F1') continue;
      await _sweepOneRange(DidSweepRange(header, fam, '$header 家族 22$fam'));
    }
  }

  /// 點名一個位址。回傳空字串代表不在，否則回傳判定依據。
  ///
  /// 第一版只認「回得出 62F190 這種正回應」，結果實車把 770 判成不存在 ——
  /// 但整份日誌裡 770 的 22BC03 到 22BC10 全部答得好好的。原因是那顆模組
  /// 不支援識別區那幾個 DID，於是回了負回應 7F 22 31（要求超出範圍），
  /// 而負回應被當成沒回應丟掉了。
  ///
  /// 負回應其實是最有力的存在證明：模組聽到了、也答了，只是不支援這個 DID。
  /// 所以 7F 22 要跟正回應一樣算數。7A5 智慧鑰匙先前判定不存在，很可能就是
  /// 同一個誤判。
  Future<String> _probeLiveness(String header) async {
    for (final String did in _livenessDids) {
      if (!_sweepRunning || !_isConnected) return '';

      _sweepCurrentCmd = did;
      sendCommand('ATSH$header');
      final Future<String> respFuture = sendCommand(did, timeoutMs: 1500);
      sendCommand('ATSH7DF');
      final String resp = await respFuture;

      final String hex =
          resp.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');

      if (hex.contains('62${did.substring(2)}')) {
        _sweepFound++;
        _recordDiscovered(header, did);
        return '$did 正回應';
      }
      // 7F 22 xx：負回應。最後那個 byte 是原因碼，31 = 要求超出範圍。
      final int nrc = hex.indexOf('7F22');
      if (nrc != -1) {
        final String code = hex.length >= nrc + 6
            ? hex.substring(nrc + 4, nrc + 6)
            : '??';
        return '$did 負回應 7F22$code，模組存在但不支援這個 DID';
      }
    }
    return '';
  }

  /// 問一個 DID，有回應就記進已知清單並回傳 true
  Future<bool> _probeOneDid(String header, String cmd) async {
    _sweepCurrentCmd = cmd;
    sendCommand('ATSH$header');
    final Future<String> respFuture = sendCommand(cmd, timeoutMs: 1500);
    sendCommand('ATSH7DF');
    final String resp = await respFuture;

    final String hex =
        resp.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
    final int idx = hex.indexOf('62${cmd.substring(2)}');
    if (idx == -1) return false;

    _sweepFound++;
    _recordDiscovered(header, cmd);
    return true;
  }

  void stopDidSweep() {
    if (!_sweepRunning) return;
    _sweepRunning = false;
    notifyListeners();
  }

  Future<void> _sweepOneRange(DidSweepRange range) async {
    _logGear('[Sweep] ── ${range.header} / 22${range.prefix}00~FF'
        '（${range.note}）──');
    int found = 0;

    for (int lo = 0; lo <= 0xFF; lo++) {
      if (!_sweepRunning || !_isConnected) return;

      final String did = '${range.prefix}'
          '${lo.toRadixString(16).padLeft(2, '0').toUpperCase()}';
      final String cmd = '22$did';

      // Header 與查詢要同步連續掛進 _commandChain，中間不能 await，
      // 否則查詢會在別的 Header 底下送出（見 _pollIgmp 的說明）。
      _sweepCurrentCmd = cmd;
      sendCommand('ATSH${range.header}');
      final Future<String> respFuture = sendCommand(cmd, timeoutMs: 1500);
      sendCommand('ATSH7DF');
      final String resp = await respFuture;

      // 每 64 個報一次進度，掃兩分鐘畫面才不會完全沒動
      if ((lo + 1) % 64 == 0) {
        _logGear('[Sweep] ${range.header}/${range.prefix} '
            '進度 ${lo + 1}/256，本區間已找到 $found 個');
      }

      final String hex =
          resp.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
      final int idx = hex.indexOf('62$did');
      if (idx == -1) continue;

      found++;
      _sweepFound++;
      final String payload = hex.substring(idx + 6);
      _logGear('[Sweep✓] ${range.header}/$cmd 有回應 payload=$payload');
      _recordDiscovered(range.header, cmd);
    }

    _logGear('[Sweep] ${range.header}/${range.prefix} 掃完，有回應 $found 個');
  }

  /// 每筆探測日誌都帶上當下的轉速與車速。
  /// 比對時要靠這兩個值排除「跟著轉速連續變動」的 byte —— 那是引擎資料不是檔位。
  String _gearContext() {
    final int r = rpm ?? 0;
    final int s = speed ?? 0;
    final String ratio = (s > 0 && r > 0) ? (r / s).toStringAsFixed(1) : '-';
    return 'rpm=$r spd=$s ratio=$ratio';
  }

  /// byte 位置用 OBD.csv 的字母表示法（A = payload 第一個 byte）。
  ///
  /// 超過 Z 之後 CSV 是接 AA、AB、AC（例如 22E004 的電瓶 SOC 寫成 AD），
  /// 不是從頭再來一輪，所以這裡也照它的規則接下去，對照公式才不會錯位。
  String _gearByteLabel(int index) {
    // 試算表欄位那種雙射 26 進位：A..Z, AA..AZ, BA..BZ, ...
    // 第一版寫成「AA 之後接 AA+1」，實車日誌印出 AC+2 這種 CSV 裡不存在的
    // 標號，對照公式會直接找不到。
    int n = index + 1;
    String out = '';
    while (n > 0) {
      final int r = (n - 1) % 26;
      out = String.fromCharCode(0x41 + r) + out;
      n = (n - 1) ~/ 26;
    }
    return out;
  }

  /// 列出兩筆 payload 之間變動的 byte
  String _gearDiff(String prev, String now) {
    final int n = prev.length < now.length ? prev.length : now.length;
    final List<String> diffs = [];
    for (int i = 0; i + 2 <= n; i += 2) {
      final String a = prev.substring(i, i + 2);
      final String b = now.substring(i, i + 2);
      if (a != b) diffs.add('${_gearByteLabel(i ~/ 2)}:$a→$b');
    }
    if (prev.length != now.length) {
      diffs.add('長度 ${prev.length ~/ 2}→${now.length ~/ 2} byte');
    }
    return diffs.isEmpty ? '(內容相同)' : diffs.join(' ');
  }

  /// 檔位探測掛勾。回傳 true 代表這筆回應由探測處理掉了，不再走一般解析。
  ///
  /// 刻意放在 _isAtResponse 的判斷之前：NODATA 也是探測要的資訊
  /// （代表這個位址不通），被當成 AT 回應濾掉就看不到了。
  bool _handleGearProbeResponse(String sanitized, String lastCmd) {
    if (!_gearProbeRunning) return false;

    GearProbeTarget? target;
    for (final GearProbeTarget t in _gearTargets) {
      if (t.cmd == lastCmd && t.header == _activeHeader) {
        target = t;
        break;
      }
    }
    if (target == null) return false;

    final int idx = sanitized.indexOf(target.sig);
    if (idx == -1) {
      target.miss++;
      if (target.miss == 1) {
        _logGear('[Probe] ${target.header}/${target.cmd} 沒有 ${target.sig} '
            '回應（${target.note}）raw=$sanitized');
      }
      if (target.miss >= _kGearMaxMiss) {
        target.alive = false;
        _logGear('[Probe] ${target.header}/${target.cmd} 連續 ${target.miss} 次'
            '沒回應，淘汰此候選');
      }
      return true;
    }

    target.miss = 0;
    final String payload = sanitized.substring(idx + target.sig.length);
    final String prev = target.lastPayload ?? '';

    if (target.lastPayload == null) {
      target.lastPayload = payload;
      _logGear('[Gear] ${target.header}/${target.cmd} 通了（${target.note}）'
          '首筆 payload=$payload ${_gearContext()}');
      return true;
    }

    if (payload == prev) {
      // 沒變就不記，只在每 10 秒補一筆心跳，讓日誌看得出探測還活著
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - _gearLastHeartbeatMs >= 10000) {
        _gearLastHeartbeatMs = nowMs;
        _logGear('[Gear] ${target.header}/${target.cmd} 不變 payload=$payload '
            '${_gearContext()}');
      }
      return true;
    }

    _logGear('[Gear★] ${target.header}/${target.cmd} '
        '${_gearDiff(prev, payload)} | payload=$payload ${_gearContext()}');
    target.lastPayload = payload;
    return true;
  }

  void _enqueueBarometricPressureQuery() {
    if (!_isConnected) return;
    sendCommand('0133');
  }

  void onGpsAltitudeChanged(double newAltitude) {
    if (referenceGpsAltitude == null) {
      referenceGpsAltitude = newAltitude;
      _log('[GPS] 初始化基準高度：$newAltitude m，請求大氣壓');
      _enqueueBarometricPressureQuery();
      return;
    }

    final double delta = (newAltitude - referenceGpsAltitude!).abs();
    if (delta > 50.0) {
      referenceGpsAltitude = newAltitude;
      _log('[GPS] 高度變化 $delta m > 50 m，更新大氣壓');
      _enqueueBarometricPressureQuery();
    }
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

        // 連線成功：停止自動重連 + 看門狗計數歸零
        _stopAutoReconnect();
        _consecutiveTimeouts = 0;

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

  @override
  void dispose() {
    _batterySubscription?.cancel();
    _batterySubscription = null;
    handleDisconnect('dispose');
    _logController.close();
    _maintenanceLogController.close();
    super.dispose();
  }

  // =========================================================================
  // 模組四：統一斷線處理器 (Centralized Disconnect Handler)
  // =========================================================================

  void handleDisconnect(String reason) {
    if (!_isConnected && connectionState == ObdConnectionState.disconnected) {
      return;
    }

    // 清空數據與旗標
    _resetDataFlags();
    _log('[OBD] --- Disconnected: $reason ---');

    _isConnected = false;
    connectionState = ObdConnectionState.disconnected;

    // 清理 Polling Timers
    _fastPollTimer?.cancel();
    _fastPollTimer = null;
    _slowPollTimer?.cancel();
    _slowPollTimer = null;
    _minutePollTimer?.cancel();
    _minutePollTimer = null;
    _longPollTimer?.cancel();
    _longPollTimer = null;
    _igmpPollTimer?.cancel();
    _igmpPollTimer = null;
    _drivePollTimer?.cancel();
    _drivePollTimer = null;
    _drivePollBusy = false;
    _gearPollTimer?.cancel();
    _gearPollTimer = null;
    // 探測旗標歸零，重連後由 _startPollingTasks 依設定重新啟動
    _gearProbeRunning = false;
    _gearPollBusy = false;
    // 掃描沒有自動續掃：斷線代表這一輪的結果不完整，讓使用者自己重跑
    _sweepRunning = false;
    _sweepCurrentCmd = null;

    // 清理 RX Buffer 與 Completer（打破死鎖）
    _rxBuffer.clear();
    if (_pendingCompleter != null && !_pendingCompleter!.isCompleted) {
      _pendingCompleter!.complete('DISCONNECTED');
    }
    _pendingCompleter = null;

    // 清空 Command Chain（打破舊 chain 的死鎖）
    _connectionEpoch++;
    _commandChain = Future.value();

    // 取消資料流訂閱
    _dataSubscription?.cancel();
    _dataSubscription = null;

    // 通知原生層斷線
    _methodChannel.invokeMethod('disconnect').catchError((_) {});

    // ── 核心重連判定（嚴格邊界條件）────────────────────────────────────────
    // 手動斷線、電源斷開、dispose、電源感知斷線 → 進入深度休眠，不重連
    const Set<String> noReconnectReasons = {
      'power_disconnected',
      'dispose',
      'manual_disconnect',
    };

    final bool shouldReconnect = _isPowerConnected &&
        !noReconnectReasons.any((r) => reason.startsWith(r));

    if (reason == 'power_disconnected') {
      _isFirstConnectOfSession = true;
      _log('[OBD] 電源斷開，重置首次連線旗標 (Safety Sweep Lock)');
    }

    if (shouldReconnect) {
      _log('[OBD] 將在 5 秒後嘗試自動重連...');
      _startAutoReconnect();
    } else {
      _log('[OBD] 進入深度休眠，不重連（reason=$reason）');
      _stopAutoReconnect();
    }
  }

  // =========================================================================
  // 核心：發送指令並 await 回應
  // =========================================================================

  Future<String> sendCommand(String cmd, {int timeoutMs = 3000}) {
    final Completer<String> resultCompleter = Completer<String>();

    _commandChain = _commandChain.then((_) async {
      final int epoch = _connectionEpoch;

      // ── 電源感知防呆：斷電時阻止所有無效發送 ─────────────────────────────
      if (!_isPowerConnected) {
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete('POWER_OFF');
        }
        return;
      }

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
        _log('[Parser TX] ${cmd.trim()}');
        _lastSentCmd = cmd.trim().toUpperCase().replaceAll(' ', '');
        if (_lastSentCmd.startsWith('ATSH')) {
          _activeHeader = _lastSentCmd.substring(4);
        }
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
        await resultCompleter.future.timeout(Duration(milliseconds: timeoutMs));

        // ── 成功收到回應：看門狗計數歸零 ────────────────────────────────────
        _consecutiveTimeouts = 0;
      } on TimeoutException {
        _log('[OBD] Timeout waiting for: ${cmd.trim()}');

        // ── 看門狗累加 ───────────────────────────────────────────────────────
        _consecutiveTimeouts++;
        _log('[Watchdog] 連續逾時次數：$_consecutiveTimeouts / $_watchdogThreshold');

        if (!resultCompleter.isCompleted) {
          resultCompleter.complete('TIMEOUT');
        }
        _pendingCompleter = null;

        // ── 達到看門狗閾值：強制斷線打破死鎖 ───────────────────────────────
        if (_consecutiveTimeouts >= _watchdogThreshold) {
          _log('[Watchdog] 達到閾值，強制斷線！清空 command chain...');
          _consecutiveTimeouts = 0; // 重置後再斷線，防止下次重連後立即再觸發
          handleDisconnect('watchdog_timeout');
        }
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
      _log('[OBD] ATH0 → ${await mustSend('ATH0')}'); // Headers Off
      _log('[OBD] ATS0 → ${await mustSend('ATS0')}'); // Spaces Off
      _log(
          '[OBD] ATAL → ${await mustSend('ATAL')}'); // Allow Long messages（多幀合併輸出）
      _log(
          '[OBD] ATST32→ ${await mustSend('ATST32')}'); // Timeout = 0x32 * 4ms = ~200ms
      _log('[OBD] ATAT1 → ${await mustSend('ATAT1')}'); // 自動調整時序
      _log(
          '[OBD] ATSP6 → ${await mustSend('ATSP6')}'); // 直接鎖定 ISO 15765-4 CAN 11-bit 500K

      _log('[OBD] --- Init Complete ---');
      connectionState = ObdConnectionState.connected;

      // 1. 觸發掃跡動畫訊號 (僅在電源開啟後的第一次連線時觸發)
      if (_isFirstConnectOfSession) {
        _log('[OBD] 首次連線，觸發掃跡動畫 (WAKEUP)');
        _shouldTriggerWakeup = true;
        notifyListeners();
        _shouldTriggerWakeup = false;
        _isFirstConnectOfSession = false;
      } else {
        _log('[OBD] 靜默重連，跳過掃跡動畫');
      }

      _log('[OBD] --- Deep Sync Starting (Timeout: 1s per cmd) ---');

      // 2. 深度同步：一次性讀取核心靜態數據 (使用 await 確保順序)
      try {
        await sendCommand('015B', timeoutMs: 1000); // HEV 電量
        await sendCommand('ATSH7DF', timeoutMs: 1000);
        await sendCommand('0167', timeoutMs: 1000); // 水溫
        await sendCommand('ATSH7C6', timeoutMs: 1000);
        await sendCommand('22B002', timeoutMs: 1000); // 里程與油量
        await sendCommand('ATSH7A0', timeoutMs: 1000);
        await sendCommand('22C00B', timeoutMs: 1000); // 胎壓
        await sendCommand('ATSH7DF', timeoutMs: 1000); // 重置廣播 Header
      } catch (e) {
        _log('[OBD] Deep sync sequence interrupted: $e');
      }

      _log('[OBD] --- Deep Sync Done, starting real-time poll ---');

      // 3. 最後啟動即時輪詢任務
      _startPollingTasks();
    } catch (e) {
      _log('[OBD] Init FAILED: $e → triggering disconnect');
      handleDisconnect('init_failed: $e');
    }
  }

  // =========================================================================
  // RX: 資料到達處理
  // =========================================================================

  void _resetDataFlags() {
    rpm = null;
    speed = null;
    coolantTemp = null;
    voltage = null;
    hevSoc = null;
    odometer = null;
    fuelLevel = null;
    turbo = null;
    tpmsFl = null;
    tpmsFr = null;
    tpmsRl = null;
    tpmsRr = null;
    serviceDistanceRemaining = 0;
    serviceDaysRemaining = 0;

    hasRpm = false;
    hasSpeed = false;
    hasCoolant = false;
    hasVoltage = false;
    hasHevSoc = false;
    hasOdometer = false;
    hasFuel = false;
    hasTurbo = false;
    hasServiceDistanceRemaining = false;
    hasServiceDaysRemaining = false;
    hasTpms = false;
    isReversing = false;
    hasReversing = false;
    isDriveGear = false;
    hasDriveGear = false;
    isLowBeamOn = false;
    isHighBeamOn = false;
    hasHeadlights = false;
    isDoorFlOpen = false;
    isDoorFrOpen = false;
    isDoorRlOpen = false;
    isDoorRrOpen = false;
    isTrunkOpen = false;
    hasDoors = false;
    isDoorUnlocked = false;
    hasDoorLock = false;
    _beamBitsSeenG = 0;
    _beamBitsSeenH = 0;
    _activeHeader = '7DF';
    _igmpHeaderLocked = null;
    _igmpFailStreak = 0;
    _igmpPollBusy = false;
    _igmpGiveUp = false;
    _fuelBuffer.clear();
  }

  bool isDataReady() {
    return hasRpm &&
        hasSpeed &&
        hasCoolant &&
        hasVoltage &&
        hasHevSoc &&
        hasOdometer &&
        hasFuel &&
        hasTpms;
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
        _log('[OBD] Stream error: $err');
        handleDisconnect('stream_error: $err');
      },
    );
  }

  void _onDataReceived(Uint8List data) {
    _rxBuffer.write(ascii.decode(data, allowInvalid: true));

    final String buf = _rxBuffer.toString();

    if (buf.endsWith('>')) {
      final String sanitized = buf
          .replaceAll(' ', '')
          .replaceAll('\r', '')
          .replaceAll('\n', '')
          .replaceAll('>', '')
          .toUpperCase()
          .replaceAll(RegExp(r'[0-9A-F]:'), '');

      if (sanitized.isNotEmpty) {
        _log('[Parser RX] cmd=$_lastSentCmd raw=$sanitized');
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

    // 檔位探測的候選回應在這裡就處理掉（含 NODATA），不往下走一般解析
    if (_handleGearProbeResponse(sanitized, lastCmd)) return;

    // 掃描的回應由 _sweepOneRange 自己判讀。不擋的話 1024 道查詢會在主日誌
    // 灌進上千行 [Parser NoData]，真正有用的那幾行反而被沖掉。
    if (_scanBusy && lastCmd == _sweepCurrentCmd) return;

    if (_isAtResponse(sanitized)) {
      if (lastCmd == '0105') {
        _log('[Parser 0105] AT response (NODATA?): $sanitized');
      }
      return;
    }

    try {
      // ── 1. 01 系列：指令隔離 + 標籤搜尋 (Label Search) ──────────────────
      if (lastCmd.startsWith('01')) {
        final int idx41 = sanitized.indexOf('41');
        if (idx41 == -1) return; // 無效回應

        // ─── 合併指令 010B0C0D：僅解析 MAP/RPM/Speed ───────────
        if (lastCmd == '010B0C0D') {
          // 依 PID 的固定資料長度逐段走訪，不要用 indexOf 找字串。
          //
          // 舊寫法是 sanitized.indexOf('0B')，等於在整串十六進位裡找那兩個
          // 字元。ECU 若不支援 0B 就不會回它，但轉速資料本身可能長得像：
          // 704~767 rpm 的高位元組正好是 0x0B，回應變成 410C0B54，
          // indexOf 就會把轉速的低位元組當成 MAP 讀走，算出憑空的增壓值。
          // 實測這個區間有 64 個轉速值會中招。
          const Map<String, int> pidLen = {'0B': 1, '0C': 2, '0D': 1};
          final Map<String, String> vals = {};
          int walk = idx41 + 2;
          while (walk + 2 <= sanitized.length) {
            final String pid = sanitized.substring(walk, walk + 2);
            final int? len = pidLen[pid];
            if (len == null) break; // 不認識就停，不再往下猜
            if (walk + 2 + len * 2 > sanitized.length) break;
            vals[pid] = sanitized.substring(walk + 2, walk + 2 + len * 2);
            walk += 2 + len * 2;
          }

          // MAP (0B)
          final String? hexMap = vals['0B'];
          if (hexMap != null) {
            try {
              final int mapKpa = int.parse(hexMap, radix: 16);
              turboBoostBar = (mapKpa - currentBaroKpa) / 100.0;
              turbo = double.parse(turboBoostBar.toStringAsFixed(2));
              hasTurbo = true;
              _mapMissingLogged = false;
              _log('[Parser Result] Turbo=$turbo Bar (MAP=$mapKpa kPa)');
            } catch (_) {}
          } else if (!_mapMissingLogged) {
            // 只講一次，否則每 300 毫秒洗一行
            _mapMissingLogged = true;
            hasTurbo = false;
            _log('[Parser Result] 回應裡沒有 0B，本車不回報 MAP，'
                '增壓無法用歧管壓力推算 raw=$sanitized');
          }

          // RPM (0C)
          final String? hexRpm = vals['0C'];
          if (hexRpm != null) {
            try {
              final int a = int.parse(hexRpm.substring(0, 2), radix: 16);
              final int b = int.parse(hexRpm.substring(2, 4), radix: 16);
              final int valRpm = ((a * 256) + b) ~/ 4;
              if (valRpm <= 10000) {
                rpm = valRpm;
                hasRpm = true;
                _log('[Parser Result] RPM=$rpm');
              }
            } catch (_) {}
          }

          // Speed (0D)
          final int idx0D = vals.containsKey('0D') ? 0 : -1;
          if (idx0D != -1) {
            try {
              final int valSpeed = int.parse(vals['0D']!, radix: 16);
              if (valSpeed <= 250) {
                bool hasRecentGps = _lastGpsSpeedTime != null && 
                    DateTime.now().difference(_lastGpsSpeedTime!).inSeconds < 5;
                
                if (hasRecentGps) {
                  double diff = (valSpeed - _lastGpsSpeedKmh!).abs();
                  if (diff > 20) {
                    _log('[Parser Result] OBD速度($valSpeed)與GPS差距過大($diff km/h)，仍採用OBD值');
                  }
                }
                speed = valSpeed;
                hasSpeed = true;
                _log('[Parser Result] Speed=$speed (OBD)');
              }
            } catch (_) {}
          }
          notifyListeners();
          return;
        }

        // ─── 單一 PID 01 指令：嚴格指令隔離 ─────────

        // --- 0133 (Baro) ---
        if (lastCmd == '0133') {
          final int idx33 = sanitized.indexOf('33', idx41);
          if (idx33 != -1 && sanitized.length >= idx33 + 4) {
            final String hex = sanitized.substring(idx33 + 2, idx33 + 4);
            currentBaroKpa = int.parse(hex, radix: 16).toDouble();
            _log('[Parser Result] Baro=$currentBaroKpa kPa');
          }
          notifyListeners();
          return;
        }

        // --- 015B (HEV SOC) ---
        if (lastCmd == '015B') {
          final int idx5B = sanitized.indexOf('5B', idx41);
          if (idx5B != -1 && sanitized.length >= idx5B + 4) {
            final String hex = sanitized.substring(idx5B + 2, idx5B + 4);
            final double rawSoc = int.parse(hex, radix: 16) * 100.0 / 255.0;
            hevSoc = double.parse(rawSoc.toStringAsFixed(1));
            hasHevSoc = true;
            _log('[Parser Result] HEV SOC=$hevSoc%');
          }
          notifyListeners();
          return;
        }

        // --- 0167 (Coolant) ─── 水溫僅在此指令下更新 ---
        if (lastCmd == '0167') {
          final int idx67 = sanitized.indexOf('67', idx41);
          if (idx67 != -1 && sanitized.length >= idx67 + 8) {
            final String hexA = sanitized.substring(idx67 + 2 + 2, idx67 + 2 + 4); // 4167 CC AA
            final int raw = int.parse(hexA, radix: 16) - 40;
            if (raw >= -40 && raw <= 150) {
              coolantTemp = raw;
              hasCoolant = true;
              _log('[Parser Result] Coolant=$coolantTemp °C');
            }
          }
          notifyListeners();
          return;
        }

        return;
      }

      // ── 2. 22 系列：保留原邏輯但與 01 系列隔離 ────────────────────────
      if (lastCmd.startsWith('22')) {
        final String pid = lastCmd.substring(2);
        final String signature = '62$pid';
        final int index = sanitized.indexOf(signature);

        if (index == -1) {
          // 沒有簽章代表 ECU 沒回應這個 PID（NO DATA / 負回應 7F / Header 不對）。
          // 原本這裡靜默略過，看不出「到底有沒有抓到資料」。
          _log('[Parser NoData] $lastCmd 無 $signature 回應 raw=$sanitized');
          notifyListeners();
          return;
        }

        {
          final int payloadStart = index + signature.length;
          final String data = sanitized.substring(payloadStart);

          if (pid == 'BC03') {
            // 四門 + 尾門開啟，全在 byte E（data[4]）的不同位元。
            if (data.length >= 10) {
              final int e = int.parse(data.substring(8, 10), radix: 16);
              isDoorRlOpen = (e & 0x01) != 0; // bit0
              isDoorRrOpen = (e & 0x04) != 0; // bit2
              isDoorFrOpen = (e & 0x10) != 0; // bit4
              isDoorFlOpen = (e & 0x20) != 0; // bit5
              isTrunkOpen = (e & 0x80) != 0; // bit7
              hasDoors = true;
              // E 以二進位印出，實車上一次開一道門就能核對位元對應
              _log('[Doors] FL=$isDoorFlOpen FR=$isDoorFrOpen '
                  'RL=$isDoorRlOpen RR=$isDoorRrOpen Trunk=$isTrunkOpen '
                  '(E=0b${e.toRadixString(2).padLeft(8, '0')}) payload=$data');
            } else {
              _log('[Doors] 回應過短，無法取 E：payload=$data');
            }
          } else if (pid == 'BC04') {
            // 同一個 PID 在兩個 Header 底下意義不同，必須靠送出時的 Header 區分：
            //   302 → 目前用來判斷倒車（此 Header 未經實車驗證，見 TODO）
            //   770 → OBD.csv 標註的 IGMP，byte E 裝的是門鎖
            if (data.length >= 10) {
              final int e = int.parse(data.substring(8, 10), radix: 16);
              if (_activeHeader == '770') {
                // CSV: lookup(((E&8)>>3):'U':0='L') —— 位元設起來代表未上鎖。
                // 只有前兩門有訊號，任一未上鎖就視為整車未上鎖。
                isDoorUnlocked = (e & 0x08) != 0 || (e & 0x04) != 0;
                hasDoorLock = true;
                // 倒車不在這個 byte（實車證實 E 從頭到尾不動），改看 22BC08
                _log('[DoorLock] Unlocked=$isDoorUnlocked '
                    '(E=0b${e.toRadixString(2).padLeft(8, '0')}) payload=$data');
              } else {
                isReversing = e != 0;
                hasReversing = true;
                _log('[Parser Result] Reversing=$isReversing '
                    '(header=$_activeHeader E=0b${e.toRadixString(2).padLeft(8, '0')})');
              }
            }
          } else if (pid == 'E000') {
            // D 檔：byte N 的 bit3（見 _kDriveMask 的實車驗證紀錄）
            const int need = (_kDriveByteIndex + 1) * 2;
            if (data.length >= need) {
              final int n = int.parse(
                  data.substring(need - 2, need), radix: 16);
              final bool nowDrive = (n & _kDriveMask) != 0;
              hasDriveGear = true;
              if (nowDrive != isDriveGear) {
                isDriveGear = nowDrive;
                _log('[Parser Result] Drive=$isDriveGear '
                    '(N=0b${n.toRadixString(2).padLeft(8, '0')})');
              }
            }
          } else if (pid == 'BC08') {
            // 倒車：byte F（data[5]）的 bit3。四張快照比對出來的唯一乾淨訊號。
            if (data.length >= 12) {
              final int f = int.parse(data.substring(10, 12), radix: 16);
              final bool nowReversing = (f & _kReverseMask) != 0;
              hasReversing = true;
              if (nowReversing != isReversing) {
                isReversing = nowReversing;
                _log('[Parser Result] Reversing=$isReversing '
                    '(F=0b${f.toRadixString(2).padLeft(8, '0')})');
              }
            }
          } else if (pid == 'BC09') {
            // 位元對應見 _kBeamMaskOn / _kBeamMaskHigh 的說明
            if (data.length >= 16) {
              final int g = int.parse(data.substring(12, 14), radix: 16);
              final int h = int.parse(data.substring(14, 16), radix: 16);

              // 大燈開啟（ESP32 的日/夜亮度切換也是吃這個旗標）
              isLowBeamOn = (g & _kBeamMaskOn) != 0;
              // 遠燈在 H 不在 G
              isHighBeamOn = (h & _kBeamMaskHigh) != 0;
              hasHeadlights = true;

              _log('[Headlights] On=$isLowBeamOn High=$isHighBeamOn '
                  '(G=0b${g.toRadixString(2).padLeft(8, '0')} '
                  'H=0b${h.toRadixString(2).padLeft(8, '0')}) payload=$data');

              // 位元探勘：G / H 出現沒看過的位元就單獨印一行。
              // 兩個遮罩都已實車確認，這行留著是為了抓「還有沒有別的燈號
              // 藏在同一個 byte」——例如小燈、日行燈。
              final int newG = g & ~_beamBitsSeenG & 0xFF;
              if (newG != 0) {
                _beamBitsSeenG |= g;
                _log('[Headlights][NEW] G 出現新位元 bit${_bitList(newG)} '
                    '（G=0b${g.toRadixString(2).padLeft(8, '0')}）');
              }
              final int newH = h & ~_beamBitsSeenH & 0xFF;
              if (newH != 0) {
                _beamBitsSeenH |= h;
                _log('[Headlights][NEW] H 出現新位元 bit${_bitList(newH)} '
                    '（H=0b${h.toRadixString(2).padLeft(8, '0')}）');
              }
            } else {
              _log('[Headlights] 回應過短，無法取 G/H：payload=$data');
            }
          } else if (pid == 'C00B') {
            if (data.length >= 42) {
              tpmsFl = int.parse(data.substring(8, 10), radix: 16) / 5.0;
              tpmsFr = int.parse(data.substring(18, 20), radix: 16) / 5.0;
              tpmsRl = int.parse(data.substring(28, 30), radix: 16) / 5.0;
              tpmsRr = int.parse(data.substring(38, 40), radix: 16) / 5.0;
              hasTpms = true;
              _log(
                  '[Parser Result] TPMS FL=$tpmsFl FR=$tpmsFr RL=$tpmsRl RR=$tpmsRr');
            }
          } else if (pid == 'B002') {
            if (data.length >= 18) {
              final int g = int.parse(data.substring(12, 14), radix: 16);
              final int h = int.parse(data.substring(14, 16), radix: 16);
              final int i = int.parse(data.substring(16, 18), radix: 16);
              final int odoRaw = (g << 16) | (h << 8) | i;
              if (odoRaw > 0) {
                odometer = odoRaw.toDouble();
                hasOdometer = true;
              }
              
              // ── Fuel Level Moving Window (Length 5) ──
              try {
                final int rawFuel = int.parse(data.substring(8, 10), radix: 16);
                _fuelBuffer.add(rawFuel);
                if (_fuelBuffer.length >= 5) {
                  final List<int> sorted = List.from(_fuelBuffer)..sort();
                  // 捨棄最大與最小值，取中間 3 筆平均
                  final int sum = sorted[1] + sorted[2] + sorted[3];
                  fuelLevel = sum ~/ 3;
                  hasFuel = true;
                  _log('[Parser Result] Filtered Fuel Level: $fuelLevel (avg of mid-3 from $_fuelBuffer)');
                  _fuelBuffer.clear();
                } else {
                  _log('[Parser] Fuel Buffer: ${_fuelBuffer.length}/5 (Current=$rawFuel)');
                }
              } catch (e) {
                _log('[Parser Error] Fuel parse error: $e');
              }

              final int f = int.parse(data.substring(10, 12), radix: 16);
              voltage = double.parse((f * 0.078125).toStringAsFixed(2));
              hasVoltage = true;

              if (data.length >= 26) {
                final int byteG = int.parse(data.substring(18, 20), radix: 16);
                final int byteH = int.parse(data.substring(20, 22), radix: 16);
                final int byteI = int.parse(data.substring(22, 24), radix: 16);
                final int byteJ = int.parse(data.substring(24, 26), radix: 16);
                serviceDistanceRemaining = (byteG * 256) + byteH;
                serviceDaysRemaining = (byteI * 256) + byteJ;
                hasServiceDistanceRemaining = true;
                hasServiceDaysRemaining = true;

                _logMaintenance('Raw Data: $data');
                _logMaintenance(
                    'Maintenance Info: Dist=$serviceDistanceRemaining km, Days=$serviceDaysRemaining days');
              }
              _log('[Parser Result] Heavy Data Parsed');
            }
          }
          notifyListeners(); // 22 系列解析完成，通知 UI
          return;
        }
      }
    } catch (e) {
      _log('[Parser Error] $e | sanitized=$sanitized');
    }
  }

  /// 把位元遮罩列成人看得懂的位元編號，例如 0b11000000 -> "7, 6"
  static String _bitList(int mask) {
    final List<int> bits = [];
    for (int i = 7; i >= 0; i--) {
      if ((mask >> i) & 1 == 1) bits.add(i);
    }
    return bits.join(', ');
  }

  // ── AT 指令回應過濾器 ─────────────────────────────────────────────────────

  bool _isAtResponse(String compact) {
    const List<String> atKeywords = [
      'OK',
      'ELM',
      'ATZ',
      'ATE',
      'ATL',
      'ATS',
      'ATH',
      'ATSP',
      'NODATA',
      'UNABLETOCONNECT',
      'BUSERROR',
      'CANERROR',
      'DATAERROR',
      'ERROR',
      'SEARCHING',
      'STOPPED',
      'BUFFERFULL',
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
    _longPollTimer?.cancel();
    _igmpPollTimer?.cancel();

    _scheduleFastPoll();

    // HEV SOC 每 5 秒：使用標準 OBD PID 015B（= 100/255*A），不需切換 Header
    _slowPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_isConnected || _busReserved) return;
      sendCommand('015B');
    });

    // 水溫每 30 秒：使用 PID 0167（SAE Coolant A/B）
    _minutePollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_isConnected || _busReserved) return;
      sendCommand('0167');
      sendCommand('ATSH7C6');
      sendCommand('22B002');
      sendCommand('ATSH7A0');
      sendCommand('22C00B');
      sendCommand('ATSH7DF');
    });

    // 維護資訊每 30 分鐘：使用 PID 22B002
    _longPollTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      if (!_isConnected || _busReserved) return;
      sendCommand('ATSH7C6');
      sendCommand('22B002');
      sendCommand('ATSH7DF');
    });

    // IGMP 模組（大燈 / 車門 / 門鎖）：固定每秒一拍，
    // 實際間隔由 _pollIgmp 依車速決定（見該處說明）。
    // 三個 PID 共用同一個 Header，一次切換全部查完，比分開輪詢還省指令。
    //
    // 原本這裡還有一組 header 302 的倒車輪詢（22BC04），實車 log 證實
    // 11 次查詢全部 NODATA、從未運作過，而 NODATA 要等滿 ELM 的逾時，
    // 單次成本是正常指令的 3~5 倍，等於整條匯流排有六成耗在空轉，
    // 因此整組移除。倒車狀態改由 header 770 的 22BC08 取得（已在下面一起查），
    // byte F bit3，四檔快照比對確認 —— 見 _kReverseMask。
    _igmpPollTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _pollIgmp());

    _drivePollTimer?.cancel();
    _drivePollTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _pollDriveGear());

    // 檔位探測：設定頁開著就跟著每次連線自動接續，斷線重連不用重按
    _gearPollTimer?.cancel();
    _gearPollTimer = null;
    _gearProbeRunning = false;
    if (SettingsService().gearProbeEnabled) {
      startGearProbe();
    }
  }

  /// 大燈輪詢。Header 尚未鎖定時依序試 _igmpHeaders，
  /// 哪個拿得到 62BC09 就鎖定；鎖定後連續失敗多次會解鎖重新探測。
  Future<void> _pollIgmp() async {
    if (!_isConnected) return;
    if (_busReserved) return; // 掃描或拍快照期間讓出匯流排
    if (_igmpGiveUp) return;
    if (_igmpPollBusy) return; // 上一輪還沒跑完，跳過避免疊在一起

    // 依車速決定實際間隔：車門與門鎖幾乎只在靜止時變動，行進間查得再勤
    // 也不會有事情發生，不如把匯流排讓給 300ms 的時速/轉速快輪詢。
    // 用「固定每秒一拍 + 跳拍」而不是遞迴重排，是為了避免某一拍提早
    // return 就再也不排程（舊的倒車輪詢就有這個死角）。
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final bool moving = (speed ?? 0) > 5;
    final int minGapMs = moving ? 3000 : 1000;
    if (nowMs - _lastIgmpPollMs < minGapMs) return;
    _lastIgmpPollMs = nowMs;

    _igmpPollBusy = true;

    try {
      final List<String> headers = _igmpHeaderLocked != null
          ? [_igmpHeaderLocked!]
          : _igmpHeaders;

      for (final String header in headers) {
        if (!_isConnected) return;

        // 三道必須「同步連續」掛進 _commandChain，中間不能 await。
        // sendCommand 是在呼叫當下才把工作接到鏈上，一旦中途 await，
        // 別的輪詢（例如 30 秒那組同步掛入的 ATSH7C6/22B002/ATSH7DF）
        // 就會整包插進 Header 與查詢之間，導致 22BC09 在別的 Header 底下
        // 送出、必然回 NODATA。先把五道掛好，再去等中間那道的結果。
        sendCommand(header);
        final Future<String> respFuture = sendCommand('22BC09');
        sendCommand('22BC03'); // 四門 + 尾門開啟
        sendCommand('22BC04'); // 門鎖（此 Header 底下 byte E 是門鎖不是倒車）
        sendCommand('22BC08'); // 倒車（byte F bit3，四檔快照比對確認）
        sendCommand('ATSH7DF');
        final String resp = await respFuture;

        final bool ok = resp
            .toUpperCase()
            .replaceAll(' ', '')
            .replaceAll('\r', '')
            .contains('62BC09');

        if (ok) {
          _igmpFailStreak = 0;
          if (_igmpHeaderLocked == null) {
            _igmpHeaderLocked = header;
            _log('[Headlights] Header $header 有效，已鎖定');
          }
          return;
        }

        if (_igmpHeaderLocked == null) {
          _log('[Headlights] Header $header 取不到 62BC09，改試下一個');
        }
      }

      // 全部試過都失敗
      _igmpFailStreak++;
      if (_igmpHeaderLocked != null && _igmpFailStreak >= 5) {
        _log('[Headlights] 已鎖定的 $_igmpHeaderLocked 連續失敗 '
            '$_igmpFailStreak 次，解除鎖定重新探測');
        _igmpHeaderLocked = null;
        _igmpFailStreak = 0;
      } else if (_igmpHeaderLocked == null &&
          _igmpFailStreak >= _igmpMaxProbes) {
        _log('[Headlights] 兩個 Header 各試 $_igmpMaxProbes 次都失敗，'
            '停止大燈輪詢（本車可能不支援 22BC09）。重新連線後會再試');
        _igmpGiveUp = true;
      }
    } finally {
      _igmpPollBusy = false;
    }
  }

  /// D 檔輪詢。22E000 是 120 byte 的多幀回應，成本不低，所以用跳拍控制頻率。
  ///
  /// 靜止時每 1.5 秒問一次：換檔幾乎都發生在停車或慢速，這時候要跟得上。
  /// 行進間每 6 秒一次就夠：一路都在 D，只是留著讓狀態不會卡住不更新。
  Future<void> _pollDriveGear() async {
    if (!_isConnected) return;
    if (_busReserved) return;
    if (_drivePollBusy) return;

    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final int minGapMs = (speed ?? 0) > 5 ? 6000 : 1500;
    if (nowMs - _lastDrivePollMs < minGapMs) return;
    _lastDrivePollMs = nowMs;

    _drivePollBusy = true;
    try {
      // Header 與查詢要同步連續掛進 _commandChain，中間不能 await
      sendCommand('ATSH7E0');
      final Future<String> respFuture = sendCommand('22E000');
      sendCommand('ATSH7DF');
      await respFuture;
    } finally {
      _drivePollBusy = false;
    }
  }

  void _scheduleFastPoll() {
    const int intervalMs = 300;
    _fastPollTimer = Timer(const Duration(milliseconds: intervalMs), () {
      if (!_isConnected) return;
      // 掃描期間只跳過發送、照常重新排程。直接 return 會讓這條自我重排的
      // 鏈斷掉，掃完之後時速與轉速就再也不更新了。
      if (_busReserved) {
        _scheduleFastPoll();
        return;
      }
      // 合併請求：010B (Turbo), 010C (RPM), 010D (Speed)
      sendCommand('010B0C0D');
      _scheduleFastPoll();
    });
  }
}
