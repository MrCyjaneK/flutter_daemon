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
      else -> {
        result.notImplemented()
      }
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }
}

class BackgroundSyncWorker(appContext: Context, workerParams: WorkerParameters) : Worker(appContext, workerParams) {
  companion object {
    private val isRunning = java.util.concurrent.atomic.AtomicBoolean(false)
  }

  override fun doWork(): androidx.work.ListenableWorker.Result {
    if (isAppInForeground()) {
      android.util.Log.i("FlutterDaemon", "Skipping background sync as app is in foreground")
      return androidx.work.ListenableWorker.Result.success()
    }
    
    if (!isRunning.compareAndSet(false, true)) {
      android.util.Log.i("FlutterDaemon", "Skipping background sync as another one is in progress")
      return androidx.work.ListenableWorker.Result.success()
    }

    try {
      val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
      val latch = java.util.concurrent.CountDownLatch(1)
      var result: androidx.work.ListenableWorker.Result = androidx.work.ListenableWorker.Result.success()
      
      mainHandler.post {
        try {
          val flutterEngine = FlutterEngine(applicationContext)
          
          FlutterMain.startInitialization(applicationContext)
          FlutterMain.ensureInitializationComplete(applicationContext, null)
          
          val appBundlePath = FlutterMain.findAppBundlePath(applicationContext)
          
          if (appBundlePath != null) {
            flutterEngine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(appBundlePath, "backgroundSync")
            )
            
            io.flutter.embedding.engine.FlutterEngineCache.getInstance()
              .put("background_engine", flutterEngine)
          } else {
            android.util.Log.e("FlutterDaemon", "Failed to find app bundle path")
            result = androidx.work.ListenableWorker.Result.failure()
          }
        } catch (e: Exception) {
          android.util.Log.e("FlutterDaemon", "Error executing Flutter task", e)
          result = androidx.work.ListenableWorker.Result.failure()
        } finally {
          latch.countDown()
        }
      }
      
      try {
        latch.await(30, java.util.concurrent.TimeUnit.SECONDS)
      } catch (e: InterruptedException) {
        android.util.Log.e("FlutterDaemon", "Background sync interrupted", e)
        return androidx.work.ListenableWorker.Result.failure()
      }
      
      return result
    } finally {
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
}
