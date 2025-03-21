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
    return FlutterDaemon().startBackgroundSync(intervalMinutes);
}

Future<String> stopBackgroundSync() {
    return FlutterDaemon().stopBackgroundSync();
}

Future<bool> getBackgroundSyncStatus() {
    return FlutterDaemon().getBackgroundSyncStatus();
}

Future<int?> getBackgroundSyncInterval() {
    return FlutterDaemon().getBackgroundSyncInterval();
}

Future<bool> isBatteryOptimizationDisabled() {
    return FlutterDaemon().isBatteryOptimizationDisabled();
}

Future<bool> requestDisableBatteryOptimization() {
    return FlutterDaemon().requestDisableBatteryOptimization();
}

Future<bool> openBatteryOptimizationSettings() {
    return FlutterDaemon().openBatteryOptimizationSettings();
}
```

in `main.dart` you need to add a function that will be called in background

```dart
@pragma('vm:entry-point')
Future<void> backgroundSync() async {
  try {
    print("Background sync triggered");
    print("- WidgetsFlutterBinding.ensureInitialized()");
    WidgetsFlutterBinding.ensureInitialized();
    print("- DartPluginRegistrant.ensureInitialized()");
    DartPluginRegistrant.ensureInitialized();
    print("- FlutterDaemon.markBackgroundSync()");
    final val = await _flutterDaemonPlugin.markBackgroundSync();
    if (val) {
      print("Background sync already in progress");
      return;
    }
    int tick = 0;
    int maxTicks = 600;
    print("path provider test");
    try {
      final path = await getApplicationDocumentsDirectory();
      print("path: ${path.path}");
    } catch (e) {
      print("Error: $e");
    }
    while (tick < maxTicks) {
      print("Tick: ${tick++}");
      sleep(Duration(seconds: 1));
      if (tick >= maxTicks) {
        break;
      }
    }
    print("Background sync completed");
  } finally {
    _flutterDaemonPlugin.unmarkBackgroundSync();
  }
}
```

Please note that there are many things that you just can't do inside of code execuded by 

```kt
flutterEngine.dartExecutor.executeDartEntrypoint(
    DartExecutor.DartEntrypoint(appBundlePath, "backgroundSync")
)
```
for example platform channels won't work.

## Platform-specific settings

### Android

Optional, not required feature if you want to prompt users to disable battery optimizations.

```xml
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
```

If you don't add this permission then users will be required to do a couple manual steps, open settings, find app name, and manually disable battery optimizations.