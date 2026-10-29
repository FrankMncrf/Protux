#!/bin/sh
# Build protux_<version>-1_all.deb into ./dist (run from the source tree).
set -eu
VERSION=$(sed -n 's/^PTX_VERSION=//p' lib/protux/common.sh)
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
make install DESTDIR="$ROOT" PREFIX=/usr LICENSEDIR=/usr/share/doc/protux
mv "$ROOT/usr/share/doc/protux/LICENSE" "$ROOT/usr/share/doc/protux/copyright"
gzip -9n -c CHANGELOG.md > "$ROOT/usr/share/doc/protux/changelog.gz"
gzip -9n "$ROOT/usr/share/man/man1/protux.1"
mkdir -p "$ROOT/DEBIAN"
sed "s/@VERSION@/$VERSION/" packaging/debian/control.in > "$ROOT/DEBIAN/control"
echo "Installed-Size: $(du -sk "$ROOT/usr" | cut -f1)" >> "$ROOT/DEBIAN/control"
mkdir -p dist
dpkg-deb --root-owner-group -Zxz --build "$ROOT" "dist/protux_${VERSION}-1_all.deb"
