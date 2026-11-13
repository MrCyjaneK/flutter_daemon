#ifndef FLUTTER_DAEMON_HOST_PATH_H_
#define FLUTTER_DAEMON_HOST_PATH_H_

#include <cstdlib>
#include <string>
#include <unistd.h>
#include <vector>

namespace flutter_daemon {

inline std::string AbsolutePath(const std::string& path) {
  char* resolved = realpath(path.c_str(), nullptr);
  if (resolved == nullptr) {
    return path;
  }
  std::string absolute(resolved);
  free(resolved);
  return absolute;
}

inline std::string ReadLink(const std::string& path) {
  char buffer[4096];
  const ssize_t n = ::readlink(path.c_str(), buffer, sizeof(buffer) - 1);
  if (n < 0) {
    return "";
  }
  buffer[n] = '\0';
  return std::string(buffer);
}

inline std::string BundleFromArguments(const std::vector<std::string>& args) {
  const std::string prefix = "--bundle=";
  for (size_t i = 0; i < args.size(); ++i) {
    if (args[i].compare(0, prefix.size(), prefix) == 0) {
      return args[i].substr(prefix.size());
    }
    if ((args[i] == "--bundle" || args[i] == "-b") && i + 1 < args.size()) {
      return args[i + 1];
    }
  }
  return "./bundle";
}

}  // namespace flutter_daemon

#endif  // FLUTTER_DAEMON_HOST_PATH_H_
