import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_daemon_platform_interface.dart';

class MethodChannelFlutterDaemon extends FlutterDaemonPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_daemon');

  @override
  Future<String?> getPlatformVersion() async {
    final version =
        await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }

  @override
  Future<String> startBackgroundSync(int intervalMinutes) async {
    final result = await methodChannel.invokeMethod<String>(
      'startBackgroundSync',
      {'intervalMinutes': intervalMinutes},
    );
    return result ?? 'Failed to start background sync';
  }

  @override
  Future<String> stopBackgroundSync() async {
    final result =
        await methodChannel.invokeMethod<String>('stopBackgroundSync');
    return result ?? 'Failed to stop background sync';
  }

  @override
  Future<bool> getBackgroundSyncStatus() async {
    final result =
        await methodChannel.invokeMethod<bool>('getBackgroundSyncStatus');
    return result ?? false;
  }

  @override
  Future<int?> getBackgroundSyncInterval() async {
    final result =
        await methodChannel.invokeMethod<int?>('getBackgroundSyncInterval');
    return result;
  }

  @override
  Future<bool> isBatteryOptimizationDisabled() async {
    final result =
        await methodChannel.invokeMethod<bool>('isBatteryOptimizationDisabled');
    return result ?? false;
  }

  @override
  Future<bool> requestDisableBatteryOptimization() async {
    final result =
        await methodChannel.invokeMethod<bool>('requestDisableBatteryOptimization');
    return result ?? false;
  }

  @override
  Future<bool> openBatteryOptimizationSettings() async {
    final result =
        await methodChannel.invokeMethod<bool>('openBatteryOptimizationSettings');
    return result ?? false;
  }

  @override
  Future<bool> setNetworkType(bool useUnmetered) async {
    final result = await methodChannel.invokeMethod<bool>(
      'setNetworkType',
      {'useUnmetered': useUnmetered},
    );
    return result ?? false;
  }
  
  @override
  Future<bool> getNetworkType() async {
    final result = await methodChannel.invokeMethod<bool>('getNetworkType');
    return result ?? false;
  }
  
  @override
  Future<bool> setBatteryNotLow(bool enabled) async {
    final result = await methodChannel.invokeMethod<bool>(
      'setBatteryNotLow',
      {'enabled': enabled},
    );
    return result ?? false;
  }
  
  @override
  Future<bool> getBatteryNotLow() async {
    final result = await methodChannel.invokeMethod<bool>('getBatteryNotLow');
    return result ?? false;
  }
  
  @override
  Future<bool> setRequiresCharging(bool enabled) async {
    final result = await methodChannel.invokeMethod<bool>(
      'setRequiresCharging',
      {'enabled': enabled},
    );
    return result ?? false;
  }
  
  @override
  Future<bool> getRequiresCharging() async {
    final result = await methodChannel.invokeMethod<bool>('getRequiresCharging');
    return result ?? false;
  }
  
  @override
  Future<bool> setDeviceIdle(bool enabled) async {
    final result = await methodChannel.invokeMethod<bool>(
      'setDeviceIdle',
      {'enabled': enabled},
    );
    return result ?? false;
  }
  
  @override
  Future<bool> getDeviceIdle() async {
    final result = await methodChannel.invokeMethod<bool>('getDeviceIdle');
    return result ?? false;
  }
}
