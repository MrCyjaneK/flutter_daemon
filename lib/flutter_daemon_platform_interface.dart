import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_daemon_method_channel.dart';

abstract class FlutterDaemonPlatform extends PlatformInterface {
  FlutterDaemonPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterDaemonPlatform _instance = MethodChannelFlutterDaemon();

  static FlutterDaemonPlatform get instance => _instance;

  static set instance(FlutterDaemonPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  Future<String> startBackgroundSync(int intervalMinutes) {
    throw UnimplementedError(
        'startBackgroundSync(intervalMinutes: $intervalMinutes) has not been implemented.');
  }

  Future<String> stopBackgroundSync() {
    throw UnimplementedError('stopBackgroundSync() has not been implemented.');
  }

  Future<bool> getBackgroundSyncStatus() {
    throw UnimplementedError(
        'getBackgroundSyncStatus() has not been implemented.');
  }

  Future<int?> getBackgroundSyncInterval() {
    throw UnimplementedError(
        'getBackgroundSyncInterval() has not been implemented.');
  }

  Future<bool> isBatteryOptimizationDisabled() {
    throw UnimplementedError(
        'isBatteryOptimizationDisabled() has not been implemented.');
  }

  Future<bool> requestDisableBatteryOptimization() {
    throw UnimplementedError(
        'requestDisableBatteryOptimization() has not been implemented.');
  }

  Future<bool> openBatteryOptimizationSettings() {
    throw UnimplementedError(
        'openBatteryOptimizationSettings() has not been implemented.');
  }

  Future<bool> setNetworkType(bool useUnmetered) {
    throw UnimplementedError(
        'setNetworkType(useUnmetered: $useUnmetered) has not been implemented.');
  }
  
  Future<bool> getNetworkType() {
    throw UnimplementedError('getNetworkType() has not been implemented.');
  }
  
  Future<bool> setBatteryNotLow(bool enabled) {
    throw UnimplementedError(
        'setBatteryNotLow(enabled: $enabled) has not been implemented.');
  }
  
  Future<bool> getBatteryNotLow() {
    throw UnimplementedError('getBatteryNotLow() has not been implemented.');
  }
  
  Future<bool> setRequiresCharging(bool enabled) {
    throw UnimplementedError(
        'setRequiresCharging(enabled: $enabled) has not been implemented.');
  }
  
  Future<bool> getRequiresCharging() {
    throw UnimplementedError('getRequiresCharging() has not been implemented.');
  }
  
  Future<bool> setDeviceIdle(bool enabled) {
    throw UnimplementedError(
        'setDeviceIdle(enabled: $enabled) has not been implemented.');
  }
  
  Future<bool> getDeviceIdle() {
    throw UnimplementedError('getDeviceIdle() has not been implemented.');
  }

  Future<String> getLogs() {
    throw UnimplementedError('getLogs() has not been implemented.');
  }

  Future<bool> clearLogs() {
    throw UnimplementedError('clearLogs() has not been implemented.');
  }
}
