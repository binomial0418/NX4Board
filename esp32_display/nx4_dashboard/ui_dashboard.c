#include "ui_dashboard.h"
#include "pins_config.h"
#include <stdio.h>
#include <string.h>

// ─────────────────────────────────────────────────────────────────────────
// 專用字型（皆以 lv_font_conv --no-compress 產生，見各檔案標頭）
//   nx4_font_num_140 — 儀表中央時速大字，僅 0-9 與 '-'（line_height 98）
//   nx4_font_num_80  — 卡片大數值、時鐘與轉速，0-9 . : % 空白（line_height 57）
//   nx4_font_tc_22   — 中文標籤 + 基本 ASCII（line_height 25）
// ─────────────────────────────────────────────────────────────────────────
LV_FONT_DECLARE(nx4_font_num_140);
LV_FONT_DECLARE(nx4_font_num_80);
LV_FONT_DECLARE(nx4_font_tc_22);

#define F_SPEED &nx4_font_num_140
#define F_VALUE &nx4_font_num_80
#define F_LABEL &nx4_font_tc_22

// 由字型的 line_height 推得，用於排版時預留高度
#define H_SPEED 98
#define H_VALUE 57
#define H_LABEL 25

// ── 配色（比照 rec.gif：純黑底、白字、色條分類）────────────────────────
#define C_BG 0x000000
#define C_CARD 0x0D1117
#define C_TEXT 0xFFFFFF
#define C_LABEL 0xE2E8F0
#define C_UNIT 0x8B95A5
#define C_TRACK 0x3A3F47

#define C_BLUE 0x2E7DF7   // 時速進度弧、RPM
#define C_TEAL 0x14B8A6   // Hev 電池色條
#define C_CYAN 0x38BDF8   // 水溫色條
#define C_ORANGE 0xF59E0B // 胎壓色條、警示刻度
#define C_RED 0xEF4444    // 速限色條、高速刻度
#define C_AMBER 0xF97316  // 時鐘色條
#define C_GREEN 0x22C55E

// ── 版面（1024 x 600）────────────────────────────────────────────────
#define PAD 14
#define COL_W 226
#define COL1_X PAD
#define COL2_X (COL1_X + COL_W + 8)
#define CARDS_Y 30
#define CARD_H 170
#define CARD_GAP 15
#define ROW1_Y CARDS_Y
#define ROW2_Y (CARDS_Y + CARD_H + CARD_GAP)
#define ROW3_Y (CARDS_Y + 2 * (CARD_H + CARD_GAP))
#define ACCENT_W 5

#define GAUGE_SIZE 372
#define GAUGE_X 542
#define GAUGE_Y 76
#define GAUGE_CX (GAUGE_X + GAUGE_SIZE / 2)
#define GAUGE_CY (GAUGE_Y + GAUGE_SIZE / 2)

#define STATUS_X 930
#define STATUS_W 80

#define SPEED_MAX 180
#define RPM_MAX 7000

// ── 物件參考（建立一次，之後只更新數值）──────────────────────────────
static lv_obj_t *s_scr;

static lv_obj_t *s_soc_value;
static lv_obj_t *s_coolant_value;
static lv_obj_t *s_clock_value;
static lv_obj_t *s_date_value;
static lv_obj_t *s_tire_value[4]; // FL, FR, RL, RR
static lv_obj_t *s_odo_value;
static lv_obj_t *s_fuel_value;
static lv_obj_t *s_limit_value;

static lv_obj_t *s_meter;
static lv_meter_indicator_t *s_speed_arc;
static lv_obj_t *s_speed_value;
static lv_obj_t *s_rpm_value;
static lv_obj_t *s_rpm_unit;
static lv_obj_t *s_turbo_value;
static lv_obj_t *s_turbo_unit;
static lv_obj_t *s_turbo_bar;

static lv_obj_t *s_status_dot;
static lv_obj_t *s_status_link;
static lv_obj_t *s_status_ip;
static lv_obj_t *s_status_brightness;
static lv_obj_t *s_status_lights;
static lv_obj_t *s_cam_pill;
static lv_obj_t *s_cam_label;

