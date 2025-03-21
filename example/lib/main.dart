import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_daemon/flutter_daemon.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

final _flutterDaemonPlugin = FlutterDaemon();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  print("BACKGROUND SYNC TEST");
  runApp(const MyApp());
}

Future<void> _checkNetworkLoop() async {
  final wsStop = _testWebSocketConnection();
  await Future.delayed(const Duration(seconds: 60));
  await wsStop();
  for (int i = 0; i < 60; i++) {
    try {
      await _checkNetwork();
    } catch (e) {
      print("Error checking network: $e");
    }
    await Future.delayed(const Duration(seconds: 1));
  }
}


Future<void> _checkNetwork() async {
  final urls = [
    "https://connectivitycheck.gstatic.com",
    "https://static.mrcyjanek.net",
    "https://getmonero.org",
    "https://github.com",
    "https://1.1.1.1/",
  ];
  final url = urls[Random().nextInt(urls.length)];
  try {
    final response = await http.get(Uri.parse(url));
    print("Network connection successful (${response.statusCode}) to $url");
  } catch (e) {
    print("Error checking network: $url: $e");
  }
}

@pragma('vm:entry-point')
Future<void> backgroundSync() async {
  try {
    print("Background sync triggered");
    print("- WidgetsFlutterBinding.ensureInitialized()");
    WidgetsFlutterBinding.ensureInitialized();
    print("- DartPluginRegistrant.ensureInitialized()");
    DartPluginRegistrant.ensureInitialized();
    print("- FlutterDaemon.markBackgroundSync()");
    final val = await _flutterDaemonPlugin.markBackgroundSync();
    if (val) {
      print("Background sync already in progress");
      return;
    }
    int tick = 0;
    int maxTicks = 600;
    print("path provider test");
    try {
      final path = await getApplicationDocumentsDirectory();
      print("path: ${path.path}");
    } catch (e) {
      print("Error: $e");
    }
    await _checkNetworkLoop();

    while (tick < maxTicks) {
      print("Tick: ${tick++}");
      sleep(Duration(seconds: 1));
      await _checkNetwork();
      if (tick >= maxTicks) {
        break;
      }
    }
    print("Background sync completed");
  } finally {
    _flutterDaemonPlugin.unmarkBackgroundSync();
  }
}

