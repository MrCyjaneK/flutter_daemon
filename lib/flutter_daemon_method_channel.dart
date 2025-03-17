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
}
