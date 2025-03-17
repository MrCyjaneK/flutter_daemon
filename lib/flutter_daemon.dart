import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import 'flutter_daemon_platform_interface.dart';

class FlutterDaemon {
  Future<String?> getPlatformVersion() {
    return FlutterDaemonPlatform.instance.getPlatformVersion();
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

  static Future<void> markBackgroundSync() async {
    print("Marking background sync");

    await Future.delayed(Duration(seconds: 1));

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
          print(
              "Daemon already running (last heartbeat: ${difference.inMinutes} minutes ago)");
          exit(0);
        }
      } catch (e) {
        print("Error parsing timestamp: $e");
      }
    } else {
      statFile.createSync(recursive: true);
    }

    unawaited(Isolate.run(() async {
      while (true) {
        await statFile.writeAsString(DateTime.now().toIso8601String());
        await Future.delayed(Duration(seconds: 15));
      }
    }));
  }
}
