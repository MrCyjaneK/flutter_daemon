import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_daemon_platform_interface.dart';
import 'src/elinux_background_sync.dart';

class MethodChannelFlutterDaemon extends FlutterDaemonPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_daemon');

  late final ElinuxBackgroundSync _elinux = ElinuxBackgroundSync(methodChannel);

  Future<bool> _unsupported(String method, String feature,
      [Object? arguments]) {
    if (Platform.isLinux) {
      return Future.error(PlatformException(
        code: 'UNSUPPORTED',
        message: '$feature is not supported on Sailfish OS',
      ));
    }
    return _invokeBool(method, arguments);
  }

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
    if (Platform.isLinux) {
      return const FlutterDaemonCapabilities(
        backgroundSync: true,
        constraints: false,
        batteryOptimization: false,
        minimumIntervalMinutes: 1,
      );
    }
    final result = await methodChannel
        .invokeMethod<Map<Object?, Object?>>('getCapabilities');
    return FlutterDaemonCapabilities.fromMap(result ?? const {});
  }

  @override
  Future<String> startBackgroundSync(int intervalMinutes) {
    if (Platform.isLinux) return _elinux.start(intervalMinutes);
    return _invokeString(
      'startBackgroundSync',
      arguments: {'intervalMinutes': intervalMinutes},
      fallback: 'Failed to start background sync',
    );
  }

  @override
  Future<String> stopBackgroundSync() {
    if (Platform.isLinux) return _elinux.stop();
    return _invokeString(
      'stopBackgroundSync',
      fallback: 'Failed to stop background sync',
    );
  }

  @override
  Future<bool> getBackgroundSyncStatus() {
    if (Platform.isLinux) return _elinux.status();
    return _invokeBool('getBackgroundSyncStatus');
  }

  @override
  Future<int?> getBackgroundSyncInterval() {
    if (Platform.isLinux) return _elinux.interval();
    return methodChannel.invokeMethod<int>('getBackgroundSyncInterval');
  }

  @override
  Future<void> signalBackgroundSyncComplete() {
    return methodChannel.invokeMethod<void>('backgroundSyncComplete');
  }

  @override
  Future<bool> isBatteryOptimizationDisabled() {
    return _unsupported(
        'isBatteryOptimizationDisabled', 'battery optimization');
  }

  @override
  Future<bool> requestDisableBatteryOptimization() {
    return _unsupported(
        'requestDisableBatteryOptimization', 'battery optimization');
  }

  @override
  Future<bool> openBatteryOptimizationSettings() {
    return _unsupported(
        'openBatteryOptimizationSettings', 'battery optimization');
  }

  @override
  Future<bool> setNetworkType(bool useUnmetered) {
    return _unsupported(
        'setNetworkType', 'work constraints', {'useUnmetered': useUnmetered});
  }

  @override
  Future<bool> getNetworkType() {
    return _unsupported('getNetworkType', 'work constraints');
  }

  @override
  Future<bool> setBatteryNotLow(bool enabled) {
    return _unsupported(
        'setBatteryNotLow', 'work constraints', {'enabled': enabled});
  }

  @override
  Future<bool> getBatteryNotLow() {
    return _unsupported('getBatteryNotLow', 'work constraints');
  }

  @override
  Future<bool> setRequiresCharging(bool enabled) {
    return _unsupported(
        'setRequiresCharging', 'work constraints', {'enabled': enabled});
  }

  @override
  Future<bool> getRequiresCharging() {
    return _unsupported('getRequiresCharging', 'work constraints');
  }

  @override
  Future<bool> setDeviceIdle(bool enabled) {
    return _unsupported(
        'setDeviceIdle', 'work constraints', {'enabled': enabled});
  }

  @override
  Future<bool> getDeviceIdle() {
    return _unsupported('getDeviceIdle', 'work constraints');
  }
}
