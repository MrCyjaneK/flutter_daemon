import Foundation

/// Persists the same log and session JSON that Android's FileLogger returns
/// from `getLogs`. Dart parses that string with `LogData.fromJson`.
final class FileLogger {
  static let shared = FileLogger()

  private static let maxLogs = 1000
  private static let logFileName = "flutter_daemon_logs.jsonl"
  private static let sessionsFileName = "flutter_daemon_sessions.json"

  private let lock = NSLock()
  private let directory: URL
  private var entries: [LogRecord] = []
  private var sessions: [Int: LogSession] = [:]
  private var nextSessionId = 0

  private struct LogRecord {
    let timestamp: Int64
    let sessionId: Int?
    let level: String
    let message: String
  }

  private struct LogSession {
    let id: Int
    let name: String
    let startTime: Int64
    var endTime: Int64?
  }

  private init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    directory = base.appendingPathComponent("flutter_daemon", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    lock.lock()
    loadSessions()
    loadLogs()
    lock.unlock()
  }

  func info(_ message: String, sessionId: Int? = nil) {
    add(level: "INFO", message: message, sessionId: sessionId)
  }

  func error(_ message: String, sessionId: Int? = nil) {
    add(level: "ERROR", message: message, sessionId: sessionId)
  }

  func startSession(_ name: String) -> Int {
    let id: Int = locked {
      nextSessionId += 1
      let sessionId = nextSessionId
      sessions[sessionId] = LogSession(
        id: sessionId,
        name: name,
        startTime: Self.nowMillis(),
        endTime: nil)
      saveSessions()
      return sessionId
    }
    info("Session started: \(name)", sessionId: id)
    return id
  }

  func endSession(_ sessionId: Int, success: Bool) {
    let name: String? = locked {
      guard var session = sessions[sessionId] else {
        return nil
      }
      session.endTime = Self.nowMillis()
      sessions[sessionId] = session
      saveSessions()
      return session.name
    }
    guard let name else {
      return
    }
    let outcome = success ? "success" : "failure"
    info("Session ended with \(outcome): \(name)", sessionId: sessionId)
  }

  func logsJSON() -> String {
    locked {
      var logs: [[String: Any]] = []
      for entry in entries {
        var object: [String: Any] = [
          "timestamp": NSNumber(value: entry.timestamp),
          "datetime": Self.format(entry.timestamp),
          "level": entry.level,
          "message": entry.message,
        ]
        if let sessionId = entry.sessionId {
          object["sessionId"] = sessionId
        }
        logs.append(object)
      }

      var sessionObjects: [[String: Any]] = []
      for session in sessions.values.sorted(by: { $0.id < $1.id }) {
        var object: [String: Any] = [
          "id": session.id,
          "name": session.name,
          "startTime": NSNumber(value: session.startTime),
          "startDateTime": Self.format(session.startTime),
        ]
        if let endTime = session.endTime {
          object["endTime"] = NSNumber(value: endTime)
          object["endDateTime"] = Self.format(endTime)
          object["durationMs"] = NSNumber(value: endTime - session.startTime)
        }
        sessionObjects.append(object)
      }

      let root: [String: Any] = [
        "logs": logs,
        "sessions": sessionObjects,
      ]
      guard let data = try? JSONSerialization.data(withJSONObject: root),
            let json = String(data: data, encoding: .utf8) else {
        return "{\"logs\":[],\"sessions\":[]}"
      }
      return json
    }
  }

  func clear() {
    locked {
      entries.removeAll()
      sessions.removeAll()
      let logFile = directory.appendingPathComponent(Self.logFileName)
      try? Data().write(to: logFile, options: .atomic)
      saveSessions()
    }
  }

  private func add(level: String, message: String, sessionId: Int?) {
    NSLog("FlutterDaemon %@: %@", level, message)
    let record = LogRecord(
      timestamp: Self.nowMillis(),
      sessionId: sessionId,
      level: level,
      message: message)
    locked {
      entries.append(record)
      if entries.count > Self.maxLogs {
        entries = Array(entries.suffix(Self.maxLogs))
        rewriteLogs()
      } else {
        append(record)
      }
    }
  }

  private func loadLogs() {
    let url = directory.appendingPathComponent(Self.logFileName)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      return
    }
    for line in text.split(whereSeparator: \.isNewline) {
      guard let data = String(line).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let timestamp = object["timestamp"] as? NSNumber,
            let level = object["level"] as? String,
            let message = object["message"] as? String else {
        continue
      }
      let sessionId = (object["sessionId"] as? NSNumber)?.intValue
      entries.append(LogRecord(
        timestamp: timestamp.int64Value,
        sessionId: sessionId,
        level: level,
        message: message))
    }
    if entries.count > Self.maxLogs {
      entries = Array(entries.suffix(Self.maxLogs))
      rewriteLogs()
    }
  }

  private func loadSessions() {
    let url = directory.appendingPathComponent(Self.sessionsFileName)
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return
    }
    var maxId = (root["nextSessionId"] as? NSNumber)?.intValue ?? 0
    let stored = root["sessions"] as? [[String: Any]] ?? []
    for object in stored {
      guard let id = (object["id"] as? NSNumber)?.intValue,
            let name = object["name"] as? String,
            let startTime = (object["startTime"] as? NSNumber)?.int64Value else {
        continue
      }
      if id > maxId {
        maxId = id
      }
      sessions[id] = LogSession(
        id: id,
        name: name,
        startTime: startTime,
        endTime: (object["endTime"] as? NSNumber)?.int64Value)
    }
    nextSessionId = maxId
  }

  private func saveSessions() {
    let stored: [[String: Any]] = sessions.values.sorted(by: { $0.id < $1.id }).map { session in
      var object: [String: Any] = [
        "id": session.id,
        "name": session.name,
        "startTime": NSNumber(value: session.startTime),
      ]
      if let endTime = session.endTime {
        object["endTime"] = NSNumber(value: endTime)
      }
      return object
    }
    let root: [String: Any] = [
      "nextSessionId": nextSessionId,
      "sessions": stored,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: root) else {
      return
    }
    let url = directory.appendingPathComponent(Self.sessionsFileName)
    try? data.write(to: url, options: .atomic)
  }

  private func append(_ record: LogRecord) {
    guard let line = jsonLine(record) else {
      return
    }
    let url = directory.appendingPathComponent(Self.logFileName)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else {
      return
    }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(line.utf8))
  }

  private func rewriteLogs() {
    let body = entries.compactMap { jsonLine($0) }.joined()
    let url = directory.appendingPathComponent(Self.logFileName)
    try? Data(body.utf8).write(to: url, options: .atomic)
  }

  private func jsonLine(_ record: LogRecord) -> String? {
    var object: [String: Any] = [
      "timestamp": NSNumber(value: record.timestamp),
      "level": record.level,
      "message": record.message,
    ]
    if let sessionId = record.sessionId {
      object["sessionId"] = sessionId
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let line = String(data: data, encoding: .utf8) else {
      return nil
    }
    return line + "\n"
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private static func nowMillis() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
  }

  private static func format(_ millis: Int64) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
  }
}
