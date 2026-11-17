Name:           flutter-daemon
Summary:        Background task example for Sailfish OS
Version:        0.0.1
Release:        1
Group:          Applications/System
License:        LGPL-3.0-only
Source0:        %{name}-%{version}.tar.bz2
Requires:       flutter-sfos-3.44.0 = 3.44.0
BuildRequires:  clang
BuildRequires:  cmake
BuildRequires:  make
BuildRequires:  git
BuildRequires:  unzip
BuildRequires:  curl
BuildRequires:  flutter-sfos-3.44.0-devel

%description
Example app for the flutter_daemon plugin.

%prep
%setup -q -n %{name}-%{version}

%build

%install
cd example
/usr/libexec/flutter-sfos/3.44.0/flutter-sfos-aot "$PWD" "$PWD/build/sfos/bundle"
cd ..
mkdir -p %{buildroot}%{_datadir}/flutter-daemon
mkdir -p %{buildroot}%{_bindir}
mkdir -p %{buildroot}%{_datadir}/applications
cp -a example/build/sfos/bundle/. %{buildroot}%{_datadir}/flutter-daemon/
rm -f %{buildroot}%{_datadir}/flutter-daemon/lib/libflutter_engine.so \
  %{buildroot}%{_datadir}/flutter-daemon/lib/libflutter_elinux_*.so
install -m 755 rpm/flutter-daemon.sh %{buildroot}%{_bindir}/flutter-daemon
install -m 644 rpm/flutter-daemon.desktop %{buildroot}%{_datadir}/applications/flutter-daemon.desktop

%preun
if [ "$1" -eq 0 ]; then
  for home in /home/*; do
    [ -d "$home" ] || continue
    user=$(stat -c %U "$home")
    uid=$(stat -c %u "$home")
    pw_home=$(getent passwd "$user" | cut -d: -f6)
    [ "$pw_home" = "$home" ] || continue
    if [ -S "/run/user/$uid/bus" ]; then
      su -s /bin/sh "$user" -c "exec /usr/bin/env HOME='$home' XDG_RUNTIME_DIR='/run/user/$uid' DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/$uid/bus' /usr/bin/flutter-daemon --uninstall-background-sync" || :
    else
      su -s /bin/sh "$user" -c "exec /usr/bin/env HOME='$home' /usr/bin/flutter-daemon --uninstall-background-sync" || :
    fi
  done
fi

%files
%{_bindir}/flutter-daemon
%{_datadir}/applications/flutter-daemon.desktop
%dir %{_datadir}/flutter-daemon
%{_datadir}/flutter-daemon/
