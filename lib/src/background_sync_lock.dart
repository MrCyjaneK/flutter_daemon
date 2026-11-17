import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

const _lockDirName = 'flutter_daemon_background';
const _lockFileName = '__daemonfile';
const _pidFileName = '__daemonfile.pid';

/// The worker installs its completion handler just after launching this
/// entrypoint. Wait until that handler is in place before deciding the lock.
const _handlerSettleDelay = Duration(seconds: 1);
const _lockFreshness = Duration(minutes: 5);
const _heartbeatInterval = Duration(seconds: 1);

class BackgroundSyncLock {
  BackgroundSyncLock({
    required Future<void> Function() signalComplete,
    required Future<void> Function() scheduleShutdown,
  })  : _signalComplete = signalComplete,
        _scheduleShutdown = scheduleShutdown;

  final Future<void> Function() _signalComplete;
  final Future<void> Function() _scheduleShutdown;
  Timer? _heartbeat;
  bool _ownsLock = false;
  bool _finishing = false;

  final String _path = p.join(
    Directory.systemTemp.path,
    _lockDirName,
    _lockFileName,
  );
  final String _pidPath = p.join(
    Directory.systemTemp.path,
    _lockDirName,
    _pidFileName,
  );

  /// Returns true when another live sync already owns the lock.
  Future<bool> mark() async {
    await Future<void>.delayed(_handlerSettleDelay);

    final directory = Directory(p.dirname(_path));
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }

    if (_isLive()) {
      _log('background sync already running');
      return true;
    }

    _deleteFiles();
    final statFile = File(_path);
    statFile.writeAsStringSync(DateTime.now().toIso8601String());
    File(_pidPath).writeAsStringSync('$pid');
    _ownsLock = true;
    _startHeartbeat(statFile.path);
    return false;
  }

  /// Schedules engine teardown, then either releases the lock this instance
  /// acquired or only tells the worker this entrypoint is done.
  Future<void> finish() async {
    if (_finishing) return;
    _finishing = true;
    try {
      await _scheduleShutdown();
    } catch (e) {
      _log('failed to schedule background engine shutdown: $e');
    }
    if (_ownsLock) {
      _ownsLock = false;
      await release();
      return;
    }
    await _signalComplete();
  }

  Future<void> release() async {
    _ownsLock = false;
    _stopHeartbeat();
    _deleteFiles();
    await _signalComplete();
  }

  bool _isLive() {
    final statFile = File(_path);
    final pidFile = File(_pidPath);
    if (!statFile.existsSync() || !pidFile.existsSync()) return false;
    try {
      final owner = int.tryParse(pidFile.readAsStringSync().trim());
      if (owner == null || !_isPidAlive(owner)) return false;
      final lastTimestamp = DateTime.parse(statFile.readAsStringSync().trim());
      return DateTime.now().difference(lastTimestamp) < _lockFreshness;
    } catch (e) {
      _log('error reading background sync lock: $e');
      return false;
    }
  }

  bool _isPidAlive(int owner) {
    if (owner <= 0) return false;
    if (owner == pid) return true;
    return Directory('/proc/$owner').existsSync();
  }

  void _deleteFiles() {
    final statFile = File(_path);
    final pidFile = File(_pidPath);
    if (statFile.existsSync()) statFile.deleteSync();
    if (pidFile.existsSync()) pidFile.deleteSync();
  }

  void _startHeartbeat(String statPath) {
    _stopHeartbeat();
    final file = File(statPath);
    _heartbeat = Timer.periodic(_heartbeatInterval, (timer) {
      try {
        if (!file.existsSync()) {
          _loseLock(timer);
          return;
        }
        file.writeAsStringSync(DateTime.now().toIso8601String(), flush: true);
      } catch (e) {
        _log('heartbeat stopped: $e');
        if (!file.existsSync()) {
          _loseLock(timer);
          return;
        }
        timer.cancel();
        _heartbeat = null;
      }
    });
  }

  void _loseLock(Timer timer) {
    timer.cancel();
    _heartbeat = null;
    if (!_ownsLock) return;
    _log('background sync lock removed, destroying engine');
    unawaited(finish());
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }
}

void _log(String message) {
  if (kDebugMode) {
    debugPrint('flutter_daemon: $message');
  }
}
