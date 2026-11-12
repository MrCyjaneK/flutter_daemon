import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:flutter_daemon/src/logging.dart';
import 'package:path/path.dart' as p;
import 'flutter_daemon_platform_interface.dart';
export 'src/logging.dart';

class FlutterDaemon {
  static const MethodChannel _channel = MethodChannel('flutter_daemon');

  Future<String> getPlatformVersion() async {
    final String version = await _channel.invokeMethod('getPlatformVersion');
    return version;
  }

  Future<String> startBackgroundSync(int intervalMinutes) {
    return FlutterDaemonPlatform.instance.startBackgroundSync(intervalMinutes);
  }

  Future<String> stopBackgroundSync() {
    return FlutterDaemonPlatform.instance.stopBackgroundSync();
  }

  Future<bool> getBackgroundSyncStatus() {
    return FlutterDaemonPlatform.instance.getBackgroundSyncStatus();
  }

  Future<int?> getBackgroundSyncInterval() {
    return FlutterDaemonPlatform.instance.getBackgroundSyncInterval();
  }

  Future<bool> isBatteryOptimizationDisabled() {
    return FlutterDaemonPlatform.instance.isBatteryOptimizationDisabled();
  }

  Future<bool> requestDisableBatteryOptimization() {
    return FlutterDaemonPlatform.instance.requestDisableBatteryOptimization();
  }

  Future<bool> openBatteryOptimizationSettings() {
    return FlutterDaemonPlatform.instance.openBatteryOptimizationSettings();
  }

  Future<bool> isBackgroundSyncActive() async {
    final io.Directory tempDir = io.Directory.systemTemp;
    print("tempDir: ${tempDir.path}");
    final directory = io.Directory(p.dirname(path));
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }

    return _syncLockIsLive();
  }

  final String path = p.join(io.Directory.systemTemp.path,
      "flutter_daemon_background", "__daemonfile");

  final String pidFilePath = p.join(io.Directory.systemTemp.path,
      "flutter_daemon_background", "__daemonfile.pid");

  /// Tells the Android worker that this background entrypoint is finished.
  ///
  /// Does not release the sync lock. Call this when [markBackgroundSync]
  /// reports that another live sync already owns the lock, so this worker
  /// can stop waiting without cancelling that other sync.
  Future<void> signalBackgroundSyncComplete() async {
    try {
      await _channel.invokeMethod<void>('backgroundSyncComplete');
    } catch (e) {
      print("Failed to signal backgroundSyncComplete: $e");
    }
  }

  Future<bool> unmarkBackgroundSync() async {
    _deleteSyncFiles();
    await signalBackgroundSyncComplete();
    return true;
  }

  Future<bool> markBackgroundSync() async {
    print("Marking background sync");

    // The worker installs its completion handler just after launching this
    // entrypoint. Wait until that handler is in place before deciding.
    await Future.delayed(const Duration(seconds: 1));

    final directory = io.Directory(p.dirname(path));
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }

    if (_syncLockIsLive()) {
      print("Daemon already running");
      return true;
    }

    _deleteSyncFiles();
    final statFile = io.File(path);
    statFile.writeAsStringSync(DateTime.now().toIso8601String());
    io.File(pidFilePath).writeAsStringSync('${io.pid}');
    _startHeartbeat(statFile.path);
    return false;
  }

  bool _syncLockIsLive() {
    final statFile = io.File(path);
    final pidFile = io.File(pidFilePath);
    if (!statFile.existsSync() || !pidFile.existsSync()) return false;
    try {
      final pid = int.tryParse(pidFile.readAsStringSync().trim());
      if (pid == null || !_isPidAlive(pid)) return false;
      final lastTimestamp = DateTime.parse(statFile.readAsStringSync().trim());
      return DateTime.now().difference(lastTimestamp).inMinutes < 5;
    } catch (e) {
      print("Error reading background sync lock: $e");
      return false;
    }
  }

  bool _isPidAlive(int pid) {
    if (pid <= 0) return false;
    if (pid == io.pid) return true;
    return io.Directory('/proc/$pid').existsSync();
  }

  void _deleteSyncFiles() {
    final statFile = io.File(path);
    final pidFile = io.File(pidFilePath);
    if (statFile.existsSync()) statFile.deleteSync();
    if (pidFile.existsSync()) pidFile.deleteSync();
  }

  void _startHeartbeat(String statPath) {
    unawaited(Isolate.run(() async {
      final file = io.File(statPath);
      final handle = file.openSync(mode: io.FileMode.writeOnly);
      try {
        while (file.existsSync()) {
          final bytes = utf8.encode(DateTime.now().toIso8601String());
          handle.setPositionSync(0);
          handle.writeFromSync(bytes);
          handle.truncateSync(bytes.length);
          handle.flushSync();
          await Future.delayed(const Duration(seconds: 1));
        }
      } catch (e) {
        print("Heartbeat stopped: $e");
      } finally {
        handle.closeSync();
      }
    }));
  }

  Future<bool> setNetworkType(bool useUnmetered) {
    return FlutterDaemonPlatform.instance.setNetworkType(useUnmetered);
  }

  Future<bool> getNetworkType() {
    return FlutterDaemonPlatform.instance.getNetworkType();
  }

  Future<bool> setBatteryNotLow(bool enabled) {
    return FlutterDaemonPlatform.instance.setBatteryNotLow(enabled);
  }

  Future<bool> getBatteryNotLow() {
    return FlutterDaemonPlatform.instance.getBatteryNotLow();
  }

  Future<bool> setRequiresCharging(bool enabled) {
    return FlutterDaemonPlatform.instance.setRequiresCharging(enabled);
  }

  Future<bool> getRequiresCharging() {
    return FlutterDaemonPlatform.instance.getRequiresCharging();
  }

  Future<bool> setDeviceIdle(bool enabled) {
    return FlutterDaemonPlatform.instance.setDeviceIdle(enabled);
  }

  Future<bool> getDeviceIdle() {
    return FlutterDaemonPlatform.instance.getDeviceIdle();
  }

  Future<LogData> getLogs() async {
    final String logsJson = await FlutterDaemonPlatform.instance.getLogs();
    return LogData.fromJson(json.decode(logsJson));
  }

  Future<bool> clearLogs() {
    return FlutterDaemonPlatform.instance.clearLogs();
  }
}
