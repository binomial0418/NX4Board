// WiFi STA + NVS 設定。介面與設計說明見 nx4_wifi.h。

#include "nx4_wifi.h"

#include <stdlib.h>
#include <string.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "nvs.h"
#include "nvs_flash.h"

#include "config.h"

static const char *TAG = "wifi";

// namespace 沿用 Arduino 版的 Preferences 名稱，換平台後已存的設定才讀得到
#define NVS_NS "nx4wifi"
#define NVS_KNOWN_KEY "known_v1"

// ── 狀態 ─────────────────────────────────────────────────────────────────
// s_pref_*：使用者在設定頁選的網路（NVS "ssid"/"pass"），開機一律先連它。
// s_ssid/s_pass：目前實際在連的網路。自動切換到其他已知網路時兩者會不同，
// 但不改寫使用者的選擇——下次開機還是先試使用者選的那台。
static char s_pref_ssid[NX4_SSID_LEN];
static char s_pref_pass[NX4_PASS_LEN];
static char s_ssid[NX4_SSID_LEN];
static char s_pass[NX4_PASS_LEN];
static char s_ip[16] = "";

static bool s_connected = false;

// 連線嘗試進行中（connect() 已送出，還沒等到 GOT_IP 或 DISCONNECTED）。
// 重試只在「沒有嘗試進行中」時發動；ESP-Hosted 經 SDIO 轉給 C6，一次嘗試
// 比原生 WiFi 慢得多，照固定週期 disconnect+connect 會把還沒完成的嘗試
// 自己中止掉（reason=8 ASSOC_LEAVE / 3 AUTH_LEAVE），永遠連不上。
static bool    s_connecting = false;
static int64_t s_attempt_ms = 0;   // 本次嘗試開始的時間
static int64_t s_ended_ms = 0;     // 上次嘗試結束（斷線事件）的時間
static int     s_fail_count = 0;   // 目前這台連續失敗的次數

// 連續失敗幾次後改找其他已知網路
#define FAIL_BEFORE_SWITCH 2

static esp_netif_t *s_netif = NULL;

static int64_t wifi_now_ms(void) { return esp_timer_get_time() / 1000; }

// ── 已知網路 ─────────────────────────────────────────────────────────────
// 只有真正拿到 IP 的網路才會加進來，所以打錯密碼的設定不會汙染清單。
// 固定 IP 也存在各自的項目裡，換網路時各用各的。
typedef struct {
    char     ssid[NX4_SSID_LEN];
    char     pass[NX4_PASS_LEN];
    uint32_t seq;        // 最近一次連線成功的序號，越大越新；0 = 空位
    uint8_t  pinned;     // 1 = 此網路使用固定 IP
    uint32_t ip, gw, mask;
} known_t;

static known_t  s_known[NX4_KNOWN_MAX];
static uint32_t s_seq = 0;

static void save_known(void) {
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_blob(h, NVS_KNOWN_KEY, s_known, sizeof(s_known));
    nvs_commit(h);
    nvs_close(h);
}

static known_t *find_known(const char *ssid) {
    for (int i = 0; i < NX4_KNOWN_MAX; i++) {
        if (s_known[i].seq && strcmp(s_known[i].ssid, ssid) == 0) return &s_known[i];
    }
    return NULL;
}

/// 連線成功：加入或更新清單。滿了就擠掉最久沒成功的那一筆。
static void remember_current(void) {
    known_t *k = find_known(s_ssid);
    if (!k) {
        k = &s_known[0];
        for (int i = 0; i < NX4_KNOWN_MAX; i++) {
            if (s_known[i].seq == 0) { k = &s_known[i]; break; }
            if (s_known[i].seq < k->seq) k = &s_known[i];
        }
        memset(k, 0, sizeof(*k));
        strlcpy(k->ssid, s_ssid, sizeof(k->ssid));
        printf("[WiFi] 加入已知網路: %s\n", s_ssid);
    }
    strlcpy(k->pass, s_pass, sizeof(k->pass));
    k->seq = ++s_seq;
    save_known();
}

