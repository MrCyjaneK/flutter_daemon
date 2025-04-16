import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
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
    final Directory tempDir = Directory.systemTemp;
    print("tempDir: ${tempDir.path}");
    final String path =
        p.join(tempDir.path, "flutter_daemon_background", "__daemonfile");

    final directory = Directory(p.dirname(path));
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }

    final statFile = File(path);

    if (statFile.existsSync()) {
      try {
        final content = await statFile.readAsString();
        final lastTimestamp = DateTime.parse(content);
        final now = DateTime.now();
        final difference = now.difference(lastTimestamp);

        if (difference.inMinutes < 5) {
          return true;
        }
      } catch (e) {
        print("Error parsing timestamp: $e");
      }
    }
    return false;
  }

  final String path = p.join(
      Directory.systemTemp.path, "flutter_daemon_background", "__daemonfile");

  Future<bool> unmarkBackgroundSync() async {
    final statFile = File(path);
    if (statFile.existsSync()) {
      statFile.deleteSync();
    }
    return true;
  }

  Future<bool> markBackgroundSync() async {
    print("Marking background sync");

    await Future.delayed(Duration(seconds: 1));

    final directory = Directory(p.dirname(path));
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }

    final statFile = File(path);

    if (statFile.existsSync()) {
      try {
        final content = await statFile.readAsString();
        final lastTimestamp = DateTime.parse(content);
        final now = DateTime.now();
        final difference = now.difference(lastTimestamp);

        if (difference.inMinutes < 5) {
          print(
              "Daemon already running (last heartbeat: ${difference.inMinutes} minutes ago)");
          return true;
        }
      } catch (e) {
        print("Error parsing timestamp: $e");
      }
    } else {
      statFile.createSync(recursive: true);
    }

    final rootToken = ServicesBinding.rootIsolateToken;
    final randomId = Random.secure().nextInt(1000000);
    unawaited(Isolate.run(() async {
      BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken!);
      while (true) {
        if (!statFile.existsSync()) {
          print("[$randomId] Stopping background sync");
          final channel = MethodChannel('flutter_daemon');
          await channel.invokeMethod('backgroundSyncComplete');
          return;
        }
        await statFile.writeAsString(DateTime.now().toIso8601String());
        await Future.delayed(Duration(seconds: 1));
      }
    }));
    return false;
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
