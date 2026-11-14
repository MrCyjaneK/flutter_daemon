import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
  BackgroundSyncLock({required Future<void> Function() signalComplete})
      : _signalComplete = signalComplete;

  final Future<void> Function() _signalComplete;

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
    _startHeartbeat(statFile.path);
    return false;
  }

  Future<void> release() async {
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
    unawaited(Isolate.run(() async {
      final file = File(statPath);
      final handle = file.openSync(mode: FileMode.writeOnly);
      try {
        while (file.existsSync()) {
          final bytes = utf8.encode(DateTime.now().toIso8601String());
          handle.setPositionSync(0);
          handle.writeFromSync(bytes);
          handle.truncateSync(bytes.length);
          handle.flushSync();
          await Future<void>.delayed(_heartbeatInterval);
        }
      } catch (e) {
        _log('heartbeat stopped: $e');
      } finally {
        handle.closeSync();
      }
    }));
  }
}

void _log(String message) {
  if (kDebugMode) {
    debugPrint('flutter_daemon: $message');
  }
}
