package net.mrcyjanek.flutter_daemon

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger

class FileLogger private constructor(private val context: Context) {
    companion object {
        private const val TAG = "FlutterDaemon"
        private const val LOG_FILE_NAME = "flutter_daemon_logs.jsonl"
        private const val SESSIONS_FILE_NAME = "flutter_daemon_sessions.json"
        private const val LEGACY_LOG_FILE_NAME = "flutter_daemon_logs.json"
        private const val MAX_LOGS = 1000

        @Volatile
        private var instance: FileLogger? = null

        fun getInstance(context: Context): FileLogger {
            return instance ?: synchronized(this) {
                instance ?: FileLogger(context.applicationContext).also { instance = it }
            }
        }
    }

    private val ioLock = Any()
    private val logEntries = mutableListOf<LogEntry>()
    private val sessionIdCounter = AtomicInteger(0)
    private val sessions = linkedMapOf<Int, LogSession>()

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
        var endTime: Long? = null
    )

    init {
        synchronized(ioLock) {
            loadSessionsLocked()
            loadLogsLocked()
        }
    }

    private fun logFile(): File = File(context.filesDir, LOG_FILE_NAME)

    private fun sessionsFile(): File = File(context.filesDir, SESSIONS_FILE_NAME)

    private fun legacyLogFile(): File = File(context.filesDir, LEGACY_LOG_FILE_NAME)

    private fun loadSessionsLocked() {
        val file = sessionsFile()
        if (!file.exists()) return
        try {
            val root = JSONObject(file.readText())
            var maxId = root.optInt("nextSessionId", 0)
            val sessionsArray = root.optJSONArray("sessions") ?: JSONArray()
            for (i in 0 until sessionsArray.length()) {
                val obj = sessionsArray.getJSONObject(i)
                val id = obj.getInt("id")
                if (id > maxId) maxId = id
                sessions[id] = LogSession(
                    id = id,
                    name = obj.getString("name"),
                    startTime = obj.getLong("startTime"),
                    endTime = if (obj.has("endTime") && !obj.isNull("endTime")) obj.getLong("endTime") else null
                )
            }
            sessionIdCounter.set(maxId)
        } catch (e: Exception) {
            Log.e(TAG, "Error loading sessions from file: ${e.message}", e)
        }
    }

    private fun loadLogsLocked() {
        val file = logFile()
        if (file.exists()) {
            try {
                file.forEachLine { line ->
                    val trimmed = line.trim()
                    if (trimmed.isEmpty()) return@forEachLine
                    try {
                        logEntries.add(parseEntry(JSONObject(trimmed)))
                    } catch (e: Exception) {
                        Log.e(TAG, "Skipping malformed log line: ${e.message}")
                    }
                }
                if (logEntries.size > MAX_LOGS) {
                    val kept = logEntries.takeLast(MAX_LOGS)
                    logEntries.clear()
                    logEntries.addAll(kept)
                    rewriteLogsLocked()
                }
                if (legacyLogFile().exists() && !legacyLogFile().delete()) {
                    Log.w(TAG, "Failed to delete legacy log file")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error loading logs from file: ${e.message}", e)
            }
            return
        }
        migrateLegacyLogsLocked()
    }

    private fun migrateLegacyLogsLocked() {
        val legacy = legacyLogFile()
        if (!legacy.exists()) return
        try {
            val jsonArray = JSONArray(legacy.readText())
            val imported = mutableListOf<LogEntry>()
            for (i in 0 until jsonArray.length()) {
                imported.add(parseEntry(jsonArray.getJSONObject(i)))
            }
            val kept = if (imported.size > MAX_LOGS) imported.takeLast(MAX_LOGS) else imported
            logEntries.clear()
            logEntries.addAll(kept)
            rewriteLogsLocked()
            if (!legacy.delete()) {
                Log.w(TAG, "Failed to delete legacy log file")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error migrating legacy logs: ${e.message}", e)
        }
    }

    private fun saveSessionsLocked() {
        try {
            val sessionsArray = JSONArray()
            sessions.values.sortedBy { it.id }.forEach { session ->
                sessionsArray.put(JSONObject().apply {
                    put("id", session.id)
                    put("name", session.name)
                    put("startTime", session.startTime)
                    session.endTime?.let { put("endTime", it) }
                })
            }
            val root = JSONObject().apply {
                put("nextSessionId", sessionIdCounter.get())
                put("sessions", sessionsArray)
            }
            writeAtomic(sessionsFile(), root.toString())
        } catch (e: Exception) {
            Log.e(TAG, "Error saving sessions to file: ${e.message}", e)
        }
    }

    private fun appendLogLocked(entry: LogEntry) {
        logFile().appendText(entryToJson(entry).toString() + "\n")
    }

    private fun rewriteLogsLocked() {
        val tmp = File(context.filesDir, "$LOG_FILE_NAME.tmp")
        tmp.bufferedWriter().use { writer ->
            for (entry in logEntries) {
                writer.write(entryToJson(entry).toString())
                writer.newLine()
            }
        }
        replaceFile(logFile(), tmp)
    }

    private fun writeAtomic(target: File, contents: String) {
        val tmp = File(context.filesDir, "${target.name}.tmp")
        tmp.writeText(contents)
        replaceFile(target, tmp)
    }

    private fun replaceFile(target: File, tmp: File) {
        if (target.exists() && !target.delete()) {
            throw IOException("Failed to replace ${target.name}")
        }
        if (!tmp.renameTo(target)) {
            tmp.copyTo(target, overwrite = true)
            if (!tmp.delete()) {
                Log.w(TAG, "Failed to delete temp file ${tmp.name}")
            }
        }
    }

    private fun parseEntry(obj: JSONObject): LogEntry {
        return LogEntry(
            timestamp = obj.getLong("timestamp"),
            sessionId = if (obj.has("sessionId") && !obj.isNull("sessionId")) obj.getInt("sessionId") else null,
            level = obj.getString("level"),
            message = obj.getString("message")
        )
    }

    private fun entryToJson(entry: LogEntry): JSONObject {
        return JSONObject().apply {
            put("timestamp", entry.timestamp)
            entry.sessionId?.let { put("sessionId", it) }
            put("level", entry.level)
            put("message", entry.message)
        }
    }

    fun startSession(name: String): Int {
        val sessionId = synchronized(ioLock) {
            val id = sessionIdCounter.incrementAndGet()
            sessions[id] = LogSession(
                id = id,
                name = name,
                startTime = System.currentTimeMillis()
            )
            saveSessionsLocked()
            id
        }
        logInfo("Session started: $name", sessionId)
        return sessionId
    }

    fun endSession(sessionId: Int, success: Boolean) {
        val name = synchronized(ioLock) {
            val session = sessions[sessionId] ?: return@synchronized null
            session.endTime = System.currentTimeMillis()
            saveSessionsLocked()
            session.name
        } ?: return
        logInfo(
            "Session ended with ${if (success) "success" else "failure"}: $name",
            sessionId
        )
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

        when (level) {
            "INFO" -> Log.i(TAG, message)
            "ERROR" -> Log.e(TAG, message)
            "WARNING" -> Log.w(TAG, message)
            "DEBUG" -> Log.d(TAG, message)
        }

        synchronized(ioLock) {
            logEntries.add(entry)
            try {
                if (logEntries.size > MAX_LOGS) {
                    val kept = logEntries.takeLast(MAX_LOGS)
                    logEntries.clear()
                    logEntries.addAll(kept)
                    rewriteLogsLocked()
                } else {
                    appendLogLocked(entry)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error saving logs to file: ${e.message}", e)
            }
        }
    }

    fun getLogsAsJson(): String {
        synchronized(ioLock) {
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
            sessions.values.sortedBy { it.id }.forEach { session ->
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

            result.put("sessions", sessionsArray)
            return result.toString()
        }
    }

    private fun formatTimestamp(timestamp: Long): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)
        return sdf.format(Date(timestamp))
    }

    fun clearLogs() {
        synchronized(ioLock) {
            logEntries.clear()
            sessions.clear()
            try {
                logFile().writeText("")
            } catch (e: Exception) {
                Log.e(TAG, "Error clearing log file: ${e.message}", e)
            }
            saveSessionsLocked()
        }
    }
}