/// 讀清單。第一次跑新版時，把舊版「單一固定 IP」的設定搬進來：
/// 舊版只有連上過才能按固定 IP，所以綁定的那組 SSID/密碼可以視為已知網路。
static void load_known(void) {
    memset(s_known, 0, sizeof(s_known));
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;

    size_t len = sizeof(s_known);
    if (nvs_get_blob(h, NVS_KNOWN_KEY, s_known, &len) != ESP_OK || len != sizeof(s_known)) {
        memset(s_known, 0, sizeof(s_known));
        char ssid[NX4_SSID_LEN] = "";
        size_t n = sizeof(ssid);
        uint32_t a = 0, g = 0, m = 0;
        bool legacy = nvs_get_str(h, "ip_ssid", ssid, &n) == ESP_OK &&
                      nvs_get_u32(h, "ip_addr", &a) == ESP_OK &&
                      nvs_get_u32(h, "ip_gw", &g) == ESP_OK &&
                      nvs_get_u32(h, "ip_mask", &m) == ESP_OK;
        if (legacy && strcmp(ssid, s_pref_ssid) == 0) {
            known_t *k = &s_known[0];
            strlcpy(k->ssid, s_pref_ssid, sizeof(k->ssid));
            strlcpy(k->pass, s_pref_pass, sizeof(k->pass));
            k->seq = 1;
            k->pinned = 1;
            k->ip = a; k->gw = g; k->mask = m;
            printf("[WiFi] 舊版固定 IP 設定已轉入已知網路: %s\n", ssid);
        }
        if (legacy) {
            nvs_erase_key(h, "ip_ssid");
            nvs_erase_key(h, "ip_addr");
            nvs_erase_key(h, "ip_gw");
            nvs_erase_key(h, "ip_mask");
        }
        nvs_set_blob(h, NVS_KNOWN_KEY, s_known, sizeof(s_known));
        nvs_commit(h);
    }
    nvs_close(h);

    for (int i = 0; i < NX4_KNOWN_MAX; i++) {
        if (s_known[i].seq > s_seq) s_seq = s_known[i].seq;
        if (s_known[i].seq) {
            printf("[WiFi] 已知網路: %s%s\n", s_known[i].ssid,
                   s_known[i].pinned ? "（固定 IP）" : "");
        }
    }
}

bool nx4_wifi_known_pass(const char *ssid, char *out, size_t n) {
    known_t *k = ssid ? find_known(ssid) : NULL;
    if (!k) return false;
    strlcpy(out, k->pass, n);
    return true;
}

const char *nx4_wifi_known_ssid(int index) {
    // 依最近成功排序，第 index 筆
    uint32_t below = UINT32_MAX;
    const known_t *pick = NULL;
    for (int n = 0; n <= index; n++) {
        pick = NULL;
        for (int i = 0; i < NX4_KNOWN_MAX; i++) {
            if (s_known[i].seq && s_known[i].seq < below &&
                (!pick || s_known[i].seq > pick->seq)) {
                pick = &s_known[i];
            }
        }
        if (!pick) return NULL;
        below = pick->seq;
    }
    return pick->ssid;
}

bool nx4_wifi_forget(const char *ssid) {
    known_t *k = ssid ? find_known(ssid) : NULL;
    if (!k) return false;
    printf("[WiFi] 忘記網路: %s\n", k->ssid);
    memset(k, 0, sizeof(*k));
    save_known();
    return true;
}

// ── NVS：使用者選的網路 ──────────────────────────────────────────────────
static void load_credentials(void) {
    nvs_handle_t h;
    s_pref_ssid[0] = s_pref_pass[0] = '\0';
    if (nvs_open(NVS_NS, NVS_READONLY, &h) == ESP_OK) {
        size_t n = sizeof(s_pref_ssid);
        if (nvs_get_str(h, "ssid", s_pref_ssid, &n) != ESP_OK) s_pref_ssid[0] = '\0';
        n = sizeof(s_pref_pass);
        if (nvs_get_str(h, "pass", s_pref_pass, &n) != ESP_OK) s_pref_pass[0] = '\0';
        nvs_close(h);
    }
    if (s_pref_ssid[0] == '\0') {
        strlcpy(s_pref_ssid, WIFI_SSID, sizeof(s_pref_ssid));
        strlcpy(s_pref_pass, WIFI_PASS, sizeof(s_pref_pass));
        printf("[WiFi] 使用 config.h 的設定: %s\n", s_pref_ssid);
    } else {
        printf("[WiFi] 使用已儲存的設定: %s\n", s_pref_ssid);
    }
    strlcpy(s_ssid, s_pref_ssid, sizeof(s_ssid));
    strlcpy(s_pass, s_pref_pass, sizeof(s_pass));
}

