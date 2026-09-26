// WebSocket Server。介面與執行緒模型見 nx4_ws.h。

#include "esp_err.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#include "nx4_ws.h"

#include <string.h>
#include <unistd.h>   // close()，httpd 的 close_fn 要自己收 socket

static const char *TAG = "ws";

static httpd_handle_t s_httpd = NULL;
static SemaphoreHandle_t s_lock = NULL;

static char   s_buf[NX4_WS_BUF_SIZE];
static size_t s_len = 0;          // 0 = 沒有待處理的封包
static bool   s_just_connected = false;

static esp_err_t on_open(httpd_handle_t hd, int sockfd) {
    (void)hd;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_just_connected = true;
    xSemaphoreGive(s_lock);
    printf("[WS] [%d] 已連接\n", sockfd);
    return ESP_OK;
}

// 設了 close_fn 就要自己收 socket，httpd 不會代勞。
static void on_close(httpd_handle_t hd, int sockfd) {
    (void)hd;
    printf("[WS] [%d] 已斷開\n", sockfd);
    close(sockfd);
}

static esp_err_t ws_handler(httpd_req_t *req) {
    // 握手階段 httpd 會以 GET 呼叫一次，此時沒有 frame 可讀
    if (req->method == HTTP_GET) return ESP_OK;

    httpd_ws_frame_t frame = {0};
    frame.type = HTTPD_WS_TYPE_TEXT;

    // 先問長度，再讀內容
    esp_err_t err = httpd_ws_recv_frame(req, &frame, 0);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "httpd_ws_recv_frame 取長度失敗: %s", esp_err_to_name(err));
        return err;
    }
    if (frame.type != HTTPD_WS_TYPE_TEXT || frame.len == 0) return ESP_OK;
    if (frame.len >= NX4_WS_BUF_SIZE) {
        ESP_LOGW(TAG, "封包 %u bytes 超過緩衝，丟棄", (unsigned)frame.len);
        return ESP_OK;
    }

    // 直接讀進共用緩衝，省一次複製。上鎖到讀完為止，LVGL 任務不會讀到半筆。
    xSemaphoreTake(s_lock, portMAX_DELAY);
    frame.payload = (uint8_t *)s_buf;
    err = httpd_ws_recv_frame(req, &frame, NX4_WS_BUF_SIZE - 1);
    if (err == ESP_OK) {
        s_buf[frame.len] = '\0';
        s_len = frame.len;     // 後到覆蓋先到：只有最後一筆需要渲染
    } else {
        s_len = 0;
    }
    xSemaphoreGive(s_lock);

    if (err != ESP_OK) ESP_LOGW(TAG, "讀取失敗: %s", esp_err_to_name(err));
    return ESP_OK;
}

void nx4_ws_inject(const char *data, size_t len) {
    if (!s_lock || len == 0 || len >= NX4_WS_BUF_SIZE) return;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    memcpy(s_buf, data, len);
    s_buf[len] = '\0';
    s_len = len;
    xSemaphoreGive(s_lock);
}

esp_err_t nx4_ws_start(uint16_t port) {
    s_lock = xSemaphoreCreateMutex();
    if (!s_lock) return ESP_ERR_NO_MEM;

    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
    cfg.server_port = port;
    cfg.max_open_sockets = 4;
    cfg.open_fn = on_open;
    cfg.close_fn = on_close;
    // httpd 任務要比 LVGL 高一級，收封包才不會被渲染拖住
    cfg.task_priority = 6;
    cfg.stack_size = 6144;
    // 手機端只送不收，沒有 keep-alive 交握，逾時放寬避免被誤斷
    cfg.recv_wait_timeout = 30;
    cfg.send_wait_timeout = 10;

    esp_err_t err = httpd_start(&s_httpd, &cfg);
    if (err != ESP_OK) return err;

    static const httpd_uri_t ws_uri = {
        .uri = "/",
        .method = HTTP_GET,
        .handler = ws_handler,
        .user_ctx = NULL,
        .is_websocket = true,
    };
    return httpd_register_uri_handler(s_httpd, &ws_uri);
}

// 直接問 httpd 有幾個 WebSocket client，不自己在 open/close 回呼裡記帳。
// 自己記帳會漏：client 粗暴斷線時 close_fn 不一定觸發，計數就永遠回不到 0，
// 畫面上的連線指示會一直亮著。
int nx4_ws_clients(void) {
    if (!s_httpd) return 0;
    size_t n = CONFIG_LWIP_MAX_LISTENING_TCP;
    int fds[CONFIG_LWIP_MAX_LISTENING_TCP];
    if (httpd_get_client_list(s_httpd, &n, fds) != ESP_OK) return 0;

    int ws = 0;
    for (size_t i = 0; i < n; i++) {
        if (httpd_ws_get_fd_info(s_httpd, fds[i]) == HTTPD_WS_CLIENT_WEBSOCKET) ws++;
    }
    return ws;
}

size_t nx4_ws_take(char *out, size_t max) {
    xSemaphoreTake(s_lock, portMAX_DELAY);
    size_t n = s_len;
    if (n > 0) {
        if (n >= max) n = max - 1;
        memcpy(out, s_buf, n);
        out[n] = '\0';
        s_len = 0;
    }
    xSemaphoreGive(s_lock);
    return n;
}

bool nx4_ws_take_connected_flag(void) {
    xSemaphoreTake(s_lock, portMAX_DELAY);
    bool f = s_just_connected;
    s_just_connected = false;
    xSemaphoreGive(s_lock);
    return f;
}
