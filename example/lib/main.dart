import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_daemon/flutter_daemon.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

final _flutterDaemonPlugin = FlutterDaemon();

String get _backgroundLogPath =>
    '${Directory.systemTemp.path}/flutter_daemon_example/background.log';

void _log(String message) {
  final line = '${DateTime.now().toIso8601String()} pid=$pid $message';
  debugPrint('flutter_daemon example: $message');
  try {
    stdout.writeln('flutter_daemon example: $line');
    stdout.flush();
  } catch (_) {}
  try {
    final file = File(_backgroundLogPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    _trimLog(file);
  } catch (e) {
    debugPrint(
      'flutter_daemon example: failed to write $_backgroundLogPath: $e',
    );
  }
}

void _trimLog(File file) {
  const maxBytes = 64 * 1024;
  final length = file.lengthSync();
  if (length <= maxBytes) return;
  final tail = file.readAsBytesSync().sublist(length - (maxBytes ~/ 2));
  final newline = tail.indexOf(0x0a);
  file.writeAsBytesSync(
    newline == -1 ? tail : tail.sublist(newline + 1),
    flush: true,
  );
}

String _readBackgroundLog() {
  try {
    final file = File(_backgroundLogPath);
    if (!file.existsSync()) return '';
    return file.readAsStringSync();
  } catch (e) {
    return 'Failed to read $_backgroundLogPath: $e';
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _log('example started');
  runApp(const MyApp());
}

Future<void> _checkNetworkLoop() async {
  final wsStop = _testWebSocketConnection();
  await Future<void>.delayed(const Duration(seconds: 15));
  wsStop();
  for (int i = 0; i < 60; i++) {
    try {
      await _checkNetwork();
    } catch (e) {
      _log('network check failed: $e');
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
    _log('${response.statusCode} from $url');
  } catch (e) {
    _log('network check failed for $url: $e');
  }
}

@pragma('vm:entry-point')
Future<void> uninstallBackgroundSync() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  _log('uninstall background sync triggered');
  try {
    await _flutterDaemonPlugin.stopBackgroundSync();
  } catch (e) {
    _log('uninstall background sync failed: $e');
  } finally {
    await _flutterDaemonPlugin.signalBackgroundSyncComplete();
  }
}

@pragma('vm:entry-point')
Future<void> backgroundSync() async {
  var acquired = false;
  try {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    _log('background sync triggered, writing $_backgroundLogPath');
    final alreadyRunning = await _flutterDaemonPlugin.markBackgroundSync();
    if (alreadyRunning) {
      _log('background sync already in progress');
      await _flutterDaemonPlugin.signalBackgroundSyncComplete();
      return;
    }
    acquired = true;
    try {
      final path = await getApplicationDocumentsDirectory();
      _log('documents path ${path.path}');
    } catch (e) {
      _log('path provider failed: $e');
    }
    await _checkNetworkLoop();
    for (var tick = 0; tick < 60; tick++) {
      _log('tick $tick');
      await Future<void>.delayed(const Duration(seconds: 1));
      await _checkNetwork();
    }
    _log('background sync completed');
  } catch (e, stack) {
    _log('background sync failed: $e\n$stack');
    rethrow;
  } finally {
    if (acquired) {
      _log('releasing background sync lock');
      await _flutterDaemonPlugin.unmarkBackgroundSync();
    }
  }
}

void Function() _testWebSocketConnection() {
  final wsUrl = Uri.parse('wss://echo.websocket.org');
  WebSocketChannel? channel;
  Timer? timer;

  try {
    channel = WebSocketChannel.connect(wsUrl);
    _log('websocket connecting');

    channel.stream.listen(
      (message) {
        _log('websocket echo: $message');
      },
      onError: (error) {
        _log('websocket error: $error');
        timer?.cancel();
        channel?.sink.close();
      },
      onDone: () {
        _log('websocket closed');
        timer?.cancel();
      },
    );

    int messageCount = 0;
    timer = Timer.periodic(const Duration(milliseconds: 750), (_) {
      if (channel?.sink != null) {
        final message = "Test message ${messageCount++}";
        channel?.sink.add(message);
        _log('websocket sent: $message');
      }
    });

    return () {
      _log('websocket stopping');
      timer?.cancel();
      channel?.sink.close();
    };
  } catch (e) {
    _log('websocket failed: $e');
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
  static const _presetIntervals = [1, 15, 30, 60, 120, 180, 360, 720, 1440];

  bool _isSyncActive = false;
  String _statusMessage = '';
  Timer? _statusCheckTimer;
  Timer? _batteryPoll;
  int _syncIntervalMinutes = 15;
  bool _isBatteryOptDisabled = false;
  bool _useUnmeteredNetwork = false;
  bool _requireBatteryNotLow = false;
  bool _requiresCharging = false;
  bool _requiresDeviceIdle = false;
  String _logText = '';
  FlutterDaemonCapabilities _capabilities = const FlutterDaemonCapabilities(
    backgroundSync: false,
    constraints: false,
    batteryOptimization: false,
    minimumIntervalMinutes: 1,
  );

  List<int> get _intervalChoices {
    final minimum = _capabilities.minimumIntervalMinutes;
    final choices =
        _presetIntervals.where((value) => value >= minimum).toList();
    return choices.isEmpty ? [minimum] : choices;
  }

  @override
  void initState() {
    super.initState();
    _loadCapabilities();
    _checkBackgroundSyncStatus();
    _loadLog();
    _flutterDaemonPlugin.getBackgroundSyncInterval().then((value) {
      if (!mounted) return;
      setState(() => _syncIntervalMinutes = _allowedInterval(value));
    });
    _statusCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkBackgroundSyncStatus();
      _loadLog();
    });
  }

  void _loadLog() {
    final text = _readBackgroundLog();
    if (!mounted || text == _logText) return;
    setState(() => _logText = text);
  }

  void _clearLog() {
    try {
      final file = File(_backgroundLogPath);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _logText = '');
  }

  int _allowedInterval(int? minutes) {
    final choices = _intervalChoices;
    return minutes != null && choices.contains(minutes)
        ? minutes
        : choices.first;
  }

  Future<void> _loadCapabilities() async {
    try {
      final capabilities = await _flutterDaemonPlugin.getCapabilities();
      if (!mounted) return;
      setState(() {
        _capabilities = capabilities;
        _syncIntervalMinutes = _allowedInterval(_syncIntervalMinutes);
      });
      if (capabilities.constraints) {
        await _loadConstraintSettings();
      }
      if (capabilities.batteryOptimization) {
        await _checkBatteryOptimizationStatus();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Failed to load capabilities: $e';
      });
    }
  }

  Future<void> _loadConstraintSettings() async {
    try {
      final useUnmetered = await _flutterDaemonPlugin.getNetworkType();
      final batteryNotLow = await _flutterDaemonPlugin.getBatteryNotLow();
      final requiresCharging = await _flutterDaemonPlugin.getRequiresCharging();
      final deviceIdle = await _flutterDaemonPlugin.getDeviceIdle();
      if (mounted) {
        setState(() {
          _useUnmeteredNetwork = useUnmetered;
          _requireBatteryNotLow = batteryNotLow;
          _requiresCharging = requiresCharging;
          _requiresDeviceIdle = deviceIdle;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Failed to load constraint settings: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _statusCheckTimer?.cancel();
    _batteryPoll?.cancel();
    super.dispose();
  }

  void _showStatus(String message) {
    if (!mounted) return;
    setState(() => _statusMessage = message);
  }

  Future<void> _toggleBackgroundSync() async {
    final interval = _allowedInterval(_syncIntervalMinutes);
    try {
      _log(_isSyncActive
          ? 'stopping background sync'
          : 'starting background sync every $interval minutes');
      final result = _isSyncActive
          ? await _flutterDaemonPlugin.stopBackgroundSync()
          : await _flutterDaemonPlugin.startBackgroundSync(interval);
      _log(result);
      _showStatus(result);
      await _checkBackgroundSyncStatus();
      _loadLog();
    } catch (e) {
      _log('background sync toggle failed: $e');
      _showStatus('Error: $e');
      _loadLog();
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
      final isDisabled =
          await _flutterDaemonPlugin.isBatteryOptimizationDisabled();
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
      _batteryPoll?.cancel();
      var remaining = 60;
      _batteryPoll = Timer.periodic(const Duration(seconds: 1), (timer) {
        remaining -= 1;
        _checkBatteryOptimizationStatus();
        if (remaining <= 0 || _isBatteryOptDisabled) timer.cancel();
      });
    } catch (e) {
      _showStatus('Error requesting battery optimization: $e');
    }
  }

  Future<void> _openBatteryOptimizationSettings() async {
    try {
      await _flutterDaemonPlugin.openBatteryOptimizationSettings();
    } catch (e) {
      _showStatus('Error opening battery settings: $e');
    }
  }

  String _intervalLabel(int minutes) {
    final hours = (minutes ~/ 60).toString().padLeft(2, '0');
    final mins = (minutes % 60).toString().padLeft(2, '0');
    return '${hours}h${mins}m';
  }

  Widget _statusDot(bool on, String label) {
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: on ? Colors.green : Colors.red,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(label, style: Theme.of(context).textTheme.bodyLarge),
      ],
    );
  }

  Widget _constraint(
    String title,
    String subtitle,
    bool value,
    Future<bool> Function(bool value) apply,
    void Function(bool value) store,
  ) {
    return SwitchListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: (next) async {
        try {
          if (await apply(next) && mounted) setState(() => store(next));
        } catch (e) {
          _showStatus('Failed to update constraint: $e');
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Flutter Daemon Example'),
        ),
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Background Sync Status',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                _statusDot(
                    _isSyncActive, _isSyncActive ? 'Active' : 'Inactive'),
                if (_statusMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(_statusMessage,
                        style: const TextStyle(color: Colors.blue)),
                  ),
                const SizedBox(height: 16),
                DropdownButton<int>(
                  value: _allowedInterval(_syncIntervalMinutes),
                  items: [
                    for (final minutes in _intervalChoices)
                      DropdownMenuItem(
                        value: minutes,
                        child: Text(_intervalLabel(minutes)),
                      ),
                  ],
                  onChanged: (minutes) {
                    if (minutes != null) {
                      setState(() => _syncIntervalMinutes = minutes);
                    }
                  },
                ),
                const SizedBox(height: 24),
                if (_capabilities.constraints) ...[
                  Text('Work Constraints',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  _constraint(
                    'Require Unmetered Network',
                    'Only run on Wi-Fi or unmetered connections',
                    _useUnmeteredNetwork,
                    _flutterDaemonPlugin.setNetworkType,
                    (value) => _useUnmeteredNetwork = value,
                  ),
                  _constraint(
                    'Require Battery Not Low',
                    'Skip when device is in low battery mode',
                    _requireBatteryNotLow,
                    _flutterDaemonPlugin.setBatteryNotLow,
                    (value) => _requireBatteryNotLow = value,
                  ),
                  _constraint(
                    'Require Charging',
                    'Only run when device is charging',
                    _requiresCharging,
                    _flutterDaemonPlugin.setRequiresCharging,
                    (value) => _requiresCharging = value,
                  ),
                  _constraint(
                    'Require Device Idle',
                    'Only run when device is idle',
                    _requiresDeviceIdle,
                    _flutterDaemonPlugin.setDeviceIdle,
                    (value) => _requiresDeviceIdle = value,
                  ),
                  OutlinedButton(
                    onPressed: _loadConstraintSettings,
                    child: const Text('Refresh Constraint Settings'),
                  ),
                ],
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _toggleBackgroundSync,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isSyncActive ? Colors.red : Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
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
                if (_capabilities.batteryOptimization) ...[
                  const SizedBox(height: 24),
                  Text('Battery Optimization',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  _statusDot(
                    _isBatteryOptDisabled,
                    _isBatteryOptDisabled ? 'Disabled' : 'Enabled',
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
                const SizedBox(height: 24),
                Text('Sync Log', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _clearLog,
                  child: const Text('Clear Logs'),
                ),
                const SizedBox(height: 8),
                SelectableText(_logText.isEmpty ? 'No log yet.' : _logText),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
