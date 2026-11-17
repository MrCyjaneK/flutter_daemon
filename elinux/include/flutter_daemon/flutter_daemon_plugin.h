#ifndef FLUTTER_PLUGIN_FLUTTER_DAEMON_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_DAEMON_PLUGIN_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

#if defined(__cplusplus)
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void FlutterDaemonPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

// Set from FlutterDaemonRunBackground. startBackgroundSync refuses to install
// a unit until main() has called that hook.
FLUTTER_PLUGIN_EXPORT void FlutterDaemonMarkRunnerHook(void);
FLUTTER_PLUGIN_EXPORT int FlutterDaemonRunnerHookInstalled(void);

// Set when the background isolate calls backgroundSyncComplete.
FLUTTER_PLUGIN_EXPORT void FlutterDaemonMarkBackgroundSyncFinished(void);
FLUTTER_PLUGIN_EXPORT int FlutterDaemonBackgroundSyncFinished(void);
FLUTTER_PLUGIN_EXPORT void FlutterDaemonResetBackgroundSyncFinished(void);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_FLUTTER_DAEMON_PLUGIN_H_
