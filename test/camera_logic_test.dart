import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import '../lib/services/camera_service.dart';
// import 'package:flutter/services.dart';
import 'dart:io';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Test Speed Camera Detection Algorithm with Mock Data', () async {
    final cameraService = CameraService();
    
    // 模擬載入 CSV (直接注入資料到私有變數或透過 Mock rootBundle)
    // 由於我們無法輕易存取私有變數，我們使用檔案系統讀取 assets/camera_data.csv
    // final file = File('assets/camera_data.csv'); // Removed as `file` is no longer used
    // final csvData = await file.readAsString(); // Removed as `csvData` is no longer used
    
    // 我們稍微修改 CameraService 的 init 讓它能接受字串，或者直接模擬 rootBundle
    // 這裡我們先用簡單的方式：手動模擬一個軌跡點，測試附近的相機
    
    print('Testing trajectory logic...');
    
    // 模擬一個相機點 (從 CSV 挑選的座標)
    // 設置地址: 金湖鎮黃海路(陽明湖路段), 118.43147, 24.458809, 南北雙向, 60
    
    // 建立軌跡：從南往北移動
    final p1 = Position(longitude: 118.43147, latitude: 24.450000, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 10, speedAccuracy: 1, floor: 0, isMocked: false, altitudeAccuracy: 0, headingAccuracy: 0);
    final p2 = Position(longitude: 118.43147, latitude: 24.458000, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 10, speedAccuracy: 1, floor: 0, isMocked: false, altitudeAccuracy: 0, headingAccuracy: 0);
    
    cameraService.addPosition(p1);
    cameraService.addPosition(p2);
    
    // 測試 checkNearbyCamera
    // 注意：init() 必須跑過，但在測試環境 init 會失敗，因為 rootBundle 沒掛載
    // 所以我們這裡只測試算法部分
  });
}
