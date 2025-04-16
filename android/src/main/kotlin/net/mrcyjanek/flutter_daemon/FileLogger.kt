package net.mrcyjanek.flutter_daemon

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

class FileLogger private constructor(private val context: Context) {
    companion object {
        private const val TAG = "FlutterDaemon"
        private const val LOG_FILE_NAME = "flutter_daemon_logs.json"
        private const val MAX_LOGS = 100000
        
        @Volatile
        private var instance: FileLogger? = null
        
        fun getInstance(context: Context): FileLogger {
            return instance ?: synchronized(this) {
                instance ?: FileLogger(context.applicationContext).also { instance = it }
            }
        }
    }
    
    private val logEntries = CopyOnWriteArrayList<LogEntry>()
    private val sessionIdCounter = AtomicInteger(0)
    private val activeSessions = mutableMapOf<Int, LogSession>()
    
    data class LogEntry(
        val timestamp: Long,
        val sessionId: Int?,
        val level: String,
        val message: String
    )
    
    data class LogSession(
        val id: Int,
        val name: String,
        val startTime: Long,
        var endTime: Long? = null,
        val logs: MutableList<LogEntry> = mutableListOf()
    )
    
    init {
        loadLogsFromFile()
    }
    
    private fun loadLogsFromFile() {
        try {
            val logFile = File(context.filesDir, LOG_FILE_NAME)
            if (logFile.exists()) {
                val jsonString = logFile.readText()
                val jsonArray = JSONArray(jsonString)
                
                for (i in 0 until jsonArray.length()) {
                    val obj = jsonArray.getJSONObject(i)
                    logEntries.add(
                        LogEntry(
                            obj.getLong("timestamp"),
                            if (obj.has("sessionId")) obj.getInt("sessionId") else null,
                            obj.getString("level"),
                            obj.getString("message")
                        )
                    )
                }
                
                while (logEntries.size > MAX_LOGS) {
                    logEntries.removeAt(0)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error loading logs from file: ${e.message}", e)
        }
    }
    
    private fun saveLogsToFile() {
        try {
            val jsonArray = JSONArray()
            logEntries.forEach { entry ->
                val obj = JSONObject().apply {
                    put("timestamp", entry.timestamp)
                    entry.sessionId?.let { put("sessionId", it) }
                    put("level", entry.level)
                    put("message", entry.message)
                }
                jsonArray.put(obj)
            }
            
            val logFile = File(context.filesDir, LOG_FILE_NAME)
            logFile.writeText(jsonArray.toString())
        } catch (e: Exception) {
            Log.e(TAG, "Error saving logs to file: ${e.message}", e)
        }
    }
    
    fun startSession(name: String): Int {
        val sessionId = sessionIdCounter.incrementAndGet()
        val session = LogSession(
            id = sessionId,
            name = name,
            startTime = System.currentTimeMillis()
        )
        
        synchronized(activeSessions) {
            activeSessions[sessionId] = session
        }
        
        logInfo("Session started: $name", sessionId)
        return sessionId
    }
    
    fun endSession(sessionId: Int, success: Boolean) {
        synchronized(activeSessions) {
            activeSessions[sessionId]?.let { session ->
                session.endTime = System.currentTimeMillis()
                logInfo("Session ended with ${if (success) "success" else "failure"}: ${session.name}", sessionId)
            }
        }
    }
    
    fun logInfo(message: String, sessionId: Int? = null) {
        addLogEntry("INFO", message, sessionId)
    }
    
    fun logError(message: String, throwable: Throwable? = null, sessionId: Int? = null) {
        val fullMessage = if (throwable != null) "$message: ${throwable.message}" else message
        addLogEntry("ERROR", fullMessage, sessionId)
    }
    
    fun logWarning(message: String, sessionId: Int? = null) {
        addLogEntry("WARNING", message, sessionId)
    }
    
    fun logDebug(message: String, sessionId: Int? = null) {
        addLogEntry("DEBUG", message, sessionId)
    }
    
    private fun addLogEntry(level: String, message: String, sessionId: Int? = null) {
        val entry = LogEntry(
            timestamp = System.currentTimeMillis(),
            sessionId = sessionId,
            level = level,
            message = message
        )
        
        logEntries.add(entry)
        
        if (sessionId != null) {
            synchronized(activeSessions) {
                activeSessions[sessionId]?.logs?.add(entry)
            }
        }
        
        while (logEntries.size > MAX_LOGS) {
            logEntries.removeAt(0)
        }
        
        when (level) {
            "INFO" -> Log.i(TAG, message)
            "ERROR" -> Log.e(TAG, message)
            "WARNING" -> Log.w(TAG, message)
            "DEBUG" -> Log.d(TAG, message)
        }
        
        saveLogsToFile()
    }
    
    fun getLogsAsJson(): String {
        val result = JSONObject()
        val logsArray = JSONArray()
        
        logEntries.forEach { entry ->
            logsArray.put(JSONObject().apply {
                put("timestamp", entry.timestamp)
                put("datetime", formatTimestamp(entry.timestamp))
                entry.sessionId?.let { put("sessionId", it) }
                put("level", entry.level)
                put("message", entry.message)
            })
        }
        
        result.put("logs", logsArray)
        
        val sessionsArray = JSONArray()
        synchronized(activeSessions) {
            activeSessions.values.forEach { session ->
                sessionsArray.put(JSONObject().apply {
                    put("id", session.id)
                    put("name", session.name)
                    put("startTime", session.startTime)
                    put("startDateTime", formatTimestamp(session.startTime))
                    session.endTime?.let { 
                        put("endTime", it)
                        put("endDateTime", formatTimestamp(it))
                        put("durationMs", it - session.startTime)
                    }
                })
            }
        }
        
        result.put("sessions", sessionsArray)
        return result.toString()
    }
    
    private fun formatTimestamp(timestamp: Long): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)
        return sdf.format(Date(timestamp))
    }
    
    fun clearLogs() {
        logEntries.clear()
        saveLogsToFile()
    }
} 