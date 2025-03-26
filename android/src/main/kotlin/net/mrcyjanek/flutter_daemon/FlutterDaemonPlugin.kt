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

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    context = flutterPluginBinding.applicationContext
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
          val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
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
          result.success("Background sync scheduled every $intervalMinutes minutes.")
        } catch (e: Exception) {
          result.error("BACKGROUND_SYNC_ERROR", "Failed to schedule background sync", e.message)
        }
      }
      "stopBackgroundSync" -> {
        try {
          WorkManager.getInstance(context).cancelUniqueWork("BackgroundSyncWork")
          result.success("Background sync stopped successfully.")
        } catch (e: Exception) {
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
}

class BackgroundSyncWorker(appContext: Context, workerParams: WorkerParameters) : Worker(appContext, workerParams) {
  companion object {
    private val isRunning = java.util.concurrent.atomic.AtomicBoolean(false)
    private const val NOTIFICATION_ID = 1337
    private const val CHANNEL_ID = "flutter_daemon_channel"
  }

  override fun doWork(): androidx.work.ListenableWorker.Result {
    android.util.Log.i("FlutterDaemon", "Starting background work process")
    android.util.Log.i("FlutterDaemon", "Creating notification channel for foreground service")
    createNotificationChannel()
    
    // Create a more visible notification
    android.util.Log.i("FlutterDaemon", "Building foreground notification")
    val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
        .setContentTitle("Background Sync")
        .setContentText("Keeping sync active...")
        .setSmallIcon(android.R.drawable.ic_popup_sync)
        .setPriority(NotificationCompat.PRIORITY_DEFAULT) // Add priority
        .setOngoing(true) // Make it ongoing
        .setAutoCancel(false) // Prevent auto-cancel
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC) // Make it visible on lock screen
        .build()

    android.util.Log.i("FlutterDaemon", "Setting foreground service with notification ID: $NOTIFICATION_ID")
    setForegroundAsync(androidx.work.ForegroundInfo(
        NOTIFICATION_ID,
        notification,
        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
    ))
    android.util.Log.i("FlutterDaemon", "Foreground service setup completed")

    android.util.Log.i("FlutterDaemon", "Checking if app is in foreground state")
    if (isAppInForeground()) {
      android.util.Log.i("FlutterDaemon", "App is currently in foreground, considering whether to skip background sync")
      return androidx.work.ListenableWorker.Result.success()
    } else {
      android.util.Log.i("FlutterDaemon", "App is in background, proceeding with background sync")
    }
    
    android.util.Log.i("FlutterDaemon", "Checking if another background sync is already running")
    if (!isRunning.compareAndSet(false, true)) {
      android.util.Log.i("FlutterDaemon", "Another background sync is already in progress, skipping this execution")
      return androidx.work.ListenableWorker.Result.success()
    }
    android.util.Log.i("FlutterDaemon", "No other background sync running, proceeding with this one")

    try {
      android.util.Log.i("FlutterDaemon", "Creating main thread handler for Flutter engine initialization")
      val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
      android.util.Log.i("FlutterDaemon", "Creating countdown latch for synchronization")
      val latch = java.util.concurrent.CountDownLatch(1)
      var result: androidx.work.ListenableWorker.Result = androidx.work.ListenableWorker.Result.success()
      
      android.util.Log.i("FlutterDaemon", "Posting Flutter engine initialization task to main thread")
      mainHandler.post {
        android.util.Log.i("FlutterDaemon", "Main thread: Starting Flutter engine initialization")
        try {
          android.util.Log.i("FlutterDaemon", "Main thread: Creating new FlutterEngine instance")
          val flutterEngine = FlutterEngine(applicationContext)
          
          android.util.Log.i("FlutterDaemon", "Main thread: Starting Flutter initialization")
          FlutterMain.startInitialization(applicationContext)
          android.util.Log.i("FlutterDaemon", "Main thread: Ensuring Flutter initialization is complete")
          FlutterMain.ensureInitializationComplete(applicationContext, null)
          
          android.util.Log.i("FlutterDaemon", "Main thread: Finding app bundle path")
          val appBundlePath = FlutterMain.findAppBundlePath(applicationContext)
          
          if (appBundlePath != null) {
            android.util.Log.i("FlutterDaemon", "Main thread: App bundle path found: $appBundlePath")
            android.util.Log.i("FlutterDaemon", "Main thread: Executing Dart entrypoint 'backgroundSync'")
            flutterEngine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(appBundlePath, "backgroundSync")
            )
            
            android.util.Log.i("FlutterDaemon", "Main thread: Caching Flutter engine with key 'background_engine'")
            io.flutter.embedding.engine.FlutterEngineCache.getInstance()
              .put("background_engine", flutterEngine)
            android.util.Log.i("FlutterDaemon", "Main thread: Flutter engine initialization successful")
          } else {
            android.util.Log.e("FlutterDaemon", "Main thread: Failed to find app bundle path, cannot execute Dart code")
            result = androidx.work.ListenableWorker.Result.failure()
          }
        } catch (e: Exception) {
          android.util.Log.e("FlutterDaemon", "Main thread: Error executing Flutter task: ${e.message}", e)
          result = androidx.work.ListenableWorker.Result.failure()
        } finally {
          android.util.Log.i("FlutterDaemon", "Main thread: Counting down latch to signal completion")
          latch.countDown()
        }
      }
      
      android.util.Log.i("FlutterDaemon", "Waiting for Flutter initialization to complete (timeout: 30 seconds)")
      
      // Wait for Flutter initialization to complete with a timeout
      if (!latch.await(30, TimeUnit.SECONDS)) {
        android.util.Log.e("FlutterDaemon", "Timeout waiting for Flutter engine initialization")
        return androidx.work.ListenableWorker.Result.failure()
      }
      
      // Set up a channel to listen for the backgroundSyncComplete message
      android.util.Log.i("FlutterDaemon", "Setting up method channel to listen for completion")
      val mainThreadLatch = java.util.concurrent.CountDownLatch(1)
      
      mainHandler.post {
        try {
          val flutterEngine = io.flutter.embedding.engine.FlutterEngineCache.getInstance().get("background_engine")
          if (flutterEngine != null) {
            android.util.Log.i("FlutterDaemon", "Creating method channel for completion signal")
            val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "flutter_daemon")
            
            methodChannel.setMethodCallHandler { call, callResult ->
              if (call.method == "backgroundSyncComplete") {
                android.util.Log.i("FlutterDaemon", "Received backgroundSyncComplete signal from Dart")
                callResult.success(true)
                mainThreadLatch.countDown()
              } else {
                callResult.notImplemented()
              }
            }
          } else {
            android.util.Log.e("FlutterDaemon", "Flutter engine not found in cache")
            mainThreadLatch.countDown()
          }
        } catch (e: Exception) {
          android.util.Log.e("FlutterDaemon", "Error setting up method channel: ${e.message}", e)
          mainThreadLatch.countDown()
        }
      }
      
      android.util.Log.i("FlutterDaemon", "Waiting for backgroundSyncComplete signal (timeout: 10 minutes)")
      if (!mainThreadLatch.await(10, TimeUnit.MINUTES)) {
        android.util.Log.e("FlutterDaemon", "Timeout waiting for backgroundSyncComplete signal")
        result = androidx.work.ListenableWorker.Result.failure()
      }

      android.util.Log.i("FlutterDaemon", "Background sync process completed with result: $result")
      return result
    } finally {
      android.util.Log.i("FlutterDaemon", "Resetting isRunning flag to allow future background syncs")
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
      // Change importance to IMPORTANCE_DEFAULT to make it more visible
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
