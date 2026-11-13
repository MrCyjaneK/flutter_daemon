package net.mrcyjanek.flutter_daemon

import android.content.Context
import androidx.annotation.NonNull
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.embedding.engine.loader.FlutterLoader
import java.util.concurrent.TimeUnit
import androidx.work.Constraints
import androidx.work.NetworkType
import android.os.PowerManager
import android.content.Intent
import android.provider.Settings
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import android.content.pm.ServiceInfo
import android.util.Log

class FlutterDaemonPlugin: FlutterPlugin, MethodCallHandler {
  companion object {
    const val MINIMUM_INTERVAL_MINUTES = 15
  }

  private lateinit var channel : MethodChannel
  private lateinit var context: Context

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    context = flutterPluginBinding.applicationContext
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_daemon")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "getCapabilities" -> {
        result.success(mapOf(
          "backgroundSync" to true,
          "constraints" to true,
          "batteryOptimization" to true,
          "minimumIntervalMinutes" to MINIMUM_INTERVAL_MINUTES,
        ))
      }
      "startBackgroundSync" -> {
        try {
          val intervalMinutes = call.argument<Int>("intervalMinutes")
          if (intervalMinutes == null || intervalMinutes < MINIMUM_INTERVAL_MINUTES) {
            result.error(
              "BACKGROUND_SYNC_ERROR",
              "intervalMinutes must be at least $MINIMUM_INTERVAL_MINUTES",
              null,
            )
            return
          }
          val constraints = buildConstraintsFromPreferences()
          val sharedPreferences = context.getSharedPreferences("flutter_daemon_prefs", Context.MODE_PRIVATE)
          sharedPreferences.edit().putInt("background_sync_interval", intervalMinutes).apply()
          
          val syncWorkRequest = PeriodicWorkRequestBuilder<BackgroundSyncWorker>(intervalMinutes.toLong(), TimeUnit.MINUTES)
              .setConstraints(constraints)
              .build()

          WorkManager.getInstance(context).enqueueUniquePeriodicWork(
              "BackgroundSyncWork", 
              ExistingPeriodicWorkPolicy.REPLACE,
              syncWorkRequest
          )
          result.success("Background sync scheduled every $intervalMinutes minutes.")
        } catch (e: Exception) {
          Log.e("flutter_daemon", "Failed to schedule background sync", e)
          result.error("BACKGROUND_SYNC_ERROR", "Failed to schedule background sync", e.message)
        }
      }
      "stopBackgroundSync" -> {
        try {
          WorkManager.getInstance(context).cancelUniqueWork("BackgroundSyncWork")
          context.getSharedPreferences("flutter_daemon_prefs", Context.MODE_PRIVATE)
            .edit()
            .remove("background_sync_interval")
            .apply()
          result.success("Background sync stopped successfully.")
        } catch (e: Exception) {
          Log.e("flutter_daemon", "Failed to stop background sync", e)
          result.error("BACKGROUND_SYNC_ERROR", "Failed to stop background sync", e.message)
        }
      }
      "getBackgroundSyncStatus" -> {
        try {
          // Use a ListenableFuture instead of LiveData to avoid multiple callbacks
          // that cause crashes when multiple result.success() are called.
          val workInfosFuture = WorkManager.getInstance(context)
            .getWorkInfosForUniqueWork("BackgroundSyncWork")
          
          workInfosFuture.addListener({
            try {
              val workInfos = workInfosFuture.get()
              
              if (workInfos == null || workInfos.isEmpty()) {
                result.success(false)
                return@addListener
              }
              
              val isScheduled = workInfos.any { workInfo -> 
                workInfo.state == androidx.work.WorkInfo.State.ENQUEUED || 
                workInfo.state == androidx.work.WorkInfo.State.RUNNING 
              }
              
              result.success(isScheduled)
            } catch (e: Exception) {
              result.error("BACKGROUND_SYNC_ERROR", "Failed to process work info", e.message)
            }
          }, java.util.concurrent.Executors.newSingleThreadExecutor())
        } catch (e: Exception) {
          result.error("BACKGROUND_SYNC_ERROR", "Failed to get background sync status", e.message)
        }
      }
      "getBackgroundSyncInterval" -> {
        try {
          val sharedPreferences = context.getSharedPreferences("flutter_daemon_prefs", Context.MODE_PRIVATE)
          val intervalMinutes = sharedPreferences.getInt("background_sync_interval", -1)
          
          if (intervalMinutes == -1) {
            result.success(null)
          } else {
            result.success(intervalMinutes)
          }
        } catch (e: Exception) {
          result.error("BACKGROUND_SYNC_ERROR", "Failed to get background sync interval", e.message)
        }
      }
      "isBatteryOptimizationDisabled" -> {
        try {
          val isDisabled = isBatteryOptimizationDisabled()
          result.success(isDisabled)
        } catch (e: Exception) {
          result.error("BATTERY_OPT_ERROR", "Failed to check battery optimization status", e.message)
        }
      }
      "requestDisableBatteryOptimization" -> {
        try {
          if (isBatteryOptimizationDisabled()) {
            result.success(true)
            return
          }
          
          val hasPermission = context.packageManager.checkPermission(
            android.Manifest.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            context.packageName
          ) == android.content.pm.PackageManager.PERMISSION_GRANTED
          
          if (!hasPermission) {
            val appName = try {
              val appInfo = context.packageManager.getApplicationInfo(context.packageName, 0)
              context.packageManager.getApplicationLabel(appInfo).toString()
            } catch (e: Exception) {
              context.packageName
            }
            
            android.widget.Toast.makeText(
              context,
              "Please find '$appName' in battery settings and select 'Unrestricted'",
              android.widget.Toast.LENGTH_LONG
            ).show()
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
              val intent = Intent().apply {
                action = Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
              }
              context.startActivity(intent)
            }
            
            result.success(false)
            return
          }
          
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent().apply {
              action = Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
              data = Uri.parse("package:${context.packageName}")
              flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            context.startActivity(intent)
            result.success(true)
          } else {
            result.success(false)
          }
        } catch (e: Exception) {
          result.error("BATTERY_OPT_ERROR", "Failed to request disable battery optimization", e.message)
        }
      }
      "openBatteryOptimizationSettings" -> {
        try {
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent().apply {
              action = Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
              flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            context.startActivity(intent)
            result.success(true)
          } else {
            result.success(false)
          }
        } catch (e: Exception) {
          result.error("BATTERY_OPT_ERROR", "Failed to open battery optimization settings", e.message)
        }
      }
      "setNetworkType" -> {
        try {
          val useUnmetered = call.argument<Boolean>("useUnmetered") ?: false
          setNetworkTypePreference(useUnmetered)
          result.success(true)
        } catch (e: Exception) {
          result.error("CONSTRAINT_ERROR", "Failed to set network type", e.message)
        }
      }
      "getNetworkType" -> {
        try {
          val useUnmetered = getNetworkTypePreference()
          result.success(useUnmetered)
        } catch (e: Exception) {
          result.error("CONSTRAINT_ERROR", "Failed to get network type", e.message)
        }
      }
      "setBatteryNotLow" -> {
        try {
          val enabled = call.argument<Boolean>("enabled") ?: false
          setBatteryNotLowPreference(enabled)
          result.success(true)
        } catch (e: Exception) {
          result.error("CONSTRAINT_ERROR", "Failed to set battery constraint", e.message)
        }
      }
      "getBatteryNotLow" -> {
        try {
          val enabled = getBatteryNotLowPreference()
          result.success(enabled)
        } catch (e: Exception) {
          result.error("CONSTRAINT_ERROR", "Failed to get battery constraint", e.message)
        }
      }
      "setRequiresCharging" -> {
        try {
          val enabled = call.argument<Boolean>("enabled") ?: false
          setRequiresChargingPreference(enabled)
          result.success(true)
        } catch (e: Exception) {
          result.error("CONSTRAINT_ERROR", "Failed to set charging constraint", e.message)
        }
      }
      "getRequiresCharging" -> {
        try {
          val enabled = getRequiresChargingPreference()
          result.success(enabled)
        } catch (e: Exception) {
          result.error("CONSTRAINT_ERROR", "Failed to get charging constraint", e.message)
        }
      }
      "setDeviceIdle" -> {
        try {
          val enabled = call.argument<Boolean>("enabled") ?: false
          setDeviceIdlePreference(enabled)
          result.success(true)
        } catch (e: Exception) {
          result.error("CONSTRAINT_ERROR", "Failed to set device idle constraint", e.message)
        }
      }
      "getDeviceIdle" -> {
        try {
          val enabled = getDeviceIdlePreference()
          result.success(enabled)
        } catch (e: Exception) {
          result.error("CONSTRAINT_ERROR", "Failed to get device idle constraint", e.message)
        }
      }
      else -> {
        result.notImplemented()
      }
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }

  private fun isBatteryOptimizationDisabled(): Boolean {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
      return powerManager.isIgnoringBatteryOptimizations(context.packageName)
    }
    // Before Android M, there was no battery optimization system like this
    return true
  }

  private fun getSharedPreferences(): android.content.SharedPreferences {
    return context.getSharedPreferences("flutter_daemon_prefs", Context.MODE_PRIVATE)
  }
  
  private fun setNetworkTypePreference(useUnmetered: Boolean) {
    getSharedPreferences().edit().putBoolean("network_type_unmetered", useUnmetered).apply()
  }
  
  private fun getNetworkTypePreference(): Boolean {
    return getSharedPreferences().getBoolean("network_type_unmetered", false)
  }
  
  private fun setBatteryNotLowPreference(enabled: Boolean) {
    getSharedPreferences().edit().putBoolean("battery_not_low", enabled).apply()
  }
  
  private fun getBatteryNotLowPreference(): Boolean {
    return getSharedPreferences().getBoolean("battery_not_low", false)
  }
  
  private fun setRequiresChargingPreference(enabled: Boolean) {
    getSharedPreferences().edit().putBoolean("requires_charging", enabled).apply()
  }
  
  private fun getRequiresChargingPreference(): Boolean {
    return getSharedPreferences().getBoolean("requires_charging", false)
  }
  
  private fun setDeviceIdlePreference(enabled: Boolean) {
    getSharedPreferences().edit().putBoolean("device_idle", enabled).apply()
  }
  
  private fun getDeviceIdlePreference(): Boolean {
    return getSharedPreferences().getBoolean("device_idle", false)
  }
  
  private fun buildConstraintsFromPreferences(): Constraints {
    val constraintsBuilder = Constraints.Builder()
    if (getNetworkTypePreference()) {
      constraintsBuilder.setRequiredNetworkType(NetworkType.UNMETERED)
    } else {
      constraintsBuilder.setRequiredNetworkType(NetworkType.CONNECTED)
    }
    if (getBatteryNotLowPreference()) {
      constraintsBuilder.setRequiresBatteryNotLow(true)
    }
    
    if (getRequiresChargingPreference()) {
      constraintsBuilder.setRequiresCharging(true)
    }
    
    if (getDeviceIdlePreference()) {
      constraintsBuilder.setRequiresDeviceIdle(true)
    }
    
    return constraintsBuilder.build()
  }
}

