#include "ui_settings.h"
#include "pins_config.h"
#include <stdio.h>
#include <string.h>

LV_FONT_DECLARE(nx4_font_tc_22);
#define F_LABEL &nx4_font_tc_22

// ── 配色（與主畫面一致）────────────────────────────────────────────────
#define C_BG 0x0B0F14
#define C_PANEL 0x161C24
#define C_FIELD 0x1F2733
#define C_TEXT 0xFFFFFF
#define C_LABEL 0xE2E8F0
#define C_UNIT 0x8B95A5
#define C_BLUE 0x2E7DF7
#define C_GREEN 0x22C55E
#define C_ALERT 0xFF2D2D

// ── 版面 ────────────────────────────────────────────────────────────────
#define PANEL_X 12
#define PANEL_Y 8
#define PANEL_W (LCD_H_RES - 2 * PANEL_X)
#define PANEL_H 292 // 下半部留給鍵盤

#define LIST_X 16
#define LIST_W 360
#define FORM_X (LIST_X + LIST_W + 24)
#define FORM_W (PANEL_W - FORM_X - 16)

#define KB_Y 306
#define KB_H (LCD_V_RES - KB_Y - 6)

static lv_obj_t *s_panel;
static lv_obj_t *s_list;
static lv_obj_t *s_ssid_ta;
static lv_obj_t *s_pass_ta;
static lv_obj_t *s_status;
static lv_obj_t *s_kb;

static nx4_settings_apply_cb_t s_apply_cb;
static nx4_settings_scan_cb_t s_scan_cb;
static bool s_open;

void ui_settings_set_callbacks(nx4_settings_apply_cb_t apply,
                               nx4_settings_scan_cb_t scan) {
  s_apply_cb = apply;
  s_scan_cb = scan;
}

// ── 事件 ────────────────────────────────────────────────────────────────
/// 點任一輸入框：把鍵盤指向它
static void ta_event_cb(lv_event_t *e) {
  lv_obj_t *ta = lv_event_get_target(e);
  lv_keyboard_set_textarea(s_kb, ta);
  lv_obj_clear_flag(s_kb, LV_OBJ_FLAG_HIDDEN);
}

/// 點掃描結果的某一列：填入 SSID，游標移到密碼欄
static void list_item_cb(lv_event_t *e) {
  lv_obj_t *btn = lv_event_get_target(e);
  const char *ssid = lv_list_get_btn_text(s_list, btn);
  if (ssid == NULL) return;

  lv_textarea_set_text(s_ssid_ta, ssid);
  lv_textarea_set_text(s_pass_ta, "");
  lv_keyboard_set_textarea(s_kb, s_pass_ta);
  lv_obj_clear_flag(s_kb, LV_OBJ_FLAG_HIDDEN);
}

static void scan_btn_cb(lv_event_t *e) {
  LV_UNUSED(e);
  ui_settings_clear_networks();
  ui_settings_set_status("掃描中...");
  if (s_scan_cb) s_scan_cb();
}

static void save_btn_cb(lv_event_t *e) {
  LV_UNUSED(e);
  const char *ssid = lv_textarea_get_text(s_ssid_ta);
  if (ssid == NULL || ssid[0] == '\0') {
    ui_settings_set_status("請輸入網路名稱");
    return;
  }
  ui_settings_set_status("連線中...");
  if (s_apply_cb) s_apply_cb(ssid, lv_textarea_get_text(s_pass_ta));
}

static void close_btn_cb(lv_event_t *e) {
  LV_UNUSED(e);
  ui_settings_close();
}

// ── 建立 ────────────────────────────────────────────────────────────────
static lv_obj_t *make_button(lv_obj_t *parent, const char *text, lv_coord_t x,
                             lv_coord_t y, lv_coord_t w, uint32_t color,
                             lv_event_cb_t cb) {
  lv_obj_t *btn = lv_btn_create(parent);
  lv_obj_set_pos(btn, x, y);
  lv_obj_set_size(btn, w, 46);
  lv_obj_set_style_bg_color(btn, lv_color_hex(color), 0);
  lv_obj_set_style_radius(btn, 8, 0);
  lv_obj_add_event_cb(btn, cb, LV_EVENT_CLICKED, NULL);

  lv_obj_t *l = lv_label_create(btn);
  lv_label_set_text(l, text);
  lv_obj_set_style_text_font(l, F_LABEL, 0);
  lv_obj_set_style_text_color(l, lv_color_hex(C_TEXT), 0);
  lv_obj_center(l);
  return btn;
}

static lv_obj_t *make_field(lv_obj_t *parent, const char *label, lv_coord_t y,
                            bool password) {
  lv_obj_t *t = lv_label_create(parent);
  lv_label_set_text(t, label);
  lv_obj_set_style_text_font(t, F_LABEL, 0);
  lv_obj_set_style_text_color(t, lv_color_hex(C_LABEL), 0);
  lv_obj_set_pos(t, FORM_X, y);

  lv_obj_t *ta = lv_textarea_create(parent);
  lv_obj_set_pos(ta, FORM_X, y + 28);
  lv_obj_set_size(ta, FORM_W, 52);
  lv_textarea_set_one_line(ta, true);
  lv_textarea_set_password_mode(ta, password);
  lv_obj_set_style_bg_color(ta, lv_color_hex(C_FIELD), 0);
  lv_obj_set_style_border_color(ta, lv_color_hex(C_UNIT), 0);
  lv_obj_set_style_border_width(ta, 1, 0);
  lv_obj_set_style_text_color(ta, lv_color_hex(C_TEXT), 0);
  lv_obj_add_event_cb(ta, ta_event_cb, LV_EVENT_CLICKED, NULL);
  return ta;
}

