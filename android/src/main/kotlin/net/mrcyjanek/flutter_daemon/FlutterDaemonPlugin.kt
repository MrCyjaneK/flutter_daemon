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
import io.flutter.view.FlutterMain
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

class FlutterDaemonPlugin: FlutterPlugin, MethodCallHandler {
  private lateinit var channel : MethodChannel
  private lateinit var context: Context
  private lateinit var logger: FileLogger

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    context = flutterPluginBinding.applicationContext
    logger = FileLogger.getInstance(context)
    logger.logInfo("FlutterDaemonPlugin attached to engine")
    
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_daemon")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "getPlatformVersion" -> {
        result.success("Android ${android.os.Build.VERSION.RELEASE}")
      }
      "startBackgroundSync" -> {
        try {
          val intervalMinutes = call.argument<Int>("intervalMinutes") ?: 15
          logger.logInfo("Starting background sync with interval: $intervalMinutes minutes")
          
          val constraints = buildConstraintsFromPreferences()
          // Store the interval in shared preferences
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
          logger.logInfo("Background sync scheduled successfully")
          result.success("Background sync scheduled every $intervalMinutes minutes.")
        } catch (e: Exception) {
          logger.logError("Failed to schedule background sync", e)
          result.error("BACKGROUND_SYNC_ERROR", "Failed to schedule background sync", e.message)
        }
      }
      "stopBackgroundSync" -> {
        try {
          logger.logInfo("Stopping background sync")
          WorkManager.getInstance(context).cancelUniqueWork("BackgroundSyncWork")
          logger.logInfo("Background sync stopped successfully")
          result.success("Background sync stopped successfully.")
        } catch (e: Exception) {
          logger.logError("Failed to stop background sync", e)
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
          // Use shared preferences to store and retrieve the interval
          val sharedPreferences = context.getSharedPreferences("flutter_daemon_prefs", Context.MODE_PRIVATE)
          val intervalMinutes = sharedPreferences.getInt("background_sync_interval", -1)
          
          if (intervalMinutes == -1) {
            // No interval stored, meaning no background sync is configured
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
            // Already disabled
            result.success(true)
            return
          }
          
          // Check if the app has the required permission in manifest
          val hasPermission = context.packageManager.checkPermission(
            android.Manifest.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            context.packageName
          ) == android.content.pm.PackageManager.PERMISSION_GRANTED
          
          if (!hasPermission) {
            val appName = try {
              val appInfo = context.packageManager.getApplicationInfo(context.packageName, 0)
              context.packageManager.getApplicationLabel(appInfo).toString()
            } catch (e: Exception) {
              context.packageName // Fallback to package name if app name can't be retrieved
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
            // Battery optimization settings not available before Android M
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
            // Battery optimization settings not available before Android M
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
      "getLogs" -> {
        try {
          val logs = logger.getLogsAsJson()
          result.success(logs)
        } catch (e: Exception) {
          logger.logError("Failed to retrieve logs", e)
          result.error("LOGS_ERROR", "Failed to retrieve logs", e.message)
        }
      }
      "clearLogs" -> {
        try {
          logger.clearLogs()
          result.success(true)
        } catch (e: Exception) {
          logger.logError("Failed to clear logs", e)
          result.error("LOGS_ERROR", "Failed to clear logs", e.message)
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

  // Helper methods for constraint preferences
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
    
    // Set network type based on preference
    if (getNetworkTypePreference()) {
      constraintsBuilder.setRequiredNetworkType(NetworkType.UNMETERED)
    } else {
      constraintsBuilder.setRequiredNetworkType(NetworkType.CONNECTED)
    }
    
    // Set other constraints based on preferences
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
    private const val CHANNEL_ID = "flutter_daemon_channel"
  }

  override fun doWork(): androidx.work.ListenableWorker.Result {
    val logger = FileLogger.getInstance(applicationContext)
    val sessionId = logger.startSession("BackgroundSync")
    
    logger.logInfo("Starting background work process", sessionId)
    logger.logInfo("Creating notification channel for foreground service", sessionId)
    createNotificationChannel()
    
    logger.logInfo("Building foreground notification", sessionId)
    val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
        .setContentTitle("Background Sync")
        .setContentText("Keeping sync active...")
        .setSmallIcon(android.R.drawable.ic_popup_sync)
        .setPriority(NotificationCompat.PRIORITY_MIN) 
        .setOngoing(true)
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        .build()

    logger.logInfo("Setting foreground service with notification ID: $NOTIFICATION_ID", sessionId)
    setForegroundAsync(androidx.work.ForegroundInfo(
        NOTIFICATION_ID,
        notification,
        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
    ))
    logger.logInfo("Foreground service setup completed", sessionId)

    logger.logInfo("Checking if app is in foreground state", sessionId)
    if (isAppInForeground()) {
      logger.logInfo("App is currently in foreground, skipping background sync", sessionId)
      logger.endSession(sessionId, true)
      return androidx.work.ListenableWorker.Result.success()
    } else {
      logger.logInfo("App is in background, proceeding with background sync", sessionId)
    }
    
    logger.logInfo("Checking if another background sync is already running", sessionId)
    if (!isRunning.compareAndSet(false, true)) {
      logger.logInfo("Another background sync is already in progress, skipping this execution", sessionId)
      logger.endSession(sessionId, true)
      return androidx.work.ListenableWorker.Result.success()
    }
    logger.logInfo("No other background sync running, proceeding with this one", sessionId)

    try {
      logger.logInfo("Creating main thread handler for Flutter engine initialization", sessionId)
      val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
      logger.logInfo("Creating countdown latch for synchronization", sessionId)
      val latch = java.util.concurrent.CountDownLatch(1)
      var result: androidx.work.ListenableWorker.Result = androidx.work.ListenableWorker.Result.success()
      
      logger.logInfo("Posting Flutter engine initialization task to main thread", sessionId)
      mainHandler.post {
        logger.logInfo("Main thread: Starting Flutter engine initialization", sessionId)
        try {
          logger.logInfo("Main thread: Creating new FlutterEngine instance", sessionId)
          val flutterEngine = FlutterEngine(applicationContext)
          
          logger.logInfo("Main thread: Starting Flutter initialization", sessionId)
          FlutterMain.startInitialization(applicationContext)
          logger.logInfo("Main thread: Ensuring Flutter initialization is complete", sessionId)
          FlutterMain.ensureInitializationComplete(applicationContext, null)
          
          logger.logInfo("Main thread: Finding app bundle path", sessionId)
          val appBundlePath = FlutterMain.findAppBundlePath(applicationContext)
          
          if (appBundlePath != null) {
            logger.logInfo("Main thread: App bundle path found: $appBundlePath", sessionId)
            logger.logInfo("Main thread: Executing Dart entrypoint 'backgroundSync'", sessionId)
            flutterEngine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(appBundlePath, "backgroundSync")
            )
            
            logger.logInfo("Main thread: Caching Flutter engine with key 'background_engine'", sessionId)
            io.flutter.embedding.engine.FlutterEngineCache.getInstance()
              .put("background_engine", flutterEngine)
            logger.logInfo("Main thread: Flutter engine initialization successful", sessionId)
          } else {
            logger.logError("Main thread: Failed to find app bundle path, cannot execute Dart code", null, sessionId)
            result = androidx.work.ListenableWorker.Result.failure()
          }
        } catch (e: Exception) {
          logger.logError("Main thread: Error executing Flutter task: ${e.message}", e, sessionId)
          result = androidx.work.ListenableWorker.Result.failure()
        } finally {
          logger.logInfo("Main thread: Counting down latch to signal completion", sessionId)
          latch.countDown()
        }
      }
      
      logger.logInfo("Waiting for Flutter initialization to complete (timeout: 30 seconds)", sessionId)
      
      // Wait for Flutter initialization to complete with a timeout
      if (!latch.await(30, TimeUnit.SECONDS)) {
        logger.logError("Timeout waiting for Flutter engine initialization", null, sessionId)
        logger.endSession(sessionId, false)
        return androidx.work.ListenableWorker.Result.failure()
      }
      
      // Set up a channel to listen for the backgroundSyncComplete message
      logger.logInfo("Setting up method channel to listen for completion", sessionId)
      val mainThreadLatch = java.util.concurrent.CountDownLatch(1)
      
      mainHandler.post {
        try {
          val flutterEngine = io.flutter.embedding.engine.FlutterEngineCache.getInstance().get("background_engine")
          if (flutterEngine != null) {
            logger.logInfo("Creating method channel for completion signal", sessionId)
            val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "flutter_daemon")
            
            methodChannel.setMethodCallHandler { call, callResult ->
              if (call.method == "backgroundSyncComplete") {
                logger.logInfo("Received backgroundSyncComplete signal from Dart", sessionId)
                callResult.success(true)
                mainThreadLatch.countDown()
              } else {
                callResult.notImplemented()
              }
            }
          } else {
            logger.logError("Flutter engine not found in cache", null, sessionId)
            mainThreadLatch.countDown()
          }
        } catch (e: Exception) {
          logger.logError("Error setting up method channel: ${e.message}", e, sessionId)
          mainThreadLatch.countDown()
        }
      }
      
      logger.logInfo("Waiting for backgroundSyncComplete signal (timeout: 10 minutes)", sessionId)
      if (!mainThreadLatch.await(10, TimeUnit.MINUTES)) {
        logger.logError("Timeout waiting for backgroundSyncComplete signal", null, sessionId)
        result = androidx.work.ListenableWorker.Result.failure()
      }

      logger.logInfo("Background sync process completed with result: $result", sessionId)
      logger.endSession(sessionId, result is androidx.work.ListenableWorker.Result.Success)
      return result
    } finally {
      logger.logInfo("Resetting isRunning flag to allow future background syncs", sessionId)
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
      val importance = android.app.NotificationManager.IMPORTANCE_DEFAULT
      val channel = android.app.NotificationChannel(CHANNEL_ID, name, importance).apply {
        description = descriptionText
        setShowBadge(true) // Show badge on app icon
        enableLights(true) // Enable lights
        enableVibration(true) // Enable vibration
      }
      
      val notificationManager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
      notificationManager.createNotificationChannel(channel)
    }
  }
}