Function _testWebSocketConnection() {
  final wsUrl = Uri.parse('wss://echo.websocket.org');
  WebSocketChannel? channel;
  Timer? timer;
  
  try {
    // Initialize the connection
    channel = WebSocketChannel.connect(wsUrl);
    print("WebSocket connection initiated to echo.websocket.org");
    
    // Listen for messages from the server
    channel.stream.listen(
      (message) {
        print("WebSocket echo received: $message");
      },
      onError: (error) {
        print("WebSocket error: $error");
        timer?.cancel();
        channel?.sink.close();
      },
      onDone: () {
        print("WebSocket connection closed");
        timer?.cancel();
      },
    );
    
    int messageCount = 0;
    timer = Timer.periodic(const Duration(milliseconds: 750), (_) {
      if (channel?.sink != null) {
        final message = "Test message ${messageCount++}";
        channel?.sink.add(message);
        print("WebSocket message sent: $message");
      }
    });
    
    return () {
      print("Stopping WebSocket connection test");
      timer?.cancel();
      channel?.sink.close();
    };
  } catch (e) {
    print("Error establishing WebSocket connection: $e");
    timer?.cancel();
    channel?.sink.close();
    return () {};
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _platformVersion = 'Unknown';
  bool _isSyncActive = false;
  String _statusMessage = '';
  Timer? _statusCheckTimer;
  int _syncIntervalMinutes = -1;
  bool _isBatteryOptDisabled = false;

  @override
  void initState() {
    super.initState();
    initPlatformState();
    _checkBackgroundSyncStatus();
    _checkBatteryOptimizationStatus();

    _flutterDaemonPlugin.getBackgroundSyncInterval().then((value) {
      setState(() {
        _syncIntervalMinutes = value ?? -1;
      });
    });

    _statusCheckTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => _checkBackgroundSyncStatus());
  }

  @override
  void dispose() {
    _statusCheckTimer?.cancel();
    super.dispose();
  }

  Future<void> initPlatformState() async {
    String platformVersion;
    try {
      platformVersion = await _flutterDaemonPlugin.getPlatformVersion() ??
          'Unknown platform version';
    } on PlatformException {
      platformVersion = 'Failed to get platform version.';
    }

    if (!mounted) return;

    setState(() {
      _platformVersion = platformVersion;
    });
  }

  Future<void> _toggleBackgroundSync() async {
    try {
      if (_isSyncActive) {
        final result = await _flutterDaemonPlugin.stopBackgroundSync();
        setState(() {
          _statusMessage = result;
        });
      } else {
        final result = await _flutterDaemonPlugin
            .startBackgroundSync(_syncIntervalMinutes);
        setState(() {
          _statusMessage = result;
        });
      }

      await _checkBackgroundSyncStatus();
    } catch (e) {
      setState(() {
        _statusMessage = 'Error: $e';
      });
    }
  }

  Future<void> _checkBackgroundSyncStatus() async {
    try {
      final isActive = await _flutterDaemonPlugin.getBackgroundSyncStatus();
      if (mounted) {
        setState(() {
          _isSyncActive = isActive;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Status check error: $e';
        });
      }
    }
  }

  Future<void> _checkBatteryOptimizationStatus() async {
    try {
      final isDisabled = await _flutterDaemonPlugin.isBatteryOptimizationDisabled();
      if (mounted) {
        setState(() {
          _isBatteryOptDisabled = isDisabled;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Battery optimization check error: $e';
        });
      }
    }
  }

  Future<void> _requestDisableBatteryOptimization() async {
    try {
      await _flutterDaemonPlugin.requestDisableBatteryOptimization();
      for (int i = 0; i < 4 * 60; i++) {
        await _checkBatteryOptimizationStatus();
        await Future.delayed(const Duration(milliseconds: 250));
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Error requesting battery optimization: $e';
      });
    }
  }

  Future<void> _openBatteryOptimizationSettings() async {
    try {
      await _flutterDaemonPlugin.openBatteryOptimizationSettings();
    } catch (e) {
      setState(() {
        _statusMessage = 'Error opening battery settings: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Flutter Daemon Example'),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  'Running on: $_platformVersion every $_syncIntervalMinutes minutes',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 24),
              Text('Background Sync Status',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _isSyncActive ? Colors.green : Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isSyncActive ? 'Active' : 'Inactive',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
              ),
              if (_statusMessage.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(_statusMessage,
                      style: const TextStyle(color: Colors.blue)),
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('Sync Interval (minutes): '),
                  SizedBox(width: 8),
                  DropdownButton<int>(
                    value: _syncIntervalMinutes,
                    items:
                        [-1, 15, 30, 60, 120, 180, 360, 720, 1440].map((int value) {
                      return DropdownMenuItem<int>(
                        value: value,
                        child: Text(
                            '${(value ~/ 60).toString().padLeft(2, '0')}h${(value % 60).toString().padLeft(2, '0')}m'),
                      );
                    }).toList(),
                    onChanged: (newValue) {
                      if (newValue != null) {
                        setState(() {
                          _syncIntervalMinutes = newValue;
                        });
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _toggleBackgroundSync,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isSyncActive ? Colors.red : Colors.green,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                child: Text(_isSyncActive
                    ? 'Stop Background Sync'
                    : 'Start Background Sync'),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: _checkBackgroundSyncStatus,
                child: const Text('Refresh Status'),
              ),
              const SizedBox(height: 24),
              Text('Battery Optimization',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _isBatteryOptDisabled ? Colors.green : Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isBatteryOptDisabled ? 'Disabled' : 'Enabled',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _requestDisableBatteryOptimization,
                child: const Text('Request Disable Battery Optimization'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _openBatteryOptimizationSettings,
                child: const Text('Open Battery Settings'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _checkBatteryOptimizationStatus,
                child: const Text('Refresh Battery Status'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
