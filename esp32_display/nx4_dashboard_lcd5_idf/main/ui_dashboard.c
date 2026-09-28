#include "ui_dashboard.h"
#include "pins_config.h"
#include "ui_settings.h"
#include <stdio.h>
#include <string.h>

// ─────────────────────────────────────────────────────────────────────────
// 專用字型（皆以 lv_font_conv --no-compress 產生，見各檔案標頭）
//   nx4_font_num_*    — 所有數字，Saira Semi Condensed（時速、轉速用 SemiBold，
//                       其餘 Regular）。line_height / base_line 手動改成原本
//                       Montserrat 版的值：兩者數字高度同為 0.70em，基線不動
//                       就不必重算下面的版面座標。重新產生時要記得再改一次。
//   nx4_font_tc_26    — 中文標籤 + 基本 ASCII（line_height 32）
//
// 尺寸相對 nx4_dashboard（1024x600 / 7 吋）的放大倍率，是各元件「容器」
// 的放大倍率，不是憑感覺挑的。時速與轉速沿用當初依錶盤尺寸算出的 184/92；
// 卡片則在移除時速外環、COL_W 由 272 加寬到 356 之後重新逐項算過上限
// （見 README「每張卡片各自的字級」）。
// ─────────────────────────────────────────────────────────────────────────
LV_FONT_DECLARE(nx4_font_num_100);
// 道路速限卡的數值刻意比其它卡片大 1.3 倍（96 -> 125）：這是行車時最需要
// 一眼看到的數字，也是測速照相警示共用的欄位。
LV_FONT_DECLARE(nx4_font_num_310s);
LV_FONT_DECLARE(nx4_font_num_96s);
LV_FONT_DECLARE(nx4_font_num_145);
LV_FONT_DECLARE(nx4_font_num_112);
LV_FONT_DECLARE(nx4_font_num_96);
LV_FONT_DECLARE(nx4_font_num_70);
LV_FONT_DECLARE(nx4_font_num_64t);
LV_FONT_DECLARE(nx4_font_num_46);
LV_FONT_DECLARE(nx4_font_num_48);
LV_FONT_DECLARE(nx4_font_tc_26);
LV_FONT_DECLARE(nx4_font_tc_32);
// 右側指示燈用的圖示字型。取自 Material Design Icons 的五個車用符號，
// 碼位已在產生時重映到私有區 U+E000-E004，避免 4-byte UTF-8。
LV_FONT_DECLARE(nx4_font_icons_64);
LV_FONT_DECLARE(nx4_font_icons_40);

#define F_SPEED &nx4_font_num_310s
#define F_RPM &nx4_font_num_96s
#define F_VALUE &nx4_font_num_112
#define F_CLOCK &nx4_font_num_96
// 每張卡片各自的字級，不再共用一個 F_VALUE。
// 之前全部共用 96px，是被 Hev 電池最寬的 "99.9"（四個字元）綁死的，
// 害水溫、胎壓、油箱都陪著一起縮。各自拆開後，以 fontTools 逐項算出
// 「中文標籤佔位、靠右單位、卡片高度」三重限制下的最大字級再退一點：
//   水溫 "120"  上限 125 -> 取 120
//   胎壓 "88"   上限 76  -> 取 74
//   油箱 "100"  上限 92  -> 取 88
// Hev 電池（97）與時鐘（79）本來就已經到極限，維持原樣。
// 里程更是六位數時本來就會頂到「里程」標籤，只能維持 46。
#define F_TIRE &nx4_font_num_70
#define F_FUEL &nx4_font_num_100
#define F_COOLANT &nx4_font_num_145
#define F_TURBO &nx4_font_num_64t
#define F_THROTTLE &nx4_font_num_48  // 只有數字、'-'、'%'
#define F_ODO &nx4_font_num_46
#define F_LIMIT &nx4_font_num_145
// 卡片抬頭用 32px，比內文標籤大一級。里程與油箱是「行內標籤」不是抬頭，
// 維持 26px——它們與右側的數值同一列，放大會擠掉數值的位置。
#define F_LABEL &nx4_font_tc_26
#define F_TITLE &nx4_font_tc_32
#define F_ICON &nx4_font_icons_64

// 圖示字元（UTF-8）。順序與產生腳本的 --range 對應，改動時要一起改。
#define ICO_LOW_BEAM "\xEE\x80\x80"  // U+E000 car-light-dimmed
#define ICO_HIGH_BEAM "\xEE\x80\x81" // U+E001 car-light-high
#define ICO_DOOR "\xEE\x80\x82"      // U+E002 car-door
#define ICO_UNLOCK "\xEE\x80\x83"    // U+E003 lock-open-variant（純鎖頭，不帶車門背景）
#define ICO_TRUNK "\xEE\x80\x84"     // U+E004 自製「後車廂開啟」，見 tools/build_trunk_icon.py
#define ICO_POSITION "\xEE\x80\x85"  // U+E005 car-parking-lights（小燈）
#define ICO_REAR_FOG "\xEE\x80\x86"  // U+E006 car-light-fog 鏡射，見 tools/build_rear_fog_icon.py

// 里程 / 油箱的行內標籤改用圖示取代中文字。碼位刻意從 U+E010 起跳，
// 與上面 64px 指示燈條的 U+E000-E006 分開，免得同一組位元組在不同字型下
// 代表不同圖示。
#define ICO_ODO "\xEE\x80\x90"       // U+E010 counter（里程表滾輪）
#define ICO_FUEL "\xEE\x80\x91"      // U+E011 gas-station（加油槍）
#define F_ICON_LABEL &nx4_font_icons_40

// 字距：SemiBold 筆畫仍偏重，拉開字距讓數字之間透氣
#define LS_SPEED 11
#define LS_RPM 4

// 由字型的 line_height 推得，用於排版時預留高度
#define H_SPEED 224
#define H_RPM 70
#define H_VALUE 80
#define H_CLOCK 69
#define H_TIRE 49
#define H_FUEL 72
#define H_COOLANT 104
#define H_ODO 33
#define H_LIMIT 104
#define H_LABEL 32
#define H_TITLE 38

// ── 配色（比照 rec.gif：純黑底、白字、色條分類）────────────────────────
#define C_BG 0x000000
#define C_CARD 0x0D1117
#define C_TEXT 0xFFFFFF
#define C_LABEL 0xE2E8F0
#define C_UNIT 0x8B95A5

#define C_BLUE 0x2E7DF7   // 時速進度弧、RPM
#define C_TEAL 0x14B8A6   // Hev 電池色條
#define C_CYAN 0x38BDF8   // 水溫色條
#define C_ORANGE 0xF59E0B // 胎壓色條、警示刻度
#define C_RED 0xEF4444    // 速限色條、測速照相面板底色、高速刻度
// 警示文字專用的高飽和紅。與 C_RED 分開是因為 C_RED 同時用於色條與
// 測速照相的「底色」，底色用太亮的紅會讓上面的白字變得刺眼。
#define C_ALERT 0xFF2D2D
#define C_AMBER 0xF97316  // 時鐘色條
#define C_REVERSE 0xFBBF24 // 倒車的 R，與 App 儀表同色（amber-400）
#define C_GREEN 0x22C55E
// 節氣門開度：比照手機端用 gray-400，明確次於白色的增壓數值
#define C_THROTTLE 0x9CA3AF

// ── 版面（LVGL 邏輯 1280 x 720；面板實體 720x1280 由 PPA 旋轉）──────────
// 由 nx4_dashboard（1024x600）等比重算：x 約 x1.25、y 約 x1.2。
// 字型維持原本的點陣尺寸不變，多出來的空間全部給卡片與錶盤留白。
#define PAD 18
// COL_W 是「左欄」的寬度；右欄另有 COL2_W，兩欄不必一樣寬。
// 左欄（Hev電池 / 水溫 / 時鐘）被時鐘的 "00:00" 與水溫的 "120" 綁在 310；
// 右欄（胎壓 / 里程油箱 / 速限）的內容較窄，里程改成緊湊的一組、油箱只需
// 兩位數之後收到 284，省下的 26px 直接變成中央區的寬度。
#define COL_W 300
#define COL2_W 284
#define COL1_X PAD
#define COL2_X (COL1_X + COL_W + 10)
#define CARDS_RIGHT (COL2_X + COL2_W)
#define CARDS_Y 36
#define CARD_H 205
#define CARD_GAP 18
#define ROW1_Y CARDS_Y
#define ROW2_Y (CARDS_Y + CARD_H + CARD_GAP)
#define ROW3_Y (CARDS_Y + 2 * (CARD_H + CARD_GAP))
#define ACCENT_W 6
#define VALUE_X (ACCENT_W + 14)
#define VALUE_Y 80
// 數值與標題同樣從 VALUE_X 起算，不再往右縮排（原本是 +12）。
// 靠左之後 Hev 電池只需要 289px、水溫 291px，左欄改由時鐘的 "00:00"
// （起點 14、寬 275）綁死在 300。
#define VALUE_DX 0

