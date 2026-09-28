import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 滑動視窗限流：任意 [window] 內最多 [max] 次，超過就等到最舊的一次滑出視窗。
///
/// TDX 免費會員每分鐘 5 次。伺服器端的視窗怎麼切不得而知（滑動或整分），
/// 滑動視窗的上限同時也保證任何整分鐘內不超過。
class RateLimiter {
  final int max;
  final Duration window;
  final DateTime Function() clock;
  final Queue<DateTime> _stamps = Queue();

  RateLimiter(this.max, this.window, {DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  /// 現在發出下一次請求之前需要等多久
  Duration waitNeeded() {
    final now = clock();
    while (_stamps.isNotEmpty && now.difference(_stamps.first) >= window) {
      _stamps.removeFirst();
    }
    if (_stamps.length < max) return Duration.zero;
    return window - now.difference(_stamps.first);
  }

  /// 登記一次請求
  void record() => _stamps.add(clock());

  Future<void> acquire() async {
    while (true) {
      final w = waitNeeded();
      if (w <= Duration.zero) {
        record();
        return;
      }
      await Future<void>.delayed(w + const Duration(milliseconds: 50));
    }
  }
}

/// [TrafficService] 用到的 TDX 查詢，抽出來讓測試可以換成假的實作
abstract class TdxApi {
  Future<Map<String, double>> sectionSpeeds(String api, List<String> ids);
  Future<Map<String, Map<String, double>>> vdLinkSpeeds(List<String> vdIds);
}

/// TDX 即時路況 API。只查指定的路段或 VD，一次回應幾百 bytes，
/// 不像 RoadRader 下載整包（省道全線 2.8 MB）。
///
/// 車上經由 esp32_relay_gateway 上網，它的限制決定了這裡的寫法：
///   - 只轉發 443 且 SNI 在白名單內的連線（tdx.transportdata.tw 已列入），一律用 https
///   - 全部只有 3 個代理 slot，與系統連線偵測共用，連線要等任一端斷線才釋放。
///     所以同一主機最多 1 條連線、請求逐一發送，閒置幾秒就關閉歸還 slot
///   - 每次 loop 只搬 512 bytes，查詢一律用 $select / $filter 壓小回應
///
/// TDX 免費會員每分鐘只能 5 次，所有請求（含 token）都經過 [limiter]，
/// 任意 60 秒最多 [maxPerMinute] 次，留一次餘裕。
class TdxClient implements TdxApi {
  static const _host = 'tdx.transportdata.tw';
  static const _authPath = '/auth/realms/TDXConnect/protocol/openid-connect/token';
  static const _apiBase = '/api/basic/v2/Road/Traffic';

  /// OData $filter 以 or 串接，每次請求最多這麼多個 ID。
  /// 50 個 VDID 的網址約 2.2 KB，遠低於一般 8 KB 的上限；一條路線前方 15 公里
  /// （台61 約 21 段）一次就查得完，請求數才壓得住。
  static const chunkSize = 50;

  static const maxPerMinute = 4;
  final RateLimiter limiter = RateLimiter(maxPerMinute, const Duration(seconds: 60));

  final String clientId;
  final String clientSecret;
  /// 單一請求（含 TLS 交握）的上限。轉發器卡住時不能讓查詢永遠等下去
  static const _requestTimeout = Duration(seconds: 20);

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 3)
    ..maxConnectionsPerHost = 1
    ..autoUncompress = true;

  String? _token;
  DateTime _tokenExpiry = DateTime.fromMillisecondsSinceEpoch(0);

  TdxClient(this.clientId, this.clientSecret);

  Future<String> _getToken() async {
    if (_token != null && DateTime.now().isBefore(_tokenExpiry)) return _token!;
    await limiter.acquire();
    final req = await _http.postUrl(Uri.https(_host, _authPath));
    req.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
    req.write(Uri(queryParameters: {
      'grant_type': 'client_credentials',
      'client_id': clientId,
      'client_secret': clientSecret,
    }).query);
    final json = await _readJson(await req.close()).timeout(_requestTimeout)
        as Map<String, dynamic>;
    _token = json['access_token'] as String;
    final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 3600;
    _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 120));
    return _token!;
  }

  Future<dynamic> _get(String path, Map<String, String> params) async {
    final token = await _getToken();
    await limiter.acquire();
    final uri = Uri.https(_host, '$_apiBase/$path', {r'$format': 'JSON', ...params});
    final req = await _http.getUrl(uri);
    req.headers.set('authorization', 'Bearer $token');
    req.headers.set('accept-encoding', 'gzip');
    final resp = await req.close().timeout(_requestTimeout);
    if (resp.statusCode == 401) _token = null; // 下次重新取得
    return _readJson(resp).timeout(_requestTimeout);
  }

  static Future<dynamic> _readJson(HttpClientResponse resp) async {
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw HttpException('TDX ${resp.statusCode}: '
          '${body.length > 200 ? body.substring(0, 200) : body}');
    }
    return jsonDecode(body);
  }

  static String _orFilter(String field, List<String> ids) =>
      ids.map((id) => "$field eq '$id'").join(' or ');

  /// 路段旅行速率（km/h）。[api] 為 'Freeway' 或 'Highway'。
  /// 回應中沒有的路段、或速率無效（TDX 以 -99 表示）的路段不會出現在結果裡。
  @override
  Future<Map<String, double>> sectionSpeeds(String api, List<String> ids) async {
    final out = <String, double>{};
    for (int i = 0; i < ids.length; i += chunkSize) {
      final chunk = ids.sublist(i, (i + chunkSize).clamp(0, ids.length));
      final json = await _get('Live/$api', {
        r'$select': 'SectionID,TravelSpeed',
        r'$filter': _orFilter('SectionID', chunk),
      }) as Map<String, dynamic>;
      for (final item in (json['LiveTraffics'] as List? ?? const [])) {
        final m = item as Map<String, dynamic>;
        final speed = (m['TravelSpeed'] as num?)?.toDouble() ?? -99;
        if (speed > 0) out[m['SectionID'] as String] = speed;
      }
    }
    return out;
  }

  /// 省道 VD 各偵測鏈路的車速：VDID → LinkID → 各車道有車時的平均車速。
  ///
  /// 一支 VD 可能同時偵測雙向（各為一條 LinkFlow），所以一定要依 LinkID 取，
  /// 不能像 RoadRader 把所有 LinkFlow 平均——對向塞車會算到自己頭上。
  @override
  Future<Map<String, Map<String, double>>> vdLinkSpeeds(List<String> vdIds) async {
    final out = <String, Map<String, double>>{};
    for (int i = 0; i < vdIds.length; i += chunkSize) {
      final chunk = vdIds.sublist(i, (i + chunkSize).clamp(0, vdIds.length));
      final json = await _get('Live/VD/Highway', {
        r'$select': 'VDID,Status,LinkFlows',
        r'$filter': _orFilter('VDID', chunk),
      }) as Map<String, dynamic>;
      for (final item in (json['VDLives'] as List? ?? const [])) {
        final vd = item as Map<String, dynamic>;
        // Status 非 0 的 VD 沒有任何車速（實測 1926 支中 547 支），直接略過
        if ((vd['Status'] as num?)?.toInt() != 0) continue;
        final links = <String, double>{};
        for (final flow in (vd['LinkFlows'] as List? ?? const [])) {
          final f = flow as Map<String, dynamic>;
          double sum = 0;
          int n = 0;
          for (final lane in (f['Lanes'] as List? ?? const [])) {
            final l = lane as Map<String, dynamic>;
            // diag0 為正常，其餘是偵測異常（實測約 1%）
            final err = l['ErrorType'] as String?;
            if (err != null && err != 'diag0') continue;
            final speed = (l['Speed'] as num?)?.toDouble() ?? 0;
            // 車速 0 是這一分鐘沒車經過，不是塞住
            if (speed > 0) {
              sum += speed;
              n++;
            }
          }
          if (n > 0) links[f['LinkID'] as String] = sum / n;
        }
        out[vd['VDID'] as String] = links;
      }
    }
    return out;
  }

  void close() {
    try {
      _http.close(force: true);
    } catch (e) {
      debugPrint('[TDX] close: $e');
    }
  }
}
