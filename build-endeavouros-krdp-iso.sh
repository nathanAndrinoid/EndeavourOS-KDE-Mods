#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_DIR="${SCRIPT_DIR}/endeavouros-iso-build"
PATCH_FILE="${SCRIPT_DIR}/patches/krdp-working-fixes.patch"
CALAMARES_SRC_DIR="${SCRIPT_DIR}/build-src/deps/endeavouros-calamares"
CALAMARES_OVERLAY_DIR="${SCRIPT_DIR}/calamares-overlay"
IMAGE_NAME="eos-krdp-iso-builder"
SKIP_ISO_BUILD=0

usage() {
  cat <<'EOF'
Usage:
  ./build-endeavouros-krdp-iso.sh [--skip-iso-build]

Options:
  --skip-iso-build   Build and cache patched KRDP + custom Calamares packages only.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-iso-build)
      SKIP_ISO_BUILD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unexpected argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd git
require_cmd docker

DOCKER_CMD=(docker)
if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    DOCKER_CMD=(sudo docker)
  else
    echo "Docker is installed but not accessible to the current user." >&2
    echo "Add your user to the docker group or run this script as root." >&2
    exit 1
  fi
fi

[[ -f "$PATCH_FILE" ]] || {
  echo "Missing patch file: $PATCH_FILE" >&2
  exit 1
}

if [[ ! -d "$ISO_DIR/.git" ]]; then
  git -C "$SCRIPT_DIR" clone https://github.com/endeavouros-team/EndeavourOS-ISO.git "$(basename "$ISO_DIR")"
fi

mkdir -p "$SCRIPT_DIR/build-src/deps"
if [[ ! -d "$CALAMARES_SRC_DIR/.git" ]]; then
  rm -rf "$CALAMARES_SRC_DIR"
  git -C "$SCRIPT_DIR/build-src/deps" clone --depth 1 https://github.com/endeavouros-team/calamares.git "$(basename "$CALAMARES_SRC_DIR")"
fi
[[ -d "$CALAMARES_OVERLAY_DIR" ]] && [[ -f "$CALAMARES_OVERLAY_DIR/data/eos/scripts/ssh_setup_script.sh" ]] || {
  echo "Missing Calamares overlay: $CALAMARES_OVERLAY_DIR/data/eos/scripts/ssh_setup_script.sh" >&2
  exit 1
}
rsync -a "$CALAMARES_OVERLAY_DIR/" "$CALAMARES_SRC_DIR/"
[[ -f "$CALAMARES_SRC_DIR/data/eos/scripts/ssh_setup_script.sh" ]] || {
  echo "Missing custom Calamares SSH setup script under: $CALAMARES_SRC_DIR" >&2
  exit 1
}

python3 - "$ISO_DIR/packages.x86_64" <<'PY'
from pathlib import Path
import sys

pkg = Path(sys.argv[1])
lines = pkg.read_text().splitlines()

result = []
for line in lines:
    if line.strip() == "kwin-x11":
        line = "kwin"
    if line.strip() == "plasma-x11-session":
        continue
    if line.strip() == "krdp":
        # Force use of locally built patched KRDP package.
        continue
    if line.strip() == "calamares":
        # Force use of locally built custom Calamares package.
        continue
    if line.strip() == "ckbcomp":
        # ckbcomp is built locally from external upstream source.
        continue
    result.append(line)

required = ["qt6-wayland", "plasma-wayland-protocols", "openssh", "kdialog", "discover", "flatpak", "gnupg", "kwallet", "kwallet-pam", "kwalletmanager"]
insertion_after = "kwin"
out = []
added = False
for line in result:
    out.append(line)
    if line.strip() == insertion_after and not added:
        for item in required:
            if item not in [l.strip() for l in result]:
                out.append(item)
        added = True

if not added:
    for item in required:
        if item not in [l.strip() for l in out]:
            out.append(item)

pkg.write_text("\n".join(out) + "\n")
PY

mkdir -p "$ISO_DIR/airootfs/root/packages"

