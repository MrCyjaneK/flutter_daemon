package net.mrcyjanek.flutter_daemon

import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.widget.Toast
import androidx.annotation.NonNull
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.ListenableWorker
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "flutter_daemon"
private const val CHANNEL = "flutter_daemon"
private const val ENGINE_CACHE_KEY = "background_engine"
private const val PREFS = "flutter_daemon_prefs"
private const val WORK_NAME = "BackgroundSyncWork"
private const val KEY_INTERVAL = "background_sync_interval"
private const val KEY_UNMETERED = "network_type_unmetered"
private const val KEY_BATTERY = "battery_not_low"
private const val KEY_CHARGING = "requires_charging"
private const val KEY_IDLE = "device_idle"

class FlutterDaemonPlugin : FlutterPlugin, MethodCallHandler {
  companion object {
    const val MINIMUM_INTERVAL_MINUTES = 15

    private val callbackExecutor = Executors.newSingleThreadExecutor()
  }

  private lateinit var channel: MethodChannel
  private lateinit var context: Context
  private var generation = 0

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    context = flutterPluginBinding.applicationContext
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, CHANNEL)
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "getCapabilities" -> result.success(mapOf(
        "backgroundSync" to true,
        "constraints" to true,
        "batteryOptimization" to true,
        "minimumIntervalMinutes" to MINIMUM_INTERVAL_MINUTES,
      ))
      "startBackgroundSync" -> result.reply("BACKGROUND_SYNC_ERROR", "Failed to schedule background sync") {
        val intervalMinutes = call.argument<Int>("intervalMinutes")
        if (intervalMinutes == null || intervalMinutes < MINIMUM_INTERVAL_MINUTES) {
          error(
            "BACKGROUND_SYNC_ERROR",
            "intervalMinutes must be at least $MINIMUM_INTERVAL_MINUTES",
            null,
          )
          return@reply
        }
        prefs().edit().putInt(KEY_INTERVAL, intervalMinutes).apply()
        val request = PeriodicWorkRequestBuilder<BackgroundSyncWorker>(
          intervalMinutes.toLong(),
          TimeUnit.MINUTES,
        ).setConstraints(buildConstraintsFromPreferences()).build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
          WORK_NAME,
          ExistingPeriodicWorkPolicy.REPLACE,
          request,
        )
        success("Background sync scheduled every $intervalMinutes minutes.")
      }
      "stopBackgroundSync" -> result.reply("BACKGROUND_SYNC_ERROR", "Failed to stop background sync") {
        WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        prefs().edit().remove(KEY_INTERVAL).apply()
        success("Background sync stopped successfully.")
      }
      "getBackgroundSyncStatus" -> querySyncStatus(result)
      "getBackgroundSyncInterval" -> result.reply("BACKGROUND_SYNC_ERROR", "Failed to get background sync interval") {
        val intervalMinutes = prefs().getInt(KEY_INTERVAL, -1)
        success(if (intervalMinutes == -1) null else intervalMinutes)
      }
      "isBatteryOptimizationDisabled" -> result.reply("BATTERY_OPT_ERROR", "Failed to check battery optimization status") {
        success(ignoresBatteryOptimizations())
      }
      "requestDisableBatteryOptimization" -> result.reply("BATTERY_OPT_ERROR", "Failed to request disable battery optimization") {
        requestDisableBatteryOptimization()
      }
      "openBatteryOptimizationSettings" -> result.reply("BATTERY_OPT_ERROR", "Failed to open battery optimization settings") {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
          success(false)
          return@reply
        }
        startSettings(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        success(true)
      }
      "setNetworkType" -> result.writeFlag(KEY_UNMETERED, call.argument<Boolean>("useUnmetered") ?: false, "Failed to set network type")
      "getNetworkType" -> result.readFlag(KEY_UNMETERED, "Failed to get network type")
      "setBatteryNotLow" -> result.writeFlag(KEY_BATTERY, call.argument<Boolean>("enabled") ?: false, "Failed to set battery constraint")
      "getBatteryNotLow" -> result.readFlag(KEY_BATTERY, "Failed to get battery constraint")
      "setRequiresCharging" -> result.writeFlag(KEY_CHARGING, call.argument<Boolean>("enabled") ?: false, "Failed to set charging constraint")
      "getRequiresCharging" -> result.readFlag(KEY_CHARGING, "Failed to get charging constraint")
      "setDeviceIdle" -> result.writeFlag(KEY_IDLE, call.argument<Boolean>("enabled") ?: false, "Failed to set device idle constraint")
      "getDeviceIdle" -> result.readFlag(KEY_IDLE, "Failed to get device idle constraint")
      else -> result.notImplemented()
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    generation += 1
    channel.setMethodCallHandler(null)
  }

  private fun querySyncStatus(result: Result) {
    val generationAtCall = generation
    try {
      val future = WorkManager.getInstance(context).getWorkInfosForUniqueWork(WORK_NAME)
      future.addListener({
        if (generationAtCall != generation) return@addListener
        try {
          val scheduled = future.get()?.any { workInfo ->
            workInfo.state == WorkInfo.State.ENQUEUED || workInfo.state == WorkInfo.State.RUNNING
          } == true
          result.success(scheduled)
        } catch (e: Exception) {
          Log.e(TAG, "Failed to process work info", e)
          result.error("BACKGROUND_SYNC_ERROR", "Failed to process work info", e.message)
        }
      }, callbackExecutor)
    } catch (e: Exception) {
      Log.e(TAG, "Failed to get background sync status", e)
      result.error("BACKGROUND_SYNC_ERROR", "Failed to get background sync status", e.message)
    }
  }

  private fun Result.requestDisableBatteryOptimization() {
    if (ignoresBatteryOptimizations()) {
      success(true)
      return
    }
    val granted = context.packageManager.checkPermission(
      android.Manifest.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
      context.packageName,
    ) == PackageManager.PERMISSION_GRANTED
    if (!granted) {
      Toast.makeText(
        context,
        "Please find '${applicationLabel()}' in battery settings and select 'Unrestricted'",
        Toast.LENGTH_LONG,
      ).show()
      startSettings(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
      success(false)
      return
    }
    startSettings(
      Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
      Uri.parse("package:${context.packageName}"),
    )
    success(true)
  }

  private fun ignoresBatteryOptimizations(): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
    val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
    return powerManager.isIgnoringBatteryOptimizations(context.packageName)
  }

  private fun applicationLabel(): String {
    return try {
      val info = context.packageManager.getApplicationInfo(context.packageName, 0)
      context.packageManager.getApplicationLabel(info).toString()
    } catch (e: Exception) {
      context.packageName
    }
  }

  private fun startSettings(action: String, data: Uri? = null) {
    context.startActivity(Intent(action).apply {
      this.data = data
      flags = Intent.FLAG_ACTIVITY_NEW_TASK
    })
  }

  private fun prefs() = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  private fun Result.readFlag(key: String, failure: String) {
    reply("CONSTRAINT_ERROR", failure) {
      success(prefs().getBoolean(key, false))
    }
  }

  private fun Result.writeFlag(key: String, value: Boolean, failure: String) {
    reply("CONSTRAINT_ERROR", failure) {
      prefs().edit().putBoolean(key, value).apply()
      success(true)
    }
  }

  private fun buildConstraintsFromPreferences(): Constraints {
    val stored = prefs()
    return Constraints.Builder().apply {
      setRequiredNetworkType(
        if (stored.getBoolean(KEY_UNMETERED, false)) NetworkType.UNMETERED else NetworkType.CONNECTED,
      )
      if (stored.getBoolean(KEY_BATTERY, false)) setRequiresBatteryNotLow(true)
      if (stored.getBoolean(KEY_CHARGING, false)) setRequiresCharging(true)
      if (stored.getBoolean(KEY_IDLE, false)) setRequiresDeviceIdle(true)
    }.build()
  }
}

