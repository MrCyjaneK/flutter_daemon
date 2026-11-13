# Flutter Daemon

> This plugin allows you to run Dart code at a chosen interval, even when your app is not in the foreground.

## Features

- Schedule periodic background sync tasks
- Control and monitor background task execution
- Run Dart code in the background with full Flutter engine support
- Configure the sync interval in minutes


## Installation

```bash
$ dart pub add flutter_daemon --git-url=https://github.com/MrCyjaneK/flutter_daemon
```

## Usage

```dart
final daemon = FlutterDaemon();

await daemon.startBackgroundSync(15);
await daemon.stopBackgroundSync();
await daemon.getBackgroundSyncStatus();
await daemon.getBackgroundSyncInterval();
```

`getCapabilities()` reports what this platform implements. `startBackgroundSync` rejects an interval below `minimumIntervalMinutes`.

The background isolate needs a top-level `backgroundSync` entrypoint. `markBackgroundSync` returns true when another live sync already holds the lock; this run must still signal completion so its worker can exit. `unmarkBackgroundSync` clears the lock and signals completion, so keep it in `finally`.

```dart
final daemon = FlutterDaemon();

@pragma('vm:entry-point')
Future<void> backgroundSync() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  var acquired = false;
  try {
    if (await daemon.markBackgroundSync()) {
      await daemon.signalBackgroundSyncComplete();
      return;
    }
    acquired = true;
    // Work that must finish within the platform time limit.
  } finally {
    if (acquired) {
      await daemon.unmarkBackgroundSync();
    }
  }
}
```

On Android the background engine does not register other plugins, so their platform channels are unavailable in `backgroundSync`. iOS and Sailfish register the host's plugin registrant.

## Platform-specific settings

### Android

The plugin manifest merges `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, `POST_NOTIFICATIONS`, and the WorkManager foreground service (`foregroundServiceType="dataSync"`). The host app does not copy those.

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

A processing task can run for several minutes. The example spends a couple of minutes on network and websocket checks, and iOS may expire the task first. Keep `unmarkBackgroundSync()` in the entrypoint's `finally` block. If the isolate is killed, the plugin deletes the sync lock files itself.

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