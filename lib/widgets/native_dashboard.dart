import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/obd_spp_service.dart';
import '../services/settings_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Public widget
// ─────────────────────────────────────────────────────────────────────────────

class NativeDashboard extends StatefulWidget {
  const NativeDashboard({super.key});

  @override
  State<NativeDashboard> createState() => _NativeDashboardState();
}

// ─────────────────────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────────────────────

class _NativeDashboardState extends State<NativeDashboard>
    with TickerProviderStateMixin {
  // Wakeup sweep: sine 0 → 180 → 0 over 1500 ms
  late final AnimationController _wakeupCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  bool _wakeupActive = false;

  // Alert pulse (800 ms repeat, opacity 0.5 ↔ 1.0)
  late final AnimationController _pulseCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);
  late final Animation<double> _pulseAnim = Tween(begin: 0.5, end: 1.0).animate(
    CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
  );

  // Card highlight controllers (420 ms, forward = flash fades out)
  static const _cardIds = ['battery', 'temp', 'tpms', 'odofuel', 'speedlimit'];
  late final Map<String, AnimationController> _hlCtrls = {
    for (final id in _cardIds)
      id: AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 420),
      ),
  };
  final Map<String, String?> _prevValues = {};

  // Camera alert state machine
  DateTime? _alertStartTime;
  int _minDisplayUntil = 0;
  bool _isZoneAlert = false;
  int? _lastCameraLimit;
  bool _cameraAlertVisible = false;
  Timer? _cameraCheckTimer;

  // Turbo peak detection
  double _lastTurboVal = 0;
  double? _lastTurboDir;
  double? _peakBarFraction; // 0.0–1.0 along bar width
  Timer? _peakTimer;

  // Clock
  String _timeStr = '';
  String _dateStr = '';
  Timer? _clockTimer;

  @override
  void initState() {
    super.initState();
    _timeStr = _fmtTime(DateTime.now());
    _dateStr = _fmtDate(DateTime.now());
    _clockTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;
        final now = DateTime.now();
        setState(() {
          _timeStr = _fmtTime(now);
          _dateStr = _fmtDate(now);
        });
      },
    );
    _cameraCheckTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkCameraExpiry(),
    );
    ObdSppService().addListener(_onObdChanged);
    _wakeupCtrl.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _wakeupActive = false);
      }
    });
  }

  @override
  void dispose() {
    ObdSppService().removeListener(_onObdChanged);
    _wakeupCtrl.dispose();
    _pulseCtrl.dispose();
    for (final c in _hlCtrls.values) c.dispose();
    _clockTimer?.cancel();
    _cameraCheckTimer?.cancel();
    _peakTimer?.cancel();
    super.dispose();
  }

  // ── OBD wakeup ────────────────────────────────────────────────────────────

  void _onObdChanged() {
    if (!mounted) return;
    if (ObdSppService().shouldTriggerWakeup && !_wakeupActive) {
      setState(() => _wakeupActive = true);
      _wakeupCtrl.forward(from: 0);
    }
  }

  // ── Card highlight ─────────────────────────────────────────────────────────

  void _maybeHighlight(String key, Object? value, String cardId) {
    if (value == null) return;
    final s = value.toString();
    if (_prevValues[key] != s) {
      _prevValues[key] = s;
      _hlCtrls[cardId]?.forward(from: 0);
    }
  }

  // ── Camera alert state machine ─────────────────────────────────────────────

  void _onCameraData(Map<String, dynamic>? info) {
    if (info == null) return;
    _alertStartTime ??= DateTime.now();
    _minDisplayUntil = DateTime.now().millisecondsSinceEpoch + 4000;
    _isZoneAlert = info['is_zone'] == true;
    _lastCameraLimit = info['limit'] as int?;
  }

  void _checkCameraExpiry() {
    if (!mounted) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final timedOut = _alertStartTime != null &&
        nowMs - _alertStartTime!.millisecondsSinceEpoch > 60000;
    final provider = context.read<AppProvider>();
    final hasCam = provider.nearestCameraInfo != null;
    final visible = (hasCam || nowMs < _minDisplayUntil) && !timedOut;
    if (visible != _cameraAlertVisible) {
      setState(() => _cameraAlertVisible = visible);
    }
  }

  // ── Turbo peak detection ───────────────────────────────────────────────────

  double _processTurbo(double? raw, int? rpm) {
    double v = raw ?? 0.0;
    final threshold = (rpm == 0) ? 0.05 : 0.02;
    if (v.abs() < threshold) v = 0.0;

    final diff = v - _lastTurboVal;
    if (diff.abs() >= 0.005) {
      final dir = diff > 0 ? 1.0 : -1.0;
      if (_lastTurboDir != null && dir != _lastTurboDir) {
        final peak = _turboFraction(_lastTurboVal);
        _peakTimer?.cancel();
        setState(() => _peakBarFraction = peak);
        _peakTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => _peakBarFraction = null);
        });
      }
      _lastTurboDir = dir;
    }
    _lastTurboVal = v;
    return v;
  }

  // Converts turbo value (range -1…+1) to 0.0–1.0 bar fraction
  double _turboFraction(double v) {
    // Range -1 to +1, zero is at 0.5
    return (v.clamp(-1.0, 1.0) + 1.0) / 2.0;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// DateTime.weekday 是 1(一) ~ 7(日)，索引 0 空著不用
  static const List<String> _weekdayNames = [
    '',
    '週一',
    '週二',
    '週三',
    '週四',
    '週五',
    '週六',
    '週日',
  ];

  String _fmtDate(DateTime t) => '${t.year}/'
      '${t.month.toString().padLeft(2, '0')}/'
      '${t.day.toString().padLeft(2, '0')} '
      '${_weekdayNames[t.weekday]}';

  double _displaySpeed(AppProvider p) {
    if (p.obdSpeed != null) return p.obdSpeed!.toDouble();
    final pos = p.currentPosition;
    if (pos != null) {
      final km = pos.speed * 3.6;
      return km > 1.5 ? km : 0.0;
    }
    return 0.0;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();

    // Camera alert
    _onCameraData(provider.nearestCameraInfo);

    // Card highlights
    _maybeHighlight('battery', provider.obdHevSoc, 'battery');
    _maybeHighlight('temp', provider.obdCoolant, 'temp');
    _maybeHighlight(
        'tpms',
        '${provider.tpmsFl}${provider.tpmsFr}${provider.tpmsRl}${provider.tpmsRr}',
        'tpms');
    _maybeHighlight('odo', provider.obdOdometer, 'odofuel');
    _maybeHighlight('fuel', provider.obdFuel, 'odofuel');
    _maybeHighlight('roadLimit', provider.roadSpeedLimit, 'speedlimit');

    final speed = _displaySpeed(provider);
    final turbo = _processTurbo(provider.obdTurbo, provider.obdRpm);
    final isReversing = provider.isReversing;

    // Wakeup: sine-sweep overrides displayed speed for dial + text
    // Reversing: freeze dial at 0
    double dialSpeed = isReversing ? 0 : speed;
    if (_wakeupActive) {
      dialSpeed = math.sin(_wakeupCtrl.value * math.pi) * 180;
    }

    // FittedBox scales the 2400×1080 reference canvas to the actual screen.
    return AnimatedBuilder(
      animation: _wakeupCtrl,
      builder: (context, _) => FittedBox(
        fit: BoxFit.fill,
        child: SizedBox(
          width: 2400,
          height: 1080,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              Row(
                children: [
                  // P1 = 卡片寬 536，右側不留白；電池卡片的 % 落在 531，
                  // 胎壓卡片從 536 開始，兩者相距 5px。
                  SizedBox(width: 536, child: _buildP1(provider)),
                  // P2 = 卡片 _kP2CardWidth + 8 + 狀態卡片 258 + 右側留白 64
                  SizedBox(width: 755, child: _buildP2(provider)),
                  // P1 讓出的 64 全給 P3，再用右內距把內容往左推同樣的量——
                  // 只是加寬的話錶盤置中只會左移一半。右下角的系統列與狀態列
                  // 是 dashboard_screen 以 Positioned(right: 16) 貼在全螢幕上的，
                  // 不受這裡影響。
                  SizedBox(
                    width: 1109,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 64),
                      child: _buildP3(provider, dialSpeed, turbo),
                    ),
                  ),
                ],
              ),
              if (provider.isDemoEnabled)
                Positioned(
                  top: 30,
                  child: _buildDemoBadge(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers: Demo Badge
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildDemoBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: const Text(
        'DEMO MODE',
        style: TextStyle(
          color: Colors.white,
          fontSize: 32,
          fontWeight: FontWeight.bold,
          letterSpacing: 2,
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // P1: HEV Battery | Coolant | Time
  // ─────────────────────────────────────────────────────────────────────────

  /// P1 不再留右側空白：卡片直接切齊欄寬，右鄰的胎壓卡片緊接其後。
  Widget _buildP1(AppProvider p) {
    final coolant = p.obdCoolant;
    final hotAlert = coolant != null && coolant > 110;
    final coldAlert = coolant != null && coolant < 40;
    final coolantAlertColor = coldAlert
        ? const Color(0xff60a5fa) // blue-400
        : const Color(0xffff3333); // red

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 16),
      child: Column(
        children: [
          Expanded(
            child: _DataCard(
              borderColor: const Color(0xff10b981), // emerald-500
              highlightCtrl: _hlCtrls['battery']!,
              child: _bigValueCard(
                label: 'Hev電池',
                value: p.obdHevSoc != null
                    ? p.obdHevSoc!.toStringAsFixed(1)
                    : '--',
                unit: '%',
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _DataCard(
              borderColor: const Color(0xff06b6d4), // cyan-500
              highlightCtrl: _hlCtrls['temp']!,
              child: _bigValueCard(
                label: '水溫',
                value: coolant?.toString() ?? '--',
                unit: '°C',
                valueColor:
                    (hotAlert || coldAlert) ? coolantAlertColor : Colors.white,
                pulse: (hotAlert || coldAlert) ? _pulseAnim : null,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _DataCard(
              borderColor: const Color(0xfffb923c), // orange-400
              highlightCtrl: null,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _dateStr,
                        style: const TextStyle(
                          fontSize: 58,
                          fontWeight: FontWeight.bold,
                          color: Color(0xffd1d5db), // gray-300
                          height: 1.0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _timeStr,
                        style: const TextStyle(
                          fontSize: 170,
                          fontWeight: FontWeight.bold,
                          color: Color(0xffd1d5db), // gray-300
                          letterSpacing: -2,
                          height: 0.85,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // P2: TPMS | ODO+Fuel | Speed Limit / Camera Alert
  // ─────────────────────────────────────────────────────────────────────────

  /// 胎壓 / 里程 / 道路速限三張卡片的共同寬度。
  ///
  /// 以里程列的內容量出來：色條 6 + 左內距 32 + 「里程」96（CJK 48 x2）
  /// + 16 + 五位數里程 231.6（80px w900）+ 8 + 「K」30.7（48px w900）
  /// = 420.3，右邊界再留 5px → 425。
  /// 里程滿六位數時內容會多 46px，該列包了 FittedBox 會等比縮，不會溢出。
  static const double _kP2CardWidth = 425;

  Widget _buildP2(AppProvider p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 64, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Row(
              children: [
                SizedBox(width: _kP2CardWidth, child: _buildTpmsCard(p)),
                const SizedBox(width: 8),
                // 狀態燈區的左邊界即三張卡片的右邊界
                SizedBox(width: 258, child: _buildStatusPanel(p)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SizedBox(width: _kP2CardWidth, child: _buildOdoFuelCard(p)),
          ),
          const SizedBox(height: 8),
          Expanded(
            child:
                SizedBox(width: _kP2CardWidth, child: _buildSpeedLimitCard(p)),
          ),
        ],
      ),
    );
  }

  Widget _buildTpmsCard(AppProvider p) {
    bool isLow(int? v) => v != null && v > 0 && v < 32;

    Widget tpmsVal(int? v) {
      final alert = isLow(v);
      final t = Text(
        v?.toString() ?? '--',
        style: TextStyle(
          fontSize: 96,
          fontWeight: FontWeight.bold,
          color: alert ? const Color(0xffff3333) : Colors.white,
          height: 1.0,
        ),
      );
      return alert ? FadeTransition(opacity: _pulseAnim, child: t) : t;
    }

    return _DataCard(
      borderColor: const Color(0xfff97316), // orange-500
      highlightCtrl: _hlCtrls['tpms']!,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '胎壓 (PSI)',
                style: TextStyle(
                  fontSize: 51,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 2,
                ),
              ),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // FittedBox 是三位數胎壓值時的安全網，正常兩位數不會縮
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        SizedBox(width: 180, child: tpmsVal(p.tpmsFl)),
                        tpmsVal(p.tpmsFr),
                      ],
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        SizedBox(width: 180, child: tpmsVal(p.tpmsRl)),
                        tpmsVal(p.tpmsRr),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 胎壓卡片右邊的狀態燈區：2x2 指示燈（大燈 / 車門 / 門鎖 / 尾門）。
  /// 純黑底、無卡片外框，只有亮起的燈看得見。
  ///
  /// 每格固定佔位，圖示只在狀態成立時顯示（Visibility 保留尺寸）——
  /// 若改成不成立就不放進 tree，四個格子會隨狀態互相推擠、位置跳來跳去。
  Widget _buildStatusPanel(AppProvider p) {
    // 格寬要吃得下最寬的圖示：大燈的長寬比是 455:350，
    // 高 84 時實際寬度約 109，所以格子不能只比 iconSize 大一點。
    const double cellSize = 112;
    const double iconSize = 84;
    const Color warn = Color(0xfff59e0b); // amber-500
    const Color ok = Color(0xff22c55e); // green-500
    const Color high = Color(0xff3b82f6); // blue-500

    Widget slot(bool active, Widget icon) => SizedBox(
          width: cellSize,
          height: cellSize,
          child: Center(
            child: Visibility(
              visible: active,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: icon,
            ),
          ),
        );

    // 這裡刻意不用 _DataCard：它一定會畫左側色條與灰色漸層底。
    // 狀態燈要的是純黑底、沒有色條，直接透出畫面背景即可。
    return Center(
      child: SizedBox(
        width: cellSize * 2,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                // 大燈。遠燈時轉藍，比照車規儀表的慣例；
                // 遠燈一定伴隨大燈開啟，所以顯示條件仍是 isLowBeamOn。
                slot(
                  p.isLowBeamOn,
                  _HeadlightIcon(
                    size: iconSize,
                    color: p.isHighBeamOn ? high : ok,
                  ),
                ),
                // 任一車門開啟
                slot(p.isAnyDoorOpen,
                    const _DoorsOpenIcon(size: iconSize, color: warn)),
              ],
            ),
            Row(
              children: [
                // 任一車門解鎖（22BC04 只有前兩門有訊號）
                slot(p.isDoorUnlocked,
                    const Icon(Icons.lock_open, size: iconSize, color: warn)),
                // 後車廂開啟
                slot(p.isTrunkOpen,
                    const _TrunkOpenIcon(size: iconSize, color: warn)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOdoFuelCard(AppProvider p) {
    final fuelAlert = p.obdFuel != null && p.obdFuel! < 20;

    Widget fuelText() {
      final t = Text(
        p.obdFuel?.toString() ?? '--',
        style: TextStyle(
          fontSize: 96,
          fontWeight: FontWeight.w900,
          color: fuelAlert ? const Color(0xffff3333) : Colors.white,
        ),
      );
      return fuelAlert ? FadeTransition(opacity: _pulseAnim, child: t) : t;
    }

    return _DataCard(
      borderColor: const Color(0xff6366f1), // indigo-500
      highlightCtrl: _hlCtrls['odofuel']!,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 卡片寬度是照五位數里程量的；滿六位數時等比縮，不溢出
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  const Text('里程',
                      style: TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                          color: Colors.white)),
                  const SizedBox(width: 16),
                  Text(
                    p.obdOdometer != null
                        ? p.obdOdometer!.toStringAsFixed(0)
                        : '--',
                    style: const TextStyle(
                        fontSize: 80,
                        fontWeight: FontWeight.w900,
                        color: Colors.white),
                  ),
                  const SizedBox(width: 8),
                  const Text('K',
                      style: TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.w900,
                          color: Color(0xff6b7280))),
                ],
              ),
            ),
            const Divider(color: Color(0xff1f2937), thickness: 2, height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                const Text('油箱',
                    style: TextStyle(
                        fontSize: 51,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                const SizedBox(width: 16),
                fuelText(),
                const SizedBox(width: 8),
                const Text('%',
                    style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.w900,
                        color: Color(0xff6b7280))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeedLimitCard(AppProvider p) {
    final borderColor = const Color(0xffdc2626); // red-600

    // Camera alert mode
    if (_cameraAlertVisible) {
      return _DataCard(
        borderColor: borderColor,
        highlightCtrl: _hlCtrls['speedlimit']!,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FadeTransition(
                opacity: _pulseAnim,
                child: Text(
                  _isZoneAlert ? '區間測速' : '測速照相',
                  style: const TextStyle(
                    fontSize: 56,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 2,
                  ),
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _lastCameraLimit?.toString() ?? '--',
                      style: const TextStyle(
                        fontSize: 280, // increased from 220
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Normal speed limit
    return _DataCard(
      borderColor: borderColor,
      highlightCtrl: _hlCtrls['speedlimit']!,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '道路速限',
              style: TextStyle(
                fontSize: 56,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 2,
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    p.roadSpeedLimit.toString(),
                    style: const TextStyle(
                      fontSize: 280, // increased from 220
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // P3: Speed Dial + Turbo Bar
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildP3(AppProvider p, double speed, double turbo) {
    final rpm = p.obdRpm;
    final isEv = rpm == 0;
    final isReversing = p.isReversing;
    final speedInt = speed.round();
    final bigSpeed = speedInt > 99;

    // Speed-over-limit glow
    final ocrEnabled = SettingsService().enableOcr;
    final limit = p.currentSpeedLimit;
    final isOverLimit =
        ocrEnabled && limit != null && limit > 0 && speedInt > limit + 10;

    return Column(
      children: [
        Expanded(
          flex: 3,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Arc dial (animated) — 最大化圓的大小，只留底部少量間距
              Padding(
                padding: const EdgeInsets.only(top: 95), // 再度下移 20 單位 (累計下移 45)
                child: _AnimatedDial(speed: speed),
              ),

              // Speed + RPM text，略偏下置於圓弧下半部
              Padding(
                padding: const EdgeInsets.only(top: 275), // 同步下移 20 單位
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Speed number：3位數縮小字型確保不超出圓；倒車時顯示 R
                    Text(
                      isReversing ? 'R' : speedInt.toString(),
                      style: TextStyle(
                        fontSize: isReversing ? 380 : (bigSpeed ? 340 : 380),
                        fontWeight: FontWeight.w900,
                        color: isReversing
                            ? const Color(0xfffbbf24) // amber-400
                            : (isOverLimit
                                ? const Color(0xffffcccc)
                                : Colors.white),
                        height: 0.9,
                        letterSpacing: bigSpeed ? -10 : -4,
                        shadows: isOverLimit && !isReversing
                            ? [
                                Shadow(
                                  color: Colors.red.withValues(alpha: 0.9),
                                  blurRadius: 60,
                                ),
                              ]
                            : null,
                      ),
                    ),
                    SizedBox(height: bigSpeed ? 45 : 15), // 補償回調的 20 單位，維持轉速位置
                    // RPM row
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          rpm == null
                              ? '--'
                              : isEv
                                  ? 'EV'
                                  : rpm.toString(),
                          style: TextStyle(
                            fontSize: isEv ? 175 : 160,
                            fontWeight:
                                isEv ? FontWeight.w900 : FontWeight.bold,
                            color: isEv
                                ? const Color(0xff4ade80) // green-400
                                : rpm == null
                                    ? const Color(0xff6b7280)
                                    : const Color(0xff60a5fa), // blue-400
                            fontStyle:
                                isEv ? FontStyle.italic : FontStyle.normal,
                            letterSpacing: isEv ? 7.0 : 0.0,
                            height: 1.0,
                          ),
                        ),
                        if (rpm != null && !isEv)
                          const Padding(
                            padding: EdgeInsets.only(left: 12, bottom: 10),
                            child: Text(
                              'R',
                              style: TextStyle(
                                fontSize: 52,
                                fontWeight: FontWeight.w900,
                                color: Color(0xff6b7280),
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 1,
          child: _buildTurboSection(turbo),
        ),
      ],
    );
  }

  Widget _buildTurboSection(double turbo) {
    final sign = turbo >= 0 ? '+' : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          180, 42, 270, 0), // 從 top 10/bottom 32 調整為 top 42/bottom 0
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Value label: Use symmetrical Row to align the decimal point to center
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Invisible dummy to balance the " BAR" suffix on the right
              const Opacity(
                opacity: 0,
                child: Text(
                  ' BAR',
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                '$sign${turbo.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 110,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  height: 1.0,
                ),
              ),
              const Text(
                ' BAR',
                style: TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.w900,
                  color: Colors.white70,
                  height: 1.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 30, // reduced height
            width: 750,
            child: CustomPaint(
              painter: _TurboBarPainter(
                turbo: turbo,
                peakFraction: _peakBarFraction,
              ),
            ),
          ),
          const SizedBox(height: 4),
          // Tick labels
          SizedBox(
            width: 750,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _tickLabel('-1'),
                _tickLabel('-0.5'),
                _tickLabel('0'),
                _tickLabel('+0.5'),
                _tickLabel('+1'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tickLabel(String s) => Text(
        s,
        style: const TextStyle(
          fontSize: 40,
          color: Color(0xff6b7280),
          fontWeight: FontWeight.bold,
        ),
      );

  // ─────────────────────────────────────────────────────────────────────────
  // Reusable: big-value card content
  // ─────────────────────────────────────────────────────────────────────────

  Widget _bigValueCard({
    required String label,
    required String value,
    required String unit,
    Color valueColor = Colors.white,
    Animation<double>? pulse,
  }) {
    Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.bottomLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 240, // increased from 200
                fontWeight: FontWeight.w900,
                color: valueColor,
                height: 1.0,
                letterSpacing: -2,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          unit,
          style: const TextStyle(
            fontSize: 72,
            fontWeight: FontWeight.bold,
            color: Color(0xff6b7280),
          ),
        ),
      ],
    );

    if (pulse != null) row = FadeTransition(opacity: pulse, child: row);

    return Padding(
      // 右內距只留 5：數值撐滿 FittedBox 時單位會貼到卡片右緣附近，
      // 「% 右方 5px」＝卡片右緣，胎壓卡片就從那裡開始。
      padding: const EdgeInsets.fromLTRB(32, 24, 5, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 56, // reverted to 56 from 64
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: 4,
            ),
          ),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: row)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _DataCard: card with colored left border + highlight flash
// ─────────────────────────────────────────────────────────────────────────────

class _DataCard extends StatelessWidget {
  final Color borderColor;
  final AnimationController? highlightCtrl;
  final Widget child;

  const _DataCard({
    required this.borderColor,
    required this.highlightCtrl,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final base = Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: borderColor, width: 6)),
        gradient: LinearGradient(
          colors: [
            const Color(0xff1f2937).withValues(alpha: 0.6),
            Colors.transparent,
          ],
        ),
      ),
      child: child,
    );

    final ctrl = highlightCtrl;
    if (ctrl == null) return base;

    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, _) {
        final t = ctrl.value; // 0 = just fired, 1 = done
        return Stack(
          children: [
            base,
            if (t < 0.95)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 10,
                child: Opacity(
                  opacity: (1.0 - t).clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.9),
                          Colors.transparent,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.white.withValues(alpha: 0.35),
                          blurRadius: 24,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _AnimatedDial: speed arc with smooth 300 ms transition
// ─────────────────────────────────────────────────────────────────────────────

class _AnimatedDial extends StatefulWidget {
  final double speed;
  const _AnimatedDial({required this.speed});

  @override
  State<_AnimatedDial> createState() => _AnimatedDialState();
}

class _AnimatedDialState extends State<_AnimatedDial>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  late Animation<double> _anim;
  double _from = 0;

  @override
  void initState() {
    super.initState();
    _anim = Tween(begin: 0.0, end: widget.speed).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
  }

  @override
  void didUpdateWidget(_AnimatedDial old) {
    super.didUpdateWidget(old);
    if (old.speed != widget.speed) {
      _from = _anim.value;
      _anim = Tween(begin: _from, end: widget.speed).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
      );
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => CustomPaint(
        painter: _SpeedDialPainter(speed: _anim.value),
        child: const SizedBox.expand(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _SpeedDialPainter: 270° arc, blue→amber→red by speed
// ─────────────────────────────────────────────────────────────────────────────

class _SpeedDialPainter extends CustomPainter {
  final double speed;
  static const _maxSpeed = 180.0;
  // Arc: 270° starting at -225° (bottom-left, clockwise to bottom-right)
  static const _startAngle = -225 * math.pi / 180; // -5π/4
  static const _sweepFull = 270 * math.pi / 180; // 3π/2

  const _SpeedDialPainter({required this.speed});

  static const double _strokeWidth = 12; // 線徑從 36 變細至 12

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius =
        (math.min(size.width, size.height) * 1.18 / 2) - _strokeWidth / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Background track
    canvas.drawArc(
      rect,
      _startAngle,
      _sweepFull,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.1)
        ..strokeWidth = _strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );

    // Progress arc
    final progress = (speed / _maxSpeed).clamp(0.0, 1.0);
    if (progress > 0) {
      canvas.drawArc(
        rect,
        _startAngle,
        _sweepFull * progress,
        false,
        Paint()
          ..color = _speedColor(speed)
          ..strokeWidth = _strokeWidth
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }

    // Speed ticks (Every 10 km/h: 0, 10, 20, 30, ...)
    const double majorTickLen = 30.0;
    const double minorTickLen = 15.0;

    for (double s = 0; s <= _maxSpeed; s += 10) {
      final angle = _startAngle + (s / _maxSpeed) * _sweepFull;
      final dx = math.cos(angle);
      final dy = math.sin(angle);

      final isMajor = (s % 20 == 0);
      final isHighSpeed = s >= 120;
      final isMidSpeed = s >= 80 && s < 120;

      final color = isHighSpeed
          ? const Color(0xffef4444)
          : (isMidSpeed
              ? const Color(0xfff59e0b)
              : Colors.white.withValues(alpha: 0.4));

      final currentTickLen = isMajor ? majorTickLen : minorTickLen;

      // Draw tick line
      canvas.drawLine(
        Offset(center.dx + dx * (radius - currentTickLen),
            center.dy + dy * (radius - currentTickLen)),
        Offset(center.dx + dx * radius, center.dy + dy * radius),
        Paint()
          ..color = color
          ..strokeWidth = isMajor ? 8 : 5 // 次刻度稍微細一點
          ..strokeCap = StrokeCap.round,
      );

      // Draw corresponding number only for major ticks
      if (isMajor) {
        final tp = TextPainter(
          text: TextSpan(
            text: s.toInt().toString(),
            style: TextStyle(
              color: isHighSpeed
                  ? const Color(0xffef4444)
                  : (isMidSpeed
                      ? const Color(0xfff59e0b)
                      : Colors.white.withValues(alpha: 0.7)),
              fontSize: 42,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        // Position number inside the arc
        final textDist = radius - majorTickLen - 37; // 因圓周調至 1.18，同步微調偏移量
        final tx = center.dx + dx * textDist - (tp.width / 2);
        final ty = center.dy + dy * textDist - (tp.height / 2);
        tp.paint(canvas, Offset(tx, ty));
      }
    }
  }

  Color _speedColor(double s) {
    if (s > 140) return const Color(0xffef4444); // red
    if (s > 100) return const Color(0xfff59e0b); // amber
    return const Color(0xff3b82f6); // blue
  }

  @override
  bool shouldRepaint(_SpeedDialPainter old) => old.speed != speed;
}

// ─────────────────────────────────────────────────────────────────────────────
// _TurboBarPainter: bidirectional bar, zero at 33.33%, peak marker
// ─────────────────────────────────────────────────────────────────────────────

class _TurboBarPainter extends CustomPainter {
  final double turbo;
  final double? peakFraction;

  const _TurboBarPainter({required this.turbo, this.peakFraction});

  @override
  void paint(Canvas canvas, Size size) {
    final barTop = 5.0;
    final barBottom = size.height - 5.0;
    final barH = barBottom - barTop;
    final zeroX = size.width / 2; // ±1 range, center is 0

    // Background track
    final bgRRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, barTop, size.width, barH),
      const Radius.circular(24),
    );
    canvas.drawRRect(
      bgRRect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.08)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      bgRRect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // Active bar
    if (turbo > 0) {
      final fraction = (turbo / 1).clamp(0.0, 1.0);
      final barW = fraction * (size.width / 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(zeroX, barTop, barW, barH),
          const Radius.circular(24),
        ),
        Paint()
          ..color = const Color(0xffff3333)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(zeroX, barTop, barW, barH),
          const Radius.circular(24),
        ),
        Paint()..color = const Color(0xffff3333),
      );
    } else if (turbo < 0) {
      final fraction = ((-turbo) / 1).clamp(0.0, 1.0);
      final barW = fraction * (size.width / 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(zeroX - barW, barTop, barW, barH),
          const Radius.circular(24),
        ),
        Paint()..color = const Color(0xff60a5fa), // blue-400
      );
    }

    // Tick marks
    final tickPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..strokeWidth = 2;
    for (final fx in [0.0, 0.25, 0.75, 1.0]) {
      final x = fx * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), tickPaint);
    }

    // Zero line (extends above and below the bar)
    canvas.drawRect(
      Rect.fromLTWH(zeroX - 2, 0, 4, size.height),
      Paint()..color = Colors.white.withValues(alpha: 0.5),
    );

    // Peak marker
    if (peakFraction != null) {
      final px = peakFraction! * size.width;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(px - 2.5, 2, 5, size.height - 4),
          const Radius.circular(2),
        ),
        Paint()
          ..color = const Color(0xffff3333)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(px - 2.5, 2, 5, size.height - 4),
          const Radius.circular(2),
        ),
        Paint()..color = const Color(0xffff3333),
      );
    }
  }

  @override
  bool shouldRepaint(_TurboBarPainter old) =>
      old.turbo != turbo || old.peakFraction != peakFraction;
}

// ─────────────────────────────────────────────────────────────────────────────
// 大燈圖示（車規近燈符號：D 形燈罩 + 五道向左下的光線）
//
// Material 內建沒有這個符號（Icons.highlight 是燈泡），改用 CustomPainter
// 直接畫，省掉一份圖檔，也不會在大尺寸下糊掉。
// 座標以 455×350 的參考畫布定義，繪製時等比縮放。
// ─────────────────────────────────────────────────────────────────────────────

class _HeadlightIcon extends StatelessWidget {
  const _HeadlightIcon({required this.size, required this.color});

  /// 圖示高度；寬度依 455:350 的比例推得
  final double size;
  final Color color;

  static const double _refW = 455;
  static const double _refH = 350;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size * _refW / _refH,
      height: size,
      child: CustomPaint(painter: _HeadlightIconPainter(color)),
    );
  }
}

class _HeadlightIconPainter extends CustomPainter {
  const _HeadlightIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.height / _HeadlightIcon._refH;
    canvas.scale(s);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 30
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 燈罩：左邊直、右邊鼓成半圓的 D 形
    final lamp = Path()
      ..moveTo(238, 60)
      ..lineTo(268, 60)
      ..cubicTo(368, 60, 426, 112, 426, 174)
      ..cubicTo(426, 236, 368, 288, 268, 288)
      ..lineTo(238, 288)
      ..close();
    canvas.drawPath(lamp, paint);

    // 五道光線，等距、一律向左下傾斜
    for (int i = 0; i < 5; i++) {
      final double yRight = 80.0 + i * 50.0;
      canvas.drawLine(
        Offset(196, yRight),
        Offset(48, yRight + 38),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_HeadlightIconPainter old) => old.color != color;
}

// ─────────────────────────────────────────────────────────────────────────────
// 車門開啟圖示
//
// 這個是圖檔不是 CustomPainter：手繪的版本怎麼調都像昆蟲，改用來源圖。
// assets/icons/door_open.png 已預先處理成「純 alpha 遮罩」——
// 去掉白底與浮水印、RGB 全填白，只有 alpha 記錄形狀，
// 因此可以用 BlendMode.srcIn 任意上色，換顏色不必重做圖。
// ─────────────────────────────────────────────────────────────────────────────

class _DoorsOpenIcon extends StatelessWidget {
  const _DoorsOpenIcon({required this.size, required this.color});

  /// 圖示高度；寬度依圖檔的 170:164 比例推得
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/icons/door_open.png',
      height: size,
      width: size * 170 / 164,
      color: color,
      colorBlendMode: BlendMode.srcIn,
      filterQuality: FilterQuality.medium,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 後車廂開啟圖示（側視車身 + 掀起的尾門）
// ─────────────────────────────────────────────────────────────────────────────

class _TrunkOpenIcon extends StatelessWidget {
  const _TrunkOpenIcon({required this.size, required this.color});

  final double size;
  final Color color;

  static const double _refW = 240;
  static const double _refH = 200;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size * _refW / _refH,
      height: size,
      child: CustomPaint(painter: _TrunkOpenPainter(color)),
    );
  }
}

class _TrunkOpenPainter extends CustomPainter {
  const _TrunkOpenPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.height / _TrunkOpenIcon._refH);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 車身側面（封閉輪廓）
    final body = Path()
      ..moveTo(22, 146)
      ..lineTo(20, 120)
      ..cubicTo(24, 110, 36, 106, 48, 104)
      ..lineTo(76, 102)
      ..lineTo(102, 60)
      ..lineTo(166, 60)
      ..lineTo(190, 146)
      ..close();
    canvas.drawPath(body, stroke);

    // 掀起的尾門：自車頂後緣向右上翻起
    canvas.drawLine(const Offset(166, 60), const Offset(216, 32), stroke);
    canvas.drawLine(const Offset(216, 32), const Offset(226, 46), stroke);

    // 車輪
    canvas.drawCircle(const Offset(68, 152), 20, stroke);
    canvas.drawCircle(const Offset(152, 152), 20, stroke);
  }

  @override
  bool shouldRepaint(_TrunkOpenPainter old) => old.color != color;
}
