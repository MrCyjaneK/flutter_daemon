import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
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
    final io.Directory tempDir = io.Directory.systemTemp;
    print("tempDir: ${tempDir.path}");
    final String path =
        p.join(tempDir.path, "flutter_daemon_background", "__daemonfile");

    final directory = io.Directory(p.dirname(path));
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }

    final statFile = io.File(path);

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

  final String path = p.join(io.Directory.systemTemp.path,
      "flutter_daemon_background", "__daemonfile");

  final String pidFilePath = p.join(io.Directory.systemTemp.path,
      "flutter_daemon_background", "__daemonfile.pid");

  /// Set by the app when it starts; a running background sync stops at its next check.
  final String foregroundFilePath = p.join(io.Directory.systemTemp.path,
      "flutter_daemon_background", "__daemonfile.foreground");

  /// Called by the app on start instead of [unmarkBackgroundSync]. The background engine
  /// runs in the app's own process, so it is asked to stop (see [foregroundRequested])
  /// rather than killed. A stale run (no heartbeat for 5 minutes) is cleared as before.
  Future<void> requestForeground() async {
    final flag = io.File(foregroundFilePath);
    if (await isBackgroundSyncActive()) {
      flag.createSync(recursive: true);
    } else {
      await unmarkBackgroundSync();
    }
  }

  /// Whether the app has started since this background sync began; the sync should then
  /// stop its current wallet and return.
  bool get foregroundRequested => io.File(foregroundFilePath).existsSync();

  Future<bool> unmarkBackgroundSync() async {
    final pidFile = io.File(pidFilePath);
    if (pidFile.existsSync()) {
      final pid = int.tryParse(pidFile.readAsStringSync());
      // The recorded pid is normally this very process (the background engine runs in the
      // app process): never signal it. Only a run left by another process is killed.
      if (pid != null && pid != io.pid) {
        io.Process.killPid(pid);
        await Future.delayed(Duration(milliseconds: 250));
        io.Process.killPid(pid, io.ProcessSignal.sigkill);
      }
      pidFile.deleteSync();
    }
    final flag = io.File(foregroundFilePath);
    if (flag.existsSync()) {
      flag.deleteSync();
    }
    final statFile = io.File(path);
    if (statFile.existsSync()) {
      statFile.deleteSync();
    }
    return true;
  }

  Future<bool> markBackgroundSync() async {
    print("Marking background sync");

    await Future.delayed(Duration(seconds: 1));

    final directory = io.Directory(p.dirname(path));
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }

    final statFile = io.File(path);

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
    final flag = io.File(foregroundFilePath);
    if (flag.existsSync()) {
      flag.deleteSync();
    }
    io.File(pidFilePath).writeAsStringSync(io.pid.toString());

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
