Name:           protux
Version:        0.1.0
Release:        1%{?dist}
Summary:        Proton Drive client for Linux: mount your drive as a folder
License:        GPL-3.0-or-later
URL:            https://github.com/FrankMncrf/Protux
Source0:        %{url}/archive/refs/tags/v%{version}/Protux-%{version}.tar.gz
BuildArch:      noarch
BuildRequires:  make
BuildRequires:  systemd-rpm-macros
Requires:       bash
Requires:       rclone
Requires:       fuse3
Requires:       systemd
Requires:       gawk
Recommends:     python3-pyqt6
Recommends:     polkit
Recommends:     libsecret
Recommends:     libnotify
Suggests:       zenity

%description
Protux mounts Proton Drive as a normal folder with rclone and a systemd
user service, and keeps it working: setup wizard, system tray icon,
2FA re-login prompts when the session expires, two-password accounts,
and no login loops that get the account rate-limited (HTTP 429).
Unofficial; not affiliated with Proton AG.

%prep
%autosetup -n Protux-%{version}

%build
make PREFIX=%{_prefix}

%install
make install DESTDIR=%{buildroot} PREFIX=%{_prefix} USERUNITDIR=%{_userunitdir} \
    DOCDIR=%{_docdir}/%{name} LICENSEDIR=%{_licensedir}/%{name}

%files
%{_bindir}/protux
%{_bindir}/protux-gui
%{_prefix}/lib/protux/
%{_userunitdir}/protux.service
%{_userunitdir}/protux-alert.service
%{_datadir}/applications/io.github.frankmncrf.protux.desktop
%{_datadir}/icons/hicolor/scalable/apps/protux.svg
%{_mandir}/man1/protux.1*
%{_docdir}/%{name}/
%{_licensedir}/%{name}/

%changelog
* Thu Oct 29 2026 FrankMncrf <57369835+FrankMncrf@users.noreply.github.com> - 0.1.0-1
- First release
