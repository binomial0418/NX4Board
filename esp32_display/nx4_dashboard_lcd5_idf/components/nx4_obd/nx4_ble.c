// BLE central：連上 ELM327 相容的 OBD dongle。說明見 nx4_ble.h。

#include "nx4_ble.h"

#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"

static const char *TAG = "nx4_ble";

// obdlab/ble.py 實測到的 UUID。BLE 的 16-bit UUID 在這裡用 BLE_UUID16 表示。
#define UUID_SERVICE 0x18F0
#define UUID_NOTIFY  0x2AF0
#define UUID_WRITE   0x2AF1

#define NAME_LEN 32
#define BLE_MTU_PAYLOAD 20   // 預設 MTU 23 扣掉 3 bytes 的 ATT 標頭

static char              s_name[NAME_LEN] = "";
static nx4_ble_rx_cb_t   s_on_rx = NULL;

static uint16_t s_conn = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_write_handle = 0;
static uint16_t s_notify_handle = 0;
static bool     s_ready = false;
static bool     s_enabled = true;
static bool     s_inited = false;

static void start_scan(void);

// ── 掃描 ─────────────────────────────────────────────────────────────────
/// 廣播封包裡找 Complete/Shortened Local Name，與設定的名稱比對。
static bool name_matches(const struct ble_hs_adv_fields *f) {
    if (!f->name || f->name_len == 0 || s_name[0] == '\0') return false;
    size_t want = strlen(s_name);
    // 名稱可能被截短（Shortened Local Name），所以用前綴比對
    size_t n = f->name_len < want ? f->name_len : want;
    if (f->name_len > want) return false;
    return strncasecmp((const char *)f->name, s_name, n) == 0 && n == want;
}

static int on_gap(struct ble_gap_event *ev, void *arg);

/// 每個名稱只印一次，避免重複廣播把日誌與 NimBLE 的 buffer 灌爆。
#define SEEN_MAX 16
static void log_name_once(const struct ble_hs_adv_fields *f, int rssi) {
    static char seen[SEEN_MAX][NAME_LEN];
    static int  seen_n = 0;

    char name[NAME_LEN];
    size_t n = f->name_len < sizeof(name) - 1 ? f->name_len : sizeof(name) - 1;
    memcpy(name, f->name, n);
    name[n] = '\0';

    for (int i = 0; i < seen_n; i++) {
        if (strcmp(seen[i], name) == 0) return;
    }
    if (seen_n < SEEN_MAX) strlcpy(seen[seen_n++], name, NAME_LEN);
    ESP_LOGI(TAG, "掃到「%s」 rssi %d", name, rssi);
}

static void start_scan(void) {
    if (!s_enabled) return;
    uint8_t own_addr_type;
    if (ble_hs_id_infer_auto(0, &own_addr_type) != 0) {
        ESP_LOGE(TAG, "取不到本機位址型別");
        return;
    }
    struct ble_gap_disc_params p = {0};
    p.filter_duplicates = 1;
    p.passive = 0;          // active scan，才拿得到 scan response 裡的名稱
    p.itvl = 0;
    p.window = 0;
    p.filter_policy = 0;
    p.limited = 0;

    int rc = ble_gap_disc(own_addr_type, BLE_HS_FOREVER, &p, on_gap, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGE(TAG, "ble_gap_disc 失敗 rc=%d", rc);
    } else {
        ESP_LOGI(TAG, "開始掃描「%s」", s_name);
    }
}