static void save_credentials(const char *ssid, const char *pass) {
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_str(h, "ssid", ssid);
    nvs_set_str(h, "pass", pass);
    nvs_commit(h);
    nvs_close(h);
}

int nx4_nvs_load_volume(void) {
    nvs_handle_t h;
    int32_t v = -1;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) == ESP_OK) {
        if (nvs_get_i32(h, "volume", &v) != ESP_OK) v = -1;
        nvs_close(h);
    }
    return (int)v;
}

bool nx4_nvs_load_obd_direct(void) {
    nvs_handle_t h;
    uint8_t v = 0;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) == ESP_OK) {
        if (nvs_get_u8(h, "obd_direct", &v) != ESP_OK) v = 0;
        nvs_close(h);
    }
    return v != 0;
}

void nx4_nvs_load_obd_name(char *out, size_t n) {
    nvs_handle_t h;
    out[0] = '\0';
    if (nvs_open(NVS_NS, NVS_READONLY, &h) == ESP_OK) {
        size_t len = n;
        if (nvs_get_str(h, "obd_name", out, &len) != ESP_OK) out[0] = '\0';
        nvs_close(h);
    }
    if (out[0] == '\0') strlcpy(out, NX4_OBD_NAME_DEFAULT, n);
}

void nx4_nvs_save_source(bool direct, const char *obd_name) {
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_u8(h, "obd_direct", direct ? 1 : 0);
    if (obd_name && obd_name[0]) nvs_set_str(h, "obd_name", obd_name);
    nvs_commit(h);
    nvs_close(h);
}

void nx4_nvs_save_volume(int volume) {
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_i32(h, "volume", volume);
    nvs_commit(h);
    nvs_close(h);
}

// ── 固定 IP（每個已知網路各自一組）────────────────────────────────────────
/// 依目前要連的網路設定 netif：有固定 IP 就停掉 DHCP 並套用，否則開 DHCP。
static void apply_ip_mode(void) {
    known_t *k = find_known(s_ssid);
    if (k && k->pinned) {
        esp_netif_ip_info_t ip = {0};
        ip.ip.addr = k->ip;
        ip.gw.addr = k->gw;
        ip.netmask.addr = k->mask;
        esp_netif_dhcpc_stop(s_netif);
        if (esp_netif_set_ip_info(s_netif, &ip) == ESP_OK) {
            printf("[WiFi] 使用固定 IP " IPSTR "（%s）\n", IP2STR(&ip.ip), s_ssid);
            return;
        }
        printf("[WiFi] 固定 IP 設定失敗，改用 DHCP\n");
    }
    esp_netif_dhcpc_start(s_netif);   // 已在跑會回傳 ALREADY_STARTED，無妨
}

bool nx4_wifi_ip_pinned(void) {
    known_t *k = find_known(s_ssid);
    return k && k->pinned;
}

bool nx4_wifi_pin_current_ip(void) {
    if (!s_connected || !s_netif) return false;
    known_t *k = find_known(s_ssid);   // 連上時就已經加入清單
    esp_netif_ip_info_t ip;
    if (!k || esp_netif_get_ip_info(s_netif, &ip) != ESP_OK || ip.ip.addr == 0) return false;
    k->pinned = 1;
    k->ip = ip.ip.addr;
    k->gw = ip.gw.addr;
    k->mask = ip.netmask.addr;
    save_known();
    printf("[WiFi] 已固定 IP " IPSTR "（%s）\n", IP2STR(&ip.ip), s_ssid);
    return true;
}

void nx4_wifi_unpin_ip(void) {
    known_t *k = find_known(s_ssid);
    if (!k || !k->pinned) return;
    k->pinned = 0;
    save_known();
    printf("[WiFi] 已取消 %s 的固定 IP，下次連線改用 DHCP\n", s_ssid);
}

