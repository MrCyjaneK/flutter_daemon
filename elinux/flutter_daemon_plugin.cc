#include "include/flutter_daemon/flutter_daemon_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/standard_method_codec.h>

#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fstream>
#include <map>
#include <memory>
#include <pwd.h>
#include <sstream>
#include <string>
#include <vector>

#ifndef FLUTTER_DAEMON_APP_ID
#error "FLUTTER_DAEMON_APP_ID must be set from the application's BINARY_NAME"
#endif

namespace {

std::atomic<bool> g_runner_hook_installed{false};
std::atomic<bool> g_background_sync_finished{false};

constexpr char kHookMissing[] =
    "flutter_daemon: add `if (FlutterDaemonRunBackground(argc, argv, "
    "RegisterPlugins)) return 0;` at the start of main()";

std::string AppId() {
  std::string out;
  const std::string raw(FLUTTER_DAEMON_APP_ID);
  for (char c : raw) {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    (c >= '0' && c <= '9') || c == ':' || c == '_' ||
                    c == '.' || c == '-';
    out.push_back(ok ? c : '-');
  }
  if (out.empty()) {
    return "flutter-daemon";
  }
  return out;
}

std::string HomeDir() {
  const char* home = getenv("HOME");
  if (home != nullptr && home[0] != '\0') {
    return home;
  }
  struct passwd* pw = getpwuid(getuid());
  if (pw != nullptr && pw->pw_dir != nullptr) {
    return pw->pw_dir;
  }
  return "/home/defaultuser";
}

bool MkdirParents(const std::string& path) {
  std::string current;
  for (size_t i = 0; i < path.size(); ++i) {
    current.push_back(path[i]);
    if (path[i] != '/' && i + 1 != path.size()) {
      continue;
    }
    if (current.empty() || current == "/") {
      continue;
    }
    if (mkdir(current.c_str(), 0755) != 0 && errno != EEXIST) {
      return false;
    }
  }
  return true;
}

std::string SystemdWord(const std::string& value) {
  if (value.find_first_of(" \t\"\\") == std::string::npos) {
    return value;
  }
  std::string out = "\"";
  for (char c : value) {
    if (c == '"' || c == '\\') {
      out.push_back('\\');
    }
    out.push_back(c);
  }
  out.push_back('"');
  return out;
}

bool WriteFile(const std::string& path, const std::string& contents, std::string* error) {
  std::ofstream out(path, std::ios::trunc);
  if (!out) {
    *error = "failed to write " + path;
    return false;
  }
  out << contents;
  if (!out) {
    *error = "failed to write " + path;
    return false;
  }
  return true;
}

struct ProcessResult {
  int status;
  std::string output;
};

ProcessResult RunProcess(const std::vector<std::string>& args) {
  ProcessResult result{-1, ""};
  int pipefd[2];
  if (pipe(pipefd) != 0) {
    result.output = std::strerror(errno);
    return result;
  }

  const pid_t pid = fork();
  if (pid < 0) {
    close(pipefd[0]);
    close(pipefd[1]);
    result.output = std::strerror(errno);
    return result;
  }
  if (pid == 0) {
    dup2(pipefd[1], STDOUT_FILENO);
    dup2(pipefd[1], STDERR_FILENO);
    close(pipefd[0]);
    close(pipefd[1]);
    std::vector<char*> argv;
    argv.reserve(args.size() + 1);
    for (const std::string& arg : args) {
      argv.push_back(const_cast<char*>(arg.c_str()));
    }
    argv.push_back(nullptr);
    execv(argv[0], argv.data());
    _exit(127);
  }

  close(pipefd[1]);
  char buffer[512];
  while (result.output.size() < 4096) {
    const ssize_t n = read(pipefd[0], buffer, sizeof(buffer));
    if (n <= 0) {
      break;
    }
    result.output.append(buffer, static_cast<size_t>(n));
  }
  close(pipefd[0]);

  int status = 0;
  if (waitpid(pid, &status, 0) < 0) {
    result.output = std::strerror(errno);
    return result;
  }
  if (WIFEXITED(status)) {
    result.status = WEXITSTATUS(status);
  }
  return result;
}

bool Systemctl(const std::vector<std::string>& args, std::string* error) {
  std::vector<std::string> command{"/usr/bin/systemctl", "--user"};
  command.insert(command.end(), args.begin(), args.end());
  const ProcessResult result = RunProcess(command);
  if (result.status != 0) {
    *error = result.output.empty() ? "systemctl failed" : result.output;
    return false;
  }
  return true;
}

std::vector<std::string> ReadCmdline() {
  std::ifstream in("/proc/self/cmdline", std::ios::binary);
  std::string data((std::istreambuf_iterator<char>(in)),
                   std::istreambuf_iterator<char>());
  std::vector<std::string> args;
  std::string current;
  for (char c : data) {
    if (c == '\0') {
      if (!current.empty()) {
        args.push_back(current);
      }
      current.clear();
    } else {
      current.push_back(c);
    }
  }
  if (!current.empty()) {
    args.push_back(current);
  }
  return args;
}

std::string BundleFromCmdline() {
  const std::vector<std::string> args = ReadCmdline();
  for (size_t i = 0; i < args.size(); ++i) {
    const std::string prefix = "--bundle=";
    if (args[i].compare(0, prefix.size(), prefix) == 0) {
      return args[i].substr(prefix.size());
    }
    if ((args[i] == "--bundle" || args[i] == "-b") && i + 1 < args.size()) {
      return args[i + 1];
    }
  }
  return "./bundle";
}

std::string AbsolutePath(const std::string& path) {
  char* resolved = realpath(path.c_str(), nullptr);
  if (resolved == nullptr) {
    return path;
  }
  std::string absolute(resolved);
  free(resolved);
  return absolute;
}

std::string ExecutablePath() {
  char buffer[4096];
  const ssize_t n = readlink("/proc/self/exe", buffer, sizeof(buffer) - 1);
  if (n < 0) {
    return "";
  }
  buffer[n] = '\0';
  return std::string(buffer);
}

std::string UnitDir() { return HomeDir() + "/.config/systemd/user"; }

std::string ConfDir() { return HomeDir() + "/.config/" + AppId(); }

std::string ConfPath() { return ConfDir() + "/flutter_daemon.conf"; }

std::string ServicePath() { return UnitDir() + "/" + AppId() + ".service"; }

std::string TimerPath() { return UnitDir() + "/" + AppId() + ".timer"; }

std::string ServiceUnit(const std::string& exe, const std::string& bundle,
                        const std::string& library_path) {
  std::ostringstream out;
  out << "[Unit]\n"
      << "Description=Background sync for " << AppId() << "\n"
      << "\n"
      << "[Service]\n"
      << "Type=oneshot\n";
  if (!library_path.empty()) {
    std::string escaped;
    for (char c : library_path) {
      if (c == '\n' || c == '\r') {
        continue;
      }
      if (c == '"' || c == '\\') {
        escaped.push_back('\\');
      }
      escaped.push_back(c);
    }
    out << "Environment=\"LD_LIBRARY_PATH=" << escaped << "\"\n";
  }
  out << "ExecStart=" << SystemdWord(exe) << " --bundle=" << SystemdWord(bundle)
      << " --background-sync\n"
      << "TimeoutStartSec=600\n"
      << "Nice=10\n";
  return out.str();
}

std::string TimerUnit(int interval_minutes) {
  std::ostringstream out;
  out << "[Unit]\n"
      << "Description=Background sync timer for " << AppId() << "\n"
      << "\n"
      << "[Timer]\n"
      << "OnActiveSec=10s\n"
      << "OnUnitActiveSec=" << interval_minutes << "min\n"
      << "AccuracySec=30s\n"
      << "Persistent=true\n"
      << "Unit=" << AppId() << ".service\n"
      << "\n"
      << "[Install]\n"
      << "WantedBy=timers.target\n";
  return out.str();
}

bool RemovePath(const std::string& path) {
  if (unlink(path.c_str()) != 0 && errno != ENOENT) {
    return false;
  }
  return true;
}

bool TimerEnabled() {
  const ProcessResult result = RunProcess(
      {"/usr/bin/systemctl", "--user", "is-enabled", AppId() + ".timer"});
  return result.status == 0;
}

bool ServiceActive() {
  const ProcessResult result = RunProcess(
      {"/usr/bin/systemctl", "--user", "is-active", AppId() + ".service"});
  return result.status == 0;
}

bool ReadInterval(int* interval) {
  std::ifstream in(ConfPath());
  if (!in) {
    return false;
  }
  std::string line;
  const std::string key = "interval_minutes=";
  while (std::getline(in, line)) {
    if (line.compare(0, key.size(), key) != 0) {
      continue;
    }
    try {
      *interval = std::stoi(line.substr(key.size()));
      return true;
    } catch (const std::exception&) {
      return false;
    }
  }
  return false;
}

bool StartSync(int interval_minutes, std::string* message) {
  if (!FlutterDaemonRunnerHookInstalled()) {
    *message = kHookMissing;
    return false;
  }
  if (interval_minutes < 1) {
    *message = "intervalMinutes must be at least 1";
    return false;
  }

  const std::string exe = ExecutablePath();
  if (exe.empty()) {
    *message = "failed to resolve /proc/self/exe";
    return false;
  }
  const std::string bundle = AbsolutePath(BundleFromCmdline());
  const char* library_path = getenv("LD_LIBRARY_PATH");
  const std::string libraries = library_path == nullptr ? "" : library_path;

  if (!MkdirParents(UnitDir()) || !MkdirParents(ConfDir())) {
    *message = "failed to create systemd config directories";
    return false;
  }

  std::string error;
  if (!WriteFile(ServicePath(), ServiceUnit(exe, bundle, libraries), &error) ||
      !WriteFile(TimerPath(), TimerUnit(interval_minutes), &error) ||
      !WriteFile(ConfPath(),
                 "interval_minutes=" + std::to_string(interval_minutes) + "\n",
                 &error)) {
    *message = error;
    return false;
  }

  if (!Systemctl({"daemon-reload"}, &error) ||
      !Systemctl({"enable", "--now", AppId() + ".timer"}, &error)) {
    const std::string failure = error;
    RemovePath(ServicePath());
    RemovePath(TimerPath());
    RemovePath(ConfPath());
    Systemctl({"daemon-reload"}, &error);
    *message = failure;
    return false;
  }

  *message = "Background sync scheduled every " +
             std::to_string(interval_minutes) + " minutes.";
  return true;
}

bool StopSync(std::string* message) {
  std::string error;
  Systemctl({"disable", "--now", AppId() + ".timer"}, &error);
  Systemctl({"stop", AppId() + ".service"}, &error);
  RemovePath(ServicePath());
  RemovePath(TimerPath());
  RemovePath(ConfPath());
  if (!Systemctl({"daemon-reload"}, &error)) {
    *message = error;
    return false;
  }
  *message = "Background sync stopped successfully.";
  return true;
}

const flutter::EncodableValue* Argument(const flutter::EncodableValue* arguments,
                                        const char* key) {
  if (arguments == nullptr) {
    return nullptr;
  }
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    return nullptr;
  }
  const auto it = map->find(flutter::EncodableValue(std::string(key)));
  if (it == map->end()) {
    return nullptr;
  }
  return &it->second;
}

