#!/bin/sh
export LD_LIBRARY_PATH=/usr/share/flutter-daemon/lib:/usr/lib64/flutter-sfos/3.44.0
exec /usr/share/flutter-daemon/flutter_daemon_example --bundle=/usr/share/flutter-daemon --fullscreen --onscreen-keyboard --title="Flutter Daemon"