class BackgroundSyncWorker(appContext: Context, workerParams: WorkerParameters) : Worker(appContext, workerParams) {
  companion object {
    private val isRunning = java.util.concurrent.atomic.AtomicBoolean(false)
    private const val NOTIFICATION_ID = 1337
    private const val CHANNEL_ID = "flutter_daemon_sync"
  }

  override fun doWork(): androidx.work.ListenableWorker.Result {
    if (isAppInForeground()) {
      Log.i("flutter_daemon", "App is in the foreground, skipping background sync")
      return androidx.work.ListenableWorker.Result.success()
    }
    if (!isRunning.compareAndSet(false, true)) {
      Log.i("flutter_daemon", "Background sync is already running")
      return androidx.work.ListenableWorker.Result.success()
    }

    val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    val released = java.util.concurrent.atomic.AtomicBoolean(false)
    try {
      createNotificationChannel()
      val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
          .setContentTitle("Background Sync")
          .setContentText("Keeping sync active...")
          .setSmallIcon(android.R.drawable.ic_popup_sync)
          .setPriority(NotificationCompat.PRIORITY_LOW)
          .setOngoing(true)
          .setSilent(true)
          .build()
      setForegroundAsync(androidx.work.ForegroundInfo(
          NOTIFICATION_ID,
          notification,
          ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
      ))

      val latch = java.util.concurrent.CountDownLatch(1)
      var result: androidx.work.ListenableWorker.Result = androidx.work.ListenableWorker.Result.success()

      mainHandler.post {
        var flutterEngine: FlutterEngine? = null
        var cached = false
        try {
          if (released.get()) {
            return@post
          }
          val engine = FlutterEngine(applicationContext)
          flutterEngine = engine
          val flutterLoader = FlutterLoader()
          flutterLoader.startInitialization(applicationContext)
          flutterLoader.ensureInitializationComplete(applicationContext, null)
          val appBundlePath = flutterLoader.findAppBundlePath()
          if (appBundlePath != null) {
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(appBundlePath, "backgroundSync")
            )
            if (released.get()) {
              engine.destroy()
            } else {
              io.flutter.embedding.engine.FlutterEngineCache.getInstance()
                .put("background_engine", engine)
              cached = true
            }
          } else {
            Log.e("flutter_daemon", "App bundle path was not found")
            engine.destroy()
            result = androidx.work.ListenableWorker.Result.failure()
          }
        } catch (e: Exception) {
          Log.e("flutter_daemon", "Failed to start the background engine", e)
          if (!cached) {
            flutterEngine?.destroy()
          }
          result = androidx.work.ListenableWorker.Result.failure()
        } finally {
          latch.countDown()
        }
      }

      if (!latch.await(30, TimeUnit.SECONDS)) {
        Log.e("flutter_daemon", "Timed out starting the background engine")
        return androidx.work.ListenableWorker.Result.failure()
      }

      val mainThreadLatch = java.util.concurrent.CountDownLatch(1)
      mainHandler.post {
        try {
          val flutterEngine = io.flutter.embedding.engine.FlutterEngineCache.getInstance().get("background_engine")
          if (flutterEngine != null) {
            val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "flutter_daemon")
            methodChannel.setMethodCallHandler { call, callResult ->
              if (call.method == "backgroundSyncComplete") {
                callResult.success(true)
                mainThreadLatch.countDown()
              } else {
                callResult.notImplemented()
              }
            }
          } else {
            Log.e("flutter_daemon", "Background engine was not cached")
            mainThreadLatch.countDown()
          }
        } catch (e: Exception) {
          Log.e("flutter_daemon", "Failed to listen for backgroundSyncComplete", e)
          mainThreadLatch.countDown()
        }
      }