// ── GATT 探索 ────────────────────────────────────────────────────────────
static int on_chr(uint16_t conn, const struct ble_gatt_error *err,
                  const struct ble_gatt_chr *chr, void *arg) {
    if (err->status == BLE_HS_EDONE) {
        if (s_write_handle && s_notify_handle) {
            // 訂閱 notify：CCCD 是 characteristic value handle + 1
            uint8_t v[2] = {0x01, 0x00};
            int rc = ble_gattc_write_flat(conn, s_notify_handle + 1, v, sizeof(v),
                                          NULL, NULL);
            if (rc != 0) {
                ESP_LOGE(TAG, "訂閱 notify 失敗 rc=%d", rc);
                return 0;
            }
            s_ready = true;
            ESP_LOGI(TAG, "就緒（write=0x%04x notify=0x%04x）",
                     s_write_handle, s_notify_handle);
        } else {
            ESP_LOGE(TAG, "找不到 2AF0/2AF1，這顆 dongle 的序列橋接服務可能不同");
        }
        return 0;
    }
    if (err->status != 0 || !chr) return 0;

    if (ble_uuid_u16(&chr->uuid.u) == UUID_WRITE) {
        s_write_handle = chr->val_handle;
    } else if (ble_uuid_u16(&chr->uuid.u) == UUID_NOTIFY) {
        s_notify_handle = chr->val_handle;
    }
    return 0;
}

static int on_svc(uint16_t conn, const struct ble_gatt_error *err,
                  const struct ble_gatt_svc *svc, void *arg) {
    if (err->status == BLE_HS_EDONE) return 0;
    if (err->status != 0 || !svc) return 0;

    ESP_LOGI(TAG, "找到序列橋接服務 18F0，開始找 characteristic");
    ble_gattc_disc_all_chrs(conn, svc->start_handle, svc->end_handle, on_chr, NULL);
    return 0;
}

// ── GAP 事件 ─────────────────────────────────────────────────────────────
static int on_gap(struct ble_gap_event *ev, void *arg) {
    switch (ev->type) {
    case BLE_GAP_EVENT_DISC: {
        struct ble_hs_adv_fields f;
        if (ble_hs_adv_parse_fields(&f, ev->disc.data, ev->disc.length_data) != 0) {
            return 0;
        }
        // 掃到的裝置名稱印出來——找不到 dongle 時這是唯一的線索。
        // 但同一台會一直重複廣播，全印會把 NimBLE 的 buffer 灌爆
        // （vhci_drv 會開始報 "Drop ADV Report Event: NimBLE OOM"），
        // 所以只在第一次看到某個名稱時印。
        if (f.name_len > 0) log_name_once(&f, ev->disc.rssi);
        if (!name_matches(&f)) return 0;

        ble_gap_disc_cancel();
        uint8_t own_addr_type;
        ble_hs_id_infer_auto(0, &own_addr_type);
        int rc = ble_gap_connect(own_addr_type, &ev->disc.addr, 10000, NULL,
                                 on_gap, NULL);
        if (rc != 0) {
            ESP_LOGE(TAG, "連線失敗 rc=%d，重新掃描", rc);
            start_scan();
        }
        return 0;
    }

    case BLE_GAP_EVENT_CONNECT:
        if (ev->connect.status == 0) {
            s_conn = ev->connect.conn_handle;
            s_write_handle = s_notify_handle = 0;
            s_ready = false;
            ESP_LOGI(TAG, "已連線，開始探索 GATT");
            ble_gattc_exchange_mtu(s_conn, NULL, NULL);
            ble_uuid16_t svc = BLE_UUID16_INIT(UUID_SERVICE);
            ble_gattc_disc_svc_by_uuid(s_conn, &svc.u, on_svc, NULL);
        } else {
            ESP_LOGW(TAG, "連線失敗 status=%d，重新掃描", ev->connect.status);
            start_scan();
        }
        return 0;

    case BLE_GAP_EVENT_DISCONNECT:
        s_conn = BLE_HS_CONN_HANDLE_NONE;
        s_ready = false;
        s_write_handle = s_notify_handle = 0;
        if (s_enabled) {
            ESP_LOGW(TAG, "斷線 reason=%d，重新掃描", ev->disconnect.reason);
            start_scan();
        } else {
            ESP_LOGI(TAG, "已停用，保持斷線");
        }
        return 0;

    case BLE_GAP_EVENT_DISC_COMPLETE:
        // BLE_HS_FOREVER 理論上不會走到這裡，保險起見重開
        start_scan();
        return 0;

    case BLE_GAP_EVENT_NOTIFY_RX: {
        if (!s_on_rx || ev->notify_rx.attr_handle != s_notify_handle) return 0;
        // om 可能是鏈結串列，逐段交出去
        for (struct os_mbuf *om = ev->notify_rx.om; om; om = SLIST_NEXT(om, om_next)) {
            if (om->om_len > 0) s_on_rx(om->om_data, om->om_len);
        }
        return 0;
    }

    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "MTU = %d", ev->mtu.value);
        return 0;

    default:
        return 0;
    }
}

