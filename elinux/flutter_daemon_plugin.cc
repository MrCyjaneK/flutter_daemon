#include "include/flutter_daemon/flutter_daemon_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <memory>

namespace {

std::atomic<bool> g_runner_hook_installed{false};
std::atomic<bool> g_background_sync_finished{false};

class FlutterDaemonPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrar* registrar);

  virtual ~FlutterDaemonPlugin() = default;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

void FlutterDaemonPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrar* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_daemon",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<FlutterDaemonPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

void FlutterDaemonPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();
  if (method == "runnerHookInstalled") {
    result->Success(flutter::EncodableValue(FlutterDaemonRunnerHookInstalled() != 0));
    return;
  }
  if (method == "backgroundSyncComplete") {
    FlutterDaemonMarkBackgroundSyncFinished();
    result->Success();
    return;
  }
  result->NotImplemented();
}

}  // namespace

extern "C" void FlutterDaemonMarkRunnerHook(void) {
  g_runner_hook_installed.store(true);
}

extern "C" int FlutterDaemonRunnerHookInstalled(void) {
  return g_runner_hook_installed.load() ? 1 : 0;
}

extern "C" void FlutterDaemonMarkBackgroundSyncFinished(void) {
  g_background_sync_finished.store(true);
}

extern "C" int FlutterDaemonBackgroundSyncFinished(void) {
  return g_background_sync_finished.load() ? 1 : 0;
}

extern "C" void FlutterDaemonResetBackgroundSyncFinished(void) {
  g_background_sync_finished.store(false);
}

void FlutterDaemonPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  FlutterDaemonPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrar>(registrar));
}