# Remove stale locally-built artifacts so each run stages a single, current
# package for krdp/calamares/ckbcomp.
rm -f \
  "$ISO_DIR"/airootfs/root/packages/krdp-*.pkg.tar.zst \
  "$ISO_DIR"/airootfs/root/packages/krdp-debug-*.pkg.tar.zst \
  "$ISO_DIR"/airootfs/root/packages/calamares-*.pkg.tar.zst \
  "$ISO_DIR"/airootfs/root/packages/calamares-debug-*.pkg.tar.zst \
  "$ISO_DIR"/airootfs/root/packages/ckbcomp-*.pkg.tar.zst

"${DOCKER_CMD[@]}" build -t "$IMAGE_NAME" - <<'DOCKERFILE'
FROM archlinux:latest

RUN pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman -Syu --noconfirm \
      archiso base-devel cmake extra-cmake-modules freerdp gcc-libs git glibc \
      imagemagick kcmutils kconfig kcoreaddons kcrash kguiaddons ki18n kparts \
      kpipewire kpmcore kservice kstatusnotifieritem kwidgetsaddons libpwquality \
      libxkbcommon networkmanager ninja pam plasma-wayland-protocols polkit-qt6 \
      pybind11 python python-jsonschema python-pyaml python-unidecode qt6-base \
      qt6-declarative qt6-svg qt6-tools qt6-wayland qt6-webengine qtkeychain-qt6 \
      reflector rsync solid squashfs-tools sudo systemd-libs upower wayland wget \
      yaml-cpp cryptsetup dmidecode doxygen gawk gptfdisk hwinfo

RUN useradd -m -G wheel -s /bin/bash builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
DOCKERFILE

"${DOCKER_CMD[@]}" run --rm \
  -v "$ISO_DIR:/build" \
  -v "$PATCH_FILE:/tmp/krdp-working-fixes.patch:ro" \
  -v "$CALAMARES_SRC_DIR:/tmp/endeavouros-calamares:ro" \
  -w /build \
  "$IMAGE_NAME" \
  bash -lc '
set -euo pipefail

PKG_DIR=/tmp/krdp-pkg
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"
cp /tmp/krdp-working-fixes.patch "$PKG_DIR/"

cat > "$PKG_DIR/PKGBUILD" <<'"'"'EOF'"'"'
pkgname=krdp
pkgver=0
epoch=1
pkgrel=1
pkgdesc="Library and examples for creating an RDP server (patched)"
arch=(x86_64)
url="https://kde.org/plasma-desktop/"
license=(LGPL-2.0-or-later)
depends=(freerdp gcc-libs glibc kcmutils kconfig kcoreaddons kcrash kguiaddons ki18n kpipewire kstatusnotifieritem libxkbcommon pam qt6-base qtkeychain-qt6 systemd-libs wayland)
makedepends=(extra-cmake-modules git plasma-wayland-protocols qt6-wayland)
source=("krdp::git+https://invent.kde.org/plasma/krdp.git" "krdp-working-fixes.patch")
sha256sums=("SKIP" "SKIP")

pkgver() {
  cd krdp
  local base
  base="$(sed -n '\''s/^set(PROJECT_VERSION \"\\(.*\\)\")/\\1/p'\'' CMakeLists.txt | head -n1)"
  if [[ -z "$base" ]]; then
    base="0"
  fi
  printf "%s.r%s.g%s" "$base" "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
}

prepare() {
  cd krdp
  patch -Np1 -i "${srcdir}/krdp-working-fixes.patch"
}

build() {
  cmake -B build -S krdp -DBUILD_TESTING=OFF
  cmake --build build
}

package() {
  DESTDIR="${pkgdir}" cmake --install build
}
EOF

chown -R builder:builder "$PKG_DIR"
su - builder -c "cd $PKG_DIR && makepkg -sf --noconfirm"
cp -f "$PKG_DIR"/krdp-*.pkg.tar.zst /build/airootfs/root/packages/
ls -1 /build/airootfs/root/packages/krdp-*.pkg.tar.zst

