import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

const _hookMissing =
    'flutter_daemon: add `if (FlutterDaemonRunBackground(argc, argv, '
    'RegisterPlugins)) return 0;` at the start of main()';

class ElinuxBackgroundSync {
  ElinuxBackgroundSync(this._channel);

  final MethodChannel _channel;

  Future<String> start(int intervalMinutes) async {
    if (!await _hookInstalled()) {
      throw _syncError(_hookMissing);
    }
    if (intervalMinutes < 1) {
      throw _syncError('intervalMinutes must be at least 1');
    }

    final executable = _executable();
    final bundle = _bundle();
    final libraries = Platform.environment['LD_LIBRARY_PATH'] ?? '';
    _ensureDir(_unitDir);
    _ensureDir(_confDir);
    _write(_servicePath, _serviceUnit(executable, bundle, libraries));
    _write(_timerPath, _timerUnit(intervalMinutes));
    _write(_confPath, 'interval_minutes=$intervalMinutes\n');

    try {
      await _systemctl(['daemon-reload']);
      await _systemctl(['enable', '--now', '$_appId.timer']);
    } catch (_) {
      _delete(_servicePath);
      _delete(_timerPath);
      _delete(_confPath);
      try {
        await _systemctl(['daemon-reload']);
      } catch (_) {}
      rethrow;
    }
    return 'Background sync scheduled every $intervalMinutes minutes.';
  }

  Future<String> stop() async {
    await _systemctl(['disable', '--now', '$_appId.timer'],
        ignoreFailure: true);
    await _systemctl(['stop', '$_appId.service'], ignoreFailure: true);
    _delete(_servicePath);
    _delete(_timerPath);
    _delete(_confPath);
    await _systemctl(['daemon-reload']);
    return 'Background sync stopped successfully.';
  }

  Future<bool> status() async {
    return await _succeeded(['is-enabled', '$_appId.timer']) ||
        await _succeeded(['is-active', '$_appId.service']);
  }

  Future<int?> interval() async {
    if (!await _succeeded(['is-enabled', '$_appId.timer'])) return null;
    try {
      for (final line in File(_confPath).readAsLinesSync()) {
        const key = 'interval_minutes=';
        if (!line.startsWith(key)) continue;
        return int.parse(line.substring(key.length));
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _hookInstalled() async {
    return await _channel.invokeMethod<bool>('runnerHookInstalled') == true;
  }

  String _executable() {
    try {
      final executable = Platform.resolvedExecutable;
      if (executable.isNotEmpty) return executable;
    } catch (_) {}
    throw _syncError('failed to resolve /proc/self/exe');
  }

  String get _appId {
    final name = _executable().split('/').last;
    final sanitized = name.replaceAll(RegExp(r'[^A-Za-z0-9:_.-]'), '-');
    return sanitized.isEmpty ? 'flutter-daemon' : sanitized;
  }

  String get _home {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw _syncError('HOME is not set');
    }
    return home;
  }

  String get _unitDir => p.join(_home, '.config', 'systemd', 'user');

  String get _confDir => p.join(_home, '.config', _appId);

  String get _confPath => p.join(_confDir, 'flutter_daemon.conf');

  String get _servicePath => p.join(_unitDir, '$_appId.service');

  String get _timerPath => p.join(_unitDir, '$_appId.timer');

  String _bundle() {
    final args = _cmdline();
    const prefix = '--bundle=';
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg.startsWith(prefix)) {
        return _absolute(arg.substring(prefix.length));
      }
      if ((arg == '--bundle' || arg == '-b') && i + 1 < args.length) {
        return _absolute(args[i + 1]);
      }
    }
    return _absolute('./bundle');
  }

  List<String> _cmdline() {
    try {
      return utf8
          .decode(
            File('/proc/self/cmdline').readAsBytesSync(),
            allowMalformed: true,
          )
          .split('\x00')
          .where((arg) => arg.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  String _absolute(String path) {
    try {
      return File(path).resolveSymbolicLinksSync();
    } catch (_) {
      return path;
    }
  }

  String _serviceUnit(String executable, String bundle, String libraries) {
    final environment = libraries.isEmpty
        ? ''
        : 'Environment="LD_LIBRARY_PATH=${_escape(libraries)}"\n';
    return '[Unit]\n'
        'Description=Background sync for $_appId\n'
        '\n'
        '[Service]\n'
        'Type=oneshot\n'
        '$environment'
        'ExecStart=${_word(executable)} --bundle=${_word(bundle)} --background-sync\n'
        'TimeoutStartSec=600\n'
        'Nice=10\n';
  }

  String _timerUnit(int intervalMinutes) {
    return '[Unit]\n'
        'Description=Background sync timer for $_appId\n'
        '\n'
        '[Timer]\n'
        'OnActiveSec=10s\n'
        'OnUnitActiveSec=${intervalMinutes}min\n'
        'AccuracySec=30s\n'
        'Persistent=true\n'
        'Unit=$_appId.service\n'
        '\n'
        '[Install]\n'
        'WantedBy=timers.target\n';
  }

  String _escape(String value) {
    final out = StringBuffer();
    for (final char in value.split('')) {
      if (char == '\n' || char == '\r') continue;
      if (char == '"' || char == r'\') out.write(r'\');
      out.write(char);
    }
    return out.toString();
  }

  String _word(String value) {
    if (!RegExp(r'''[ \t"\\]''').hasMatch(value)) return value;
    return '"${_escape(value)}"';
  }

  void _ensureDir(String path) {
    try {
      Directory(path).createSync(recursive: true);
    } catch (_) {
      throw _syncError('failed to create systemd config directories');
    }
  }

  void _write(String path, String contents) {
    try {
      File(path).writeAsStringSync(contents);
    } catch (_) {
      throw _syncError('failed to write $path');
    }
  }

  void _delete(String path) {
    try {
      File(path).deleteSync();
    } catch (_) {}
  }

  Future<void> _systemctl(List<String> args,
      {bool ignoreFailure = false}) async {
    try {
      final result =
          await Process.run('/usr/bin/systemctl', ['--user', ...args]);
      if (result.exitCode == 0 || ignoreFailure) return;
      final output = '${result.stdout}${result.stderr}';
      throw _syncError(output.isEmpty ? 'systemctl failed' : output);
    } on ProcessException catch (error) {
      if (ignoreFailure) return;
      throw _syncError(error.message);
    }
  }

  Future<bool> _succeeded(List<String> args) async {
    try {
      final result =
          await Process.run('/usr/bin/systemctl', ['--user', ...args]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  PlatformException _syncError(String message) {
    return PlatformException(code: 'BACKGROUND_SYNC_ERROR', message: message);
  }
}
