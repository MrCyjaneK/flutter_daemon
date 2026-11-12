#include "include/flutter_daemon/flutter_daemon_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/standard_method_codec.h>

#include <map>
#include <memory>
#include <sstream>

namespace {

class FlutterDaemonPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrar *registrar);

  FlutterDaemonPlugin();

  virtual ~FlutterDaemonPlugin();

 private:
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

// static
void FlutterDaemonPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrar *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_daemon",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<FlutterDaemonPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

FlutterDaemonPlugin::FlutterDaemonPlugin() {}

FlutterDaemonPlugin::~FlutterDaemonPlugin() {}

void FlutterDaemonPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("getPlatformVersion") == 0) {
    std::ostringstream version_stream;
    version_stream << "eLinux";
    result->Success(flutter::EncodableValue(version_stream.str()));
  } else {
    result->NotImplemented();
  }
}

}  // namespace

void FlutterDaemonPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  FlutterDaemonPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrar>(registrar));
}
