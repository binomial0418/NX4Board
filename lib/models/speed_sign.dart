class SpeedSign {
  final String roadNumber;      // 公路編號 (台1, 台21, etc.)
  final String county;          // 隸屬縣市
  final double lat;             // 緯度 (WGS84)
  final double lng;             // 經度 (WGS84)
  final int speedLimit;         // 速限 (km/h)
  final String location;        // 隸屬鄉鎮
  final String village;         // 隸屬村里
  final String placement;       // 設置位置 (左側, 右側, 中央)
  final String direction;       // 牌面方向 (順向, 逆向)
  final String position;        // 設置位置 (左側, 右側, 中央)

  SpeedSign({
    required this.roadNumber,
    required this.county,
    required this.lat,
    required this.lng,
    required this.speedLimit,
    required this.location,
    required this.village,
    required this.placement,
    required this.direction,
    required this.position,
  });

  /// Calculate distance from current position using Haversine formula
  /// Returns distance in meters
  double calculateDistance(double userLat, double userLng) {
    const earthRadiusM = 6371000; // Earth radius in meters
    
    final dLat = _toRadians(lat - userLat);
    final dLng = _toRadians(lng - userLng);
    
    final a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
        Math.cos(_toRadians(userLat)) * Math.cos(_toRadians(lat)) *
        Math.sin(dLng / 2) * Math.sin(dLng / 2);
    
    final c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return earthRadiusM * c;
  }

  double _toRadians(double degree) {
    return degree * (3.14159265359 / 180);
  }

  @override
  String toString() => 'SpeedSign(road: $roadNumber, speedLimit: $speedLimit, at: $location)';
}

// Simple Math class for trigonometric functions
//
// 2026-10-09：原本的 sqrt 從 x 本身開始只做 10 次牛頓法，x 很小時根本沒收斂
// （haversine 裡的 a 約 1e-8，結果大了約 10 倍），1 km 外的牌面算成 12 km，
// 省道牌面從來對不到、一律退回分級推定；atan 的級數在 |x| > 1 時發散。
// 演算法修正，仍不依賴 dart:math。
class Math {
  static const double pi = 3.14159265359;

  /// 把角度收到 [-π, π]，Taylor 級數在這個範圍內 10 項就夠準
  static double _wrap(double x) {
    const twoPi = 2 * pi;
    if (x > pi || x < -pi) x -= twoPi * ((x + pi) / twoPi).floorToDouble();
    return x;
  }

  static double sin(double x) {
    x = _wrap(x);
    double result = 0;
    double term = x;
    for (int i = 1; i <= 12; i++) {
      result += term;
      term *= -x * x / ((2 * i) * (2 * i + 1));
    }
    return result;
  }

  static double cos(double x) {
    x = _wrap(x);
    double result = 1;
    double term = 1;
    for (int i = 1; i <= 12; i++) {
      term *= -x * x / ((2 * i - 1) * (2 * i));
      result += term;
    }
    return result;
  }

  /// 牛頓法開根號，疊代到收斂。從 max(x, 1) 起算：x < 1 時從 x 起算會收斂得極慢
  static double sqrt(double x) {
    if (x < 0) return double.nan;
    if (x == 0) return 0;
    double guess = x >= 1 ? x : 1.0;
    for (int i = 0; i < 200; i++) {
      final next = (guess + x / guess) / 2;
      if ((next - guess).abs() <= next * 1e-15) return next;
      guess = next;
    }
    return guess;
  }

  static double atan2(double y, double x) {
    if (x > 0) return atan(y / x);
    if (x < 0 && y >= 0) return atan(y / x) + pi;
    if (x < 0 && y < 0) return atan(y / x) - pi;
    if (x == 0 && y > 0) return pi / 2;
    if (x == 0 && y < 0) return -pi / 2;
    return 0;
  }

  /// 級數只在 |x| 小時收斂得快：|x| > 1 用 atan(x) = ±π/2 − atan(1/x)，
  /// 再用 atan(x) = 2·atan(x / (1 + √(1 + x²))) 縮到 |x| < 0.4
  static double atan(double x) {
    if (x > 1) return pi / 2 - atan(1 / x);
    if (x < -1) return -pi / 2 - atan(1 / x);
    if (x > 0.4 || x < -0.4) return 2 * atan(x / (1 + sqrt(1 + x * x)));
    double result = 0;
    double term = x;
    for (int i = 0; i < 20; i++) {
      result += term / (2 * i + 1);
      term *= -x * x;
    }
    return result;
  }
}
