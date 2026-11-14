#ifndef FLUTTER_DAEMON_BACKGROUND_RUNNER_H_
#define FLUTTER_DAEMON_BACKGROUND_RUNNER_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_engine.h>
#include <flutter/plugin_registry.h>

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <dirent.h>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

#include "flutter_daemon_plugin.h"
#include "host_path.h"

// Call this at the start of main(), before the embedder parses arguments:
//
//   if (FlutterDaemonRunBackground(argc, argv, RegisterPlugins)) return 0;
//
// Returns non-zero when this process was started with --background-sync or
// --uninstall-background-sync and the call handled it. Returns 0 for a normal
// GUI launch, after recording that the hook ran. --uninstall-background-sync
// runs the uninstallBackgroundSync Dart entrypoint, which calls
// stopBackgroundSync.

using FlutterDaemonRegisterPlugins = void (*)(flutter::PluginRegistry*);

namespace flutter_daemon_internal {

inline std::wstring Widen(const std::string& path) {
  return std::wstring(path.begin(), path.end());
}

inline std::string BundlePath(int argc, char** argv) {
  std::vector<std::string> args;
  args.reserve(static_cast<size_t>(argc));
  for (int i = 0; i < argc; ++i) {
    args.emplace_back(argv[i]);
  }
  return flutter_daemon::AbsolutePath(flutter_daemon::BundleFromArguments(args));
}

inline bool HasArgument(int argc, char** argv, const char* flag) {
  for (int i = 1; i < argc; ++i) {
    if (std::string(argv[i]) == flag) {
      return true;
    }
  }
  return false;
}

inline bool IsBackgroundInvocation(int argc, char** argv) {
  return HasArgument(argc, argv, "--background-sync");
}

inline bool IsUninstallInvocation(int argc, char** argv) {
  return HasArgument(argc, argv, "--uninstall-background-sync");
}

inline bool CmdlineRequestsBackgroundSync(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    return false;
  }
  const std::string data((std::istreambuf_iterator<char>(in)),
                         std::istreambuf_iterator<char>());
  return data.find("--background-sync") != std::string::npos;
}

// The GUI and the sync process are the same executable. A GUI process has
// this exe and does not pass --background-sync.
inline bool GuiProcessIsRunning() {
  const std::string self_exe = flutter_daemon::ReadLink("/proc/self/exe");
  if (self_exe.empty()) {
    return false;
  }
  const pid_t self_pid = ::getpid();
  DIR* directory = ::opendir("/proc");
  if (directory == nullptr) {
    return false;
  }
  bool found = false;
  while (const dirent* entry = ::readdir(directory)) {
    if (entry->d_name[0] < '1' || entry->d_name[0] > '9') {
      continue;
    }
    char* end = nullptr;
    const long pid = std::strtol(entry->d_name, &end, 10);
    if (end == entry->d_name || *end != '\0' || pid == self_pid) {
      continue;
    }
    const std::string proc = std::string("/proc/") + entry->d_name;
    if (flutter_daemon::ReadLink(proc + "/exe") != self_exe) {
      continue;
    }
    if (CmdlineRequestsBackgroundSync(proc + "/cmdline")) {
      continue;
    }
    found = true;
    break;
  }
  ::closedir(directory);
  return found;
}

template <typename Process, typename Dispatch>
bool PumpUntilFinished(Process process, Dispatch dispatch) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::minutes(10);
  while (!FlutterDaemonBackgroundSyncFinished()) {
    if (std::chrono::steady_clock::now() >= deadline) {
      std::cerr << "flutter_daemon: timed out waiting for backgroundSyncComplete"
                << std::endl;
      return false;
    }
    if (!dispatch()) {
      std::cerr << "flutter_daemon: background view closed" << std::endl;
      return false;
    }
    const auto wait = process();
    const auto cap = std::chrono::milliseconds(50);
    auto slice = wait > cap ? cap
                            : std::chrono::duration_cast<std::chrono::milliseconds>(wait);
    if (slice.count() < 1) {
      slice = std::chrono::milliseconds(1);
    }
    std::this_thread::sleep_for(slice);
  }
  return true;
}

class EngineRegistry : public flutter::PluginRegistry {
 public:
  explicit EngineRegistry(FlutterDesktopEngineRef engine) : engine_(engine) {}

  FlutterDesktopPluginRegistrarRef GetRegistrarForPlugin(
      const std::string& plugin_name) override {
    return FlutterDesktopEngineGetPluginRegistrar(engine_, plugin_name.c_str());
  }

 private:
  FlutterDesktopEngineRef engine_;
};

