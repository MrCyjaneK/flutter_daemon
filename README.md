# Flutter Daemon

> This plugin allows you to run Dart code at specified intervals, even when your app is not in the foreground.

## Features

- Schedule periodic background sync tasks
- Control and monitor background task execution
- Run Dart code in the background with full Flutter engine support
- Configure sync intervals as needed for your application


# Installation

```bash
$ dart pub add flutter_daemon --git-url=https://github.com/MrCyjaneK/flutter_daemon
```

# Usage

```dart
Future<String> startBackgroundSync(int intervalMinutes) {
    return FlutterDaemonPlatform.instance.startBackgroundSync(intervalMinutes);
}

Future<String> stopBackgroundSync() {
    return FlutterDaemonPlatform.instance.stopBackgroundSync();
}

Future<bool> getBackgroundSyncStatus() {
    return FlutterDaemonPlatform.instance.getBackgroundSyncStatus();
}
```

in `main.dart` you need to add a function that will be called in background

```dart
@pragma('vm:entry-point')
Future<void> backgroundSync() async {
  print("Background sync triggered");
  print("- WidgetsFlutterBinding.ensureInitialized()");
  WidgetsFlutterBinding.ensureInitialized();
  print("- DartPluginRegistrant.ensureInitialized()");
  DartPluginRegistrant.ensureInitialized();
  print("- FlutterDaemon.markBackgroundSync()");
  await FlutterDaemon.markBackgroundSync();
  int tick = 0;
  int maxTicks = 36000;
  while (true) {
    print("Tick: ${tick++}");
    sleep(Duration(seconds: 1));
    if (tick >= maxTicks) {
      break;
    }
  }
  print("Background sync completed");
}
```

Please note that there are many things that you just can't do inside of code execuded by 

```kt
flutterEngine.dartExecutor.executeDartEntrypoint(
    DartExecutor.DartEntrypoint(appBundlePath, "backgroundSync")
)
```

for example platform channels won't work.