private inline fun Result.reply(code: String, failure: String, block: Result.() -> Unit) {
  try {
    block()
  } catch (e: Exception) {
    Log.e(TAG, failure, e)
    error(code, failure, e.message)
  }
}

class BackgroundSyncWorker(
  appContext: Context,
  workerParams: WorkerParameters,
) : Worker(appContext, workerParams) {
  companion object {
    private val isRunning = AtomicBoolean(false)
    private const val NOTIFICATION_ID = 1337
    private const val CHANNEL_ID = "flutter_daemon_sync"
  }

  override fun doWork(): ListenableWorker.Result {
    if (isAppInForeground()) {
      Log.i(TAG, "App is in the foreground, skipping background sync")
      return ListenableWorker.Result.success()
    }
    if (!isRunning.compareAndSet(false, true)) {
      Log.i(TAG, "Background sync is already running")
      return ListenableWorker.Result.success()
    }

    val mainHandler = Handler(Looper.getMainLooper())
    val released = AtomicBoolean(false)
    try {
      createNotificationChannel()
      setForegroundAsync(ForegroundInfo(NOTIFICATION_ID, buildNotification(), foregroundServiceType()))

      val latch = CountDownLatch(1)
      var result = ListenableWorker.Result.success()
      mainHandler.post { startEngine(released, latch) { result = it } }

      if (!latch.await(30, TimeUnit.SECONDS)) {
        Log.e(TAG, "Timed out starting the background engine")
        return ListenableWorker.Result.failure()
      }

      val mainThreadLatch = CountDownLatch(1)
      mainHandler.post { listenForCompletion(mainThreadLatch) }
      if (!mainThreadLatch.await(10, TimeUnit.MINUTES)) {
        Log.e(TAG, "Timed out waiting for backgroundSyncComplete")
        result = ListenableWorker.Result.failure()
      }
      return result
    } finally {
      released.set(true)
      val destroyLatch = CountDownLatch(1)
      mainHandler.post {
        val cache = FlutterEngineCache.getInstance()
        val engine = cache.get(ENGINE_CACHE_KEY)
        cache.remove(ENGINE_CACHE_KEY)
        engine?.destroy()
        destroyLatch.countDown()
      }
      destroyLatch.await(5, TimeUnit.SECONDS)
      isRunning.set(false)
    }
  }

  private fun startEngine(
    released: AtomicBoolean,
    latch: CountDownLatch,
    setResult: (ListenableWorker.Result) -> Unit,
  ) {
    var flutterEngine: FlutterEngine? = null
    var cached = false
    try {
      if (released.get()) return
      val engine = FlutterEngine(applicationContext)
      flutterEngine = engine
      val flutterLoader = FlutterLoader()
      flutterLoader.startInitialization(applicationContext)
      flutterLoader.ensureInitializationComplete(applicationContext, null)
      val appBundlePath = flutterLoader.findAppBundlePath()
      if (appBundlePath == null) {
        Log.e(TAG, "App bundle path was not found")
        engine.destroy()
        setResult(ListenableWorker.Result.failure())
        return
      }
      engine.dartExecutor.executeDartEntrypoint(
        DartExecutor.DartEntrypoint(appBundlePath, "backgroundSync"),
      )
      if (released.get()) {
        engine.destroy()
      } else {
        FlutterEngineCache.getInstance().put(ENGINE_CACHE_KEY, engine)
        cached = true
      }
    } catch (e: Exception) {
      Log.e(TAG, "Failed to start the background engine", e)
      if (!cached) flutterEngine?.destroy()
      setResult(ListenableWorker.Result.failure())
    } finally {
      latch.countDown()
    }
  }

  private fun listenForCompletion(latch: CountDownLatch) {
    try {
      val engine = FlutterEngineCache.getInstance().get(ENGINE_CACHE_KEY)
      if (engine == null) {
        Log.e(TAG, "Background engine was not cached")
        latch.countDown()
        return
      }
      val methodChannel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
      methodChannel.setMethodCallHandler { call, callResult ->
        if (call.method == "backgroundSyncComplete") {
          callResult.success(null)
          latch.countDown()
        } else {
          callResult.notImplemented()
        }
      }
    } catch (e: Exception) {
      Log.e(TAG, "Failed to listen for backgroundSyncComplete", e)
      latch.countDown()
    }
  }

  private fun foregroundServiceType(): Int {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
    } else {
      0
    }
  }

  private fun buildNotification() = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
    .setContentTitle("Background Sync")
    .setContentText("Keeping sync active...")
    .setSmallIcon(android.R.drawable.ic_popup_sync)
    .setPriority(NotificationCompat.PRIORITY_LOW)
    .setOngoing(true)
    .setSilent(true)
    .build()

  private fun isAppInForeground(): Boolean {
    val activityManager = applicationContext.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    val packageName = applicationContext.packageName
    return activityManager.runningAppProcesses?.any { process ->
      process.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND &&
        process.processName == packageName
    } == true
  }

  private fun createNotificationChannel() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val channel = NotificationChannel(
      CHANNEL_ID,
      "Flutter Daemon",
      NotificationManager.IMPORTANCE_LOW,
    ).apply {
      description = "Background sync notifications"
      setShowBadge(false)
      enableLights(false)
      enableVibration(false)
      setSound(null, null)
    }
    val notificationManager =
      applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    notificationManager.createNotificationChannel(channel)
  }
}
