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
}
