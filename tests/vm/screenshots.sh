#!/bin/bash
# README screenshots, taken inside an Arch test VM left running by `run-vm.sh arch --gui --keep`:
#   tests/vm/screenshots.sh            → docs/screenshots/*.png
# The VM gets a virtual X display (Xvfb) with xfwm4, xfce4-panel and Thunar; nothing runs on the
# host desktop, and the account and files are fake (tests/fake-proton-rclone).
set -euo pipefail
cd "$(dirname "$0")/../.."
VM=tests/vm/vmssh
OUT=docs/screenshots

$VM arch 'sudo pacman -S --noconfirm --needed xorg-server-xvfb xfwm4 xfce4-panel xfce4-settings xfdesktop \
  thunar imagemagick wmctrl xdotool noto-fonts papirus-icon-theme >/dev/null'
$VM arch --put tests/vm/screenshots.py bin/protux-gui '~/'
$VM arch 'sudo install -m755 ~/protux-gui /usr/bin/protux-gui'  # current GUI code
$VM arch 'bash -s' <<'VM'
set -e
# made-up files for the fake drive
D=~/.fake-drive
rm -rf "$D" && mkdir -p "$D"/{Documents,Photos,Projects,Shared,Backups}
printf 'Welcome to Protux!\n' > "$D/Welcome.txt"
printf 'Groceries\n- coffee\n- bread\n' > "$D/Documents/Notes.md"
for n in 1 2 3; do magick -size 640x400 "plasma:" "$D/Photos/Trip-$n.jpg"; done
magick -size 800x500 gradient:'#6d4aff-#1b1340' "$D/Photos/Wallpaper.png"
printf 'a,b\n1,2\n' > "$D/Projects/budget.csv"
cp "$D/Welcome.txt" "$D/Shared/README.txt"
dd if=/dev/urandom of="$D/Backups/laptop-2026-10.tar.zst" bs=1M count=3 status=none

X=~/.config/xfce4/xfconf/xfce-perchannel-xml; mkdir -p "$X"
cat > "$X/xsettings.xml" <<'E'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Adwaita"/>
    <property name="IconThemeName" type="string" value="Papirus"/>
  </property>
  <property name="Gtk" type="empty"><property name="FontName" type="string" value="Noto Sans 10"/></property>
</channel>
E
cat > "$X/xfwm4.xml" <<'E'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Default"/>
    <property name="title_font" type="string" value="Noto Sans Bold 10"/>
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
E
cat > "$X/xfce4-panel.xml" <<'E'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="32"/>
      <property name="icon-size" type="uint" value="22"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/><value type="int" value="2"/><value type="int" value="3"/><value type="int" value="4"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="applicationsmenu"/>
    <property name="plugin-2" type="string" value="separator"><property name="expand" type="bool" value="true"/><property name="style" type="uint" value="0"/></property>
    <property name="plugin-3" type="string" value="systray"><property name="square-icons" type="bool" value="true"/></property>
    <property name="plugin-4" type="string" value="clock"/>
  </property>
</channel>
E
cat > "$X/xfce4-desktop.xml" <<'E'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="desktop-icons" type="empty"><property name="style" type="int" value="0"/></property>
</channel>
E
cat > ~/xsession.sh <<'E'
#!/bin/bash
xfsettingsd --no-daemon & sleep 1
xfwm4 & sleep 1
xfdesktop & sleep 1
xfce4-panel & sleep 3
QT_QPA_PLATFORMTHEME=gtk3 python3 ~/screenshots.py
E
chmod +x ~/xsession.sh
pkill -x Xvfb || true
Xvfb :5 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 & sleep 2
rm -rf ~/readme-shots
DISPLAY=:5 LANG=en_US.UTF-8 timeout 300 dbus-run-session -- ~/xsession.sh
pkill -x Xvfb || true
ls ~/readme-shots
VM
rm -rf "$OUT.new" && mkdir -p "$OUT.new"
$VM arch --get 'readme-shots/*.png' "$OUT.new/"
rm -rf "$OUT" && mv "$OUT.new" "$OUT"
ls "$OUT"