int ReadIntArgument(const flutter::EncodableValue* arguments, const char* key,
                    int fallback) {
  const flutter::EncodableValue* value = Argument(arguments, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* as_int = std::get_if<int32_t>(value)) {
    return static_cast<int>(*as_int);
  }
  if (const auto* as_long = std::get_if<int64_t>(value)) {
    return static_cast<int>(*as_long);
  }
  return fallback;
}

void Unsupported(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
    const char* feature) {
  result->Error("UNSUPPORTED",
                std::string(feature) + " is not supported on Sailfish OS");
}

class FlutterDaemonPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrar* registrar);

  FlutterDaemonPlugin();

  virtual ~FlutterDaemonPlugin();

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

FlutterDaemonPlugin::FlutterDaemonPlugin() {}

FlutterDaemonPlugin::~FlutterDaemonPlugin() {}

void FlutterDaemonPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method == "getPlatformVersion") {
    result->Success(flutter::EncodableValue(std::string("eLinux")));
    return;
  }

  if (method == "getCapabilities") {
    flutter::EncodableMap capabilities;
    capabilities[flutter::EncodableValue(std::string("backgroundSync"))] =
        flutter::EncodableValue(true);
    capabilities[flutter::EncodableValue(std::string("constraints"))] =
        flutter::EncodableValue(false);
    capabilities[flutter::EncodableValue(std::string("batteryOptimization"))] =
        flutter::EncodableValue(false);
    capabilities[flutter::EncodableValue(std::string("logs"))] =
        flutter::EncodableValue(false);
    capabilities[flutter::EncodableValue(std::string("minimumIntervalMinutes"))] =
        flutter::EncodableValue(static_cast<int32_t>(1));
    result->Success(flutter::EncodableValue(capabilities));
    return;
  }

  if (method == "backgroundSyncComplete") {
    FlutterDaemonMarkBackgroundSyncFinished();
    result->Success();
    return;
  }

  if (method == "startBackgroundSync") {
    const int interval =
        ReadIntArgument(method_call.arguments(), "intervalMinutes", -1);
    std::string message;
    if (!StartSync(interval, &message)) {
      result->Error("BACKGROUND_SYNC_ERROR", message);
      return;
    }
    result->Success(flutter::EncodableValue(message));
    return;
  }

  if (method == "stopBackgroundSync") {
    std::string message;
    if (!StopSync(&message)) {
      result->Error("BACKGROUND_SYNC_ERROR", message);
      return;
    }
    result->Success(flutter::EncodableValue(message));
    return;
  }

  if (method == "getBackgroundSyncStatus") {
    result->Success(flutter::EncodableValue(TimerEnabled() || ServiceActive()));
    return;
  }

  if (method == "getBackgroundSyncInterval") {
    int interval = 0;
    if (!TimerEnabled() || !ReadInterval(&interval)) {
      result->Success(flutter::EncodableValue());
      return;
    }
    result->Success(flutter::EncodableValue(static_cast<int32_t>(interval)));
    return;
  }

  if (method == "isBatteryOptimizationDisabled" ||
      method == "requestDisableBatteryOptimization" ||
      method == "openBatteryOptimizationSettings") {
    Unsupported(std::move(result), "battery optimization");
    return;
  }

  if (method == "setNetworkType" || method == "getNetworkType" ||
      method == "setBatteryNotLow" || method == "getBatteryNotLow" ||
      method == "setRequiresCharging" || method == "getRequiresCharging" ||
      method == "setDeviceIdle" || method == "getDeviceIdle") {
    Unsupported(std::move(result), "work constraints");
    return;
  }

  if (method == "getLogs" || method == "clearLogs") {
    Unsupported(std::move(result), "logs");
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
