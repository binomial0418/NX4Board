import 'package:flutter/services.dart';
import 'package:csv/csv.dart';
import '../models/speed_sign.dart';

class CsvParser {
  static Future<List<SpeedSign>> loadSpeedSigns() async {
    try {
      final csvData = await rootBundle.loadString('refdata/省道速限圖資.csv');
      List<List<dynamic>> rows = const CsvToListConverter().convert(csvData);
      
      // Skip header row
      List<SpeedSign> speedSigns = [];
      
      for (int i = 1; i < rows.length; i++) {
        try {
          final row = rows[i];
          
          // Parse CSV columns
          String roadNumber = row[0]?.toString() ?? '';
          String county = row[2]?.toString() ?? '';
          double lat = double.tryParse(row[9]?.toString() ?? '') ?? 0.0;
          double lng = double.tryParse(row[8]?.toString() ?? '') ?? 0.0;
          
          // Extract speed limit from牌面內容 column (column 18)
          String signContent = row[18]?.toString() ?? '';
          int speedLimit = _extractSpeedLimit(signContent);
          
          if (speedLimit <= 0 || lat == 0 || lng == 0) continue;
          
          String location = row[11]?.toString() ?? '';
          String village = row[12]?.toString() ?? '';
          String placement = row[14]?.toString() ?? ''; // 設置位置
          String direction = row[22]?.toString() ?? ''; // 牌面方向
          String position = row[14]?.toString() ?? ''; // 設置位置
          
          speedSigns.add(SpeedSign(
            roadNumber: roadNumber,
            county: county,
            lat: lat,
            lng: lng,
            speedLimit: speedLimit,
            location: location,
            village: village,
            placement: placement,
            direction: direction,
            position: position,
          ));
        } catch (e) {
          // Skip malformed rows
          continue;
        }
      }
      
      return speedSigns;
    } catch (e) {
      print('Error loading CSV: $e');
      return [];
    }
  }
  
  /// Extract speed limit from sign content (e.g., "50" -> 50)
  static int _extractSpeedLimit(String content) {
    final regex = RegExp(r'(\d{2,3})');
    final match = regex.firstMatch(content);
    if (match != null) {
      int? speed = int.tryParse(match.group(1) ?? '');
      // Only accept valid Taiwan speed limits
      if (speed != null && speed >= 20 && speed <= 120) {
        return speed;
      }
    }
    return 0;
  }
  
  /// Find nearby speed signs within radius (meters)
  static List<SpeedSign> findNearby(
    List<SpeedSign> allSigns,
    double userLat,
    double userLng,
    double radiusMeters,
  ) {
    List<SpeedSign> nearby = [];
    
    for (var sign in allSigns) {
      double distance = sign.calculateDistance(userLat, userLng);
      if (distance <= radiusMeters) {
        nearby.add(sign);
      }
    }
    
    // Sort by distance
    nearby.sort((a, b) => 
      a.calculateDistance(userLat, userLng)
        .compareTo(b.calculateDistance(userLat, userLng))
    );
    
    return nearby;
  }
}
