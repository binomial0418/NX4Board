import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';

class LocationService {
  static Future<bool> requestLocationPermission() async {
    final permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      final result = await Geolocator.requestPermission();
      return result == LocationPermission.whileInUse ||
          result == LocationPermission.always;
    } else if (permission == LocationPermission.deniedForever) {
      await Geolocator.openLocationSettings();
      return false;
    }
    return true;
  }

  /// Start listening to position changes
  /// Returns a stream of Position updates
  static Stream<Position> getPositionStream({int distanceFilter = 10}) {
    LocationSettings locationSettings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: distanceFilter,
        intervalDuration: const Duration(seconds: 2), // 至少每 2 秒更新一次
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationText: "NX4Board 正在追蹤行車位置",
          notificationTitle: "行車定位服務",
          enableWakeLock: true,
        ),
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS || 
               defaultTargetPlatform == TargetPlatform.macOS) {
      locationSettings = AppleSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: distanceFilter,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
      );
    } else {
      locationSettings = LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: distanceFilter,
      );
    }

    return Geolocator.getPositionStream(locationSettings: locationSettings);
  }

  /// Get current position once
  static Future<Position?> getCurrentPosition() async {
    try {
      return await Geolocator.getCurrentPosition();
    } catch (e) {
      debugPrint('Error getting position: $e');
      return null;
    }
  }

  /// Check if location services are enabled
  static Future<bool> isLocationServiceEnabled() async {
    return await Geolocator.isLocationServiceEnabled();
  }

  /// Calculate bearing between two points
  /// Returns bearing in degrees (0-360)
  static double calculateBearing(
    double startLat,
    double startLng,
    double endLat,
    double endLng,
  ) {
    final dLng = endLng - startLng;
    final y = Math.sin(dLng) * Math.cos(endLat);
    final x = Math.cos(startLat) * Math.sin(endLat) -
        Math.sin(startLat) * Math.cos(endLat) * Math.cos(dLng);

    double bearing = Math.atan2(y, x);
    bearing = bearing * 180 / 3.14159265359; // Convert to degrees
    bearing = (bearing + 360) % 360; // Normalize to 0-360
    return bearing;
  }
}

// Simple Math class for trigonometric functions
class Math {
  static const double pi = 3.14159265359;

  static double sin(double x) {
    double result = 0;
    double term = x;
    for (int i = 1; i <= 10; i++) {
      result += term;
      term *= -x * x / ((2 * i) * (2 * i + 1));
    }
    return result;
  }

  static double cos(double x) {
    double result = 1;
    double term = 1;
    for (int i = 1; i <= 10; i++) {
      term *= -x * x / ((2 * i - 1) * (2 * i));
      result += term;
    }
    return result;
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
