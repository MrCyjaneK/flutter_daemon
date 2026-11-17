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

The background isolate needs a top-level `backgroundSync` entrypoint. Use one `FlutterDaemon` for the whole run. `markBackgroundSync` returns true when another live sync already holds the lock. `finishBackgroundSync` belongs in `finally`: it releases the lock when this run holds it, signals the worker, and destroys the background engine after 5 seconds if that engine is still running.

```dart
@pragma('vm:entry-point')
Future<void> backgroundSync() async {
  final daemon = FlutterDaemon();
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  try {
    if (await daemon.markBackgroundSync()) {
      return;
    }
    // Work that must finish within the platform time limit.
  } finally {
    await daemon.finishBackgroundSync();
  }
}
```

## Platform-specific settings

### Android

Optional, not required feature if you want to prompt users to disable battery optimizations.

```xml
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
```

If you don't add this permission then users will be required to do a couple manual steps, open settings, find app name, and manually disable battery optimizations.

### iOS

`intervalMinutes` is a mere suggestion, the system will most likely run it way less often.

Register the handler from `application(_:didFinishLaunchingWithOptions:)` on every launch, including a cold launch that exists only to service the task, before that method returns:

```swift
import flutter_daemon

FlutterDaemonPlugin.registerBackgroundProcessing()
```

Info.plist configuration:

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

## Sailfish OS

Background sync is a systemd user timer and a oneshot service. The unit name is the executable name (`flutter_daemon_example` for this example). Units are written to `~/.config/systemd/user/` when `startBackgroundSync` runs.

`elinux/runner/main.cc` must call the plugin before the embedder parses arguments. Without that line, `startBackgroundSync` throws and does not install a unit:

```cpp
if (FlutterDaemonRunBackground(argc, argv, RegisterPlugins)) return 0;
```

Build:

```bash
sfosbuild --network --in-place 5.1.0.11 aarch64 rpm/flutter-daemon.spec
```

## Special thanks

- https://github.com/transistorsoft/transistor-background-fetch
- https://github.com/transistorsoft/flutter_background_fetch