CKBCOMP_PKG_DIR=/tmp/ckbcomp-pkg
rm -rf "$CKBCOMP_PKG_DIR"
mkdir -p "$CKBCOMP_PKG_DIR"

cat > "$CKBCOMP_PKG_DIR/PKGBUILD" <<'"'"'EOF'"'"'
pkgname=ckbcomp
pkgver=1.0
epoch=1
pkgrel=1
pkgdesc="Compile XKB keyboard description to map for console"
arch=(any)
url="https://salsa.debian.org/installer-team/console-setup"
license=(GPL2)
depends=(perl)
source=("https://salsa.debian.org/installer-team/console-setup/-/raw/master/Keyboard/ckbcomp")
sha256sums=("SKIP")

package() {
  install -Dm755 "${srcdir}/ckbcomp" "${pkgdir}/usr/bin/ckbcomp"
}
EOF

chown -R builder:builder "$CKBCOMP_PKG_DIR"
su - builder -c "cd $CKBCOMP_PKG_DIR && makepkg -sf --noconfirm"
cp -f "$CKBCOMP_PKG_DIR"/ckbcomp-*.pkg.tar.zst /build/airootfs/root/packages/
ls -1 /build/airootfs/root/packages/ckbcomp-*.pkg.tar.zst

# Calamares makepkg -s resolves runtime deps via pacman; install local ckbcomp first.
ckbcomp_pkg="$(ls -1 /build/airootfs/root/packages/ckbcomp-*.pkg.tar.zst | head -n1)"
pacman -U --noconfirm "$ckbcomp_pkg"
pacman -Q ckbcomp

CALAMARES_PKG_DIR=/tmp/calamares-pkg
rm -rf "$CALAMARES_PKG_DIR"
mkdir -p "$CALAMARES_PKG_DIR"
cp -a /tmp/endeavouros-calamares "$CALAMARES_PKG_DIR/calamares-src"
tar -C "$CALAMARES_PKG_DIR" -czf "$CALAMARES_PKG_DIR/calamares-src.tar.gz" calamares-src
rm -rf "$CALAMARES_PKG_DIR/calamares-src"

cat > "$CALAMARES_PKG_DIR/PKGBUILD" <<'"'"'EOF'"'"'
pkgname=calamares
pkgver=0
epoch=1
pkgrel=1
pkgdesc="Calamares installer for EndeavourOS (custom installer hooks)"
arch=(x86_64)
url="https://github.com/endeavouros-team/calamares"
license=(GPL3)
depends=(qt6-svg qt6-webengine yaml-cpp networkmanager upower kcoreaddons kconfig ki18n kservice kwidgetsaddons kpmcore squashfs-tools rsync pybind11 cryptsetup doxygen dmidecode gptfdisk hwinfo kparts polkit-qt6 python solid qt6-tools libpwquality qt6-declarative ckbcomp)
makedepends=(cmake extra-cmake-modules gawk python-jsonschema python-pyaml python-unidecode)
provides=(calamares)
conflicts=(calamares-git)
source=("calamares-src.tar.gz")
sha256sums=("SKIP")

pkgver() {
  cd calamares-src
  local version
  version="$(sed -n '\''s/^set(CALAMARES_VERSION_SHORT[[:space:]]*\"\\([^\"]*\\)\")/\\1/p'\'' CMakeLists.txt | head -n1)"
  if [[ -z "$version" ]]; then
    version="0"
  fi
  printf "%s.r%s.g%s" "$version" "$(git rev-list --count HEAD 2>/dev/null || echo 0)" "$(git rev-parse --short HEAD 2>/dev/null || echo local)"
}

build() {
  cmake -B build -S calamares-src \
    -DWITH_QT6=ON \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_INSTALL_LIBDIR=/usr/lib \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DINSTALL_CONFIG=OFF \
    -DSKIP_MODULES="dracut \
    dummycpp dummyprocess dummypython dummypythonqt \
    finishedq initcpio keyboardq license localeq notesqml oemid \
    openrcdmcryptcfg plymouthcfg plasmalnf services-openrc \
    summaryq tracking webview welcomeq"
  cmake --build build
}