// ── NimBLE host ──────────────────────────────────────────────────────────
static void on_sync(void) {
    ble_hs_util_ensure_addr(0);
    start_scan();
}

static void on_reset(int reason) {
    ESP_LOGW(TAG, "NimBLE reset, reason=%d", reason);
    s_ready = false;
}

static void host_task(void *param) {
    nimble_port_run();          // 回來代表要收工
    nimble_port_freertos_deinit();
}

void nx4_ble_start(const char *name, nx4_ble_rx_cb_t on_rx) {
    s_on_rx = on_rx;
    if (name) strlcpy(s_name, name, sizeof(s_name));
    s_enabled = true;

    if (s_inited) {          // 之前停用過，現在只要重新開始掃描
        start_scan();
        return;
    }
    s_inited = true;

    esp_err_t err = nimble_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init 失敗: %s", esp_err_to_name(err));
        return;
    }
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    // 不呼叫 ble_svc_gap_init()：那是本機 GATT server 的 Device Name 服務，
    // 只有 peripheral 角色才需要。這裡是純 central，而且 sdkconfig 已經把
    // BT_NIMBLE_ROLE_PERIPHERAL 關掉，那些符號根本沒編進來。
    nimble_port_freertos_init(host_task);
    ESP_LOGI(TAG, "NimBLE 啟動，目標裝置「%s」", s_name);
}

void nx4_ble_set_name(const char *name) {
    if (!name) return;
    if (strcmp(s_name, name) == 0) return;
    strlcpy(s_name, name, sizeof(s_name));
    ESP_LOGI(TAG, "改連「%s」", s_name);
    s_ready = false;
    if (s_conn != BLE_HS_CONN_HANDLE_NONE) {
        ble_gap_terminate(s_conn, BLE_ERR_REM_USER_CONN_TERM);   // 斷線後會自動重掃
    } else {
        ble_gap_disc_cancel();
        start_scan();
    }
}

void nx4_ble_set_enabled(bool on) {
    if (s_enabled == on) return;
    s_enabled = on;
    if (on) {
        ESP_LOGI(TAG, "啟用，開始掃描「%s」", s_name);
        if (s_inited) start_scan();
        return;
    }
    // 停用：取消掃描並主動斷線，把 dongle 讓給手機端
    ESP_LOGI(TAG, "停用，斷開並停止掃描");
    s_ready = false;
    ble_gap_disc_cancel();
    if (s_conn != BLE_HS_CONN_HANDLE_NONE) {
        ble_gap_terminate(s_conn, BLE_ERR_REM_USER_CONN_TERM);
    }
}

bool nx4_ble_ready(void) { return s_ready; }

bool nx4_ble_write(const uint8_t *data, size_t len) {
    if (!s_ready || s_conn == BLE_HS_CONN_HANDLE_NONE) return false;
    while (len > 0) {
        size_t n = len > BLE_MTU_PAYLOAD ? BLE_MTU_PAYLOAD : len;
        if (ble_gattc_write_flat(s_conn, s_write_handle, data, n, NULL, NULL) != 0) {
            return false;
        }
        data += n;
        len -= n;
    }
    return true;
}
