import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import '../lib/services/camera_service.dart';
import 'package:csv/csv.dart';
import 'dart:io';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Reproduction Test: Taichung Camera', () async {
    // 1. Load data
    final file = File('assets/camera_data.csv');
    final csvData = await file.readAsString();
    final List<List<dynamic>> rows = const CsvToListConverter().convert(csvData);
    
    List<SpeedCamera> cameras = [];
    for (int i = 2; i < rows.length; i++) {
        if (rows[i].length < 9) continue;
        cameras.add(SpeedCamera.fromCsv(rows[i]));
    }
    print('[TEST] Total cameras loaded: ' + cameras.length.toString());

    // 2. User coordinates sequence (Taichung)
    final List<Position> points = [
      Position(latitude: 24.2458, longitude: 120.5525, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 10, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
      Position(latitude: 24.2439, longitude: 120.5517, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 10, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
      Position(latitude: 24.2419, longitude: 120.5506, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 10, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
      Position(latitude: 24.2396, longitude: 120.5496, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 10, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
      Position(latitude: 24.2389, longitude: 120.5494, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 10, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
      Position(latitude: 24.2383, longitude: 120.5492, timestamp: DateTime.now(), accuracy: 1, altitude: 0, heading: 0, speed: 10, speedAccuracy: 1, floor: 0, isMocked: true, altitudeAccuracy: 0, headingAccuracy: 0),
    ];

    final List<Position> trajectory = [];

    // Simulate stepping through points
    for (int i = 0; i < points.length; i++) {
      final pos = points[i];
      trajectory.add(pos);
      if (trajectory.length > 5) trajectory.removeAt(0);

      if (trajectory.isEmpty) continue;

      final last = trajectory.last;
      final first = trajectory.first;
      
      final double moveDist = CameraAlgorithm.haversine(
        first.latitude, first.longitude, last.latitude, last.longitude
      );

      double? userHeading;
      String? userDir;

      if (moveDist >= 0.005) {
        userHeading = CameraAlgorithm.calculateBearing(
          first.latitude, first.longitude, last.latitude, last.longitude
        );
        userDir = CameraAlgorithm.bearingToDirection(userHeading);
      }

      print('\n--- Step ' + i.toString() + ' ---');
      print('Pos: ' + pos.latitude.toString() + ', ' + pos.longitude.toString());
      print('MoveDist: ' + moveDist.toString() + ' km');
      print('Heading: ' + (userHeading?.toString() ?? 'null') + ' (' + (userDir ?? 'null') + ')');

      // Logic from CameraService.checkNearbyCamera
      SpeedCamera? nearestCam;
      double minOverallDist = 1.0; 
      double? finalAngleDiff;

      for (var cam in cameras) {
        double minTrajectoryDist = double.infinity;
        for (var p in trajectory) {
          double d = CameraAlgorithm.haversine(p.latitude, p.longitude, cam.latitude, cam.longitude);
          if (d < minTrajectoryDist) minTrajectoryDist = d;
        }

        if (minTrajectoryDist > minOverallDist) continue;

        bool passCheck = true;
        double? currentAngleDiff;

        if (userHeading != null && userDir != null) {
          final bearingToCam = CameraAlgorithm.calculateBearing(
            last.latitude, last.longitude, cam.latitude, cam.longitude
          );
          
          currentAngleDiff = (bearingToCam - userHeading).abs();
          if (currentAngleDiff > 180) currentAngleDiff = 360 - currentAngleDiff;

          if (currentAngleDiff > 80) passCheck = false;

          if (passCheck) {
            if (!CameraAlgorithm.matchDirection(userDir, cam.direct, cam.address, userHeading)) {
              passCheck = false;
            }
          }
        }

        if (!passCheck) continue;

        if (minTrajectoryDist < minOverallDist) {
          minOverallDist = minTrajectoryDist;
          nearestCam = cam;
          finalAngleDiff = currentAngleDiff;
        }
      }

      if (nearestCam != null) {
        print('FOUND CAMERA!');
        print('Address: ' + nearestCam.address);
        print('Direct: ' + nearestCam.direct);
        print('Dist: ' + (minOverallDist * 1000).round().toString() + 'm');
        print('AngleDiff: ' + finalAngleDiff.toString());
      } else {
        print('NO CAMERA in range/match');
      }
    }
  });
}
