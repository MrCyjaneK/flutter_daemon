# Flutter Daemon

> This plugin allows you to run Dart code at a chosen interval, even when your app is not in the foreground.

## Features

- Schedule periodic background sync tasks
- Control and monitor background task execution
- Run Dart code in the background with full Flutter engine support
- Configure the sync interval in minutes


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
  var acquired = false;
  try {
    print("Background sync triggered");
    print("- WidgetsFlutterBinding.ensureInitialized()");
    WidgetsFlutterBinding.ensureInitialized();
    print("- DartPluginRegistrant.ensureInitialized()");
    DartPluginRegistrant.ensureInitialized();
    print("- FlutterDaemon.markBackgroundSync()");
    final alreadyRunning = await _flutterDaemonPlugin.markBackgroundSync();
    if (alreadyRunning) {
      print("Background sync already in progress");
      await _flutterDaemonPlugin.signalBackgroundSyncComplete();
      return;
    }
    acquired = true;
    int tick = 0;
    int maxTicks = 60;
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
    if (acquired) {
      await _flutterDaemonPlugin.unmarkBackgroundSync();
    }
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

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />

<manifest>
  <application>
    <service 
      android:name="androidx.work.impl.foreground.SystemForegroundService"
      android:foregroundServiceType="dataSync"
      android:exported="false" />
  </application>
</manifest>
```

Optional, not required feature if you want to prompt users to disable battery optimizations.

```xml
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
```

If you don't add this permission then users will be required to do a couple manual steps, open settings, find app name, and manually disable battery optimizations.

### iOS

Background sync is a `BGProcessingTask` and requires iOS 15. `intervalMinutes` is required and must be at least 1. It is written to `earliestBeginDate` as `now + intervalMinutes`: iOS will not launch the task before that, and the request stays queued after it. The system runs it while the device is idle and prefers the device to be charging. Each run submits the next request with the same interval. If sync is enabled and iOS has no pending request, the next launch submits one again. `startBackgroundSync` throws if the launch handler was not registered.

Register the handler from `application(_:didFinishLaunchingWithOptions:)` on every launch, including a cold launch that exists only to service the task, before that method returns:

```swift
import flutter_daemon

FlutterDaemonPlugin.registerBackgroundProcessing()
```

The example does this before `super.application`. The background engine loads `GeneratedPluginRegistrant` itself, which is the same plugin set as the foreground engine. Foreground registration on the current Flutter template happens later, from `didInitializeImplicitFlutterEngine`.

Add both keys to the host `Info.plist`. The identifier must match `Bundle.main.bundleIdentifier + ".flutter_daemon.processing"`. Xcode expands `$(PRODUCT_BUNDLE_IDENTIFIER)` to that bundle id.

```xml
<key>UIBackgroundModes</key>
<array>
  <string>processing</string>
</array>
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
  <string>$(PRODUCT_BUNDLE_IDENTIFIER).flutter_daemon.processing</string>
</array>
```

A processing task can run for several minutes. The example loop is about 75 seconds and can finish, but iOS may expire the task first. Keep `unmarkBackgroundSync()` in the entrypoint's `finally` block. If the isolate is killed, the plugin deletes the sync lock files itself.

To fire the task in the simulator, pause in the debugger and run:

```text
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.example.flutterDaemonExample.flutter_daemon.processing"]
```

Replace the identifier with `<bundle id>.flutter_daemon.processing` for another app.

## Sailfish OS

Background sync is a systemd user timer and a oneshot service. The unit name is the application's compile-time `BINARY_NAME` (`flutter_daemon_example` for this example), baked into the plugin when the app is built. Units are written to `~/.config/systemd/user/` when `startBackgroundSync` runs.

`elinux/runner/main.cc` must call the plugin before the embedder parses arguments. Without that line, `startBackgroundSync` throws and does not install a unit:

```cpp
if (FlutterDaemonRunBackground(argc, argv, RegisterPlugins)) return 0;
```

That runs the `backgroundSync` Dart entrypoint when the process is started with `--background-sync`. A normal launch continues into the window.

`getCapabilities()` reports what the current platform implements, including `minimumIntervalMinutes`: 15 on Android, 1 on iOS and Sailfish. `startBackgroundSync` rejects a smaller value. On Sailfish only background sync is supported. Work constraints and battery optimization are Android-only. The example hides a section when its capability is false, and the eLinux plugin throws if an unsupported method is called anyway.

Packaging is `rpm/` and `.sfosbuild/` (cyanek-sfos), pinned to flutter-sfos 3.44.0. sfosbuild runs from the repository root so `example/` can see this plugin at `path: ../`.

```bash
sfosbuild --network --in-place 5.1.0.11 aarch64 rpm/flutter-daemon.yaml
```

## Special thanks

- https://github.com/transistorsoft/transistor-background-fetch
- https://github.com/transistorsoft/flutter_background_fetch