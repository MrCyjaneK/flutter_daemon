#ifndef FLUTTER_DAEMON_BACKGROUND_RUNNER_H_
#define FLUTTER_DAEMON_BACKGROUND_RUNNER_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_engine.h>
#include <flutter/plugin_registry.h>

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>

#include "flutter_daemon_plugin.h"

// Call this at the start of main(), before the embedder parses arguments:
//
//   if (FlutterDaemonRunBackground(argc, argv, RegisterPlugins)) return 0;
//
// Returns non-zero when this process was started with --background-sync and
// the call handled it. Returns 0 for a normal GUI launch, after recording that
// the hook ran.

using FlutterDaemonRegisterPlugins = void (*)(flutter::PluginRegistry*);

namespace flutter_daemon_internal {

inline std::wstring Widen(const std::string& path) {
  return std::wstring(path.begin(), path.end());
}

inline std::string AbsolutePath(const std::string& path) {
  char* resolved = realpath(path.c_str(), nullptr);
  if (resolved == nullptr) {
    return path;
  }
  std::string absolute(resolved);
  free(resolved);
  return absolute;
}

inline std::string BundlePath(int argc, char** argv) {
  for (int i = 1; i < argc; ++i) {
    const std::string arg(argv[i]);
    const std::string prefix = "--bundle=";
    if (arg.compare(0, prefix.size(), prefix) == 0) {
      return AbsolutePath(arg.substr(prefix.size()));
    }
    if ((arg == "--bundle" || arg == "-b") && i + 1 < argc) {
      return AbsolutePath(argv[i + 1]);
    }
  }
  return AbsolutePath("./bundle");
}

inline bool IsBackgroundInvocation(int argc, char** argv) {
  for (int i = 1; i < argc; ++i) {
    if (std::string(argv[i]) == "--background-sync") {
      return true;
    }
  }
  return false;
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
                        FlutterDaemonRegisterPlugins register_plugins) {
  flutter::DartProject project(bundle);
  flutter::FlutterEngine engine(project);
  if (register_plugins != nullptr) {
    register_plugins(&engine);
  }
  if (!engine.Run("backgroundSync")) {
    std::cerr << "flutter_daemon: headless FlutterEngine::Run failed"
              << std::endl;
    return false;
  }
  std::cerr << "flutter_daemon: running backgroundSync" << std::endl;
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
  if (!flutter_daemon_internal::IsBackgroundInvocation(argc, argv)) {
    return 0;
  }

  FlutterDaemonResetBackgroundSyncFinished();
  const std::wstring bundle =
      flutter_daemon_internal::Widen(flutter_daemon_internal::BundlePath(argc, argv));
  if (flutter_daemon_internal::RunHeadless(bundle, register_plugins)) {
    return 1;
  }
  std::cerr << "flutter_daemon: retrying backgroundSync with a 1x1 view"
            << std::endl;
  flutter_daemon_internal::RunTinyView(bundle, register_plugins);
  return 1;
}

#endif  // FLUTTER_DAEMON_BACKGROUND_RUNNER_H_
