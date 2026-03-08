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
class Math {
  static const double pi = 3.14159265359;
  
  static double sin(double x) {
    // Using Taylor series approximation for sin
    double result = 0;
    double term = x;
    for (int i = 1; i <= 10; i++) {
      result += term;
      term *= -x * x / ((2 * i) * (2 * i + 1));
    }
    return result;
  }

  static double cos(double x) {
    // Using Taylor series approximation for cos
    double result = 1;
    double term = 1;
    for (int i = 1; i <= 10; i++) {
      term *= -x * x / ((2 * i - 1) * (2 * i));
      result += term;
    }
    return result;
  }

  static double sqrt(double x) {
    if (x < 0) return double.nan;
    if (x == 0) return 0;
    double guess = x;
    for (int i = 0; i < 10; i++) {
      guess = (guess + x / guess) / 2;
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

  static double atan(double x) {
    double result = 0;
    double term = x;
    for (int i = 0; i < 20; i++) {
      result += term;
      term *= -x * x * (2 * i + 1) / (2 * i + 3);
    }
    return result;
  }
}