// ── 連線 ─────────────────────────────────────────────────────────────────
static void do_connect(void) {
    wifi_config_t cfg = {0};
    strlcpy((char *)cfg.sta.ssid, s_ssid, sizeof(cfg.sta.ssid));
    strlcpy((char *)cfg.sta.password, s_pass, sizeof(cfg.sta.password));
    // 不限定加密方式：開放網路與 WPA2/WPA3 都要能連
    cfg.sta.threshold.authmode = WIFI_AUTH_OPEN;
    apply_ip_mode();
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &cfg));
    s_connecting = true;
    s_attempt_ms = wifi_now_ms();
    esp_wifi_connect();
}

// ── 掃描 ─────────────────────────────────────────────────────────────────
// 設定頁的手動掃描與自動切換共用一次硬體掃描，結果放進快取，誰先來誰取。
#define SCAN_CACHE_MAX 20
static nx4_ap_t s_cache[SCAN_CACHE_MAX];
static int      s_cache_n = -2;        // 筆數，-2 = 失敗
static volatile int s_scan_result = -1; // SCAN_DONE 事件寫入：-1 未完成 / 筆數
static bool s_scan_active = false;      // 硬體掃描進行中
static bool s_scan_pending = false;     // 要掃但還沒成功啟動（連線中會被拒）
static int  s_scan_tries = 0;
static int64_t s_scan_retry_ms = 0;
static bool s_ui_wants = false;         // 設定頁在等結果
static bool s_auto_wants = false;       // 自動切換在等結果

static bool try_start_scan(void) {
    s_scan_result = -1;
    wifi_scan_config_t cfg = {0};
    if (esp_wifi_scan_start(&cfg, false) == ESP_OK) {
        s_scan_active = true;
        s_scan_pending = false;
        return true;
    }
    return false;
}

static void request_scan(void) {
    if (s_scan_active || s_scan_pending) return;
    // 連線嘗試中掃描會被拒（ESP_ERR_WIFI_STATE）。先中止這次嘗試——
    // 使用者要掃描就是要換網路，自動切換則是這台已經連不上了。
    if (s_connecting && !s_connected) {
        s_connecting = false;          // 讓斷線事件不被算成失敗
        esp_wifi_disconnect();
    }
    s_scan_tries = 0;
    s_scan_retry_ms = wifi_now_ms();
    if (!try_start_scan()) s_scan_pending = true;
}

/// 硬體掃描完成就把結果搬進快取。回傳 false 代表還在掃。
static bool collect_scan(void) {
    if (s_scan_pending) {
        // 剛中止連線時掃描可能還會被拒幾次，每秒重試，5 次放棄
        int64_t now = wifi_now_ms();
        if (now - s_scan_retry_ms < 1000) return false;
        s_scan_retry_ms = now;
        if (++s_scan_tries > 5) {
            s_scan_pending = false;
            s_cache_n = -2;
            return true;
        }
        try_start_scan();
        return false;
    }
    if (!s_scan_active) return true;
    if (s_scan_result == -1) return false;

    s_scan_active = false;
    uint16_t n = (uint16_t)(s_scan_result > SCAN_CACHE_MAX ? SCAN_CACHE_MAX : s_scan_result);
    s_scan_result = -1;
    s_cache_n = 0;
    if (n == 0) {
        esp_wifi_clear_ap_list();
        return true;
    }
    wifi_ap_record_t *recs = calloc(n, sizeof(wifi_ap_record_t));
    if (!recs) {
        esp_wifi_clear_ap_list();
        s_cache_n = -2;
        return true;
    }
    esp_wifi_scan_get_ap_records(&n, recs);
    for (int i = 0; i < n; i++) {
        strlcpy(s_cache[i].ssid, (const char *)recs[i].ssid, sizeof(s_cache[i].ssid));
        s_cache[i].rssi = recs[i].rssi;
        s_cache[i].locked = recs[i].authmode != WIFI_AUTH_OPEN;
    }
    free(recs);
    s_cache_n = n;
    ESP_LOGD(TAG, "掃描到 %u 個 AP", n);
    return true;
}