// ── 卡片內部的相對位移 ──────────────────────────────────────────────────
// 全部相對於卡片左上角。改 CARD_H 時這一組要一起重算，
// 否則分隔線與油箱那一列會疊在一起。
#define TITLE_Y 12

// 速限卡片右上角的次要速限。字級由標題右緣到卡片右邊界的空檔決定：
// 卡片 284 - 標題「道路速限」128 - 起點 20 - 右邊界 14 = 122px 可用。
// 以 lv_font_conv 產生的字寬實測，montserrat_48 的最壞情況「↓120」要
// 119.3px，只剩 2.7px 就貼上標題；44 的最壞情況 109.4px，留 12.6px。
// 垂直上抬 2px，讓 44px 的字與 32px 的標題看起來在同一列。
#define ALT_Y (TITLE_Y - 2)
#define F_ALT &lv_font_montserrat_44
#define DATE_Y 46
// 時鐘是少數被「寬度」而非高度卡死的：'0' 是最寬的數字（0.662 em），
// "00:00" 在 110px 下佔 315px，起點 16 → 右緣 331，卡片寬 356 還留 25px。
#define CLOCK_X 14
// 日期佔到 y=78，時鐘 79 高，在 78..205 之間置中 -> 102
#define CLOCK_Y 107
#define TIRE_X0 (ACCENT_W + 18)
#define TIRE_Y0 66
// 80px 下 "88" 寬 102。欄距 180：左欄 24..126、右欄 204..306，
// 卡片內界 342，尾端留 36。欄距不取到滿版，兩欄才不會散開。
#define TIRE_DX 120
// 列距。標題佔到 y=44，卡片高 205 → 可用 161px。兩列各 53 高時：
//   列1 52..105、列2 140..193，上緣 8、**列距 35**、下緣 12。
// 這張卡的垂直空間是固定的（161px），上緣、兩個行高、列距、下緣要共用它，
// 所以「標題到數值的間隔」「兩列的間隔」「字級」三者是同一筆預算：
//   86px → 上緣 8、列距 17     76px → 上緣 8、列距 35
//   70px → 上緣 16、列距 31   ← 現在這組
// 抬頭由 26px 放大到 32px 之後（行高 32→38），可用高度少了 6px，
// 上緣與列距各退 1~3px 吸收掉。
#define TIRE_DY 80
#define ODO_LABEL_Y 42   // 圖示行高 30（原中文標籤 32），下移 1px 維持原本的垂直中心
#define ODO_VALUE_Y 27
#define ODO_UNIT_Y 46
// 里程排成緊湊的一組「里程 XXXXXX K」。數字欄是固定寬度、靠右對齊，
// 未達六位時前方自然留空，因此位數變動時 K 不會左右跑。
// 78 = 標籤起點 20 + 「里程」26px 寬 52 + 間距 6；168 = "999999" 在 46px 的寬度。
#define ODO_VALUE_X 78
#define ODO_FIELD_W 168
#define ODO_UNIT_X (ODO_VALUE_X + ODO_FIELD_W + 6)
#define DIVIDER_Y 101
// 油箱實際只會是 1-99（外加未取得資料時的 "--"），所以數字欄置中，
// 一位數與兩位數切換時視覺重心不會跳動。欄位右界留給靠右的 % 單位。
#define FUEL_VALUE_X 78
#define FUEL_FIELD_W 174
#define FUEL_LABEL_Y 136 // 同上
#define FUEL_VALUE_Y 118
#define FUEL_UNIT_Y (FUEL_VALUE_Y + H_FUEL - 24)

// ── 中央：時速 / 轉速 / 增壓的垂直堆疊 ──────────────────────────────────
// 原本是 0-180 的圓形錶盤。拿掉外環與刻度後改成單純由上而下堆疊，
// 版面語彙與兩側卡片一致，也把橫向空間還給卡片（COL_W 272 -> 356）。
//
// 中央區從卡片右緣（CARDS_RIGHT = 634）一路到畫面右邊距 1260，共 626px。
// 指示燈改成橫排放在時速上方之後，右邊那 102px 不必再讓給它們。先前寫成 676..1158
// （482）是自己多畫的界線，白白浪費了兩側各 24px——時速因此得以再放大到 272。
//
// 這 530 是拿卡片換來的：COL_W 由 356 收到 310。原本 356 的卡片把
// 字級推到被「卡片高度」卡住，橫向就吃不滿、留白過多；收窄之後多數卡片的
// 字級幾乎不用動，時速反而從 184 放大到 248（+35%）。
//
// 轉速刻意壓到 96（時速/轉速 = 2.58），讓時速在堆疊裡明顯是主角。
// 原始設計是 150/76 = 1.97，兩者差不多大，在拿掉錶環之後主從就不夠分明。
//
// 代價：失去「目前速度佔上限多少」的視覺指示，只剩數字。
// 時速 / 轉速 / 增壓三個單位**靠右對齊到同一條線**，而且位置固定不隨
// 數值寬度變動——數值改變位數時單位若跟著跑，視覺上會很晃。
//
// 水平配置（可用範圍 CARDS_RIGHT=612 到 1266）：
//   最寬時速 "180"@310 含字距 = 551、最寬單位 "km/h"@26 = 70、間距 12
//   區塊 633 置中 → 時速 622..1173、單位右界 1255
// 數值仍然置中於 STACK_CX，所以窄數值與單位之間會留白，這是刻意的：
// 單位是固定的參考點，不是跟著數值跑的附屬物。
#define STACK_CX 897
#define UNIT_RIGHT 1255
#define UNIT_OFS (LCD_H_RES - UNIT_RIGHT)

// 由上而下。數值都以 lv_obj_set_pos() 絕對定位並自行置中，
// 因此這裡給的是每一列的「頂端 y」。
//
// 轉速與增壓刻意對齊到右欄第三張卡（道路速限，ROW3_Y 482..687）的上下緣：
//   轉速頂端 = ROW3_Y - 10 = 472      （比卡片上緣再高 10px）
// 指示燈橫排在最上面（56..127），時速接在其下（180..404）。
// 三個單位各自貼齊所屬數值的下緣：km/h 375、R 518、BAR 596。
//   增壓刻度底端 = 643 + 20 + 24 = 687（貼卡片下緣）
// 這樣中央堆疊與兩側卡片在視覺上有共同的基準線。
// 時速則置中於第一、二列卡片所在的 36..482 之間。
#define SPEED_Y 180
#define RPM_Y (ROW3_Y - 10)
#define TURBO_Y 580
#define TURBO_CX STACK_CX
#define TURBO_BAR_W 450
#define TURBO_BAR_X (TURBO_CX - TURBO_BAR_W / 2)
#define TURBO_BAR_Y 643
#define H_TURBO 45
// 增壓數值改為靠右對齊，緊鄰 BAR 單位（BAR 佔 1198..1255），
// 把左邊讓給節氣門開度。時速與轉速維持置中，只有這一列是成對的。
#define TURBO_VALUE_RIGHT 1180
// 節氣門切齊增壓長條的左緣，底部與增壓數值對齊（montserrat_48 行高 52）
#define THROTTLE_X TURBO_BAR_X
#define THROTTLE_Y (TURBO_Y + H_TURBO - 52)
#define SPEED_UNIT_Y 375
#define RPM_UNIT_Y 518
#define TURBO_UNIT_Y 596

// 狀態區：右下角，靠右對齊到此 x。大燈狀態已改為右側的圖示，這裡只剩 IP。
#define STATUS_RIGHT 1258
#define STATUS_IP_Y 650

