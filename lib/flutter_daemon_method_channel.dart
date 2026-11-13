import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_daemon_platform_interface.dart';

class MethodChannelFlutterDaemon extends FlutterDaemonPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_daemon');

  Future<String> _invokeString(
    String method, {
    Object? arguments,
    required String fallback,
  }) async {
    final result = await methodChannel.invokeMethod<String>(method, arguments);
    return result ?? fallback;
  }

  Future<bool> _invokeBool(String method, [Object? arguments]) async {
    final result = await methodChannel.invokeMethod<bool>(method, arguments);
    return result ?? false;
  }

  @override
  Future<FlutterDaemonCapabilities> getCapabilities() async {
    final result = await methodChannel
        .invokeMethod<Map<Object?, Object?>>('getCapabilities');
    return FlutterDaemonCapabilities.fromMap(result ?? const {});
  }

  @override
  Future<String> startBackgroundSync(int intervalMinutes) {
    return _invokeString(
      'startBackgroundSync',
      arguments: {'intervalMinutes': intervalMinutes},
      fallback: 'Failed to start background sync',
    );
  }

  @override
  Future<String> stopBackgroundSync() {
    return _invokeString(
      'stopBackgroundSync',
      fallback: 'Failed to stop background sync',
    );
  }

  @override
  Future<bool> getBackgroundSyncStatus() {
    return _invokeBool('getBackgroundSyncStatus');
  }

  @override
  Future<int?> getBackgroundSyncInterval() {
    return methodChannel.invokeMethod<int>('getBackgroundSyncInterval');
  }

  @override
  Future<void> signalBackgroundSyncComplete() {
    return methodChannel.invokeMethod<void>('backgroundSyncComplete');
  }

  @override
  Future<bool> isBatteryOptimizationDisabled() {
    return _invokeBool('isBatteryOptimizationDisabled');
  }

  @override
  Future<bool> requestDisableBatteryOptimization() {
    return _invokeBool('requestDisableBatteryOptimization');
  }

  @override
  Future<bool> openBatteryOptimizationSettings() {
    return _invokeBool('openBatteryOptimizationSettings');
  }

  @override
  Future<bool> setNetworkType(bool useUnmetered) {
    return _invokeBool('setNetworkType', {'useUnmetered': useUnmetered});
  }

  @override
  Future<bool> getNetworkType() {
    return _invokeBool('getNetworkType');
  }

  @override
  Future<bool> setBatteryNotLow(bool enabled) {
    return _invokeBool('setBatteryNotLow', {'enabled': enabled});
  }

  @override
  Future<bool> getBatteryNotLow() {
    return _invokeBool('getBatteryNotLow');
  }

  @override
  Future<bool> setRequiresCharging(bool enabled) {
    return _invokeBool('setRequiresCharging', {'enabled': enabled});
  }

  @override
  Future<bool> getRequiresCharging() {
    return _invokeBool('getRequiresCharging');
  }

  @override
  Future<bool> setDeviceIdle(bool enabled) {
    return _invokeBool('setDeviceIdle', {'enabled': enabled});
  }

  @override
  Future<bool> getDeviceIdle() {
    return _invokeBool('getDeviceIdle');
  }
}
