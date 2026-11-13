import 'package:flutter/foundation.dart';

import 'flutter_daemon_platform_interface.dart';
import 'src/background_sync_lock.dart';

export 'flutter_daemon_platform_interface.dart' show FlutterDaemonCapabilities;

class FlutterDaemon {
  final BackgroundSyncLock _lock = BackgroundSyncLock(
    signalComplete: _signalBackgroundSyncComplete,
  );

  Future<FlutterDaemonCapabilities> getCapabilities() {
    return FlutterDaemonPlatform.instance.getCapabilities();
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

  /// Tells the platform worker that this background entrypoint is finished.
  ///
  /// Does not release the sync lock. Call this when [markBackgroundSync]
  /// reports that another live sync already owns the lock, so this worker
  /// can stop waiting without cancelling that other sync.
  Future<void> signalBackgroundSyncComplete() {
    return _signalBackgroundSyncComplete();
  }

  Future<bool> unmarkBackgroundSync() async {
    await _lock.release();
    return true;
  }

  /// Returns true when another live sync already owns the lock.
  Future<bool> markBackgroundSync() {
    return _lock.mark();
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
}

Future<void> _signalBackgroundSyncComplete() async {
  try {
    await FlutterDaemonPlatform.instance.signalBackgroundSyncComplete();
  } catch (e) {
    if (kDebugMode) {
      debugPrint('flutter_daemon: failed to signal backgroundSyncComplete: $e');
    }
  }
}