inline bool RunHeadless(const std::wstring& bundle,
                        FlutterDaemonRegisterPlugins register_plugins,
                        const char* entrypoint) {
  flutter::DartProject project(bundle);
  flutter::FlutterEngine engine(project);
  if (register_plugins != nullptr) {
    register_plugins(&engine);
  }
  if (!engine.Run(entrypoint)) {
    std::cerr << "flutter_daemon: headless FlutterEngine::Run failed for "
              << entrypoint << std::endl;
    return false;
  }
  std::cerr << "flutter_daemon: running " << entrypoint << std::endl;
  PumpUntilFinished([&engine]() { return engine.ProcessMessages(); },
                    []() { return true; });
  engine.ShutDown();
  return true;
}

inline bool RunTinyView(const std::wstring& bundle,
                        FlutterDaemonRegisterPlugins register_plugins) {
  const std::wstring assets = bundle + L"/data/flutter_assets";
  const std::wstring icu = bundle + L"/data/icudtl.dat";
  const std::wstring aot = bundle + L"/lib/libapp.so";

  FlutterDesktopEngineProperties properties = {};
  properties.assets_path = assets.c_str();
  properties.icu_data_path = icu.c_str();
  properties.aot_library_path = aot.c_str();
  properties.dart_entrypoint_argc = 0;
  properties.dart_entrypoint_argv = nullptr;

  FlutterDesktopEngineRef engine = FlutterDesktopEngineCreate(&properties);
  if (engine == nullptr) {
    std::cerr << "flutter_daemon: failed to create fallback engine" << std::endl;
    return false;
  }

  EngineRegistry registry(engine);
  if (register_plugins != nullptr) {
    register_plugins(&registry);
  }
  if (!FlutterDesktopEngineRun(engine, "backgroundSync")) {
    std::cerr << "flutter_daemon: fallback engine failed to run backgroundSync"
              << std::endl;
    FlutterDesktopEngineDestroy(engine);
    return false;
  }

  FlutterDesktopViewProperties view = {};
  view.width = 1;
  view.height = 1;
  view.view_rotation = kRotation_0;
  view.view_mode = kNormalscreen;
  view.title = "flutter_daemon";
  view.app_id = "flutter_daemon";
  view.use_mouse_cursor = false;
  view.use_onscreen_keyboard = false;
  view.use_window_decoration = false;
  view.text_scale_factor = 1.0;
  view.enable_high_contrast = false;
  view.force_scale_factor = false;
  view.scale_factor = 1.0;
  view.enable_vsync = true;

  FlutterDesktopViewControllerRef controller =
      FlutterDesktopViewControllerCreate(&view, engine);
  if (controller == nullptr) {
    std::cerr << "flutter_daemon: failed to create fallback view" << std::endl;
    return false;
  }

  std::cerr << "flutter_daemon: running backgroundSync in a 1x1 view"
            << std::endl;
  FlutterDesktopViewRef view_ref = FlutterDesktopViewControllerGetView(controller);
  FlutterDesktopEngineRef running =
      FlutterDesktopViewControllerGetEngine(controller);
  PumpUntilFinished(
      [running]() {
        const uint64_t wait_ns = FlutterDesktopEngineProcessMessages(running);
        constexpr uint64_t kCapNs = 50ULL * 1000ULL * 1000ULL;
        if (wait_ns > kCapNs) {
          return std::chrono::nanoseconds(static_cast<int64_t>(kCapNs));
        }
        return std::chrono::nanoseconds(static_cast<int64_t>(wait_ns));
      },
      [view_ref]() { return FlutterDesktopViewDispatchEvent(view_ref); });
  FlutterDesktopViewControllerDestroy(controller);
  return true;
}

}  // namespace flutter_daemon_internal

inline int FlutterDaemonRunBackground(int argc, char** argv,
                                      FlutterDaemonRegisterPlugins register_plugins) {
  FlutterDaemonMarkRunnerHook();
  if (flutter_daemon_internal::IsUninstallInvocation(argc, argv)) {
    FlutterDaemonResetBackgroundSyncFinished();
    const std::wstring bundle = flutter_daemon_internal::Widen(
        flutter_daemon_internal::BundlePath(argc, argv));
    flutter_daemon_internal::RunHeadless(bundle, register_plugins,
                                         "uninstallBackgroundSync");
    return 1;
  }
  if (!flutter_daemon_internal::IsBackgroundInvocation(argc, argv)) {
    return 0;
  }

  FlutterDaemonResetBackgroundSyncFinished();
  if (flutter_daemon_internal::GuiProcessIsRunning()) {
    std::cerr << "flutter_daemon: app is in the foreground, skipping background sync"
              << std::endl;
    return 1;
  }
  const std::wstring bundle =
      flutter_daemon_internal::Widen(flutter_daemon_internal::BundlePath(argc, argv));
  if (flutter_daemon_internal::RunHeadless(bundle, register_plugins,
                                           "backgroundSync")) {
    return 1;
  }
  std::cerr << "flutter_daemon: retrying backgroundSync with a 1x1 view"
            << std::endl;
  flutter_daemon_internal::RunTinyView(bundle, register_plugins);
  return 1;
}

#endif  // FLUTTER_DAEMON_BACKGROUND_RUNNER_H_