void nx4_wifi_scan_start(void) {
    s_ui_wants = true;
    request_scan();
}

bool nx4_wifi_scan_busy(void) { return s_ui_wants; }

int nx4_wifi_scan_take(nx4_ap_t *out, int max) {
    if (!s_ui_wants) return -1;
    if (!collect_scan()) return -1;
    s_ui_wants = false;
    if (s_cache_n < 0) return -2;
    int n = s_cache_n > max ? max : s_cache_n;
    memcpy(out, s_cache, n * sizeof(nx4_ap_t));
    return n;
}

/// 自動切換：從掃描結果挑一台已知網路（排除剛連不上的這台），訊號最強者勝。
/// 都不在範圍內就回到使用者選的那台繼續試。
static void pick_fallback(void) {
    const known_t *best = NULL;
    int best_rssi = -1000;
    for (int i = 0; i < (s_cache_n > 0 ? s_cache_n : 0); i++) {
        if (strcmp(s_cache[i].ssid, s_ssid) == 0) continue;
        const known_t *k = find_known(s_cache[i].ssid);
        if (k && s_cache[i].rssi > best_rssi) {
            best = k;
            best_rssi = s_cache[i].rssi;
        }
    }
    if (best) {
        printf("[WiFi] %s 連不上，改連已知網路 %s（%d dBm）\n", s_ssid, best->ssid, best_rssi);
        strlcpy(s_ssid, best->ssid, sizeof(s_ssid));
        strlcpy(s_pass, best->pass, sizeof(s_pass));
    } else if (strcmp(s_ssid, s_pref_ssid) != 0) {
        printf("[WiFi] 附近沒有其他已知網路，回到 %s\n", s_pref_ssid);
        strlcpy(s_ssid, s_pref_ssid, sizeof(s_ssid));
        strlcpy(s_pass, s_pref_pass, sizeof(s_pass));
    } else {
        printf("[WiFi] 附近沒有其他已知網路，繼續嘗試 %s\n", s_ssid);
    }
}

/// 事件處理。斷線原因碼是診斷連不上的唯一可靠依據
/// （15=4WAY_HANDSHAKE_TIMEOUT 密碼錯誤、201=NO_AP_FOUND、
///   202=AUTH_FAIL、203=ASSOC_FAIL、8=ASSOC_LEAVE）。
static void on_wifi(void *arg, esp_event_base_t base, int32_t id, void *data) {
    if (base == WIFI_EVENT) {
        switch (id) {
        case WIFI_EVENT_STA_START:
            printf("[WiFi] STA start\n");
            do_connect();
            break;
        case WIFI_EVENT_STA_CONNECTED:
            printf("[WiFi] 已與 AP 關聯\n");
            break;
        case WIFI_EVENT_STA_DISCONNECTED: {
            wifi_event_sta_disconnected_t *e = data;
            printf("[WiFi] 斷線, reason=%d\n", e->reason);
            // 嘗試中收到斷線 = 這次嘗試失敗；已連線後才斷則不算
            if (s_connecting) s_fail_count++;
            s_connected = false;
            s_connecting = false;
            s_ended_ms = wifi_now_ms();
            s_ip[0] = '\0';
            break;
        }
        case WIFI_EVENT_SCAN_DONE: {
            uint16_t n = 0;
            esp_wifi_scan_get_ap_num(&n);
            s_scan_result = (int)n;
            break;
        }
        default:
            break;
        }
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = data;
        snprintf(s_ip, sizeof(s_ip), IPSTR, IP2STR(&e->ip_info.ip));
        s_connected = true;
        s_connecting = false;
        s_fail_count = 0;
        printf("[WiFi] 取得 IP: %s\n", s_ip);
        remember_current();
        // 關聯完成後才關省電模式。在 connect() 之前呼叫會讓 ESP-Hosted
        // 重新初始化，導致剛送出的連線請求被以 reason=8 (ASSOC_LEAVE) 中止。
        esp_wifi_set_ps(WIFI_PS_NONE);
    }
}

void nx4_nvs_init_early(void) {
    static bool done = false;
    if (done) return;
    done = true;
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
}

