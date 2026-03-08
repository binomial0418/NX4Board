import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import '../providers/app_provider.dart';
import '../services/location_service.dart';
import 'camera_screen.dart';
import '../widgets/speed_limit_display.dart';
import '../widgets/status_display.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late AppProvider appProvider;
  bool _locationPermissionGranted = false;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _startLocationTracking();
  }

  Future<void> _requestPermissions() async {
    final granted = await LocationService.requestLocationPermission();
    setState(() {
      _locationPermissionGranted = granted;
    });

    if (!granted) {
      _showPermissionDialog();
    }
  }

  void _startLocationTracking() async {
    appProvider = context.read<AppProvider>();
    
    final positionStream = LocationService.getPositionStream();
    positionStream.listen(
      (Position position) {
        appProvider.updatePosition(position);
      },
      onError: (error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Location error: $error')),
        );
      },
    );
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('位置權限'),
        content: const Text('需要位置權限才能使用此應用程序'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('確認'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('省道速限警告系統'),
        centerTitle: true,
      ),
      body: Consumer<AppProvider>(
        builder: (context, provider, _) {
          if (provider.isLoading) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(provider.status),
                ],
              ),
            );
          }

          if (!_locationPermissionGranted) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.location_off, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text('位置權限未授予'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _requestPermissions,
                    child: const Text('授予權限'),
                  ),
                ],
              ),
            );
          }

          return SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  // Status Display
                  StatusDisplay(status: provider.status),
                  const SizedBox(height: 24),

                  // Speed Limit Display
                  if (provider.nearbySpeedSigns.isNotEmpty)
                    SpeedLimitDisplay(
                      speedLimit: provider.nearbySpeedSigns.first.speedLimit,
                      detected: provider.detectedSpeedLimit,
                      isNearby: true,
                    )
                  else
                    const SpeedLimitDisplay(
                      speedLimit: null,
                      detected: null,
                      isNearby: false,
                    ),
                  const SizedBox(height: 24),

                  // Nearby Speed Signs List
                  if (provider.nearbySpeedSigns.isNotEmpty)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '附近的速限標誌',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        ...provider.nearbySpeedSigns.take(5).map((sign) {
                          final distance = sign.calculateDistance(
                            provider.currentPosition?.latitude ?? 0,
                            provider.currentPosition?.longitude ?? 0,
                          );
                          
                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: Row(
                                children: [
                                  // Speed badge
                                  Container(
                                    width: 50,
                                    height: 50,
                                    decoration: BoxDecoration(
                                      color: Colors.blue,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Center(
                                      child: Text(
                                        '${sign.speedLimit}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  // Info
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${sign.roadNumber} - ${sign.location}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        Text(
                                          'Distance: ${distance.toStringAsFixed(0)}m',
                                          style: const TextStyle(
                                            color: Colors.grey,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Direction badge
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: sign.direction == '順向'
                                          ? Colors.green
                                          : Colors.orange,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      sign.direction,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ],
                    )
                  else
                    Center(
                      child: Column(
                        children: const [
                          Icon(
                            Icons.location_off,
                            size: 48,
                            color: Colors.grey,
                          ),
                          SizedBox(height: 12),
                          Text('附近沒有速限標誌'),
                        ],
                      ),
                    ),
                  const SizedBox(height: 24),

                  // Camera Test Button
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const CameraScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('測試相機'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
