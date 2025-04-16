import 'dart:convert';
import 'package:flutter_daemon/flutter_daemon.dart';

class LogEntry {
  final DateTime timestamp;
  final String level;
  final String message;
  final int? sessionId;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.sessionId,
  });

  factory LogEntry.fromJson(Map<String, dynamic> json) {
    return LogEntry(
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp']),
      level: json['level'],
      message: json['message'],
      sessionId: json['sessionId'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp.millisecondsSinceEpoch,
      'timestampFormatted': timestamp.toString(),
      'level': level,
      'message': message,
      if (sessionId != null) 'sessionId': sessionId,
    };
  }
}

class LogSession {
  final int id;
  final String name;
  final DateTime startTime;
  final DateTime? endTime;
  final Duration? duration;
  
  LogSession({
    required this.id,
    required this.name,
    required this.startTime,
    this.endTime,
    this.duration,
  });
  
  factory LogSession.fromJson(Map<String, dynamic> json) {
    return LogSession(
      id: json['id'],
      name: json['name'],
      startTime: DateTime.fromMillisecondsSinceEpoch(json['startTime']),
      endTime: json['endTime'] != null ? 
        DateTime.fromMillisecondsSinceEpoch(json['endTime']) : null,
      duration: json['durationMs'] != null ? 
        Duration(milliseconds: json['durationMs']) : null,
    );
  }
  
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'startTime': startTime.millisecondsSinceEpoch,
      'startTimeFormatted': startTime.toString(),
      if (endTime != null) 'endTime': endTime!.millisecondsSinceEpoch,
      if (endTime != null) 'endTimeFormatted': endTime.toString(),
      if (duration != null) 'durationMs': duration!.inMilliseconds,
      if (duration != null) 'durationFormatted': _formatDuration(duration!),
    };
  }
  
  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return '${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds';
  }
}

class LogData {
  final List<LogEntry> logs;
  final List<LogSession> sessions;
  
  LogData({
    required this.logs,
    required this.sessions,
  });
  
  factory LogData.fromJson(Map<String, dynamic> json) {
    final logs = (json['logs'] as List)
        .map((e) => LogEntry.fromJson(e as Map<String, dynamic>))
        .toList();
        
    final sessions = (json['sessions'] as List)
        .map((e) => LogSession.fromJson(e as Map<String, dynamic>))
        .toList();
        
    return LogData(logs: logs, sessions: sessions);
  }
  
  Map<String, dynamic> toJson() {
    return {
      'logs': logs.map((e) => e.toJson()).toList(),
      'sessions': sessions.map((e) => e.toJson()).toList(),
    };
  }
}