package() {
  DESTDIR="${pkgdir}" cmake --install build
  install -dm 0755 "${pkgdir}/etc"
  cp -rp "${srcdir}/calamares-src/data/eos" "${pkgdir}/etc/calamares"
}
EOF

chown -R builder:builder "$CALAMARES_PKG_DIR"
su - builder -c "cd $CALAMARES_PKG_DIR && makepkg -sf --noconfirm"
cp -f "$CALAMARES_PKG_DIR"/calamares-*.pkg.tar.zst /build/airootfs/root/packages/
ls -1 /build/airootfs/root/packages/calamares-*.pkg.tar.zst
'

if [[ "$SKIP_ISO_BUILD" -eq 1 ]]; then
  echo "Patched KRDP + custom Calamares packages prepared under: $ISO_DIR/airootfs/root/packages"
  exit 0
fi

"${DOCKER_CMD[@]}" run --rm --privileged \
  -v "$ISO_DIR:/build" \
  -w /build \
  "$IMAGE_NAME" \
  bash -lc '
set -euo pipefail

mkdir -p /etc/pacman.d
if [[ ! -s /etc/pacman.d/mirrorlist ]] || ! grep -qE "^[[:space:]]*Server[[:space:]]*=" /etc/pacman.d/mirrorlist; then
  cat > /etc/pacman.d/mirrorlist <<'"'"'EOF'"'"'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
EOF
fi

cat > /etc/pacman.d/endeavouros-mirrorlist <<'"'"'EOF'"'"'
Server = https://mirror.alpix.eu/endeavouros/repo/$repo/$arch
Server = https://us.mirror.endeavouros.com/endeavouros/repo/$repo/$arch
EOF

if grep -q "^\[endeavouros\]" /build/pacman.conf; then
  sed -i "/^\[endeavouros\]/,/^\[/ s/^SigLevel.*/SigLevel = Optional TrustAll/" /build/pacman.conf
  if ! awk '\''/^\[endeavouros\]/{in_repo=1;next}/^\[/{in_repo=0}in_repo && /^SigLevel[[:space:]]*=/{found=1}END{exit !found}'\'' /build/pacman.conf; then
    sed -i "/^\[endeavouros\]/a SigLevel = Optional TrustAll" /build/pacman.conf
  fi
fi

pacman-conf --config /build/pacman.conf >/dev/null
su - builder -c "cd /build && ./prepare.sh"
rm -rf /build/work /build/out
su - builder -c "cd /build && sudo ./mkarchiso -v ."
'

latest_iso="$(ls -1t "$ISO_DIR"/out/*.iso 2>/dev/null | head -n1 || true)"
if [[ -n "$latest_iso" ]]; then
  if ! bsdtar -tf "$latest_iso" | grep -qx "boot/syslinux/isolinux.bin"; then
    echo "ISO validation failed: boot/syslinux/isolinux.bin is missing in $latest_iso" >&2
    exit 1
  fi
  if ! bsdtar -tf "$latest_iso" | grep -qx "boot/syslinux/ldlinux.c32"; then
    echo "ISO validation failed: boot/syslinux/ldlinux.c32 is missing in $latest_iso" >&2
    exit 1
  fi
  iso_syslinux_cfg="$(bsdtar -xOf "$latest_iso" boot/syslinux/syslinux.cfg 2>/dev/null || true)"
  if [[ "$iso_syslinux_cfg" == *"whichsys.c32"* ]]; then
    echo "ISO validation failed: boot/syslinux/syslinux.cfg still references whichsys.c32" >&2
    exit 1
  fi
  echo "ISO build complete: $latest_iso"
else
  echo "ISO build finished but no ISO found under $ISO_DIR/out" >&2
  exit 1
fi