void nx4_wifi_start(void) {
    nx4_nvs_init_early();
    load_credentials();
    load_known();

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_netif = esp_netif_create_default_wifi_sta();

    wifi_init_config_t ic = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&ic));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        WIFI_EVENT, ESP_EVENT_ANY_ID, on_wifi, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        IP_EVENT, IP_EVENT_STA_GOT_IP, on_wifi, NULL, NULL));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_start());
    printf("[WiFi] 連線中: %s\n", s_ssid);
}

void nx4_wifi_apply(const char *ssid, const char *pass) {
    printf("[WiFi] 套用新設定: %s\n", ssid);
    save_credentials(ssid, pass);
    strlcpy(s_pref_ssid, ssid, sizeof(s_pref_ssid));
    strlcpy(s_pref_pass, pass, sizeof(s_pref_pass));
    strlcpy(s_ssid, ssid, sizeof(s_ssid));
    strlcpy(s_pass, pass, sizeof(s_pass));
    // 不直接 connect：舊連線的斷線事件會晚到，把新嘗試標成已結束。
    // 交給 nx4_wifi_service()，約 1 秒後（或斷線事件後 5 秒）用新設定連線。
    esp_wifi_disconnect();
    s_connected = false;
    s_connecting = false;
    s_fail_count = 0;
    s_ended_ms = wifi_now_ms() - 4000;
}

const char *nx4_wifi_ssid(void) { return s_ssid; }
bool nx4_wifi_connected(void) { return s_connected; }
const char *nx4_wifi_ip(void) { return s_connected ? s_ip : NULL; }

int nx4_wifi_rssi(void) {
    wifi_ap_record_t ap;
    return (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) ? ap.rssi : 0;
}

int nx4_wifi_channel(void) {
    wifi_ap_record_t ap;
    return (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) ? ap.primary : 0;
}

bool nx4_wifi_ps_on(void) {
    wifi_ps_type_t ps = WIFI_PS_NONE;
    esp_wifi_get_ps(&ps);
    return ps != WIFI_PS_NONE;
}

static int other_known_count(void) {
    int n = 0;
    for (int i = 0; i < NX4_KNOWN_MAX; i++) {
        if (s_known[i].seq && strcmp(s_known[i].ssid, s_ssid) != 0) n++;
    }
    return n;
}

bool nx4_wifi_service(void) {
    // 自動切換的掃描結果回來了 → 挑下一台
    if (s_auto_wants) {
        if (!collect_scan()) return s_connected;
        s_auto_wants = false;
        pick_fallback();
        s_fail_count = 0;
        if (!s_connected) do_connect();
        return s_connected;
    }

    // 不論是初次連線失敗還是中途斷線都會重試——只在「已連線 → 斷線」時
    // 重連的話，開機第一次就失敗會永遠卡住。
    //   * 上一次嘗試已結束（收到斷線事件）→ 隔 5 秒再試
    //   * 同一台連續失敗 FAIL_BEFORE_SWITCH 次、且還有其他已知網路 → 掃描後換一台
    //   * 嘗試進行中 → 等它自己結束；超過 30 秒沒有任何事件才視為卡住，強制重來
    // 設定頁掃描中則跳過，重連會中斷掃描。
    if (s_connected || s_ui_wants) return s_connected;
    int64_t now = wifi_now_ms();
    if (s_connecting) {
        if (now - s_attempt_ms >= 30000) {
            printf("[WiFi] 連線 30 秒無回應，放棄這次嘗試 %s\n", s_ssid);
            s_connecting = false;
            s_fail_count++;
            s_ended_ms = now;
            esp_wifi_disconnect();
        }
    } else if (now - s_ended_ms >= 5000) {
        if (s_fail_count >= FAIL_BEFORE_SWITCH && other_known_count() > 0) {
            printf("[WiFi] %s 連續失敗 %d 次，掃描其他已知網路\n", s_ssid, s_fail_count);
            s_auto_wants = true;
            request_scan();
        } else {
            printf("[WiFi] 未連線，重試 %s\n", s_ssid);
            do_connect();
        }
    }
    return s_connected;
}