// ── 指示燈（小燈 / 大燈 / 後霧燈 / 車門 / 門鎖 / 後車廂）─────────────────
// 原本是畫面最右側的垂直四格，那會吃掉右邊 102px（1178..1280）。
// 改成橫排放在時速上方之後，中央區從 544 變成 626，時速得以由 272 放大到 310。
//
// 以 STACK_CX 897 置中，左邊只到 CARDS_RIGHT 612，半寬上限 285。
// 80px 的圖示六格就算間距歸零也要 480、而且會黏在一起，所以縮到 64px：
// 列寬 6x64 + 5x28 = 524，佔 635..1159，離卡片 23px。
// 64px 的 line_height 是 57，ICON_Y 由 56 下移到 63，維持原本 80px 那排
// （56..127）的垂直中心，與時速之間的留白不變。
#define ICON_COUNT 6
#define ICON_H 57
#define ICON_W 64
#define ICON_DX 92                        // 64 寬 + 28 間距
#define ICON_ROW_W (ICON_COUNT * ICON_W + (ICON_COUNT - 1) * (ICON_DX - ICON_W))
#define ICON_X0 (STACK_CX - ICON_ROW_W / 2)
#define ICON_Y 63

// ── 前方路況紅條 ────────────────────────────────────────────────────────
// 夾在指示燈列與時速之間。指示燈 64px 字型行高 57，列底 63+57=120；
// 時速 310s 字型行高 224、base_line 3，數字最高的 glyph 高 219、ofs_y -2，
// 筆畫頂端在 180 + 224 - 3 - 217 = 184。兩者之間 64px，紅條高 46
// （32px 中文字行高 38 + 上下各 4）放在 129..175，上下各留約 9px。
// 寬度隨文字變動、以 STACK_CX 置中。以 Noto Sans TC 字寬實算，最長的
// 「前方9.9公里緩慢  長9.9公里  時速99」含內距 545px → 625..1170，
// 中央區左界是卡片右緣 612，不會碰到。車速必定低於速限六成（兩位數），
// 前方只掃 10 公里（長度不會到三位數），所以不會更長。
#define JAM_Y 129
#define JAM_PAD_X 20
#define JAM_PAD_Y 4

#define RPM_MAX 7000

// ── 警示門檻（達到即以紅字標示）─────────────────────────────────────────
#define ALERT_FUEL_MAX 15   // 油量 <= 15 %
#define ALERT_TIRE_MIN 30   // 胎壓 <= 30 psi
#define ALERT_COOLANT 110   // 水溫 >= 110 °C
#define WARN_TIRE_HIGH 40   // 胎壓 > 40 psi 以琥珀色文字提示（次級）

// ── 物件參考（建立一次，之後只更新數值）──────────────────────────────
static lv_obj_t *s_scr;

static lv_obj_t *s_soc_value;
static lv_obj_t *s_coolant_value;
static lv_obj_t *s_clock_value; // HH:MM
static lv_obj_t *s_date_value;
static lv_obj_t *s_tire_value[4]; // FL, FR, RL, RR
static lv_obj_t *s_odo_value;
static lv_obj_t *s_fuel_value;
// 道路速限卡片兼作測速照相警示，需要卡片本體與標題的參考
static lv_obj_t *s_limit_card;
static lv_obj_t *s_limit_title;
static lv_obj_t *s_limit_value;
static lv_obj_t *s_limit_alt;  // 另一可能的速限，前面帶上下箭頭

static lv_obj_t *s_speed_value;
static lv_obj_t *s_rpm_value;
static lv_obj_t *s_speed_unit;
static lv_obj_t *s_rpm_unit;
static lv_obj_t *s_throttle_value;
static lv_obj_t *s_turbo_value;
static lv_obj_t *s_turbo_unit;
static lv_obj_t *s_turbo_bar;

static lv_obj_t *s_status_ip;
// 時速上方六格指示燈。位置固定，不成立時以 HIDDEN 隱藏而非移除，
// 這樣其它格不會因為某一格消失而遞補過去。
static lv_obj_t *s_icon_position;
static lv_obj_t *s_icon_light;
static lv_obj_t *s_icon_rear_fog;
static lv_obj_t *s_icon_door;
static lv_obj_t *s_icon_lock;
static lv_obj_t *s_icon_trunk;
static lv_obj_t *s_jam;  // 前方路況紅條
static char s_current_ssid[36];

// ── 數值補間 ────────────────────────────────────────────────────────────
// 手機端最快也只有 3~5 Hz（受限於 OBD 輪詢），直接跳值看起來會很鈍。
// 收到新值後改用 lv_anim 在「兩筆資料的實際間隔」內線性走到新值，
// 讓 LVGL 以自己的 66 Hz 補出中間影格。動畫長度取實測間隔而非固定值，
// 這樣動畫剛好在下一筆資料抵達時結束，既不停頓也不落後。
#define ANIM_MS_MIN 60
#define ANIM_MS_MAX 500
#define ANIM_MS_FIRST 250

static int s_speed_shown;
static int s_rpm_shown;
static int s_turbo_shown; // 百分之一 Bar
// 已寫進畫面的十分之一 Bar（含正負號）。顯示只到一位小數，但補間仍以
// 百分之一為單位跑，若每一步都重設文字會白白 invalidate，所以另外記一份。
// 999 是「尚未寫過」的哨兵值，強制更新時用它繞過比較。
static int s_turbo_deci_shown = 999;
static uint32_t s_speed_last_ms;
static uint32_t s_rpm_last_ms;
static uint32_t s_turbo_last_ms;

/// 依距離上次更新的實際間隔決定動畫長度
static uint32_t anim_ms(uint32_t *last_ms) {
  uint32_t now = lv_tick_get();
  uint32_t dt = (*last_ms == 0) ? ANIM_MS_FIRST : (now - *last_ms);
  *last_ms = now;
  if (dt < ANIM_MS_MIN) dt = ANIM_MS_MIN;
  if (dt > ANIM_MS_MAX) dt = ANIM_MS_MAX;
  return dt;
}

// ── 上一次已套用的數值：相同就跳過，避免無謂的 invalidate ─────────────
static nx4_dash_data_t s_last;
static bool s_last_valid;
static bool s_stale;
static bool s_cam_active;
static bool s_cam_blink_on;

// ── 時鐘 ────────────────────────────────────────────────────────────────
// 手機每筆推送都帶當下時間，但推送率不保證剛好 1 Hz，且斷線後就不再更新。
// 因此本機保存時分秒並用 lv_timer 每秒自增，收到新封包時再校時。
static int s_clk_h = -1, s_clk_m = 0, s_clk_s = 0;

static void render_clock(void) {
  // 手機每秒都會送新的時間字串，但畫面只到分鐘。快取已顯示的內容，
  // 內容沒變就不呼叫 lv_label_set_text，避免每秒白白重繪一次。
  static char shown[8] = "";
  char buf[8];
  if (s_clk_h < 0) {
    strcpy(buf, "--:--");
  } else {
    lv_snprintf(buf, sizeof(buf), "%02d:%02d", s_clk_h, s_clk_m);
  }
  if (strcmp(buf, shown) == 0) return;
  strcpy(shown, buf);
  lv_label_set_text(s_clock_value, buf);
}

static void clock_tick_cb(lv_timer_t *timer) {
  LV_UNUSED(timer);
  if (s_clk_h < 0) return; // 尚未從手機取得時間
  // 秒數仍在本機累加，只是不顯示——手機斷線後仍需正確跨分鐘
  if (++s_clk_s >= 60) {
    s_clk_s = 0;
    if (++s_clk_m >= 60) {
      s_clk_m = 0;
      if (++s_clk_h >= 24) s_clk_h = 0;
    }
  }
  render_clock();
}

void nx4_dash_data_init(nx4_dash_data_t *data) {
  memset(data, 0, sizeof(nx4_dash_data_t));
  // 這幾個欄位的 0 都是合法讀數，不能拿 memset 的 0 當「沒資料」，
  // 否則開機還沒連上 OBD 就會顯示時速 0、轉速 EV、油量 0、增壓 +0.0，
  // 看起來像真實狀態。水溫、里程、電量、胎壓的 0 不合理，沿用 > 0 判斷即可。
  data->throttle = -1;
  data->speed = -1;
  data->rpm = -1;
  data->fuel = -1;
  data->turbo = NX4_NO_VALUE_F;
  strcpy(data->clock, "--:--:--");
  strcpy(data->date, "--/--");
}

// ── 小工具 ──────────────────────────────────────────────────────────────
static lv_obj_t *make_label(lv_obj_t *parent, const char *text,
                            const lv_font_t *font, uint32_t color) {
  lv_obj_t *label = lv_label_create(parent);
  lv_label_set_text(label, text);
  lv_obj_set_style_text_font(label, font, 0);
  lv_obj_set_style_text_color(label, lv_color_hex(color), 0);
  return label;
}

