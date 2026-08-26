#include "ui_dashboard.h"
#include "pins_config.h"
#include <stdio.h>
#include <string.h>

// ─────────────────────────────────────────────────────────────────────────
// 大字時速字型
//
// 預設使用本專案內附的 nx4_font_speed_120.c（Montserrat 120 px，只含數字，
// 約 43 KB）。若想省 Flash 或改回內建字型，編譯時加上
//   -DNX4_NO_BIG_SPEED_FONT
// 即可退回 LVGL 內建的 Montserrat 48。
// ─────────────────────────────────────────────────────────────────────────
#ifdef NX4_NO_BIG_SPEED_FONT
#define NX4_FONT_SPEED &lv_font_montserrat_48
#else
LV_FONT_DECLARE(nx4_font_speed_120);
#define NX4_FONT_SPEED &nx4_font_speed_120
#endif

// ── 配色 ────────────────────────────────────────────────────────────────
#define C_BG 0x0B0F14
#define C_CARD 0x161C24
#define C_CARD_HI 0x1F2733
#define C_TEXT 0xE6EDF3
#define C_MUTED 0x7D8896
#define C_ACCENT 0x22D3EE
#define C_RED 0xEF4444
#define C_AMBER 0xF59E0B
#define C_GREEN 0x22C55E

// ── 版面常數（1024 x 600）─────────────────────────────────────────────
#define PAD 16
#define STATUS_H 40
#define MAIN_Y (STATUS_H + 8)
#define MAIN_H 400

#define LEFT_X PAD
#define LEFT_W 200

#define CENTER_X (LEFT_X + LEFT_W + 16)
#define CENTER_W 468

#define RIGHT_X (CENTER_X + CENTER_W + 16)
#define RIGHT_W (LCD_H_RES - RIGHT_X - PAD)

#define TPMS_Y (MAIN_Y + MAIN_H + 12)
#define TPMS_H 120
#define TPMS_GAP 10
#define TPMS_W ((LCD_H_RES - 2 * PAD - 3 * TPMS_GAP) / 4)

#define RPM_MAX 7000

// ── 物件參考（建立一次，之後只更新數值）──────────────────────────────
static lv_obj_t *s_scr;

static lv_obj_t *s_status_title;
static lv_obj_t *s_status_ip;
static lv_obj_t *s_status_dot;
static lv_obj_t *s_status_link;

static lv_obj_t *s_limit_sign;
static lv_obj_t *s_limit_label;
static lv_obj_t *s_cam_panel;
static lv_obj_t *s_cam_limit;

static lv_obj_t *s_speed_label;
static lv_obj_t *s_speed_unit;
static lv_obj_t *s_rpm_bar;
static lv_obj_t *s_rpm_value;

static lv_obj_t *s_coolant_bar;
static lv_obj_t *s_coolant_value;
static lv_obj_t *s_soc_arc;
static lv_obj_t *s_soc_value;
static lv_obj_t *s_fuel_bar;
static lv_obj_t *s_fuel_value;

static lv_obj_t *s_tire_value[4];  // FL, FR, RL, RR

// ── 上一次已套用的數值：相同就跳過，避免無謂的 invalidate ─────────────
static nx4_dash_data_t s_last;
static bool s_last_valid;
static bool s_stale;
static bool s_cam_blink_on;
static lv_timer_t *s_cam_blink_timer;

void nx4_dash_data_init(nx4_dash_data_t *data) {
  memset(data, 0, sizeof(nx4_dash_data_t));
}