void ui_settings_create(void) {
  // 全螢幕遮罩，擋住底下的儀表也吃掉誤觸
  s_panel = lv_obj_create(lv_layer_top());
  lv_obj_set_pos(s_panel, 0, 0);
  lv_obj_set_size(s_panel, LCD_H_RES, LCD_V_RES);
  lv_obj_clear_flag(s_panel, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_bg_color(s_panel, lv_color_hex(C_BG), 0);
  lv_obj_set_style_bg_opa(s_panel, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(s_panel, 0, 0);
  lv_obj_set_style_radius(s_panel, 0, 0);
  lv_obj_set_style_pad_all(s_panel, 0, 0);
  lv_obj_add_flag(s_panel, LV_OBJ_FLAG_HIDDEN);

  lv_obj_t *card = lv_obj_create(s_panel);
  lv_obj_set_pos(card, PANEL_X, PANEL_Y);
  lv_obj_set_size(card, PANEL_W, PANEL_H);
  lv_obj_clear_flag(card, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_bg_color(card, lv_color_hex(C_PANEL), 0);
  lv_obj_set_style_border_width(card, 0, 0);
  lv_obj_set_style_radius(card, 12, 0);
  lv_obj_set_style_pad_all(card, 0, 0);

  lv_obj_t *title = lv_label_create(card);
  lv_label_set_text(title, "WiFi 設定");
  lv_obj_set_style_text_font(title, F_LABEL, 0);
  lv_obj_set_style_text_color(title, lv_color_hex(C_TEXT), 0);
  lv_obj_set_pos(title, LIST_X, 12);

  // 左：掃描結果清單
  s_list = lv_list_create(card);
  lv_obj_set_pos(s_list, LIST_X, 46);
  lv_obj_set_size(s_list, LIST_W, 176);
  lv_obj_set_style_bg_color(s_list, lv_color_hex(C_FIELD), 0);
  lv_obj_set_style_border_width(s_list, 0, 0);
  lv_obj_set_style_radius(s_list, 8, 0);
  lv_obj_set_style_pad_all(s_list, 4, 0);
  lv_obj_set_style_text_font(s_list, F_LABEL, 0);

  make_button(card, "掃描", LIST_X, 230, 120, C_FIELD, scan_btn_cb);

  s_status = lv_label_create(card);
  lv_label_set_text(s_status, "");
  lv_obj_set_style_text_font(s_status, F_LABEL, 0);
  lv_obj_set_style_text_color(s_status, lv_color_hex(C_UNIT), 0);
  lv_obj_set_pos(s_status, LIST_X + 136, 242);

  // 右：輸入欄位與動作鈕
  s_ssid_ta = make_field(card, "網路名稱", 46, false);
  s_pass_ta = make_field(card, "密碼", 138, true);

  make_button(card, "儲存並連線", FORM_X, 230, 180, C_BLUE, save_btn_cb);
  make_button(card, "取消", FORM_X + 196, 230, 120, C_FIELD, close_btn_cb);

  // 下：注音/中文不需要，維持預設的 ASCII 鍵盤
  s_kb = lv_keyboard_create(s_panel);
  lv_obj_set_pos(s_kb, PANEL_X, KB_Y);
  lv_obj_set_size(s_kb, PANEL_W, KB_H);
  lv_keyboard_set_textarea(s_kb, s_ssid_ta);
}

// ── 開關 ────────────────────────────────────────────────────────────────
void ui_settings_open(const char *current_ssid) {
  if (current_ssid != NULL) {
    lv_textarea_set_text(s_ssid_ta, current_ssid);
  }
  lv_textarea_set_text(s_pass_ta, "");
  lv_keyboard_set_textarea(s_kb, s_ssid_ta);
  ui_settings_set_status("");
  lv_obj_clear_flag(s_panel, LV_OBJ_FLAG_HIDDEN);
  s_open = true;
}

void ui_settings_close(void) {
  lv_obj_add_flag(s_panel, LV_OBJ_FLAG_HIDDEN);
  s_open = false;
}

bool ui_settings_is_open(void) { return s_open; }

// ── 掃描結果 ────────────────────────────────────────────────────────────
void ui_settings_clear_networks(void) { lv_obj_clean(s_list); }

void ui_settings_add_network(const char *ssid, int rssi, bool locked) {
  if (ssid == NULL || ssid[0] == '\0') return;

  char buf[48];
  lv_snprintf(buf, sizeof(buf), "%s", ssid);
  lv_obj_t *btn = lv_list_add_btn(
      s_list, locked ? LV_SYMBOL_WIFI : LV_SYMBOL_OK, buf);
  lv_obj_set_style_text_color(btn, lv_color_hex(C_TEXT), 0);
  lv_obj_set_style_bg_opa(btn, LV_OPA_TRANSP, 0);
  lv_obj_add_event_cb(btn, list_item_cb, LV_EVENT_CLICKED, NULL);

  // 訊號強度靠右附註
  lv_obj_t *r = lv_label_create(btn);
  lv_snprintf(buf, sizeof(buf), "%d", rssi);
  lv_label_set_text(r, buf);
  lv_obj_set_style_text_font(r, &lv_font_montserrat_14, 0);
  lv_obj_set_style_text_color(r, lv_color_hex(C_UNIT), 0);
  lv_obj_align(r, LV_ALIGN_RIGHT_MID, 0, 0);
}

void ui_settings_set_status(const char *text) {
  lv_label_set_text(s_status, text ? text : "");
}
