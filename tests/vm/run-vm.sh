#!/bin/bash
# Run the protux tests in a throwaway QEMU VM (cloud image + cloud-init).
#   tests/vm/run-vm.sh <arch|debian|ubuntu|fedora> [--gui] [--keep]
# Safe for the host desktop: no display (only an emulated VGA card: Debian's kernel resets without
# one), no GPU or USB passthrough, user-mode network only,
# low CPU/IO priority. Images live in ~/.cache/protux-vm.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=$PWD
DISTRO=${1:?distro}
SUMS=
GUI=0 KEEP=0
for a in "${@:2}"; do case "$a" in --gui) GUI=1 ;; --keep) KEEP=1 ;; esac; done
VMDIR=${VMDIR:-$HOME/.cache/protux-vm}
RCLONE_BIN=${RCLONE_BIN:-$(command -v rclone)}
W=$VMDIR/$DISTRO
mkdir -p "$W"
chattr +C "$VMDIR" 2>/dev/null || true # no copy-on-write for VM disks on btrfs

case "$DISTRO" in
  arch) URL=${ARCH_URL:-https://mirror.osbeck.com/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2}
    SUMS=https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2.SHA256 PORT=2231 ;;
  debian) URL=https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2
    SUMS=https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS PORT=2232 ;;
  ubuntu) URL=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
    SUMS=https://cloud-images.ubuntu.com/noble/current/SHA256SUMS PORT=2233 ;;
  fedora) F=https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images
    URL=$F/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2 SUMS=$F/Fedora-Cloud-44-1.7-x86_64-CHECKSUM PORT=2234 ;;
  *) echo "unknown distro $DISTRO" >&2; exit 2 ;;
esac

log() { printf '\n[%s] %s\n' "$(date +%T)" "$*"; }
SSH=(ssh -i "$VMDIR/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR -o ConnectTimeout=5 tester@127.0.0.1)
SCP=(scp -i "$VMDIR/key" -P "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

[ -f "$VMDIR/key" ] || ssh-keygen -q -t ed25519 -N '' -f "$VMDIR/key"
if [ ! -f "$W/base.img" ]; then
  log "downloading $URL"
  curl -fL --retry 3 -o "$W/base.img.part" "$URL"
  if [ -n "${SUMS:-}" ]; then
    # Formats: "hash  file" (Arch, Debian, Ubuntu) and "SHA256 (file) = hash" (Fedora)
    want=$(curl -fsSL "$SUMS" | grep -F "${URL##*/}" | grep -oE '\b[0-9a-f]{64}([0-9a-f]{64})?\b' | head -n1)
    if [ ${#want} = 128 ]; then got=$(sha512sum "$W/base.img.part" | awk '{print $1}')
    else got=$(sha256sum "$W/base.img.part" | awk '{print $1}'); fi
    [ "$want" = "$got" ] || { echo "checksum mismatch ($got != $want)" >&2; rm -f "$W/base.img.part"; exit 1; }
  fi
  mv "$W/base.img.part" "$W/base.img"
fi

# Fresh disk on top of the downloaded image every run
rm -f "$W/disk.qcow2"
qemu-img create -q -f qcow2 -F qcow2 -b "$W/base.img" "$W/disk.qcow2" 20G

mkdir -p "$W/seed"
cat >"$W/seed/meta-data" <<M
instance-id: ptx-$DISTRO-$(date +%s)
local-hostname: ptx-$DISTRO
M
cat >"$W/seed/user-data" <<U
#cloud-config
users:
  - name: tester
    uid: "1000"
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "$VMDIR/key.pub")
growpart: {mode: auto, devices: ["/"]}
U
xorriso -as mkisofs -quiet -V cidata -J -r -o "$W/seed.iso" "$W/seed" 2>/dev/null

# A VM left running by --keep: stop it and wait, or the new one can't take its pid file
if [ -f "$W/pid" ] && kill "$(cat "$W/pid")" 2>/dev/null; then
  for _ in $(seq 30); do kill -0 "$(cat "$W/pid")" 2>/dev/null || break; sleep 1; done
fi
log "booting $DISTRO VM (ssh on 127.0.0.1:$PORT)"
nice -n 10 ionice -c 3 qemu-system-x86_64 -name "ptx-$DISTRO" -enable-kvm -cpu host -m 3072 -smp 2 \
  -display none -vga std -nodefaults -serial "file:$W/serial.log" \
  -drive "file=$W/disk.qcow2,if=virtio" -drive "file=$W/seed.iso,media=cdrom,readonly=on" \
  -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$PORT-:22" \
  -daemonize -pidfile "$W/pid"
cleanup() { ((KEEP)) || { kill "$(cat "$W/pid")" 2>/dev/null || true; }; }
trap cleanup EXIT

for i in $(seq 120); do "${SSH[@]}" true 2>/dev/null && break; sleep 3; done
"${SSH[@]}" true || { log "VM did not come up; see $W/serial.log"; exit 1; }
"${SSH[@]}" 'sudo cloud-init status --wait >/dev/null 2>&1 || true'

log "installing packages"
case "$DISTRO" in
  arch) PKG='sudo sed -i "1i Server = ${ARCH_MIRROR:-https://mirror.osbeck.com/archlinux}/\$repo/os/\$arch" /etc/pacman.d/mirrorlist && sudo pacman -Syu --noconfirm --needed fuse3 make gawk libsecret libnotify polkit python-pyqt6 ttf-dejavu' ;;
  debian | ubuntu) PKG='sudo DEBIAN_FRONTEND=noninteractive apt-get update -q && sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends fuse3 make gawk procps libsecret-tools libnotify-bin pkexec python3-pyqt6 dbus-user-session fonts-dejavu-core' ;;
  fedora) PKG='sudo dnf -yq install fuse3 make gawk procps-ng libsecret libnotify polkit python3-pyqt6 dejavu-sans-fonts' ;;
esac
"${SSH[@]}" "$PKG" >"$W/packages.log" 2>&1 || { log "package install failed, see $W/packages.log"; tail -5 "$W/packages.log"; exit 1; }

log "installing protux"
tar -C "$REPO" --exclude=./build --exclude=./.git -czf "$W/src.tgz" .
"${SCP[@]}" "$W/src.tgz" "$RCLONE_BIN" tester@127.0.0.1:/tmp/
"${SSH[@]}" 'set -e; sudo install -m755 /tmp/rclone /usr/bin/rclone
  rm -rf ~/src && mkdir ~/src && tar -xzf /tmp/src.tgz -C ~/src
  cd ~/src && make -s all && sudo make -s install PREFIX=/usr && sudo install -m755 tests/fake-proton-rclone /usr/local/bin/
  sudo loginctl enable-linger tester; systemctl --user daemon-reload
  # test VM only: pkexec without a password for tester (the default /media/ProtonDrive needs it)
  echo "polkit.addRule(function(a, s) { if (s.user == \"tester\") return polkit.Result.YES; });" |
    sudo tee /etc/polkit-1/rules.d/00-protux-test.rules >/dev/null'

log "CLI tests"
rc=0
"${SSH[@]}" 'bash ~/src/tests/cli-tests.sh' | tee "$W/cli-tests.log" || rc=1

if ((GUI)); then
  log "GUI tests"
  "${SSH[@]}" 'python3 ~/src/tests/test_gui.py 2>&1' | tee "$W/gui-tests.log" || rc=1
  rm -rf "$W/shots" && mkdir -p "$W/shots"
  "${SCP[@]}" 'tester@127.0.0.1:shots/*.png' "$W/shots/" 2>/dev/null || true
  log "screenshots in $W/shots"
fi
exit $rc
