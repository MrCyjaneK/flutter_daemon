import BackgroundTasks
import Flutter
import UIKit

public class FlutterDaemonPlugin: NSObject, FlutterPlugin {
  private static let enabledKey = "flutter_daemon.processing.enabled"
  private static let intervalKey = "flutter_daemon.processing.interval_minutes"
  private static let minimumIntervalMinutes = 1
  private static let completionTimeout: TimeInterval = 10 * 60

  private static var registered = false
  private static var activeTask: BGProcessingTask?
  private static var backgroundEngine: FlutterEngine?
  private static var onBackgroundSyncComplete: (() -> Void)?
  private static var runToken = 0

  /// `<bundle id>.flutter_daemon.processing`
  ///
  /// The host Info.plist must list this string under
  /// `BGTaskSchedulerPermittedIdentifiers`. `$(PRODUCT_BUNDLE_IDENTIFIER)`
  /// expands to the same value.
  public static var taskIdentifier: String? {
    guard let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty else {
      return nil
    }
    return bundleId + ".flutter_daemon.processing"
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "flutter_daemon",
      binaryMessenger: registrar.messenger())
    let instance = FlutterDaemonPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  /// Registers the processing-task launch handler.
  ///
  /// Call this from `application(_:didFinishLaunchingWithOptions:)` on every
  /// launch, including launches that exist only to service the task, before
  /// that method returns.
  public static func registerBackgroundProcessing() {
    if registered {
      return
    }
    guard let identifier = taskIdentifier else {
      NSLog("flutter_daemon: missing bundle identifier; background processing was not registered")
      return
    }
    registered = true
    BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
      guard let processingTask = task as? BGProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      handle(processingTask)
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    case "getCapabilities":
      result([
        "backgroundSync": true,
        "constraints": false,
        "batteryOptimization": false,
        "minimumIntervalMinutes": Self.minimumIntervalMinutes,
      ])
    case "startBackgroundSync":
      startBackgroundSync(call, result: result)
    case "stopBackgroundSync":
      stopBackgroundSync(result: result)
    case "getBackgroundSyncStatus":
      result(UserDefaults.standard.bool(forKey: Self.enabledKey))
    case "getBackgroundSyncInterval":
      result(Self.storedInterval())
    case "backgroundSyncComplete":
      result(nil)
      DispatchQueue.main.async {
        FlutterDaemonPlugin.onBackgroundSyncComplete?()
      }
    case "isBatteryOptimizationDisabled",
         "requestDisableBatteryOptimization",
         "openBatteryOptimizationSettings":
      unsupported("battery optimization", result: result)
    case "setNetworkType",
         "getNetworkType",
         "setBatteryNotLow",
         "getBatteryNotLow",
         "setRequiresCharging",
         "getRequiresCharging",
         "setDeviceIdle",
         "getDeviceIdle":
      unsupported("work constraints", result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startBackgroundSync(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard Self.registered else {
      NSLog("flutter_daemon: registerBackgroundProcessing() was not called")
      result(FlutterError(
        code: "BACKGROUND_SYNC_ERROR",
        message: "Call FlutterDaemonPlugin.registerBackgroundProcessing() from application(_:didFinishLaunchingWithOptions:) before the application finishes launching.",
        details: nil))
      return
    }
    guard let interval = intervalMinutes(from: call),
          interval >= Self.minimumIntervalMinutes else {
      result(FlutterError(
        code: "BACKGROUND_SYNC_ERROR",
        message: "intervalMinutes must be at least \(Self.minimumIntervalMinutes)",
        details: nil))
      return
    }
    do {
      try Self.submit(intervalMinutes: interval)
      UserDefaults.standard.set(true, forKey: Self.enabledKey)
      UserDefaults.standard.set(interval, forKey: Self.intervalKey)
      result("Background sync scheduled. Earliest begin is in \(interval) minutes.")
    } catch {
      NSLog("flutter_daemon: failed to schedule background sync: \(error.localizedDescription)")
      result(FlutterError(
        code: "BACKGROUND_SYNC_ERROR",
        message: "Failed to schedule background sync",
        details: error.localizedDescription))
    }
  }

  private func stopBackgroundSync(result: @escaping FlutterResult) {
    UserDefaults.standard.set(false, forKey: Self.enabledKey)
    if let identifier = Self.taskIdentifier {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
    result("Background sync stopped successfully.")
  }

  private func unsupported(_ feature: String, result: @escaping FlutterResult) {
    result(FlutterError(
      code: "UNSUPPORTED",
      message: "\(feature) is not supported on iOS",
      details: nil))
  }

  private func intervalMinutes(from call: FlutterMethodCall) -> Int? {
    let arguments = call.arguments as? [String: Any]
    return (arguments?["intervalMinutes"] as? NSNumber)?.intValue
  }

  private static func storedInterval() -> Int? {
    guard UserDefaults.standard.bool(forKey: enabledKey) else {
      return nil
    }
    let interval = UserDefaults.standard.integer(forKey: intervalKey)
    return interval >= minimumIntervalMinutes ? interval : nil
  }

  private static func submit(intervalMinutes: Int) throws {
    guard let identifier = taskIdentifier else {
      throw ScheduleError.missingBundleIdentifier
    }
    let request = BGProcessingTaskRequest(identifier: identifier)
    request.requiresExternalPower = false
    request.requiresNetworkConnectivity = false
    request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(intervalMinutes) * 60)
    // A second pending request for the same identifier is rejected.
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    try BGTaskScheduler.shared.submit(request)
  }

  private static func scheduleNextIfEnabled() {
    guard UserDefaults.standard.bool(forKey: enabledKey) else {
      return
    }
    let interval = UserDefaults.standard.integer(forKey: intervalKey)
    guard interval >= minimumIntervalMinutes else {
      NSLog("flutter_daemon: cannot reschedule without a valid interval")
      return
    }
    do {
      try submit(intervalMinutes: interval)
    } catch {
      NSLog("flutter_daemon: failed to reschedule: \(error.localizedDescription)")
    }
  }

  private static func handle(_ task: BGProcessingTask) {
    DispatchQueue.main.async {
      // Submit the follow-up before doing work so an expiration does not drop
      // the schedule. Cancel does not affect a task that has already started.
      scheduleNextIfEnabled()

      if activeTask != nil || backgroundEngine != nil {
        task.setTaskCompleted(success: true)
        return
      }

      runToken += 1
      let token = runToken
      let gate = CompletionGate()
      activeTask = task

      func finish(success: Bool) {
        if !Thread.isMainThread {
          DispatchQueue.main.async {
            finish(success: success)
          }
          return
        }
        guard token == runToken else {
          return
        }
        guard gate.claim() else {
          return
        }
        onBackgroundSyncComplete = nil
        let engine = backgroundEngine
        backgroundEngine = nil
        activeTask = nil
        engine?.destroyContext()
        if !success {
          // A killed isolate does not run its finally block, so the lock
          // files would otherwise look live for up to five minutes.
          clearLockFiles()
        }
        task.setTaskCompleted(success: success)
      }

      task.expirationHandler = {
        NSLog("flutter_daemon: processing task expired")
        finish(success: false)
      }

      onBackgroundSyncComplete = {
        finish(success: true)
      }

      let engine = FlutterEngine(
        name: "flutter_daemon_background",
        project: nil,
        allowHeadlessExecution: true)
      backgroundEngine = engine

      // The engine must be running before a message handler can be set.
      // Register on this engine directly. DartPluginRegistrant only binds
      // Dart implementations; a second registrarForPlugin: for this key
      // asserts, so the background entrypoint must not register it again.
      guard engine.run(withEntrypoint: "backgroundSync") else {
        NSLog("flutter_daemon: failed to run backgroundSync")
        finish(success: false)
        return
      }
      guard let registrar = engine.registrar(forPlugin: "FlutterDaemonPlugin") else {
        NSLog("flutter_daemon: failed to register the background engine plugin")
        finish(success: false)
        return
      }
      FlutterDaemonPlugin.register(with: registrar)

      DispatchQueue.main.asyncAfter(deadline: .now() + completionTimeout) {
        if token == runToken && activeTask != nil {
          NSLog("flutter_daemon: timed out waiting for backgroundSyncComplete")
        }
        finish(success: false)
      }
    }
  }

  private static func clearLockFiles() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("flutter_daemon_background", isDirectory: true)
    try? FileManager.default.removeItem(at: directory)
  }
}

private final class CompletionGate {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if claimed {
      return false
    }
    claimed = true
    return true
  }
}

private enum ScheduleError: LocalizedError {
  case missingBundleIdentifier

  var errorDescription: String? {
    switch self {
    case .missingBundleIdentifier:
      return "Application bundle identifier is unavailable."
    }
  }
}