// ── 小工具 ──────────────────────────────────────────────────────────────
static lv_obj_t *make_card(lv_obj_t *parent, lv_coord_t x, lv_coord_t y,
                           lv_coord_t w, lv_coord_t h, uint32_t bg) {
  lv_obj_t *card = lv_obj_create(parent);
  lv_obj_set_pos(card, x, y);
  lv_obj_set_size(card, w, h);
  lv_obj_clear_flag(card, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_bg_color(card, lv_color_hex(bg), 0);
  lv_obj_set_style_bg_opa(card, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(card, 0, 0);
  lv_obj_set_style_radius(card, 14, 0);
  lv_obj_set_style_pad_all(card, 10, 0);
  return card;
}

static lv_obj_t *make_label(lv_obj_t *parent, const char *text,
                            const lv_font_t *font, uint32_t color) {
  lv_obj_t *label = lv_label_create(parent);
  lv_label_set_text(label, text);
  lv_obj_set_style_text_font(label, font, 0);
  lv_obj_set_style_text_color(label, lv_color_hex(color), 0);
  return label;
}

/// 建立「標題 + 大數值 + 進度條」的右側量表卡片
static void make_gauge_card(lv_obj_t *parent, lv_coord_t y, lv_coord_t h,
                            const char *title, const char *unit,
                            uint32_t bar_color, lv_obj_t **out_value,
                            lv_obj_t **out_bar) {
  lv_obj_t *card = make_card(parent, RIGHT_X, y, RIGHT_W, h, C_CARD);

  lv_obj_t *t = make_label(card, title, &lv_font_montserrat_16, C_MUTED);
  lv_obj_align(t, LV_ALIGN_TOP_LEFT, 0, 0);

  lv_obj_t *u = make_label(card, unit, &lv_font_montserrat_16, C_MUTED);
  lv_obj_align(u, LV_ALIGN_TOP_RIGHT, 0, 0);

  lv_obj_t *value = make_label(card, "--", &lv_font_montserrat_40, C_TEXT);
  lv_obj_align(value, LV_ALIGN_TOP_LEFT, 0, 24);

  lv_obj_t *bar = lv_bar_create(card);
  lv_obj_set_size(bar, RIGHT_W - 20, 10);
  lv_obj_align(bar, LV_ALIGN_BOTTOM_MID, 0, 0);
  lv_obj_set_style_bg_color(bar, lv_color_hex(C_CARD_HI), LV_PART_MAIN);
  lv_obj_set_style_bg_color(bar, lv_color_hex(bar_color), LV_PART_INDICATOR);
  lv_obj_set_style_radius(bar, 5, LV_PART_MAIN);
  lv_obj_set_style_radius(bar, 5, LV_PART_INDICATOR);
  lv_bar_set_range(bar, 0, 100);
  lv_bar_set_value(bar, 0, LV_ANIM_OFF);

  *out_value = value;
  *out_bar = bar;
}

/// 測速照相警示閃爍（500ms 週期，僅切換單一面板的底色）
static void cam_blink_cb(lv_timer_t *timer) {
  LV_UNUSED(timer);
  if (lv_obj_has_flag(s_cam_panel, LV_OBJ_FLAG_HIDDEN)) return;
  s_cam_blink_on = !s_cam_blink_on;
  lv_obj_set_style_bg_color(
      s_cam_panel, lv_color_hex(s_cam_blink_on ? C_RED : 0x7F1D1D), 0);
}

// ── 各區塊 ──────────────────────────────────────────────────────────────
static void build_status_bar(void) {
  lv_obj_t *bar = lv_obj_create(s_scr);
  lv_obj_set_pos(bar, 0, 0);
  lv_obj_set_size(bar, LCD_H_RES, STATUS_H);
  lv_obj_clear_flag(bar, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_bg_color(bar, lv_color_hex(C_CARD), 0);
  lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(bar, 0, 0);
  lv_obj_set_style_radius(bar, 0, 0);
  lv_obj_set_style_pad_all(bar, 0, 0);

  s_status_title = make_label(bar, "NX4BOARD", &lv_font_montserrat_18, C_ACCENT);
  lv_obj_align(s_status_title, LV_ALIGN_LEFT_MID, PAD, 0);

  s_status_dot = lv_obj_create(bar);
  lv_obj_set_size(s_status_dot, 12, 12);
  lv_obj_set_style_radius(s_status_dot, 6, 0);
  lv_obj_set_style_border_width(s_status_dot, 0, 0);
  lv_obj_set_style_bg_color(s_status_dot, lv_color_hex(C_MUTED), 0);
  lv_obj_clear_flag(s_status_dot, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_align(s_status_dot, LV_ALIGN_RIGHT_MID, -PAD, 0);

  s_status_link = make_label(bar, "NO LINK", &lv_font_montserrat_16, C_MUTED);
  lv_obj_align_to(s_status_link, s_status_dot, LV_ALIGN_OUT_LEFT_MID, -8, 0);

  s_status_ip = make_label(bar, "WiFi ...", &lv_font_montserrat_16, C_MUTED);
  lv_obj_align_to(s_status_ip, s_status_link, LV_ALIGN_OUT_LEFT_MID, -20, 0);
}

static void build_left_column(void) {
  // 速限標誌（白底紅圈黑字，圓形）
  s_limit_sign = lv_obj_create(s_scr);
  lv_obj_set_pos(s_limit_sign, LEFT_X + (LEFT_W - 176) / 2, MAIN_Y + 20);
  lv_obj_set_size(s_limit_sign, 176, 176);
  lv_obj_clear_flag(s_limit_sign, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_radius(s_limit_sign, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_color(s_limit_sign, lv_color_hex(0xFFFFFF), 0);
  lv_obj_set_style_bg_opa(s_limit_sign, LV_OPA_COVER, 0);
  lv_obj_set_style_border_color(s_limit_sign, lv_color_hex(C_RED), 0);
  lv_obj_set_style_border_width(s_limit_sign, 12, 0);
  lv_obj_set_style_pad_all(s_limit_sign, 0, 0);

  s_limit_label = make_label(s_limit_sign, "--", &lv_font_montserrat_48, 0x101010);
  lv_obj_center(s_limit_label);

  // 測速照相提示（預設隱藏，偵測到時顯示並閃爍）
  s_cam_panel = make_card(s_scr, LEFT_X, MAIN_Y + 216, LEFT_W, 150, C_RED);
  lv_obj_add_flag(s_cam_panel, LV_OBJ_FLAG_HIDDEN);

  lv_obj_t *icon =
      make_label(s_cam_panel, LV_SYMBOL_WARNING, &lv_font_montserrat_28, 0xFFFFFF);
  lv_obj_align(icon, LV_ALIGN_TOP_MID, 0, 0);

  lv_obj_t *text = make_label(s_cam_panel, "CAMERA", &lv_font_montserrat_20, 0xFFFFFF);
  lv_obj_align(text, LV_ALIGN_TOP_MID, 0, 40);

  s_cam_limit = make_label(s_cam_panel, "--", &lv_font_montserrat_44, 0xFFFFFF);
  lv_obj_align(s_cam_limit, LV_ALIGN_BOTTOM_MID, 0, 0);

  s_cam_blink_timer = lv_timer_create(cam_blink_cb, 500, NULL);
}

static void build_center_column(void) {
  lv_obj_t *card =
      make_card(s_scr, CENTER_X, MAIN_Y, CENTER_W, MAIN_H, C_CARD);

  s_speed_label = make_label(card, "0", NX4_FONT_SPEED, C_TEXT);
  lv_obj_align(s_speed_label, LV_ALIGN_CENTER, 0, -70);

  s_speed_unit = make_label(card, "km/h", &lv_font_montserrat_26, C_MUTED);
  lv_obj_align_to(s_speed_unit, s_speed_label, LV_ALIGN_OUT_BOTTOM_MID, 0, 4);

  lv_obj_t *rpm_title = make_label(card, "RPM", &lv_font_montserrat_16, C_MUTED);
  lv_obj_align(rpm_title, LV_ALIGN_BOTTOM_LEFT, 0, -54);

  s_rpm_value = make_label(card, "0", &lv_font_montserrat_24, C_ACCENT);
  lv_obj_align(s_rpm_value, LV_ALIGN_BOTTOM_RIGHT, 0, -48);

  // 轉速條：0 ~ RPM_MAX，超過紅線時指示條轉紅
  s_rpm_bar = lv_bar_create(card);
  lv_obj_set_size(s_rpm_bar, CENTER_W - 20, 22);
  lv_obj_align(s_rpm_bar, LV_ALIGN_BOTTOM_MID, 0, 0);
  lv_obj_set_style_bg_color(s_rpm_bar, lv_color_hex(C_CARD_HI), LV_PART_MAIN);
  lv_obj_set_style_bg_color(s_rpm_bar, lv_color_hex(C_ACCENT), LV_PART_INDICATOR);
  lv_obj_set_style_radius(s_rpm_bar, 11, LV_PART_MAIN);
  lv_obj_set_style_radius(s_rpm_bar, 11, LV_PART_INDICATOR);
  lv_bar_set_range(s_rpm_bar, 0, RPM_MAX);
  lv_bar_set_value(s_rpm_bar, 0, LV_ANIM_OFF);
}

static void build_right_column(void) {
  // 水溫
  make_gauge_card(s_scr, MAIN_Y, 120, "COOLANT", "C", C_AMBER, &s_coolant_value,
                  &s_coolant_bar);
  lv_bar_set_range(s_coolant_bar, 0, 130);

  // SOC（混合動力電池）— 以圓弧呈現
  lv_obj_t *soc_card = make_card(s_scr, RIGHT_X, MAIN_Y + 132, RIGHT_W, 156, C_CARD);
  lv_obj_t *soc_title = make_label(soc_card, "SOC", &lv_font_montserrat_16, C_MUTED);
  lv_obj_align(soc_title, LV_ALIGN_TOP_LEFT, 0, 0);

  s_soc_arc = lv_arc_create(soc_card);
  lv_obj_set_size(s_soc_arc, 116, 116);
  lv_obj_align(s_soc_arc, LV_ALIGN_BOTTOM_MID, 0, 6);
  lv_arc_set_rotation(s_soc_arc, 135);
  lv_arc_set_bg_angles(s_soc_arc, 0, 270);
  lv_arc_set_range(s_soc_arc, 0, 100);
  lv_arc_set_value(s_soc_arc, 0);
  lv_obj_remove_style(s_soc_arc, NULL, LV_PART_KNOB);
  lv_obj_clear_flag(s_soc_arc, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_set_style_arc_width(s_soc_arc, 12, LV_PART_MAIN);
  lv_obj_set_style_arc_width(s_soc_arc, 12, LV_PART_INDICATOR);
  lv_obj_set_style_arc_color(s_soc_arc, lv_color_hex(C_CARD_HI), LV_PART_MAIN);
  lv_obj_set_style_arc_color(s_soc_arc, lv_color_hex(C_GREEN), LV_PART_INDICATOR);
  lv_obj_set_style_bg_opa(s_soc_arc, LV_OPA_TRANSP, LV_PART_MAIN);
  lv_obj_set_style_border_width(s_soc_arc, 0, LV_PART_MAIN);

  s_soc_value = make_label(soc_card, "--", &lv_font_montserrat_32, C_TEXT);
  lv_obj_align_to(s_soc_value, s_soc_arc, LV_ALIGN_CENTER, 0, 0);

  // 油量
  make_gauge_card(s_scr, MAIN_Y + 300, 100, "FUEL", "%", C_ACCENT, &s_fuel_value,
                  &s_fuel_bar);
}

static void build_tpms_row(void) {
  static const char *names[4] = {"FL", "FR", "RL", "RR"};

  for (int i = 0; i < 4; i++) {
    lv_coord_t x = PAD + i * (TPMS_W + TPMS_GAP);
    lv_obj_t *card = make_card(s_scr, x, TPMS_Y, TPMS_W, TPMS_H, C_CARD);

    lv_obj_t *name = make_label(card, names[i], &lv_font_montserrat_18, C_MUTED);
    lv_obj_align(name, LV_ALIGN_TOP_LEFT, 0, 0);

    lv_obj_t *unit = make_label(card, "psi", &lv_font_montserrat_16, C_MUTED);
    lv_obj_align(unit, LV_ALIGN_BOTTOM_RIGHT, 0, 0);

    s_tire_value[i] = make_label(card, "--", &lv_font_montserrat_44, C_TEXT);
    lv_obj_align(s_tire_value[i], LV_ALIGN_BOTTOM_LEFT, 0, 0);
  }
}

void ui_dashboard_create(void) {
  s_scr = lv_scr_act();
  lv_obj_clear_flag(s_scr, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_bg_color(s_scr, lv_color_hex(C_BG), 0);
  lv_obj_set_style_bg_opa(s_scr, LV_OPA_COVER, 0);

  build_status_bar();
  build_left_column();
  build_center_column();
  build_right_column();
  build_tpms_row();

  nx4_dash_data_init(&s_last);
  s_last_valid = false;
}

// ── 更新 ────────────────────────────────────────────────────────────────
static void update_tire(int index, int psi, int prev, bool force) {
  if (!force && psi == prev) return;
  if (psi <= 0) {
    lv_label_set_text(s_tire_value[index], "--");
    lv_obj_set_style_text_color(s_tire_value[index], lv_color_hex(C_MUTED), 0);
    return;
  }
  lv_label_set_text_fmt(s_tire_value[index], "%d", psi);
  // 28 psi 以下偏低、40 psi 以上偏高，兩者都以顏色提示
  uint32_t color = C_TEXT;
  if (psi < 28) {
    color = C_RED;
  } else if (psi > 40) {
    color = C_AMBER;
  }
  lv_obj_set_style_text_color(s_tire_value[index], lv_color_hex(color), 0);
}

void ui_dashboard_update(const nx4_dash_data_t *data) {
  // 剛從逾時狀態恢復時，先解除淡出再強制重套所有欄位
  // （逾時期間曾隱藏測速照相提示，需要重新評估顯示狀態）
  const bool was_stale = s_stale;
  if (was_stale) ui_dashboard_set_stale(false);

  const bool force = !s_last_valid || was_stale;
  const nx4_dash_data_t *p = &s_last;

  // 時速
  if (force || data->speed != p->speed) {
    lv_label_set_text_fmt(s_speed_label, "%d", data->speed);
    // 超速時（有速限資料且超出 5 km/h）時速轉紅
    bool over = data->speed_limit > 0 && data->speed > data->speed_limit + 5;
    lv_obj_set_style_text_color(s_speed_label,
                                lv_color_hex(over ? C_RED : C_TEXT), 0);
    lv_obj_align_to(s_speed_unit, s_speed_label, LV_ALIGN_OUT_BOTTOM_MID, 0, 4);
  }

  // 轉速
  if (force || data->rpm != p->rpm) {
    int rpm = data->rpm;
    if (rpm < 0) rpm = 0;
    if (rpm > RPM_MAX) rpm = RPM_MAX;
    lv_bar_set_value(s_rpm_bar, rpm, LV_ANIM_OFF);
    lv_label_set_text_fmt(s_rpm_value, "%d", data->rpm);
    lv_obj_set_style_bg_color(s_rpm_bar,
                              lv_color_hex(rpm >= 5500 ? C_RED : C_ACCENT),
                              LV_PART_INDICATOR);
    lv_obj_align(s_rpm_value, LV_ALIGN_BOTTOM_RIGHT, 0, -48);
  }

  // 水溫
  if (force || data->coolant != p->coolant) {
    if (data->coolant > 0) {
      lv_label_set_text_fmt(s_coolant_value, "%d", data->coolant);
    } else {
      lv_label_set_text(s_coolant_value, "--");
    }
    int c = data->coolant;
    if (c < 0) c = 0;
    if (c > 130) c = 130;
    lv_bar_set_value(s_coolant_bar, c, LV_ANIM_OFF);
    lv_obj_set_style_bg_color(s_coolant_bar,
                              lv_color_hex(data->coolant >= 105 ? C_RED : C_AMBER),
                              LV_PART_INDICATOR);
  }

  // SOC
  if (force || data->soc != p->soc) {
    int soc = (int)(data->soc + 0.5f);
    if (soc < 0) soc = 0;
    if (soc > 100) soc = 100;
    lv_arc_set_value(s_soc_arc, soc);
    lv_label_set_text_fmt(s_soc_value, "%d%%", soc);
    lv_obj_set_style_arc_color(s_soc_arc,
                               lv_color_hex(soc <= 20 ? C_RED : C_GREEN),
                               LV_PART_INDICATOR);
  }

  // 油量
  if (force || data->fuel != p->fuel) {
    int fuel = data->fuel;
    if (fuel < 0) fuel = 0;
    if (fuel > 100) fuel = 100;
    lv_label_set_text_fmt(s_fuel_value, "%d", fuel);
    lv_bar_set_value(s_fuel_bar, fuel, LV_ANIM_OFF);
    lv_obj_set_style_bg_color(s_fuel_bar,
                              lv_color_hex(fuel <= 15 ? C_RED : C_ACCENT),
                              LV_PART_INDICATOR);
  }

  // 速限標誌
  if (force || data->speed_limit != p->speed_limit) {
    if (data->speed_limit > 0) {
      lv_label_set_text_fmt(s_limit_label, "%d", data->speed_limit);
    } else {
      lv_label_set_text(s_limit_label, "--");
    }
    lv_obj_center(s_limit_label);
  }

  // 測速照相提示
  if (force || data->camera_active != p->camera_active ||
      data->camera_limit != p->camera_limit) {
    if (data->camera_active) {
      if (data->camera_limit > 0) {
        lv_label_set_text_fmt(s_cam_limit, "%d", data->camera_limit);
      } else {
        lv_label_set_text(s_cam_limit, "!");
      }
      lv_obj_align(s_cam_limit, LV_ALIGN_BOTTOM_MID, 0, 0);
      lv_obj_clear_flag(s_cam_panel, LV_OBJ_FLAG_HIDDEN);
    } else {
      lv_obj_add_flag(s_cam_panel, LV_OBJ_FLAG_HIDDEN);
      s_cam_blink_on = false;
      lv_obj_set_style_bg_color(s_cam_panel, lv_color_hex(C_RED), 0);
    }
  }

  // 胎壓
  update_tire(0, data->tire_fl, p->tire_fl, force);
  update_tire(1, data->tire_fr, p->tire_fr, force);
  update_tire(2, data->tire_rl, p->tire_rl, force);
  update_tire(3, data->tire_rr, p->tire_rr, force);

  s_last = *data;
  s_last_valid = true;
}

void ui_dashboard_set_status(bool wifi_up, const char *ip, bool client_linked) {
  if (wifi_up && ip != NULL) {
    lv_label_set_text_fmt(s_status_ip, "%s", ip);
    lv_obj_set_style_text_color(s_status_ip, lv_color_hex(C_TEXT), 0);
  } else {
    lv_label_set_text(s_status_ip, "WiFi ...");
    lv_obj_set_style_text_color(s_status_ip, lv_color_hex(C_MUTED), 0);
  }

  lv_label_set_text(s_status_link, client_linked ? "LINKED" : "NO LINK");
  lv_obj_set_style_text_color(
      s_status_link, lv_color_hex(client_linked ? C_GREEN : C_MUTED), 0);
  lv_obj_set_style_bg_color(
      s_status_dot, lv_color_hex(client_linked ? C_GREEN : C_MUTED), 0);

  // 文字寬度會變，重新對齊右側三個元素
  lv_obj_align(s_status_dot, LV_ALIGN_RIGHT_MID, -PAD, 0);
  lv_obj_align_to(s_status_link, s_status_dot, LV_ALIGN_OUT_LEFT_MID, -8, 0);
  lv_obj_align_to(s_status_ip, s_status_link, LV_ALIGN_OUT_LEFT_MID, -20, 0);
}

void ui_dashboard_set_stale(bool stale) {
  if (stale == s_stale) return;
  s_stale = stale;

  lv_opa_t opa = stale ? LV_OPA_40 : LV_OPA_COVER;
  lv_obj_set_style_text_opa(s_speed_label, opa, 0);
  lv_obj_set_style_text_opa(s_speed_unit, opa, 0);
  lv_obj_set_style_text_opa(s_rpm_value, opa, 0);
  lv_obj_set_style_opa(s_rpm_bar, opa, 0);
  lv_obj_set_style_text_opa(s_coolant_value, opa, 0);
  lv_obj_set_style_text_opa(s_soc_value, opa, 0);
  lv_obj_set_style_text_opa(s_fuel_value, opa, 0);
  for (int i = 0; i < 4; i++) {
    lv_obj_set_style_text_opa(s_tire_value[i], opa, 0);
  }

  if (stale) {
    // 逾時不再顯示過期的警示
    lv_obj_add_flag(s_cam_panel, LV_OBJ_FLAG_HIDDEN);
  }
}