      if (!mainThreadLatch.await(10, TimeUnit.MINUTES)) {
        Log.e("flutter_daemon", "Timed out waiting for backgroundSyncComplete")
        result = androidx.work.ListenableWorker.Result.failure()
      }
      return result
    } finally {
      released.set(true)
      val destroyLatch = java.util.concurrent.CountDownLatch(1)
      mainHandler.post {
        val cache = io.flutter.embedding.engine.FlutterEngineCache.getInstance()
        val engine = cache.get("background_engine")
        cache.remove("background_engine")
        engine?.destroy()
        destroyLatch.countDown()
      }
      destroyLatch.await(5, TimeUnit.SECONDS)
      isRunning.set(false)
    }
  }
  
  private fun isAppInForeground(): Boolean {
    val activityManager = applicationContext.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
    val appProcesses = activityManager.runningAppProcesses ?: return false
    val packageName = applicationContext.packageName
    
    for (appProcess in appProcesses) {
      if (appProcess.importance == android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND 
          && appProcess.processName == packageName) {
        return true
      }
    }
    return false
  }

  private fun createNotificationChannel() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val name = "Flutter Daemon"
      val descriptionText = "Background sync notifications"
      val importance = android.app.NotificationManager.IMPORTANCE_LOW
      val channel = android.app.NotificationChannel(CHANNEL_ID, name, importance).apply {
        description = descriptionText
        setShowBadge(false)
        enableLights(false)
        enableVibration(false)
        setSound(null, null)
      }
      
      val notificationManager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
      notificationManager.createNotificationChannel(channel)
    }
  }
}
