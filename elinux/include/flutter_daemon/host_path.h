#ifndef FLUTTER_DAEMON_HOST_PATH_H_
#define FLUTTER_DAEMON_HOST_PATH_H_

#include <cstdlib>
#include <limits>
#include <string>
#include <sys/stat.h>
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

// st_size is the target length. /proc/self/exe reports 0, and readlink reports
// truncation by filling the buffer, so grow until the read comes back short.
inline std::string ReadLink(const std::string& path) {
  struct stat info;
  size_t size = 128;
  if (::lstat(path.c_str(), &info) == 0 && info.st_size > 0) {
    size = static_cast<size_t>(info.st_size);
  }
  for (;;) {
    std::string buffer(size, '\0');
    const ssize_t n = ::readlink(path.c_str(), &buffer[0], buffer.size());
    if (n < 0) {
      return "";
    }
    if (static_cast<size_t>(n) < size) {
      buffer.resize(static_cast<size_t>(n));
      return buffer;
    }
    if (size > std::numeric_limits<size_t>::max() / 2) {
      return "";
    }
    size *= 2;
  }
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
