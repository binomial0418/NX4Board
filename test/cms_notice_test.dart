// 前方看板（資訊可變標誌）訊息分類：事件才念，宣導、收費、旅行時間不念。
// 範例取自 2026-10-03 TDX Live/CMS 的實際訊息。
import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/services/traffic_service.dart';

void main() {
  bool ev(String t, [int? type]) => TrafficService.isCmsEvent(TrafficService.normalizeCms(t), type);

  test('事件訊息', () {
    expect(ev('國1 高架北向27-25K壅塞 車速40以下', 7), isTrue);
    expect(ev('國1(圖)高架北52-51K內路肩散落物', 7), isTrue);
    expect(ev('5日20-6施工封(國3)雙向瑪東系統出口', 7), isTrue);
    expect(ev('10/6-7 21-06時 台78東39-43K封閉施工'), isTrue); // 省道看板沒有分類
    expect(ev('雙向151-160K移動性施工'), isTrue);
    expect(ev('清晨常有濃霧請注意路況並減速慢行'), isTrue);
  });

  test('宣導、收費、旅行時間', () {
    expect(ev('高架(至)楊梅約27分平面(至)端 約25分', 1), isFalse);
    expect(ev('國慶日連假 實施單一費率', 6), isFalse);
    expect(ev('內側車道為超車道', 6), isFalse);
    expect(ev('散落物請撥打0800-001-821'), isFalse);
    expect(ev('屏東縣 9 月車禍死亡4 人請減速慢行'), isFalse);
    expect(ev('車輛故障 應於後方 豎立警告標誌', 6), isFalse);
    expect(ev('養足精神切勿分心'), isFalse);
    expect(ev('-99'), isFalse);
    expect(ev('   '), isFalse);
  });

  test('語音', () {
    expect(TrafficService.cmsAnnouncementFor(const CmsNotice('x', '國1 北向11- 9K壅塞車速40以下', 1200)),
        '前方看板：國1 北向11- 9K壅塞車速40以下');
    expect(TrafficService.normalizeCms('  國1  高架 \n 壅塞 '), '國1 高架 壅塞');
  });
}
