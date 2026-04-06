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
  Timer? _clockTimer;

  @override
  void initState() {
    super.initState();
    _timeStr = _fmtTime(DateTime.now());
    _clockTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (mounted) setState(() => _timeStr = _fmtTime(DateTime.now()));
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

  // Converts turbo value (range -1…+2) to 0.0–1.0 bar fraction
  double _turboFraction(double v) {
    if (v >= 0) return 1 / 3 + (v.clamp(0, 2) / 2) * (2 / 3);
    return 1 / 3 + (v.clamp(-1, 0)) * (1 / 3);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

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

    // Wakeup: sine-sweep overrides displayed speed for dial + text
    double dialSpeed = speed;
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
          child: Row(
            children: [
              SizedBox(width: 600, child: _buildP1(provider)),
              SizedBox(width: 600, child: _buildP2(provider)),
              SizedBox(
                width: 1200,
                child: _buildP3(provider, dialSpeed, turbo),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // P1: HEV Battery | Coolant | Time
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildP1(AppProvider p) {
    final coolant = p.obdCoolant;
    final hotAlert = coolant != null && coolant > 110;
    final coldAlert = coolant != null && coolant < 40;
    final coolantAlertColor = coldAlert
        ? const Color(0xff60a5fa) // blue-400
        : const Color(0xffff3333); // red

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 64, 16),
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
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _timeStr,
                    style: const TextStyle(
                      fontSize: 200,
                      fontWeight: FontWeight.bold,
                      color: Color(0xffd1d5db), // gray-300
                      letterSpacing: -2,
                      height: 0.85,
                    ),
                  ),
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

  Widget _buildP2(AppProvider p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 64, 16),
      child: Column(
        children: [
          Expanded(child: _buildTpmsCard(p)),
          const SizedBox(height: 8),
          Expanded(child: _buildOdoFuelCard(p)),
          const SizedBox(height: 8),
          Expanded(child: _buildSpeedLimitCard(p)),
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
            const Text(
              '胎壓 (PSI)',
              style: TextStyle(
                fontSize: 51,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 2,
              ),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      SizedBox(width: 180, child: tpmsVal(p.tpmsFl)),
                      tpmsVal(p.tpmsFr),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      SizedBox(width: 180, child: tpmsVal(p.tpmsRl)),
                      tpmsVal(p.tpmsRr),
                    ],
                  ),
                ],
              ),
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
            Row(
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
                  child: Text(
                    _lastCameraLimit?.toString() ?? '--',
                    style: const TextStyle(
                      fontSize: 180,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      height: 1.0,
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
                child: Text(
                  p.roadSpeedLimit.toString(),
                  style: const TextStyle(
                    fontSize: 180,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    height: 1.0,
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
    final speedInt = speed.round();
    final bigSpeed = speedInt > 99;

    // Speed-over-limit glow
    final ocrEnabled = SettingsService().enableOcr;
    final limit = p.currentSpeedLimit;
    final isOverLimit =
        ocrEnabled && limit != null && limit > 0 && speedInt > limit + 10;

    return Column(
      children: [
        // ── 70%: Dial + text ──────────────────────────────────────────────
        Expanded(
          flex: 7,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Arc dial (animated) — 最大化圓的大小，只留底部少量間距
              Padding(
                padding: const EdgeInsets.only(top: 60),
                child: _AnimatedDial(speed: speed),
              ),

              // Demo Mode Badge
              if (p.isDemoEnabled)
                Positioned(
                  top: 40,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
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
                  ),
                ),

              // Speed + RPM text，略偏下置於圓弧下半部
              Padding(
                padding: const EdgeInsets.only(top: 150),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Speed number：3位數縮小字型確保不超出圓
                    Text(
                      speedInt.toString(),
                      style: TextStyle(
                        fontSize: bigSpeed ? 340 : 380,
                        fontWeight: FontWeight.w900,
                        color: isOverLimit
                            ? const Color(0xffffcccc)
                            : Colors.white,
                        height: 0.9,
                        letterSpacing: bigSpeed ? -10 : -4,
                        shadows: isOverLimit
                            ? [
                                Shadow(
                                  color: Colors.red.withValues(alpha: 0.9),
                                  blurRadius: 60,
                                ),
                              ]
                            : null,
                      ),
                    ),
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
                            fontSize: 160,
                            fontWeight: FontWeight.bold,
                            color: isEv
                                ? const Color(0xff4ade80) // green-400
                                : rpm == null
                                    ? const Color(0xff6b7280)
                                    : const Color(0xff60a5fa), // blue-400
                            fontStyle:
                                isEv ? FontStyle.italic : FontStyle.normal,
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
        // ── 30%: Turbo bar ────────────────────────────────────────────────
        Expanded(
          flex: 3,
          child: _buildTurboSection(turbo),
        ),
      ],
    );
  }

  Widget _buildTurboSection(double turbo) {
    final sign = turbo >= 0 ? '+' : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(180, 8, 270, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Value label
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$sign${turbo.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 110,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const TextSpan(
                  text: ' BAR',
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.w900,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
            style: const TextStyle(
              color: Colors.white,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 16),
          // Bar
          SizedBox(
            height: 60, // extra height for zero-line overflow
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
                _tickLabel('0'),
                _tickLabel('+1'),
                _tickLabel('+2'),
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
                fontSize: 200,
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
      padding: const EdgeInsets.fromLTRB(32, 24, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 56,
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

  static const double _strokeWidth = 36;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) / 2) - _strokeWidth / 2;
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
    final barTop = 10.0;
    final barBottom = size.height - 10.0;
    final barH = barBottom - barTop;
    final zeroX = size.width / 3;

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
      final fraction = (turbo / 2).clamp(0.0, 1.0);
      final barW = fraction * (size.width * 2 / 3);
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
      final barW = fraction * (size.width / 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(zeroX - barW, barTop, barW, barH),
          const Radius.circular(24),
        ),
        Paint()..color = const Color(0xff60a5fa), // blue-400
      );
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
