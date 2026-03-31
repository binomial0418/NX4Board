import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/services/camera_service.dart';

void main() {
  group('CameraAlgorithm.matchDirection', () {
    // 簡稱
    bool? md(String direct, double? heading) =>
        CameraAlgorithm.matchDirection(direct, heading);

    // ── 雙向 ─────────────────────────────────────────────────────────────────
    group('雙向 → 永遠通過', () {
      test('雙向', () => expect(md('雙向', 90), true));
      test('南北雙向', () => expect(md('南北雙向', 180), true));
      test('東西雙向', () => expect(md('東西雙向', 0), true));
      test('雙向(區間測速)', () => expect(md('雙向(區間測速)', 45), true));
      test('南北向 (軸向標記)', () => expect(md('南北向', 270), true));
      test('東西向 (軸向標記)', () => expect(md('東西向', 0), true));
      test('南北相向 → null（無法識別，不過濾）', () => expect(md('南北相向', 90), null));
    });

    // ── 雙向（兩方向並列字串）────────────────────────────────────────────────
    group('雙方向並列字串', () {
      test('南向60北向70', () => expect(md('南向60北向70', 0), true));
      test('北向50南向60', () => expect(md('北向50南向60', 180), true));
      test('南向北(區間測速) 北向南(區間測速)', () =>
          expect(md('南向北(區間測速) 北向南(區間測速)', 45), true));
    });

    // ── 數字方位角 ───────────────────────────────────────────────────────────
    group('數字方位角', () {
      test('heading=90, cam=90 → 吻合', () => expect(md('90', 90), true));
      test('heading=90, cam=135 → 差45° → 恰在門檻(不含)→ false',
          () => expect(md('135', 90), false));
      test('heading=90, cam=50 → 差40° → true', () => expect(md('50', 90), true));
      test('heading=90, cam=270 → 差180° → false', () => expect(md('270', 90), false));
      test('heading=null, cam=180 → null', () => expect(md('180', null), null));
    });

    // ── 南下 / 北上（國道用語）──────────────────────────────────────────────
    group('南下 / 北上', () {
      test('北向南：往南開(180°) → true', () => expect(md('北向南', 180), true));
      test('北向南：往北開(0°) → false', () => expect(md('北向南', 0), false));
      test('南向北：往北開(0°) → true', () => expect(md('南向北', 0), true));
      test('南向北：往南開(180°) → false', () => expect(md('南向北', 180), false));
      test('南下：往南開(180°) → true', () => expect(md('南下', 180), true));
      test('南下車道：往南開(200°) → true', () => expect(md('南下車道', 200), true));
      test('北上：往北開(350°) → true', () => expect(md('北上', 350), true));
      test('北上車道：往南開(180°) → false', () => expect(md('北上車道', 180), false));
    });

    // ── 複合基方位 ───────────────────────────────────────────────────────────
    group('複合基方位', () {
      test('北往南：往南(180°) → true', () => expect(md('北往南', 180), true));
      test('南往北：往北(10°) → true', () => expect(md('南往北', 10), true));
      test('東向西：往西(270°) → true', () => expect(md('東向西', 270), true));
      test('東向西：往東(90°) → false', () => expect(md('東向西', 90), false));
      test('西向東：往東(90°) → true', () => expect(md('西向東', 90), true));
      test('由東向西：往西(260°) → true', () => expect(md('由東向西', 260), true));
    });

    // ── 單純基方位 ───────────────────────────────────────────────────────────
    group('單純基方位', () {
      test('往南：往南(170°) → true', () => expect(md('往南', 170), true));
      test('往南：往北(5°) → false', () => expect(md('往南', 5), false));
      test('往北：往北(350°) → true', () => expect(md('往北', 350), true));
      test('往東：往東(80°) → true', () => expect(md('往東', 80), true));
      test('往西：往西(265°) → true', () => expect(md('往西', 265), true));
      test('南向：往南(190°) → true', () => expect(md('南向', 190), true));
      test('北向(區間測速)：往北(10°) → true', () => expect(md('北向(區間測速)', 10), true));
      test('北上方向：往北(5°) → true', () => expect(md('北上方向', 5), true));
      test('往北方向：往北(355°) → true', () => expect(md('往北方向', 355), true));
    });

    // ── 斜向 ─────────────────────────────────────────────────────────────────
    group('斜向', () {
      test('西南向東北：往NE(45°) → true', () => expect(md('西南向東北', 45), true));
      test('西南向東北：往SW(225°) → false', () => expect(md('西南向東北', 225), false));
      test('東北向西南：往SW(220°) → true', () => expect(md('東北向西南', 220), true));
      test('西北向東南：往SE(130°) → true', () => expect(md('西北向東南', 130), true));
      test('東南向西北：往NW(310°) → true', () => expect(md('東南向西北', 310), true));
    });

    // ── 模糊地名方向 → null ──────────────────────────────────────────────────
    group('地名方向 → null（不過濾）', () {
      test('往大溪方向', () => expect(md('往大溪方向', 90), null));
      test('往高鐵方向', () => expect(md('往高鐵方向', 90), null));
      test('往桃園', () => expect(md('往桃園', 180), null));
      test('往南港（地名非基方位）', () => expect(md('往南港', 90), null));
      test('往台66快速道路方向', () => expect(md('往台66快速道路方向', 0), null));
      test('往市區', () => expect(md('往市區', 45), null));
      test('大金往烈嶼(區間測速)', () => expect(md('大金往烈嶼(區間測速)', 90), null));
      test('烈嶼往大金(區間測速)', () => expect(md('烈嶼往大金(區間測速)', 270), null));
      test('單向', () => expect(md('單向', 90), null));
      test('多向', () => expect(md('多向', 45), null));
    });

    // ── 無 heading → null ────────────────────────────────────────────────────
    group('無 heading → null', () {
      test('北向南 + heading=null → null', () => expect(md('北向南', null), null));
      test('往南 + heading=null → null', () => expect(md('往南', null), null));
      test('西南向東北 + heading=null → null', () => expect(md('西南向東北', null), null));
    });
  });
}