// ── 上一次已套用的數值：相同就跳過，避免無謂的 invalidate ─────────────
static nx4_dash_data_t s_last;
static bool s_last_valid;
static bool s_stale;
static bool s_cam_blink_on;

void nx4_dash_data_init(nx4_dash_data_t *data) {
  memset(data, 0, sizeof(nx4_dash_data_t));
  strcpy(data->clock, "--:--");
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
static void make_value_card(lv_coord_t x, lv_coord_t y, lv_coord_t h,
                            uint32_t accent, const char *label,
                            const char *unit, lv_obj_t **out_value) {
  lv_obj_t *card = make_card(x, y, COL_W, h, accent);

  if (label != NULL) {
    lv_obj_t *t = make_label(card, label, F_LABEL, C_LABEL);
    lv_obj_align(t, LV_ALIGN_TOP_LEFT, ACCENT_W + 12, 10);
  }

  // 數值緊接在標籤下方（靠上），單位對齊數值下緣
  lv_obj_t *value = make_label(card, "--", F_VALUE, C_TEXT);
  lv_obj_align(value, LV_ALIGN_TOP_LEFT, ACCENT_W + 12, 44);

  if (unit != NULL) {
    lv_obj_t *u = make_label(card, unit, &lv_font_montserrat_18, C_UNIT);
    lv_obj_align(u, LV_ALIGN_TOP_RIGHT, -12, 44 + H_VALUE - 24);
  }

  *out_value = value;
}

// ── 左側第一欄：Hev電池 / 水溫 / 時鐘 ───────────────────────────────────
static void build_column1(void) {
  make_value_card(COL1_X, ROW1_Y, CARD_H, C_TEAL, "Hev電池", "%", &s_soc_value);
  make_value_card(COL1_X, ROW2_Y, CARD_H, C_CYAN, "水溫", "C",
                  &s_coolant_value);

  // 時鐘：上方日期 + 下方時間
  lv_obj_t *card = make_card(COL1_X, ROW3_Y, COL_W, CARD_H, C_AMBER);
  s_date_value = make_label(card, "--/--", F_LABEL, C_LABEL);
  lv_obj_align(s_date_value, LV_ALIGN_TOP_LEFT, ACCENT_W + 12, 30);
  s_clock_value = make_label(card, "--:--", F_VALUE, C_TEXT);
  lv_obj_align(s_clock_value, LV_ALIGN_TOP_LEFT, ACCENT_W + 12, 68);
}

// ── 左側第二欄：胎壓四格 / 里程+油箱 / 道路速限 ─────────────────────────
static void build_column2(void) {
  // 胎壓 (PSI)：2x2
  lv_obj_t *card = make_card(COL2_X, ROW1_Y, COL_W, CARD_H, C_ORANGE);
  lv_obj_t *t = make_label(card, "胎壓 (PSI)", F_LABEL, C_LABEL);
  lv_obj_align(t, LV_ALIGN_TOP_LEFT, ACCENT_W + 12, 10);

  for (int i = 0; i < 4; i++) {
    s_tire_value[i] = make_label(card, "--", &lv_font_montserrat_44, C_TEXT);
    lv_obj_align(s_tire_value[i], LV_ALIGN_TOP_LEFT,
                 ACCENT_W + 16 + (i % 2) * 100, 46 + (i / 2) * 58);
  }

  // 里程 + 油箱：兩列，中間一條細分隔線
  card = make_card(COL2_X, ROW2_Y, COL_W, CARD_H, C_CYAN);

  lv_obj_t *odo_label = make_label(card, "里程", F_LABEL, C_LABEL);
  lv_obj_align(odo_label, LV_ALIGN_TOP_LEFT, ACCENT_W + 12, 32);
  s_odo_value = make_label(card, "--", &lv_font_montserrat_32, C_TEXT);
  lv_obj_align(s_odo_value, LV_ALIGN_TOP_LEFT, ACCENT_W + 70, 24);
  lv_obj_t *odo_unit = make_label(card, "K", &lv_font_montserrat_16, C_UNIT);
  lv_obj_align(odo_unit, LV_ALIGN_TOP_RIGHT, -12, 38);

  lv_obj_t *divider = lv_obj_create(card);
  lv_obj_set_pos(divider, ACCENT_W + 12, 84);
  lv_obj_set_size(divider, COL_W - ACCENT_W - 24, 1);
  lv_obj_clear_flag(divider, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_bg_color(divider, lv_color_hex(0x2A303B), 0);
  lv_obj_set_style_bg_opa(divider, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(divider, 0, 0);
  lv_obj_set_style_radius(divider, 0, 0);

  lv_obj_t *fuel_label = make_label(card, "油箱", F_LABEL, C_LABEL);
  lv_obj_align(fuel_label, LV_ALIGN_TOP_LEFT, ACCENT_W + 12, 110);
  s_fuel_value = make_label(card, "--", &lv_font_montserrat_32, C_TEXT);
  lv_obj_align(s_fuel_value, LV_ALIGN_TOP_LEFT, ACCENT_W + 70, 102);
  lv_obj_t *fuel_unit = make_label(card, "%", &lv_font_montserrat_16, C_UNIT);
  lv_obj_align(fuel_unit, LV_ALIGN_TOP_RIGHT, -12, 116);

  // 道路速限
  make_value_card(COL2_X, ROW3_Y, CARD_H, C_RED, "道路速限", NULL,
                  &s_limit_value);
}

// ── 右側 0-180 圓形時速錶 ───────────────────────────────────────────────
static void build_gauge(void) {
  s_meter = lv_meter_create(s_scr);
  lv_obj_set_pos(s_meter, GAUGE_X, GAUGE_Y);
  lv_obj_set_size(s_meter, GAUGE_SIZE, GAUGE_SIZE);
  lv_obj_clear_flag(s_meter, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_bg_opa(s_meter, LV_OPA_TRANSP, LV_PART_MAIN);
  lv_obj_set_style_border_width(s_meter, 0, LV_PART_MAIN);
  lv_obj_set_style_pad_all(s_meter, 0, LV_PART_MAIN);
  lv_obj_set_style_text_font(s_meter, &lv_font_montserrat_16, LV_PART_TICKS);
  // lv_meter 會在 LV_PART_INDICATOR 無條件畫出指針樞紐的小圓點；
  // 本儀表沒有指針，把它的尺寸與不透明度歸零藏起來
  lv_obj_set_style_size(s_meter, 0, LV_PART_INDICATOR);
  lv_obj_set_style_bg_opa(s_meter, LV_OPA_TRANSP, LV_PART_INDICATOR);

  // 無刻度的隱藏 scale，僅用來畫背景軌道與時速進度弧（涵蓋完整 0-180）
  lv_meter_scale_t *arc_scale = lv_meter_add_scale(s_meter);
  lv_meter_set_scale_ticks(s_meter, arc_scale, 0, 0, 0, lv_color_black());
  lv_meter_set_scale_range(s_meter, arc_scale, 0, SPEED_MAX, 270, 135);

  lv_meter_indicator_t *track =
      lv_meter_add_arc(s_meter, arc_scale, 9, lv_color_hex(C_TRACK), 0);
  lv_meter_set_indicator_start_value(s_meter, track, 0);
  lv_meter_set_indicator_end_value(s_meter, track, SPEED_MAX);

  s_speed_arc = lv_meter_add_arc(s_meter, arc_scale, 9, lv_color_hex(C_BLUE), 0);
  lv_meter_set_indicator_start_value(s_meter, s_speed_arc, 0);
  lv_meter_set_indicator_end_value(s_meter, s_speed_arc, 0);

  // 刻度分成三段，讓刻度線與數字能依速域上色（白 → 琥珀 → 紅）
  // 三段的角度是依 270° / 180 km/h = 1.5°每單位換算，彼此不重疊也不留空。
  lv_meter_scale_t *s1 = lv_meter_add_scale(s_meter);
  lv_meter_set_scale_ticks(s_meter, s1, 8, 2, 9, lv_color_hex(0x7A8494));
  lv_meter_set_scale_major_ticks(s_meter, s1, 2, 3, 15, lv_color_hex(0xD8DEE9),
                                 14);
  lv_meter_set_scale_range(s_meter, s1, 0, 70, 105, 135);

  lv_meter_scale_t *s2 = lv_meter_add_scale(s_meter);
  lv_meter_set_scale_ticks(s_meter, s2, 4, 2, 9, lv_color_hex(0x8A6A2A));
  lv_meter_set_scale_major_ticks(s_meter, s2, 2, 3, 15, lv_color_hex(C_ORANGE),
                                 14);
  lv_meter_set_scale_range(s_meter, s2, 80, 110, 45, 255);

  lv_meter_scale_t *s3 = lv_meter_add_scale(s_meter);
  lv_meter_set_scale_ticks(s_meter, s3, 7, 2, 9, lv_color_hex(0x8A3A3A));
  lv_meter_set_scale_major_ticks(s_meter, s3, 2, 3, 15, lv_color_hex(C_RED), 14);
  lv_meter_set_scale_range(s_meter, s3, 120, 180, 90, 315);

  // 中央時速大字。
  // 注意：這些標籤一律不呼叫 lv_obj_align()，因為 LVGL v8 中只要設過
  // align，之後的 lv_obj_set_pos() 就會被當成「相對於該對齊點的偏移」，
  // 我們在 update 裡是以絕對座標置中的。
  s_speed_value = make_label(s_scr, "0", F_SPEED, C_TEXT);

  // 轉速（藍色）與單位 R
  s_rpm_value = make_label(s_scr, "0", F_VALUE, C_BLUE);
  s_rpm_unit = make_label(s_scr, "R", &lv_font_montserrat_18, C_UNIT);

  // 渦輪增壓
  s_turbo_value = make_label(s_scr, "+0.00", &lv_font_montserrat_32, C_TEXT);
  s_turbo_unit = make_label(s_scr, "BAR", &lv_font_montserrat_18, C_LABEL);

  s_turbo_bar = lv_bar_create(s_scr);
  lv_obj_set_size(s_turbo_bar, 340, 8);
  lv_obj_set_pos(s_turbo_bar, GAUGE_CX - 170, GAUGE_Y + 446);
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
    lv_obj_t *tl = make_label(s_scr, ticks[i], &lv_font_montserrat_14, C_UNIT);
    lv_obj_update_layout(tl);
    lv_obj_set_pos(tl, GAUGE_CX - 170 + i * 85 - lv_obj_get_width(tl) / 2,
                   GAUGE_Y + 460);
  }
}

// ── 最右側狀態欄（對應 rec.gif 中 App 的按鈕列位置）─────────────────────
static void build_status(void) {
  s_status_dot = lv_obj_create(s_scr);
  lv_obj_set_pos(s_status_dot, STATUS_X, CARDS_Y + 4);
  lv_obj_set_size(s_status_dot, 12, 12);
  lv_obj_clear_flag(s_status_dot, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_radius(s_status_dot, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_border_width(s_status_dot, 0, 0);
  lv_obj_set_style_bg_color(s_status_dot, lv_color_hex(C_UNIT), 0);
  lv_obj_set_style_bg_opa(s_status_dot, LV_OPA_COVER, 0);

  s_status_link = make_label(s_scr, "NO LINK", &lv_font_montserrat_14, C_UNIT);
  lv_obj_set_pos(s_status_link, STATUS_X + 18, CARDS_Y + 3);

  s_status_ip = make_label(s_scr, "WiFi ...", &lv_font_montserrat_14, C_UNIT);
  lv_obj_set_pos(s_status_ip, STATUS_X, CARDS_Y + 26);

  s_status_brightness =
      make_label(s_scr, "BRT --", &lv_font_montserrat_14, C_UNIT);
  lv_obj_set_pos(s_status_brightness, STATUS_X, CARDS_Y + 48);

  s_status_lights = make_label(s_scr, "", F_LABEL, C_ORANGE);
  lv_obj_set_pos(s_status_lights, STATUS_X, CARDS_Y + 74);

  // 測速照相警示：預設隱藏，偵測到時顯示並閃爍
  s_cam_pill = lv_obj_create(s_scr);
  lv_obj_set_pos(s_cam_pill, STATUS_X - 4, CARDS_Y + 120);
  lv_obj_set_size(s_cam_pill, STATUS_W + 8, 76);
  lv_obj_clear_flag(s_cam_pill, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_radius(s_cam_pill, 10, 0);
  lv_obj_set_style_border_width(s_cam_pill, 0, 0);
  lv_obj_set_style_bg_color(s_cam_pill, lv_color_hex(C_RED), 0);
  lv_obj_set_style_bg_opa(s_cam_pill, LV_OPA_COVER, 0);
  lv_obj_set_style_pad_all(s_cam_pill, 0, 0);
  lv_obj_add_flag(s_cam_pill, LV_OBJ_FLAG_HIDDEN);

  lv_obj_t *cam_title = make_label(s_cam_pill, "測速", F_LABEL, 0xFFFFFF);
  lv_obj_align(cam_title, LV_ALIGN_TOP_MID, 0, 6);
  s_cam_label = make_label(s_cam_pill, "--", &lv_font_montserrat_32, 0xFFFFFF);
  lv_obj_align(s_cam_label, LV_ALIGN_BOTTOM_MID, 0, -4);
}

/// 測速照相警示閃爍（500ms 週期，僅切換單一面板的底色）
static void cam_blink_cb(lv_timer_t *timer) {
  LV_UNUSED(timer);
  if (lv_obj_has_flag(s_cam_pill, LV_OBJ_FLAG_HIDDEN)) return;
  s_cam_blink_on = !s_cam_blink_on;
  lv_obj_set_style_bg_color(
      s_cam_pill, lv_color_hex(s_cam_blink_on ? C_RED : 0x7F1D1D), 0);
}

void ui_dashboard_create(void) {
  s_scr = lv_scr_act();
  lv_obj_clear_flag(s_scr, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_bg_color(s_scr, lv_color_hex(C_BG), 0);
  lv_obj_set_style_bg_opa(s_scr, LV_OPA_COVER, 0);
  lv_obj_set_style_pad_all(s_scr, 0, 0);

  build_column1();
  build_column2();
  build_gauge();
  build_status();

  lv_timer_create(cam_blink_cb, 500, NULL);

  nx4_dash_data_init(&s_last);
  s_last_valid = false;
}

// ── 更新 ────────────────────────────────────────────────────────────────
static void update_tire(int index, int psi, int prev, bool force) {
  if (!force && psi == prev) return;
  if (psi <= 0) {
    lv_label_set_text(s_tire_value[index], "--");
    lv_obj_set_style_text_color(s_tire_value[index], lv_color_hex(C_UNIT), 0);
    return;
  }
  lv_label_set_text_fmt(s_tire_value[index], "%d", psi);
  // 28 psi 以下偏低、40 psi 以上偏高，兩者都以顏色提示
  uint32_t color = C_TEXT;
  if (psi < 28) {
    color = C_RED;
  } else if (psi > 40) {
    color = C_ORANGE;
  }
  lv_obj_set_style_text_color(s_tire_value[index], lv_color_hex(color), 0);
}

void ui_dashboard_update(const nx4_dash_data_t *data) {
  // 剛從逾時狀態恢復時，先解除淡出再強制重套所有欄位
  const bool was_stale = s_stale;
  if (was_stale) ui_dashboard_set_stale(false);

  const bool force = !s_last_valid || was_stale;
  const nx4_dash_data_t *p = &s_last;

  // 時速：大字 + 進度弧
  if (force || data->speed != p->speed) {
    int speed = data->speed;
    if (speed < 0) speed = 0;
    lv_label_set_text_fmt(s_speed_value, "%d", speed);
    lv_meter_set_indicator_end_value(s_meter, s_speed_arc,
                                     speed > SPEED_MAX ? SPEED_MAX : speed);
    // 超速時（有速限資料且超出 5 km/h）時速轉紅
    bool over = data->speed_limit > 0 && speed > data->speed_limit + 5;
    lv_obj_set_style_text_color(s_speed_value,
                                lv_color_hex(over ? C_RED : C_TEXT), 0);
    // 字寬會隨位數改變，每次重新以絕對座標對齊到錶盤圓心
    lv_obj_update_layout(s_speed_value);
    lv_obj_set_pos(s_speed_value, GAUGE_CX - lv_obj_get_width(s_speed_value) / 2,
                   GAUGE_CY - H_SPEED / 2 - 26);
  }

  // 轉速
  if (force || data->rpm != p->rpm) {
    int rpm = data->rpm;
    if (rpm < 0) rpm = 0;
    if (rpm > RPM_MAX) rpm = RPM_MAX;
    lv_label_set_text_fmt(s_rpm_value, "%d", rpm);
    lv_obj_set_style_text_color(s_rpm_value,
                                lv_color_hex(rpm >= 5500 ? C_RED : C_BLUE), 0);
    lv_obj_update_layout(s_rpm_value);
    lv_coord_t rw = lv_obj_get_width(s_rpm_value);
    lv_coord_t rx = GAUGE_CX - rw / 2 - 10;
    lv_obj_set_pos(s_rpm_value, rx, GAUGE_CY + 46);
    lv_obj_set_pos(s_rpm_unit, rx + rw + 8, GAUGE_CY + 46 + H_VALUE - 22);
  }

  // Hev 電池
  if (force || data->soc != p->soc) {
    if (data->soc > 0) {
      // LVGL 的 lv_snprintf 在 LV_SPRINTF_USE_FLOAT = 0 時不支援 %f，
      // 會印出空白方框，因此一律以整數拆出小數位
      int soc10 = (int)(data->soc * 10.0f + 0.5f);
      lv_label_set_text_fmt(s_soc_value, "%d.%d", soc10 / 10, soc10 % 10);
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
    lv_obj_set_style_text_color(
        s_coolant_value, lv_color_hex(data->coolant >= 105 ? C_RED : C_TEXT), 0);
  }

  // 時鐘與日期
  if (force || strcmp(data->clock, p->clock) != 0) {
    lv_label_set_text(s_clock_value, data->clock);
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
    if (fuel < 0) fuel = 0;
    if (fuel > 100) fuel = 100;
    lv_label_set_text_fmt(s_fuel_value, "%d", fuel);
    lv_obj_set_style_text_color(s_fuel_value,
                                lv_color_hex(fuel <= 15 ? C_RED : C_TEXT), 0);
  }

  // 道路速限
  if (force || data->speed_limit != p->speed_limit) {
    if (data->speed_limit > 0) {
      lv_label_set_text_fmt(s_limit_value, "%d", data->speed_limit);
    } else {
      lv_label_set_text(s_limit_value, "--");
    }
  }

  // 渦輪增壓
  if (force || data->turbo != p->turbo) {
    float turbo = data->turbo;
    if (turbo < -1.0f) turbo = -1.0f;
    if (turbo > 1.0f) turbo = 1.0f;
    int centi = (int)(turbo * 100.0f + (turbo >= 0 ? 0.5f : -0.5f));
    int mag = centi < 0 ? -centi : centi;
    lv_label_set_text_fmt(s_turbo_value, "%c%d.%02d", centi < 0 ? '-' : '+',
                          mag / 100, mag % 100);
    lv_bar_set_value(s_turbo_bar, centi, LV_ANIM_OFF);

    lv_obj_update_layout(s_turbo_value);
    lv_coord_t tw = lv_obj_get_width(s_turbo_value);
    lv_coord_t tx = GAUGE_CX - (tw + 52) / 2;
    lv_obj_set_pos(s_turbo_value, tx, GAUGE_Y + 396);
    lv_obj_set_pos(s_turbo_unit, tx + tw + 8, GAUGE_Y + 396 + 14);
  }

  // 胎壓
  update_tire(0, data->tire_fl, p->tire_fl, force);
  update_tire(1, data->tire_fr, p->tire_fr, force);
  update_tire(2, data->tire_rl, p->tire_rl, force);
  update_tire(3, data->tire_rr, p->tire_rr, force);

  // 大燈狀態
  if (force || data->low_beam != p->low_beam ||
      data->high_beam != p->high_beam) {
    if (data->high_beam) {
      lv_label_set_text(s_status_lights, "遠燈");
      lv_obj_set_style_text_color(s_status_lights, lv_color_hex(C_BLUE), 0);
    } else if (data->low_beam) {
      lv_label_set_text(s_status_lights, "近燈");
      lv_obj_set_style_text_color(s_status_lights, lv_color_hex(C_ORANGE), 0);
    } else {
      lv_label_set_text(s_status_lights, "");
    }
  }

  // 測速照相提示
  if (force || data->camera_active != p->camera_active ||
      data->camera_limit != p->camera_limit) {
    if (data->camera_active) {
      if (data->camera_limit > 0) {
        lv_label_set_text_fmt(s_cam_label, "%d", data->camera_limit);
      } else {
        lv_label_set_text(s_cam_label, "!");
      }
      lv_obj_align(s_cam_label, LV_ALIGN_BOTTOM_MID, 0, -4);
      lv_obj_clear_flag(s_cam_pill, LV_OBJ_FLAG_HIDDEN);
    } else {
      lv_obj_add_flag(s_cam_pill, LV_OBJ_FLAG_HIDDEN);
      s_cam_blink_on = false;
      lv_obj_set_style_bg_color(s_cam_pill, lv_color_hex(C_RED), 0);
    }
  }

  s_last = *data;
  s_last_valid = true;
}

void ui_dashboard_set_status(bool wifi_up, const char *ip, bool client_linked) {
  if (wifi_up && ip != NULL) {
    lv_label_set_text_fmt(s_status_ip, "%s", ip);
    lv_obj_set_style_text_color(s_status_ip, lv_color_hex(C_LABEL), 0);
  } else {
    lv_label_set_text(s_status_ip, "WiFi ...");
    lv_obj_set_style_text_color(s_status_ip, lv_color_hex(C_UNIT), 0);
  }

  lv_label_set_text(s_status_link, client_linked ? "LINK" : "NO LINK");
  lv_obj_set_style_text_color(
      s_status_link, lv_color_hex(client_linked ? C_GREEN : C_UNIT), 0);
  lv_obj_set_style_bg_color(
      s_status_dot, lv_color_hex(client_linked ? C_GREEN : C_UNIT), 0);
}

void ui_dashboard_set_brightness(int percent) {
  lv_label_set_text_fmt(s_status_brightness, "BRT %d%%", percent);
}

void ui_dashboard_set_stale(bool stale) {
  if (stale == s_stale) return;
  s_stale = stale;

  lv_opa_t opa = stale ? LV_OPA_40 : LV_OPA_COVER;
  lv_obj_set_style_text_opa(s_speed_value, opa, 0);
  lv_obj_set_style_text_opa(s_rpm_value, opa, 0);
  lv_obj_set_style_text_opa(s_soc_value, opa, 0);
  lv_obj_set_style_text_opa(s_coolant_value, opa, 0);
  lv_obj_set_style_text_opa(s_clock_value, opa, 0);
  lv_obj_set_style_text_opa(s_date_value, opa, 0);
  lv_obj_set_style_text_opa(s_odo_value, opa, 0);
  lv_obj_set_style_text_opa(s_fuel_value, opa, 0);
  lv_obj_set_style_text_opa(s_limit_value, opa, 0);
  lv_obj_set_style_text_opa(s_turbo_value, opa, 0);
  lv_obj_set_style_opa(s_turbo_bar, opa, 0);
  for (int i = 0; i < 4; i++) {
    lv_obj_set_style_text_opa(s_tire_value[i], opa, 0);
  }

  if (stale) {
    // 逾時不再顯示過期的警示
    lv_obj_add_flag(s_cam_pill, LV_OBJ_FLAG_HIDDEN);
  }
}