// ── 警示 ────────────────────────────────────────────────────────────────
/// alert 為真時數值轉紅字；否則使用指定的一般文字色
static void set_alert(lv_obj_t *label, bool alert, uint32_t normal_color) {
  lv_obj_set_style_text_color(
      label, lv_color_hex(alert ? C_ALERT : normal_color), 0);
}

/// rec.gif 風格的卡片：近黑底、直角、左側一道分類色條
static lv_obj_t *make_card(lv_coord_t x, lv_coord_t y, lv_coord_t w,
                           lv_coord_t h, uint32_t accent) {
  lv_obj_t *card = lv_obj_create(s_scr);
  lv_obj_set_pos(card, x, y);
  lv_obj_set_size(card, w, h);
  lv_obj_clear_flag(card, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_bg_color(card, lv_color_hex(C_CARD), 0);
  lv_obj_set_style_bg_opa(card, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(card, 0, 0);
  lv_obj_set_style_radius(card, 0, 0);
  lv_obj_set_style_pad_all(card, 0, 0);

  lv_obj_t *bar = lv_obj_create(card);
  lv_obj_set_pos(bar, 0, 0);
  lv_obj_set_size(bar, ACCENT_W, h);
  lv_obj_clear_flag(bar, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_bg_color(bar, lv_color_hex(accent), 0);
  lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(bar, 0, 0);
  lv_obj_set_style_radius(bar, 0, 0);

  return card;
}

/// 「標籤 + 大數值 + 單位」的標準卡片（Hev電池 / 水溫 / 道路速限）
static lv_obj_t *make_value_card(lv_coord_t x, lv_coord_t y, lv_coord_t w,
                                 lv_coord_t h,
                                 uint32_t accent, const char *label,
                                 const char *unit, const lv_font_t *vfont,
                                 lv_coord_t vh, lv_obj_t **out_value,
                                 lv_obj_t **out_title) {
  lv_obj_t *card = make_card(x, y, w, h, accent);

  lv_obj_t *title = NULL;
  if (label != NULL) {
    title = make_label(card, label, F_TITLE, C_LABEL);
    lv_obj_align(title, LV_ALIGN_TOP_LEFT, ACCENT_W + 14, TITLE_Y);
  }
  if (out_title != NULL) *out_title = title;

  // 數值緊接在標籤下方（靠上），單位對齊數值下緣
  lv_obj_t *value = make_label(card, "--", vfont, C_TEXT);
  lv_obj_align(value, LV_ALIGN_TOP_LEFT, VALUE_X, VALUE_Y);

  // 單位貼齊數值下緣，因此要用該卡片自己的行高，不能用共用常數
  if (unit != NULL) {
    lv_obj_t *u = make_label(card, unit, &lv_font_montserrat_22, C_UNIT);
    lv_obj_align(u, LV_ALIGN_TOP_RIGHT, -14, VALUE_Y + vh - 24);
  }

  *out_value = value;
  return card;
}

// ── 左側第一欄：Hev電池 / 水溫 / 時鐘 ───────────────────────────────────
static void build_column1(void) {
  make_value_card(COL1_X, ROW1_Y, COL_W, CARD_H, C_TEAL, "Hev電池", "%", F_VALUE,
                  H_VALUE, &s_soc_value, NULL);
  make_value_card(COL1_X, ROW2_Y, COL_W, CARD_H, C_CYAN, "水溫", "C", F_COOLANT,
                  H_COOLANT, &s_coolant_value, NULL);
  // 只有這兩張卡的數值右移，道路速限維持原位
  lv_obj_align(s_soc_value, LV_ALIGN_TOP_LEFT, VALUE_X + VALUE_DX, VALUE_Y);
  lv_obj_align(s_coolant_value, LV_ALIGN_TOP_LEFT, VALUE_X + VALUE_DX, VALUE_Y);

  // 時鐘：上方日期 + 下方時間（HH:MM 大字 + :SS 小字）
  lv_obj_t *card = make_card(COL1_X, ROW3_Y, COL_W, CARD_H, C_AMBER);
  s_date_value = make_label(card, "--/--", F_TITLE, C_LABEL);
  lv_obj_align(s_date_value, LV_ALIGN_TOP_LEFT, ACCENT_W + 14, DATE_Y);

  // 只顯示 HH:MM。字型已放大到 86px，是這張卡片寬度容得下的極限。
  s_clock_value = make_label(card, "--:--", F_CLOCK, C_TEXT);
  lv_obj_align(s_clock_value, LV_ALIGN_TOP_LEFT, CLOCK_X, CLOCK_Y);
}

// ── 左側第二欄：胎壓四格 / 里程+油箱 / 道路速限 ─────────────────────────
static void build_column2(void) {
  // 胎壓 (PSI)：2x2
  lv_obj_t *card = make_card(COL2_X, ROW1_Y, COL2_W, CARD_H, C_ORANGE);
  lv_obj_t *t = make_label(card, "胎壓 (PSI)", F_TITLE, C_LABEL);
  lv_obj_align(t, LV_ALIGN_TOP_LEFT, ACCENT_W + 14, TITLE_Y);

  for (int i = 0; i < 4; i++) {
    s_tire_value[i] = make_label(card, "--", F_TIRE, C_TEXT);
    lv_obj_align(s_tire_value[i], LV_ALIGN_TOP_LEFT,
                 TIRE_X0 + (i % 2) * TIRE_DX, TIRE_Y0 + (i / 2) * TIRE_DY);
  }

  // 里程 + 油箱：兩列，中間一條細分隔線
  card = make_card(COL2_X, ROW2_Y, COL2_W, CARD_H, C_CYAN);

  lv_obj_t *odo_label = make_label(card, ICO_ODO, F_ICON_LABEL, C_LABEL);
  lv_obj_align(odo_label, LV_ALIGN_TOP_LEFT, ACCENT_W + 14, ODO_LABEL_Y);
  // 固定寬度 + 靠右對齊 = 前方補空。位數變動時 K 不會跟著移動。
  s_odo_value = make_label(card, "--", F_ODO, C_TEXT);
  lv_obj_set_width(s_odo_value, ODO_FIELD_W);
  lv_obj_set_style_text_align(s_odo_value, LV_TEXT_ALIGN_RIGHT, 0);
  lv_obj_align(s_odo_value, LV_ALIGN_TOP_LEFT, ODO_VALUE_X, ODO_VALUE_Y);
  lv_obj_t *odo_unit = make_label(card, "K", &lv_font_montserrat_20, C_UNIT);
  lv_obj_align(odo_unit, LV_ALIGN_TOP_LEFT, ODO_UNIT_X, ODO_UNIT_Y);

  lv_obj_t *divider = lv_obj_create(card);
  lv_obj_set_pos(divider, ACCENT_W + 14, DIVIDER_Y);
  lv_obj_set_size(divider, COL2_W - ACCENT_W - 28, 1);
  lv_obj_clear_flag(divider, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_bg_color(divider, lv_color_hex(0x2A303B), 0);
  lv_obj_set_style_bg_opa(divider, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(divider, 0, 0);
  lv_obj_set_style_radius(divider, 0, 0);

  lv_obj_t *fuel_label = make_label(card, ICO_FUEL, F_ICON_LABEL, C_LABEL);
  lv_obj_align(fuel_label, LV_ALIGN_TOP_LEFT, ACCENT_W + 14, FUEL_LABEL_Y);
  // 只會是 1-99，固定寬度 + 置中，位數變動時重心不跳。
  s_fuel_value = make_label(card, "--", F_FUEL, C_TEXT);
  lv_obj_set_width(s_fuel_value, FUEL_FIELD_W);
  lv_obj_set_style_text_align(s_fuel_value, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_align(s_fuel_value, LV_ALIGN_TOP_LEFT, FUEL_VALUE_X, FUEL_VALUE_Y);
  lv_obj_t *fuel_unit = make_label(card, "%", &lv_font_montserrat_20, C_UNIT);
  lv_obj_align(fuel_unit, LV_ALIGN_TOP_RIGHT, -10, FUEL_UNIT_Y);

  // 道路速限（偵測到測速照相時，本卡片會轉為紅底閃爍的警示）
  // 速限數值比其它卡片大 1.3 倍。VALUE_Y 不用動：標題佔到 y=44、卡片高 205，
  // 89px 的數值置中後起點正好還是 80。
  s_limit_card = make_value_card(COL2_X, ROW3_Y, COL2_W, CARD_H, C_RED, "道路速限",
                                 NULL, F_LIMIT, H_LIMIT, &s_limit_value,
                                 &s_limit_title);
  lv_obj_align(s_limit_value, LV_ALIGN_TOP_LEFT, VALUE_X, VALUE_Y);

  // 箭頭用 LVGL 內建的符號（montserrat 字型本身就含 FontAwesome 符號），
  // 不必重新產生圖示字型。主速限旁邊放不下箭頭——145px 字型的數字寬 88px，
  // 三位數就佔滿卡片可用寬度——所以只標在這個次要數字上：
  // 「↓60」即代表另一條路在下方，也就是目前判定在高架上。
  s_limit_alt = make_label(s_limit_card, "", F_ALT, C_UNIT);
  lv_obj_align(s_limit_alt, LV_ALIGN_TOP_RIGHT, -14, ALT_Y);
  lv_obj_add_flag(s_limit_alt, LV_OBJ_FLAG_HIDDEN);
}

// ── 中央：時速 / 轉速 / 增壓的垂直堆疊 ──────────────────────────────────
static void build_speed_stack(void) {
  // 時速大字。
  // 注意：這些標籤一律不呼叫 lv_obj_align()，因為 LVGL v8 中只要設過
  // align，之後的 lv_obj_set_pos() 就會被當成「相對於該對齊點的偏移」，
  // 我們在 update 裡是以絕對座標置中的。
  // 尚未收到資料前顯示 "--"，而不是 0 / EV —— 那會看起來像真實狀態
  s_speed_value = make_label(s_scr, "--", F_SPEED, C_TEXT);
  lv_obj_set_style_text_letter_space(s_speed_value, LS_SPEED, 0);
  // 單位一律用 lv_obj_align() 靠右對齊到 UNIT_RIGHT，建立後就不再移動
  s_speed_unit = make_label(s_scr, "km/h", &lv_font_montserrat_26, C_UNIT);
  lv_obj_align(s_speed_unit, LV_ALIGN_TOP_RIGHT, -UNIT_OFS, SPEED_UNIT_Y);

  // 轉速（藍色）與單位 R
  s_rpm_value = make_label(s_scr, "--", F_RPM, C_BLUE);
  lv_obj_set_style_text_letter_space(s_rpm_value, LS_RPM, 0);
  s_rpm_unit = make_label(s_scr, "R", &lv_font_montserrat_22, C_UNIT);
  lv_obj_align(s_rpm_unit, LV_ALIGN_TOP_RIGHT, -UNIT_OFS, RPM_UNIT_Y);
  lv_obj_add_flag(s_rpm_unit, LV_OBJ_FLAG_HIDDEN);

  // 節氣門開度。位置固定在增壓長條左緣，只更新文字。
  s_throttle_value = make_label(s_scr, "--%", F_THROTTLE, C_THROTTLE);
  lv_obj_set_pos(s_throttle_value, THROTTLE_X, THROTTLE_Y);

  // 渦輪增壓
  s_turbo_value = make_label(s_scr, "+0.0", F_TURBO, C_TEXT);
  s_turbo_unit = make_label(s_scr, "BAR", &lv_font_montserrat_26, C_LABEL);
  lv_obj_align(s_turbo_unit, LV_ALIGN_TOP_RIGHT, -UNIT_OFS, TURBO_UNIT_Y);

  s_turbo_bar = lv_bar_create(s_scr);
  lv_obj_set_size(s_turbo_bar, TURBO_BAR_W, 8);
  lv_obj_set_pos(s_turbo_bar, TURBO_BAR_X, TURBO_BAR_Y);
  lv_obj_set_style_bg_color(s_turbo_bar, lv_color_hex(0x2A303B), LV_PART_MAIN);
  lv_obj_set_style_bg_color(s_turbo_bar, lv_color_hex(C_BLUE),
                            LV_PART_INDICATOR);
  lv_obj_set_style_radius(s_turbo_bar, 0, LV_PART_MAIN);
  lv_obj_set_style_radius(s_turbo_bar, 0, LV_PART_INDICATOR);
  // -1.0 ~ +1.0 Bar，以百分之一為單位避免浮點；0 對應中線
  lv_bar_set_range(s_turbo_bar, -100, 100);
  lv_bar_set_mode(s_turbo_bar, LV_BAR_MODE_SYMMETRICAL);
  lv_bar_set_value(s_turbo_bar, 0, LV_ANIM_OFF);

  static const char *ticks[5] = {"-1", "-0.5", "0", "+0.5", "+1"};
  for (int i = 0; i < 5; i++) {
    lv_obj_t *tl = make_label(s_scr, ticks[i], &lv_font_montserrat_22, C_UNIT);
    lv_obj_update_layout(tl);
    lv_obj_set_pos(tl,
                   TURBO_CX - TURBO_BAR_W / 2 + i * (TURBO_BAR_W / 4) -
                       lv_obj_get_width(tl) / 2,
                   TURBO_BAR_Y + 20);
  }
}

// ── 指示燈 ──────────────────────────────────────────────────────────────
// 時速上方的橫排六格：小燈 / 大燈 / 後霧燈 / 車門 / 門鎖 / 後車廂，
// 順序與手機端狀態區的閱讀順序相同。
// 位置寫死，只靠顯示或隱藏切換，因此不會互相推擠。
static lv_obj_t *make_icon(const char *glyph, uint32_t color, int slot) {
  lv_obj_t *o = make_label(s_scr, glyph, F_ICON, color);
  lv_obj_set_pos(o, ICON_X0 + slot * ICON_DX, ICON_Y);
  lv_obj_add_flag(o, LV_OBJ_FLAG_HIDDEN);
  return o;
}

static void build_indicators(void) {
  s_icon_position = make_icon(ICO_POSITION, C_GREEN, 0);
  // 大燈：近燈綠、遠燈藍，比照車規儀表的慣例（圖示也會換成遠燈符號）
  s_icon_light = make_icon(ICO_LOW_BEAM, C_GREEN, 1);
  // 後霧燈用琥珀色，車規上它是警示性質的燈
  s_icon_rear_fog = make_icon(ICO_REAR_FOG, C_ORANGE, 2);
  s_icon_door = make_icon(ICO_DOOR, C_ORANGE, 3);
  s_icon_lock = make_icon(ICO_UNLOCK, C_ORANGE, 4);
  s_icon_trunk = make_icon(ICO_TRUNK, C_ORANGE, 5);
}

// ── 前方路況 ────────────────────────────────────────────────────────────
// 手機端只在國道與快速公路上送 jam（平面省道的旅行速率含號誌等候，偏低是常態），
// 所以這裡看到就顯示，不再另外判斷道路種類。
static void build_jam_banner(void) {
  s_jam = make_label(s_scr, "", F_TITLE, C_TEXT);
  lv_obj_set_style_bg_color(s_jam, lv_color_hex(C_RED), 0);
  lv_obj_set_style_bg_opa(s_jam, LV_OPA_COVER, 0);
  lv_obj_set_style_radius(s_jam, 6, 0);
  lv_obj_set_style_pad_hor(s_jam, JAM_PAD_X, 0);
  lv_obj_set_style_pad_ver(s_jam, JAM_PAD_Y, 0);
  lv_obj_add_flag(s_jam, LV_OBJ_FLAG_HIDDEN);
}

/// 距離轉成念起來順的文字：1 公里以上取一位小數（整數時不帶 .0），以下取整百公尺
static void format_distance(char *out, size_t n, int m) {
  if (m >= 1000) {
    int d10 = (m + 50) / 100;
    if (d10 % 10 == 0) {
      lv_snprintf(out, n, "%d公里", d10 / 10);
    } else {
      lv_snprintf(out, n, "%d.%d公里", d10 / 10, d10 % 10);
    }
  } else {
    int h = (m + 50) / 100 * 100;
    lv_snprintf(out, n, "%d公尺", h < 100 ? 100 : h);
  }
}

static void set_jam(const nx4_dash_data_t *d) {
  if (!d->jam_active || d->jam_len <= 0) {
    lv_obj_add_flag(s_jam, LV_OBJ_FLAG_HIDDEN);
    return;
  }
  const char *what = d->jam_level >= 3 ? "壅塞" : "緩慢";
  char len[16];
  char buf[64];
  format_distance(len, sizeof(len), d->jam_len);
  if (d->jam_dist < 100) {
    // 已經在車陣裡，距離沒有意義，改說還剩多長
    lv_snprintf(buf, sizeof(buf), "%s中  剩%s  時速%d", what, len, d->jam_speed);
  } else {
    char dist[16];
    format_distance(dist, sizeof(dist), d->jam_dist);
    lv_snprintf(buf, sizeof(buf), "前方%s%s  長%s  時速%d", dist, what, len,
                d->jam_speed);
  }
  lv_label_set_text(s_jam, buf);
  lv_obj_clear_flag(s_jam, LV_OBJ_FLAG_HIDDEN);
  // 寬度隨文字變動，每次重新置中（不能用 lv_obj_align，見 README 的 LVGL 坑）
  lv_obj_update_layout(s_jam);
  lv_obj_set_pos(s_jam, STACK_CX - lv_obj_get_width(s_jam) / 2, JAM_Y);
}

/// 單一格的顯示與隱藏。狀態沒變就不動，避免多餘的 invalidate。
static void set_icon(lv_obj_t *o, bool on) {
  if (on == !lv_obj_has_flag(o, LV_OBJ_FLAG_HIDDEN)) return;
  if (on) {
    lv_obj_clear_flag(o, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_add_flag(o, LV_OBJ_FLAG_HIDDEN);
  }
}

/// 點右下角的 IP 開啟 WiFi 設定面板，並帶入目前的 SSID
static void ip_clicked_cb(lv_event_t *e) {
  LV_UNUSED(e);
  ui_settings_open(s_current_ssid);
}

// ── 右下角狀態區（只剩 IP）──────────────────────────────────────────────
// 連線狀態改由「資料逾時淡出」表達，螢幕亮度僅在序列日誌回報，
// 兩者不再佔用畫面。測速照相警示已整合進「道路速限」卡片，
// 大燈狀態則改成右側指示燈條的第一格。
static void build_status(void) {
  s_status_ip = make_label(s_scr, "WiFi ...", &lv_font_montserrat_18, C_UNIT);
  lv_obj_set_pos(s_status_ip, STATUS_RIGHT - 62, STATUS_IP_Y);

  // 點 IP 開啟 WiFi 設定面板。字很小，把可點範圍往外擴 24px 才好按。
  lv_obj_add_flag(s_status_ip, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_set_ext_click_area(s_status_ip, 24);
  lv_obj_add_event_cb(s_status_ip, ip_clicked_cb, LV_EVENT_CLICKED, NULL);
}

/// 文字寬度會隨內容變動，統一靠右對齊到 STATUS_RIGHT
static void align_status_right(lv_obj_t *label, lv_coord_t y) {
  lv_obj_update_layout(label);
  lv_obj_set_pos(label, STATUS_RIGHT - lv_obj_get_width(label), y);
}

/// 測速照相警示閃爍：切換「道路速限」卡片的底色（500ms 週期）
static void cam_blink_cb(lv_timer_t *timer) {
  LV_UNUSED(timer);
  if (!s_cam_active) return;
  s_cam_blink_on = !s_cam_blink_on;
  lv_obj_set_style_bg_color(
      s_limit_card, lv_color_hex(s_cam_blink_on ? C_RED : 0x7F1D1D), 0);
}

/// 切換「道路速限」卡片在一般模式與測速照相警示模式之間
static void set_camera_mode(bool active, nx4_cam_kind_t kind, int camera_limit,
                            int speed_limit) {
  s_cam_active = active;

  if (active) {
    lv_label_set_text(s_limit_title, kind == NX4_CAM_RED_LIGHT  ? "闖紅燈照相"
                                     : kind == NX4_CAM_OVERPASS ? "天橋偷拍"
                                                                : "測速照相");
    lv_obj_set_style_text_color(s_limit_title, lv_color_hex(0xFFFFFF), 0);
    if (camera_limit > 0) {
      lv_label_set_text_fmt(s_limit_value, "%d", camera_limit);
    } else {
      lv_label_set_text(s_limit_value, "!");
    }
    s_cam_blink_on = true;
    lv_obj_set_style_bg_color(s_limit_card, lv_color_hex(C_RED), 0);
  } else {
    lv_label_set_text(s_limit_title, "道路速限");
    lv_obj_set_style_text_color(s_limit_title, lv_color_hex(C_LABEL), 0);
    if (speed_limit > 0) {
      lv_label_set_text_fmt(s_limit_value, "%d", speed_limit);
    } else {
      lv_label_set_text(s_limit_value, "--");
    }
    s_cam_blink_on = false;
    lv_obj_set_style_bg_color(s_limit_card, lv_color_hex(C_CARD), 0);
  }
}

/// 速限卡片右上角的次要速限（純顯示，不影響任何警示）。
///
/// 高架與正下方的平面道路判別不出來、且兩者速限不同時顯示，
/// 前面的箭頭指出這個速限屬於上方還是下方的道路。
/// 測速照相警示期間隱藏，避免與警示數字混淆。
static void set_limit_extras(int alt_limit, bool alt_above, bool camera_active) {
  if (camera_active || alt_limit <= 0) {
    lv_obj_add_flag(s_limit_alt, LV_OBJ_FLAG_HIDDEN);
    return;
  }
  lv_label_set_text_fmt(s_limit_alt, "%s%d",
                        alt_above ? LV_SYMBOL_UP : LV_SYMBOL_DOWN, alt_limit);
  lv_obj_clear_flag(s_limit_alt, LV_OBJ_FLAG_HIDDEN);
}

void ui_dashboard_create(void) {
  s_scr = lv_scr_act();
  lv_obj_clear_flag(s_scr, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_bg_color(s_scr, lv_color_hex(C_BG), 0);
  lv_obj_set_style_bg_opa(s_scr, LV_OPA_COVER, 0);
  lv_obj_set_style_pad_all(s_scr, 0, 0);

  build_column1();
  build_column2();
  build_speed_stack();
  build_status();
  build_indicators();
  build_jam_banner();
  ui_settings_create();

  // 這兩個 label 平常由補間的 callback 定位；開機時還沒有資料，
  // 先手動擺一次，否則會停在 (0,0)
  lv_obj_update_layout(s_speed_value);
  lv_obj_set_pos(s_speed_value, STACK_CX - lv_obj_get_width(s_speed_value) / 2,
                 SPEED_Y);
  lv_obj_update_layout(s_rpm_value);
  lv_obj_set_pos(s_rpm_value, STACK_CX - lv_obj_get_width(s_rpm_value) / 2,
                 RPM_Y);

  lv_timer_create(cam_blink_cb, 500, NULL);
  lv_timer_create(clock_tick_cb, 1000, NULL);

  nx4_dash_data_init(&s_last);
  s_last_valid = false;
}

// ── 更新 ────────────────────────────────────────────────────────────────

/// 時速補間。外環移除後只剩大字，不再驅動進度弧。
static void anim_speed_cb(void *var, int32_t v) {
  LV_UNUSED(var);
  if (v == s_speed_shown) return;
  s_speed_shown = v;

  // int32_t 在 IDF 的 riscv 工具鏈是 long int，%d 不匹配，明確轉成 int
  lv_label_set_text_fmt(s_speed_value, "%d", (int)v);
  // 位數改變時字寬會變，重新對齊到堆疊中線
  lv_obj_update_layout(s_speed_value);
  lv_obj_set_pos(s_speed_value, STACK_CX - lv_obj_get_width(s_speed_value) / 2,
                 SPEED_Y);
}

/// 轉速補間。引擎熄火（轉速 0）時改顯示 EV — HEV 以純電行駛的狀態。
static void anim_rpm_cb(void *var, int32_t v) {
  LV_UNUSED(var);
  if (v == s_rpm_shown) return;
  s_rpm_shown = v;

  const bool ev = (v <= 0);
  if (ev) {
    lv_label_set_text(s_rpm_value, "EV");
    lv_obj_set_style_text_color(s_rpm_value, lv_color_hex(C_GREEN), 0);
    // EV 沒有轉速可言，隱藏單位 R
    lv_obj_add_flag(s_rpm_unit, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_label_set_text_fmt(s_rpm_value, "%d", (int)v);
    lv_obj_clear_flag(s_rpm_unit, LV_OBJ_FLAG_HIDDEN);
  }

  lv_obj_update_layout(s_rpm_value);
  lv_coord_t rw = lv_obj_get_width(s_rpm_value);
  // EV 沒有單位要擺，整個置中；有轉速時預留右側的 R
  // 單位位置固定，這裡只置中數值
  lv_obj_set_pos(s_rpm_value, STACK_CX - rw / 2, RPM_Y);
}

/// 增壓補間（單位為百分之一 Bar）
static void anim_turbo_cb(void *var, int32_t v) {
  LV_UNUSED(var);
  if (v == s_turbo_shown) return;
  s_turbo_shown = v;

  // 只顯示一位小數。MAP 是單一位元組、1 kPa 一格等於 0.01 Bar，顯示到第二位
  // 時每一格量化誤差都看得見，數字會一直抖（手機端同樣的理由，見 fac9f31）。
  int mag = v < 0 ? -v : v;
  int deci = (mag + 5) / 10;                 // 四捨五入到十分位
  // deci 歸零時一律顯示正號，避免出現 "-0.0"
  int sdeci = (v < 0 && deci > 0) ? -deci : deci;

  // 長條吃完整解析度，每一步都更新；文字只在十分位真的變了才重寫
  lv_bar_set_value(s_turbo_bar, v, LV_ANIM_OFF);
  if (sdeci == s_turbo_deci_shown) return;
  s_turbo_deci_shown = sdeci;

  lv_label_set_text_fmt(s_turbo_value, "%c%d.%d", sdeci < 0 ? '-' : '+',
                        deci / 10, deci % 10);

  // 靠右對齊到 BAR 單位前方。左邊留給節氣門，兩者相距超過 200px，不會相撞。
  lv_obj_update_layout(s_turbo_value);
  lv_obj_set_pos(s_turbo_value,
                 TURBO_VALUE_RIGHT - lv_obj_get_width(s_turbo_value), TURBO_Y);
}

/// 啟動一段補間。同一組 (var, exec_cb) 再次啟動會自動取代前一段動畫，
/// 因此新資料抵達時會從目前顯示值接著走，不會跳回起點。
static void start_anim(lv_obj_t *var, lv_anim_exec_xcb_t cb, int32_t from,
                       int32_t to, uint32_t ms) {
  lv_anim_t a;
  lv_anim_init(&a);
  lv_anim_set_var(&a, var);
  lv_anim_set_exec_cb(&a, cb);
  lv_anim_set_values(&a, from, to);
  lv_anim_set_time(&a, ms);
  // 線性：兩筆資料之間等速移動，看起來最連續
  lv_anim_set_path_cb(&a, lv_anim_path_linear);
  lv_anim_start(&a);
}

static void update_tire(int index, int psi, int prev, bool force) {
  if (!force && psi == prev) return;
  if (psi <= 0) {
    lv_label_set_text(s_tire_value[index], "--");
    set_alert(s_tire_value[index], false, C_UNIT);
    return;
  }
  lv_label_set_text_fmt(s_tire_value[index], "%d", psi);
  // 30 psi 以下：紅字警示；40 psi 以上：琥珀色文字（次級提示）
  set_alert(s_tire_value[index], psi <= ALERT_TIRE_MIN,
            psi > WARN_TIRE_HIGH ? C_ORANGE : C_TEXT);
}

void ui_dashboard_update(const nx4_dash_data_t *data) {
  // 剛從逾時狀態恢復時，先解除淡出再強制重套所有欄位
  const bool was_stale = s_stale;
  if (was_stale) ui_dashboard_set_stale(false);

  const bool force = !s_last_valid || was_stale;
  const nx4_dash_data_t *p = &s_last;

  // 時速：大字（以補間平滑過渡）。倒車時整個換成琥珀色的 R，比照 App 儀表。
  if (force || data->speed != p->speed || data->reversing != p->reversing) {
    int speed = data->speed;
    if (speed < 0 && !data->reversing) {
      // 還沒讀到過。停掉補間，否則它會把 "--" 蓋成數字
      lv_anim_del(s_speed_value, anim_speed_cb);
      lv_obj_set_style_text_color(s_speed_value, lv_color_hex(C_TEXT), 0);
      lv_label_set_text(s_speed_value, "--");
      lv_obj_update_layout(s_speed_value);
      lv_obj_set_pos(s_speed_value,
                     STACK_CX - lv_obj_get_width(s_speed_value) / 2, SPEED_Y);
      s_speed_shown = -1;
      goto speed_done;
    }
    if (speed < 0) speed = 0;
    if (data->reversing) {
      // 已經在倒車就維持原樣；倒車中時速仍會跳動，不擋的話每筆資料
      // 都會重寫一次同樣的 "R"
      if (force || !p->reversing) {
        // 停掉補間，否則它會在 R 上面繼續寫數字
        lv_anim_del(s_speed_value, anim_speed_cb);
        lv_obj_set_style_text_color(s_speed_value, lv_color_hex(C_REVERSE), 0);
        lv_label_set_text(s_speed_value, "R");
        lv_obj_update_layout(s_speed_value);
        lv_obj_set_pos(s_speed_value,
                       STACK_CX - lv_obj_get_width(s_speed_value) / 2, SPEED_Y);
        // 讓退出倒車時 cb 一定會重寫（s_speed_shown 目前對應的是 "R"）
        s_speed_shown = -1;
      }
    } else {
      // 超速時（有速限資料且超出 5 km/h）時速轉紅
      bool over = data->speed_limit > 0 && speed > data->speed_limit + 5;
      lv_obj_set_style_text_color(s_speed_value,
                                  lv_color_hex(over ? C_ALERT : C_TEXT), 0);
      if (force || p->reversing) {
        s_speed_last_ms = 0;
        s_speed_shown = speed + 1; // 迫使 cb 實際寫入
        anim_speed_cb(NULL, speed);
      } else {
        start_anim(s_speed_value, anim_speed_cb, s_speed_shown, speed,
                   anim_ms(&s_speed_last_ms));
      }
    }
  }
speed_done:

  // 轉速（以補間平滑過渡）
  if (force || data->rpm != p->rpm) {
    int rpm = data->rpm;
    if (rpm < 0) {
      // 還沒讀到過。不能讓它走到 anim_rpm_cb，那裡 0 會被畫成綠色的 EV
      lv_anim_del(s_rpm_value, anim_rpm_cb);
      lv_obj_set_style_text_color(s_rpm_value, lv_color_hex(C_BLUE), 0);
      lv_label_set_text(s_rpm_value, "--");
      lv_obj_add_flag(s_rpm_unit, LV_OBJ_FLAG_HIDDEN);
      lv_obj_update_layout(s_rpm_value);
      lv_obj_set_pos(s_rpm_value,
                     STACK_CX - lv_obj_get_width(s_rpm_value) / 2, RPM_Y);
      s_rpm_shown = -1;
      goto rpm_done;
    }
    if (rpm > RPM_MAX) rpm = RPM_MAX;
    // EV 狀態的綠色由 anim_rpm_cb 決定，這裡只處理有轉速時的配色
    if (rpm > 0) {
      lv_obj_set_style_text_color(
          s_rpm_value, lv_color_hex(rpm >= 5500 ? C_ALERT : C_BLUE), 0);
    }
    if (force) {
      s_rpm_last_ms = 0;
      s_rpm_shown = rpm + 1;
      anim_rpm_cb(NULL, rpm);
    } else {
      start_anim(s_rpm_value, anim_rpm_cb, s_rpm_shown, rpm,
                 anim_ms(&s_rpm_last_ms));
    }
  }
rpm_done:;


  // Hev 電池
  if (force || data->soc != p->soc) {
    if (data->soc > 0) {
      // LVGL 的 lv_snprintf 在 LV_SPRINTF_USE_FLOAT = 0 時不支援 %f，
      // 會印出空白方框，因此一律以整數拆出小數位
      int soc10 = (int)(data->soc * 10.0f + 0.5f);
      if (soc10 >= 1000) {
        // "100.0" 約 199px，會撞到右側的單位「%」；滿電時小數位無意義
        lv_label_set_text(s_soc_value, "100");
      } else {
        lv_label_set_text_fmt(s_soc_value, "%d.%d", soc10 / 10, soc10 % 10);
      }
    } else {
      lv_label_set_text(s_soc_value, "--");
    }
  }

  // 水溫
  if (force || data->coolant != p->coolant) {
    if (data->coolant > 0) {
      lv_label_set_text_fmt(s_coolant_value, "%d", data->coolant);
    } else {
      lv_label_set_text(s_coolant_value, "--");
    }
    set_alert(s_coolant_value, data->coolant >= ALERT_COOLANT, C_TEXT);
  }

  // 時鐘與日期。手機端送 "HH:MM:SS"，只送 "HH:MM" 的舊格式也相容。
  if (force || strcmp(data->clock, p->clock) != 0) {
    int h, m, sec;
    int n = sscanf(data->clock, "%d:%d:%d", &h, &m, &sec);
    if (n >= 2) {
      s_clk_h = h;
      s_clk_m = m;
      s_clk_s = (n == 3) ? sec : 0;
      render_clock();
    }
  }
  if (force || strcmp(data->date, p->date) != 0) {
    lv_label_set_text(s_date_value, data->date);
  }

  // 里程 / 油箱
  if (force || data->odo != p->odo) {
    if (data->odo > 0) {
      lv_label_set_text_fmt(s_odo_value, "%d", data->odo);
    } else {
      lv_label_set_text(s_odo_value, "--");
    }
  }
  if (force || data->fuel != p->fuel) {
    int fuel = data->fuel;
    if (fuel < 0) {
      // 還沒讀到過。油量要攢滿五筆才算一次平均，30 秒一輪等於開機
      // 兩分半內都沒有值，這段期間本來會顯示 0。
      lv_label_set_text(s_fuel_value, "--");
      set_alert(s_fuel_value, false, C_TEXT);
      goto fuel_done;
    }
    if (fuel > 100) fuel = 100;
    lv_label_set_text_fmt(s_fuel_value, "%d", fuel);
    set_alert(s_fuel_value, fuel <= ALERT_FUEL_MAX, C_TEXT);
  }
fuel_done:;


  // 節氣門開度
  if (force || data->throttle != p->throttle) {
    if (data->throttle < 0) {
      lv_label_set_text(s_throttle_value, "--%");
    } else {
      lv_label_set_text_fmt(s_throttle_value, "%d%%", data->throttle);
    }
  }

  // 渦輪增壓（以補間平滑過渡）
  if (force || data->turbo != p->turbo) {
    float turbo = data->turbo;
    if (turbo < NX4_NO_VALUE_F / 2.0f) {
      // 還沒讀到過。0.0 是合法的增壓值，所以要另外用哨兵區分
      lv_anim_del(s_turbo_value, anim_turbo_cb);
      lv_label_set_text(s_turbo_value, "--");
      s_turbo_shown = 0;
      s_turbo_deci_shown = 999;
      goto turbo_done;
    }
    if (turbo < -1.0f) turbo = -1.0f;
    if (turbo > 1.0f) turbo = 1.0f;
    int centi = (int)(turbo * 100.0f + (turbo >= 0 ? 0.5f : -0.5f));
    if (force) {
      s_turbo_last_ms = 0;
      s_turbo_shown = centi + 1;
      s_turbo_deci_shown = 999;   // 強制重寫文字
      anim_turbo_cb(NULL, centi);
    } else {
      start_anim(s_turbo_value, anim_turbo_cb, s_turbo_shown, centi,
                 anim_ms(&s_turbo_last_ms));
    }
  }
turbo_done:;

  // 胎壓
  update_tire(0, data->tire_fl, p->tire_fl, force);
  update_tire(1, data->tire_fr, p->tire_fr, force);
  update_tire(2, data->tire_rl, p->tire_rl, force);
  update_tire(3, data->tire_rr, p->tire_rr, force);

  // 時速上方指示燈條：小燈 / 大燈 / 後霧燈 / 車門 / 門鎖 / 後車廂
  if (force || data->position_lamp != p->position_lamp) {
    set_icon(s_icon_position, data->position_lamp);
  }
  if (force || data->low_beam != p->low_beam ||
      data->high_beam != p->high_beam) {
    // 遠燈一定伴隨大燈開啟，所以顯示條件是 low_beam；
    // 遠燈時換成遠燈符號並轉藍。
    set_icon(s_icon_light, data->low_beam);
    lv_label_set_text(s_icon_light,
                      data->high_beam ? ICO_HIGH_BEAM : ICO_LOW_BEAM);
    lv_obj_set_style_text_color(
        s_icon_light, lv_color_hex(data->high_beam ? C_BLUE : C_GREEN), 0);
  }
  if (force || data->rear_fog != p->rear_fog) {
    set_icon(s_icon_rear_fog, data->rear_fog);
  }
  if (force || data->door_open != p->door_open) {
    set_icon(s_icon_door, data->door_open);
  }
  if (force || data->door_unlocked != p->door_unlocked) {
    set_icon(s_icon_lock, data->door_unlocked);
  }
  if (force || data->trunk_open != p->trunk_open) {
    set_icon(s_icon_trunk, data->trunk_open);
  }

  // 前方路況紅條
  if (force || data->jam_active != p->jam_active ||
      data->jam_dist != p->jam_dist || data->jam_len != p->jam_len ||
      data->jam_speed != p->jam_speed || data->jam_level != p->jam_level) {
    set_jam(data);
  }

  // 道路速限卡片：有測速照相時取代為警示，消失後恢復速限
  if (force || data->speed_limit != p->speed_limit ||
      data->camera_active != p->camera_active ||
      data->camera_limit != p->camera_limit ||
      data->camera_kind != p->camera_kind) {
    set_camera_mode(data->camera_active, data->camera_kind, data->camera_limit,
                    data->speed_limit);
  }
  if (force || data->limit_alt != p->limit_alt ||
      data->limit_alt_above != p->limit_alt_above ||
      data->camera_active != p->camera_active) {
    set_limit_extras(data->limit_alt, data->limit_alt_above,
                     data->camera_active);
  }

  s_last = *data;
  s_last_valid = true;
}

void ui_dashboard_set_status(bool wifi_up, const char *ip, bool client_linked) {
  // 連線狀態不再獨立顯示：資料逾時時整片數值會淡出，已足以表達
  LV_UNUSED(client_linked);

  if (wifi_up && ip != NULL) {
    lv_label_set_text_fmt(s_status_ip, "%s", ip);
    lv_obj_set_style_text_color(s_status_ip, lv_color_hex(C_LABEL), 0);
  } else {
    lv_label_set_text(s_status_ip, "WiFi ...");
    lv_obj_set_style_text_color(s_status_ip, lv_color_hex(C_UNIT), 0);
  }
  align_status_right(s_status_ip, STATUS_IP_Y);
}

void ui_dashboard_set_ssid(const char *ssid) {
  if (ssid == NULL) return;
  strncpy(s_current_ssid, ssid, sizeof(s_current_ssid) - 1);
  s_current_ssid[sizeof(s_current_ssid) - 1] = '\0';
}

void ui_dashboard_set_brightness(int percent) {
  // 亮度不再顯示於畫面，只在序列日誌回報（見 nx4_dashboard.ino 的 [BRT]）
  LV_UNUSED(percent);
}

void ui_dashboard_set_stale(bool stale) {
  if (stale == s_stale) return;
  s_stale = stale;

  lv_opa_t opa = stale ? LV_OPA_40 : LV_OPA_COVER;
  lv_obj_set_style_text_opa(s_speed_value, opa, 0);
  lv_obj_set_style_text_opa(s_rpm_value, opa, 0);
  lv_obj_set_style_text_opa(s_soc_value, opa, 0);
  lv_obj_set_style_text_opa(s_coolant_value, opa, 0);
  // 時鐘與日期由本機的 lv_timer 自行維護，資料逾時仍然正確，不淡出
  lv_obj_set_style_text_opa(s_odo_value, opa, 0);
  lv_obj_set_style_text_opa(s_fuel_value, opa, 0);
  lv_obj_set_style_text_opa(s_limit_value, opa, 0);
  lv_obj_set_style_text_opa(s_limit_alt, opa, 0);
  lv_obj_set_style_text_opa(s_turbo_value, opa, 0);
  lv_obj_set_style_text_opa(s_throttle_value, opa, 0);
  lv_obj_set_style_opa(s_turbo_bar, opa, 0);
  for (int i = 0; i < 4; i++) {
    lv_obj_set_style_text_opa(s_tire_value[i], opa, 0);
  }
  // 指示燈同樣淡出：逾時後的車門 / 門鎖狀態一樣是過期資料
  lv_obj_set_style_text_opa(s_icon_position, opa, 0);
  lv_obj_set_style_text_opa(s_icon_light, opa, 0);
  lv_obj_set_style_text_opa(s_icon_rear_fog, opa, 0);
  lv_obj_set_style_text_opa(s_icon_door, opa, 0);
  lv_obj_set_style_text_opa(s_icon_lock, opa, 0);
  lv_obj_set_style_text_opa(s_icon_trunk, opa, 0);

  // 路況同樣是過期資料，逾時直接收掉紅條；恢復時 force 重套會再顯示
  if (stale) lv_obj_add_flag(s_jam, LV_OBJ_FLAG_HIDDEN);

  if (stale && s_cam_active) {
    // 逾時不再顯示過期的測速照相警示，卡片恢復為道路速限
    set_camera_mode(false, NX4_CAM_SPEED, 0, s_last.speed_limit);
    set_limit_extras(s_last.limit_alt, s_last.limit_alt_above, false);
  }
}
