import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_daemon/flutter_daemon.dart';
import 'package:path_provider/path_provider.dart';
final _flutterDaemonPlugin = FlutterDaemon();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  print("BACKGROUND SYNC TEST");
  runApp(const MyApp());
}

@pragma('vm:entry-point')
Future<void> backgroundSync() async {
  print("Background sync triggered");
  print("- WidgetsFlutterBinding.ensureInitialized()");
  WidgetsFlutterBinding.ensureInitialized();
  print("- DartPluginRegistrant.ensureInitialized()");
  DartPluginRegistrant.ensureInitialized();
  print("- FlutterDaemon.markBackgroundSync()");
  final val = await FlutterDaemon.markBackgroundSync();
  if (val) {
    print("Background sync already in progress");
    return;
  }
  int tick = 0;
  int maxTicks = 36000;
  print("path provider test");
  try {
    final path = await getApplicationDocumentsDirectory();
    print("path: ${path.path}");
  } catch (e) {
    print("Error: $e");
  }
  while (true) {
    print("Tick: ${tick++}");
    sleep(Duration(seconds: 1));
    if (tick >= maxTicks) {
      break;
    }
  }
  print("Background sync completed");
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
  int _syncIntervalMinutes = 15;

  @override
  void initState() {
    super.initState();
    initPlatformState();
    _checkBackgroundSyncStatus();
    
    _statusCheckTimer = Timer.periodic(
      const Duration(seconds: 5), 
      (_) => _checkBackgroundSyncStatus()
    );
  }

  @override
  void dispose() {
    _statusCheckTimer?.cancel();
    super.dispose();
  }

  Future<void> initPlatformState() async {
    String platformVersion;
    try {
      platformVersion =
          await _flutterDaemonPlugin.getPlatformVersion() ?? 'Unknown platform version';
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
        final result = await _flutterDaemonPlugin.startBackgroundSync(_syncIntervalMinutes);
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
              Text('Running on: $_platformVersion', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 24),
              
              Text(
                'Background Sync Status', 
                style: Theme.of(context).textTheme.titleLarge
              ),
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
                  child: Text(_statusMessage, style: const TextStyle(color: Colors.blue)),
                ),
              
              const SizedBox(height: 16),
              
              Row(
                children: [
                  Text('Sync Interval (minutes): '),
                  SizedBox(width: 8),
                  DropdownButton<int>(
                    value: _syncIntervalMinutes,
                    items: [15, 30, 60, 120, 180, 360, 720, 1440].map((int value) {
                      return DropdownMenuItem<int>(
                        value: value,
                        child: Text(
                          '${(value ~/ 60).toString().padLeft(2, '0')}h${(value % 60).toString().padLeft(2, '0')}m'
                        ),
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
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                child: Text(_isSyncActive ? 'Stop Background Sync' : 'Start Background Sync'),
              ),
              
              const SizedBox(height: 16),
              
              OutlinedButton(
                onPressed: _checkBackgroundSyncStatus,
                child: const Text('Refresh Status'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
