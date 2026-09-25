// WiFi STA + NVS 設定。介面與設計說明見 nx4_wifi.h。

#include "nx4_wifi.h"

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

static char s_ssid[NX4_SSID_LEN];
static char s_pass[NX4_PASS_LEN];
static char s_ip[16] = "";

static bool s_connected = false;
static bool s_scanning = false;
static int  s_scan_result = -1;   // -1 進行中 / -2 失敗 / >=0 筆數

static esp_netif_t *s_netif = NULL;

// ── NVS ──────────────────────────────────────────────────────────────────
static void load_credentials(void) {
    nvs_handle_t h;
    s_ssid[0] = s_pass[0] = '\0';
    if (nvs_open(NVS_NS, NVS_READONLY, &h) == ESP_OK) {
        size_t n = sizeof(s_ssid);
        if (nvs_get_str(h, "ssid", s_ssid, &n) != ESP_OK) s_ssid[0] = '\0';
        n = sizeof(s_pass);
        if (nvs_get_str(h, "pass", s_pass, &n) != ESP_OK) s_pass[0] = '\0';
        nvs_close(h);
    }
    if (s_ssid[0] == '\0') {
        strlcpy(s_ssid, WIFI_SSID, sizeof(s_ssid));
        strlcpy(s_pass, WIFI_PASS, sizeof(s_pass));
        printf("[WiFi] 使用 config.h 的設定: %s\n", s_ssid);
    } else {
        printf("[WiFi] 使用已儲存的設定: %s\n", s_ssid);
    }
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

// ── 固定 IP ──────────────────────────────────────────────────────────────
static bool load_pinned(esp_netif_ip_info_t *ip) {
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) return false;

    char ssid[NX4_SSID_LEN] = "";
    size_t n = sizeof(ssid);
    bool ok = nvs_get_str(h, "ip_ssid", ssid, &n) == ESP_OK;
    uint32_t a = 0, g = 0, m = 0;
    ok = ok && nvs_get_u32(h, "ip_addr", &a) == ESP_OK;
    ok = ok && nvs_get_u32(h, "ip_gw", &g) == ESP_OK;
    ok = ok && nvs_get_u32(h, "ip_mask", &m) == ESP_OK;
    nvs_close(h);

    // 綁定 SSID：換了網路就不套用，避免網段不符而完全連不上
    if (!ok || strcmp(ssid, s_ssid) != 0) return false;
    ip->ip.addr = a;
    ip->gw.addr = g;
    ip->netmask.addr = m;
    return true;
}

static void apply_pinned_ip(void) {
    esp_netif_ip_info_t ip = {0};
    if (!load_pinned(&ip)) return;      // 沒設定或 SSID 不符，維持 DHCP

    esp_netif_dhcpc_stop(s_netif);
    if (esp_netif_set_ip_info(s_netif, &ip) != ESP_OK) {
        printf("[WiFi] 固定 IP 設定失敗，改用 DHCP\n");
        esp_netif_dhcpc_start(s_netif);
        return;
    }
    printf("[WiFi] 使用固定 IP " IPSTR "（綁定 %s）\n", IP2STR(&ip.ip), s_ssid);
}

bool nx4_wifi_ip_pinned(void) {
    esp_netif_ip_info_t ip;
    return load_pinned(&ip);
}

bool nx4_wifi_pin_current_ip(void) {
    if (!s_connected || !s_netif) return false;
    esp_netif_ip_info_t ip;
    if (esp_netif_get_ip_info(s_netif, &ip) != ESP_OK || ip.ip.addr == 0) return false;

    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return false;
    nvs_set_str(h, "ip_ssid", s_ssid);
    nvs_set_u32(h, "ip_addr", ip.ip.addr);
    nvs_set_u32(h, "ip_gw", ip.gw.addr);
    nvs_set_u32(h, "ip_mask", ip.netmask.addr);
    nvs_commit(h);
    nvs_close(h);
    printf("[WiFi] 已固定 IP " IPSTR "（綁定 %s）\n", IP2STR(&ip.ip), s_ssid);
    return true;
}

void nx4_wifi_unpin_ip(void) {
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_erase_key(h, "ip_ssid");
    nvs_erase_key(h, "ip_addr");
    nvs_erase_key(h, "ip_gw");
    nvs_erase_key(h, "ip_mask");
    nvs_commit(h);
    nvs_close(h);
    printf("[WiFi] 已取消固定 IP，下次連線改用 DHCP\n");
}

// ── 連線 ─────────────────────────────────────────────────────────────────
static void do_connect(void) {
    wifi_config_t cfg = {0};
    strlcpy((char *)cfg.sta.ssid, s_ssid, sizeof(cfg.sta.ssid));
    strlcpy((char *)cfg.sta.password, s_pass, sizeof(cfg.sta.password));
    // 不限定加密方式：開放網路與 WPA2/WPA3 都要能連
    cfg.sta.threshold.authmode = WIFI_AUTH_OPEN;
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &cfg));
    esp_wifi_connect();
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
            s_connected = false;
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
        printf("[WiFi] 取得 IP: %s\n", s_ip);
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

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_netif = esp_netif_create_default_wifi_sta();

    apply_pinned_ip();

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
    strlcpy(s_ssid, ssid, sizeof(s_ssid));
    strlcpy(s_pass, pass, sizeof(s_pass));
    esp_wifi_disconnect();
    do_connect();
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

bool nx4_wifi_service(void) {
    // 不論是初次連線失敗還是中途斷線，都每 10 秒重試一次。只在
    // 「已連線 → 斷線」時重連的話，開機第一次就失敗會永遠卡住。
    // 掃描進行中則跳過，重連會中斷掃描。
    static int64_t last_retry = 0;
    if (!s_connected && !s_scanning) {
        int64_t now = esp_timer_get_time() / 1000;
        if (now - last_retry >= 10000) {
            last_retry = now;
            printf("[WiFi] 未連線，重試 %s\n", s_ssid);
            esp_wifi_disconnect();
            do_connect();
        }
    }
    return s_connected;
}

// ── 掃描 ─────────────────────────────────────────────────────────────────
void nx4_wifi_scan_start(void) {
    if (s_scanning) return;
    s_scanning = true;
    s_scan_result = -1;
    wifi_scan_config_t cfg = {0};
    if (esp_wifi_scan_start(&cfg, false) != ESP_OK) {
        s_scanning = false;
        s_scan_result = -2;
    }
}

bool nx4_wifi_scan_busy(void) { return s_scanning; }

int nx4_wifi_scan_take(nx4_ap_t *out, int max) {
    if (!s_scanning) return -1;
    if (s_scan_result == -1) return -1;

    s_scanning = false;
    if (s_scan_result < 0) return -2;

    uint16_t n = (uint16_t)(s_scan_result > max ? max : s_scan_result);
    if (n == 0) {
        esp_wifi_clear_ap_list();
        s_scan_result = -1;
        return 0;
    }

    wifi_ap_record_t *recs = calloc(n, sizeof(wifi_ap_record_t));
    if (!recs) {
        esp_wifi_clear_ap_list();
        s_scan_result = -1;
        return -2;
    }
    esp_wifi_scan_get_ap_records(&n, recs);
    for (int i = 0; i < n; i++) {
        strlcpy(out[i].ssid, (const char *)recs[i].ssid, sizeof(out[i].ssid));
        out[i].rssi = recs[i].rssi;
        out[i].locked = recs[i].authmode != WIFI_AUTH_OPEN;
    }
    free(recs);
    s_scan_result = -1;
    ESP_LOGD(TAG, "掃描到 %u 個 AP", n);
    return n;
}
