#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_DIR="${SCRIPT_DIR}/endeavouros-iso-build"
# Pin EndeavourOS-ISO profile to a fixed tag (https://github.com/endeavouros-team/EndeavourOS-ISO). Empty = default branch tip.
ISO_TAG="${ISO_TAG:-26.01.1.3}"
ISO_HOOKS_DIR="${SCRIPT_DIR}/iso-hooks"
# Package cache: run ./download-packages.sh to populate; build will use it when present
PKG_CACHE_DIR="${PKG_CACHE_DIR:-$SCRIPT_DIR/pkg-cache}"
PATCH_FILE="${SCRIPT_DIR}/patches/krdp-working-fixes.patch"
KRDP_OVERLAY_DIR="${SCRIPT_DIR}/patches/krdp-overlay"
# Pin KRDP to a fixed tag (https://github.com/KDE/krdp). Empty = default branch tip.
KRDP_TAG="${KRDP_TAG:-v6.6.1}"
CALAMARES_PATCH_FILE="${SCRIPT_DIR}/patches/calamares-eos-script-kdialog.patch"
CALAMARES_DESKTOP_PATCH="${SCRIPT_DIR}/patches/calamares-desktop-exec.patch"
CALAMARES_WEBVIEW_SCHEME_PATCH="${SCRIPT_DIR}/patches/calamares-webview-scheme.patch"
CALAMARES_SRC_DIR="${SCRIPT_DIR}/build-src/deps/endeavouros-calamares"
# Pin Calamares to a fixed tag (https://github.com/endeavouros-team/calamares). Empty = default branch tip.
CALAMARES_TAG="${CALAMARES_TAG:-26.01.1.5}"
CALAMARES_OVERLAY_DIR="${SCRIPT_DIR}/calamares-overlay"
BOOT_OVERLAY_DIR="${SCRIPT_DIR}/boot-overlay"
IMAGE_NAME="eos-krdp-iso-builder"
SKIP_ISO_BUILD=0

usage() {
  cat <<'EOF'
Usage:
  ./build-endeavouros-krdp-iso.sh [--skip-iso-build]

Options:
  --skip-iso-build   Build and cache patched KRDP + custom Calamares packages only.

Package cache (optional):
  If mirrors return 404 for packages, run ./download-packages.sh first to fill
  pkg-cache/; the build will then use those packages. Set PKG_CACHE_DIR to use
  a different cache directory.
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

trace_syslinux_candidates() {
  local root="$1"
  local phase="$2"
  local -a candidates=()

  while IFS= read -r -d '' cfg; do
    candidates+=("$cfg")
  done < <(find "$root" -type f -name "syslinux.cfg" -print0 2>/dev/null || true)

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    echo "[$phase] No syslinux.cfg files found under: $root"
    return 0
  fi

  for cfg in "${candidates[@]}"; do
    if grep -Eq '^[[:space:]]*[^#].*whichsys\.c32' "$cfg"; then
      echo "[$phase] $cfg still references whichsys.c32"
    else
      echo "[$phase] $cfg is clean (no whichsys.c32)"
    fi
  done
}

apply_syslinux_overlay() {
  local root="$1"
  local overlay_cfg="$2"
  local phase="$3"
  local -a candidates=()
  local replaced=0

  while IFS= read -r -d '' cfg; do
    candidates+=("$cfg")
  done < <(find "$root" -type f -name "syslinux.cfg" -print0 2>/dev/null || true)

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    echo "[$phase] No syslinux.cfg candidates found under: $root"
    return 0
  fi

  for cfg in "${candidates[@]}"; do
    # Always replace canonical profile path; also replace any file that still references whichsys.c32.
    if [[ "$cfg" == */syslinux/syslinux.cfg ]] || grep -Eq '^[[:space:]]*[^#].*whichsys\.c32' "$cfg"; then
      cp -f "$overlay_cfg" "$cfg"
      replaced=$((replaced + 1))
    fi
  done

  echo "[$phase] Applied boot overlay to $replaced syslinux.cfg file(s) under: $root"
  trace_syslinux_candidates "$root" "$phase"
}

stage_calamares_overlay() {
  local airootfs_root="$1"
  local overlay_root="$2"
  local phase="$3"
  local source_dir="$overlay_root/data/eos"
  local target_dir="$airootfs_root/etc/calamares"
  local required_file
  local missing=0

  mkdir -p "$target_dir"
  rsync -a --delete "$source_dir/" "$target_dir/"

  local required_files=(
    "settings_online.conf"
    "settings_offline.conf"
    "remote-setup.html"
    "modules/eos_script_ssh_setup.conf"
    "modules/shellprocess_copy_calamares_scripts.conf"
    "modules/shellprocess_fix_pacman_servers.conf"
    "modules/shellprocess_fix_keyring.conf"
    "modules/shellprocess_fix_osprober.conf"
    "modules/shellprocess_write_remote_setup_config.conf"
    "modules/webview@remote_setup.conf"
    "scripts/ssh_setup_script.sh"
    "scripts/fix_pacman_servers.sh"
    "scripts/fix_keyring.sh"
    "scripts/fix_osprober.sh"
  )

  for required_file in "${required_files[@]}"; do
    if [[ ! -f "$target_dir/$required_file" ]]; then
      echo "[$phase] Missing required file: $target_dir/$required_file" >&2
      missing=$((missing + 1))
    fi
  done

  if [[ $missing -gt 0 ]]; then
    echo "[$phase] ERROR: $missing required file(s) missing. Aborting." >&2
    return 1
  fi

  chmod +x "$target_dir"/scripts/*.sh 2>/dev/null || true
  echo "[$phase] Overlay staged: ${#required_files[@]} files verified in $target_dir"
}

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
[[ -d "$KRDP_OVERLAY_DIR" ]] && [[ -f "$KRDP_OVERLAY_DIR/src/RdpConnection.cpp" ]] || {
  echo "Missing KRDP overlay: $KRDP_OVERLAY_DIR/src/RdpConnection.cpp" >&2
  exit 1
}

if [[ ! -d "$ISO_DIR/.git" ]]; then
  if [[ -n "${ISO_TAG:-}" ]]; then
    git -C "$SCRIPT_DIR" clone --depth 1 --branch "$ISO_TAG" https://github.com/endeavouros-team/EndeavourOS-ISO.git "$(basename "$ISO_DIR")"
  else
    git -C "$SCRIPT_DIR" clone https://github.com/endeavouros-team/EndeavourOS-ISO.git "$(basename "$ISO_DIR")"
  fi
fi

# Ensure our custom hooks are always applied into the disposable ISO profile tree.
if [[ -d "$ISO_HOOKS_DIR" ]]; then
  if [[ -f "$ISO_HOOKS_DIR/run_before_squashfs.sh" ]]; then
    cp -f "$ISO_HOOKS_DIR/run_before_squashfs.sh" "$ISO_DIR/run_before_squashfs.sh"
  fi
  if [[ -f "$ISO_HOOKS_DIR/prepare.sh" ]]; then
    cp -f "$ISO_HOOKS_DIR/prepare.sh" "$ISO_DIR/prepare.sh"
  fi
  if [[ -f "$ISO_HOOKS_DIR/packages.x86_64" ]]; then
    cp -f "$ISO_HOOKS_DIR/packages.x86_64" "$ISO_DIR/packages.x86_64"
  fi
  if [[ -f "$ISO_HOOKS_DIR/get_country.sh" ]]; then
    # Make helper available to the chrooted script as /root/get_country.sh.
    mkdir -p "$ISO_DIR/airootfs/root"
    cp -f "$ISO_HOOKS_DIR/get_country.sh" "$ISO_DIR/airootfs/root/get_country.sh"
  fi
fi

mkdir -p "$SCRIPT_DIR/build-src/deps"
if [[ ! -d "$CALAMARES_SRC_DIR/.git" ]]; then
  rm -rf "$CALAMARES_SRC_DIR"
  git -C "$SCRIPT_DIR/build-src/deps" clone --depth 1 --branch "${CALAMARES_TAG}" https://github.com/endeavouros-team/calamares.git "$(basename "$CALAMARES_SRC_DIR")"
fi
[[ -d "$CALAMARES_OVERLAY_DIR" ]] && [[ -f "$CALAMARES_OVERLAY_DIR/data/eos/scripts/ssh_setup_script.sh" ]] || {
  echo "Missing Calamares overlay: $CALAMARES_OVERLAY_DIR/data/eos/scripts/ssh_setup_script.sh" >&2
  exit 1
}
[[ -f "$CALAMARES_WEBVIEW_SCHEME_PATCH" ]] || {
  echo "Missing Calamares webview scheme patch: $CALAMARES_WEBVIEW_SCHEME_PATCH" >&2
  exit 1
}
[[ -f "$CALAMARES_OVERLAY_DIR/src/modules/webview/CMakeLists.txt" ]] || {
  echo "Missing webview module source: $CALAMARES_OVERLAY_DIR/src/modules/webview/CMakeLists.txt" >&2
  exit 1
}
[[ -d "$BOOT_OVERLAY_DIR" ]] && [[ -f "$BOOT_OVERLAY_DIR/syslinux/syslinux.cfg" ]] || {
  echo "Missing boot overlay: $BOOT_OVERLAY_DIR/syslinux/syslinux.cfg (required for legacy boot; must be in repo)" >&2
  exit 1
}
rsync -a "$CALAMARES_OVERLAY_DIR/" "$CALAMARES_SRC_DIR/"
[[ -f "$CALAMARES_SRC_DIR/data/eos/scripts/ssh_setup_script.sh" ]] || {
  echo "Missing custom Calamares SSH setup script under: $CALAMARES_SRC_DIR" >&2
  exit 1
}

mkdir -p "$ISO_DIR/airootfs/root/packages"

# Remove stale locally-built artifacts so each run stages a single, current
# package for krdp/calamares/ckbcomp.
rm -f \
  "$ISO_DIR"/airootfs/root/packages/krdp-*.pkg.tar.zst \
  "$ISO_DIR"/airootfs/root/packages/krdp-debug-*.pkg.tar.zst \
  "$ISO_DIR"/airootfs/root/packages/calamares-*.pkg.tar.zst \
  "$ISO_DIR"/airootfs/root/packages/calamares-debug-*.pkg.tar.zst \
  "$ISO_DIR"/airootfs/root/packages/ckbcomp-*.pkg.tar.zst

# Apply boot overlay so every clone of the ISO repo gets our supported legacy syslinux.cfg (no whichsys.c32).
# This is built into the produced ISO by mkarchiso. Required for validation and for any clone of this repo.
apply_syslinux_overlay "$ISO_DIR" "$BOOT_OVERLAY_DIR/syslinux/syslinux.cfg" "host-prebuild"

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
      yaml-cpp cryptsetup dmidecode doxygen gawk gptfdisk hwinfo \
      kirigami kdeclarative qt6-5compat nbd

# Workaround for the known XZ compression bug in squashfs-tools 4.7.x
RUN pacman -U --noconfirm https://archive.archlinux.org/packages/s/squashfs-tools/squashfs-tools-4.6.1-1-x86_64.pkg.tar.zst

RUN useradd -m -G wheel -s /bin/bash builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
DOCKERFILE

# Optional: use host package cache so pacman finds already-downloaded packages (avoids mirror 404s)
CACHE_VOL=()
if [[ -d "$PKG_CACHE_DIR" ]] && compgen -G "$PKG_CACHE_DIR"/*.pkg.tar.zst >/dev/null 2>&1; then
  CACHE_VOL=(-v "$PKG_CACHE_DIR:/host-pkg-cache:ro")
fi

"${DOCKER_CMD[@]}" run --rm \
  "${CACHE_VOL[@]}" \
  -e "KRDP_TAG=$KRDP_TAG" \
  -v "$ISO_DIR:/build" \
  -v "$PATCH_FILE:/tmp/krdp-working-fixes.patch:ro" \
  -v "$KRDP_OVERLAY_DIR:/tmp/krdp-overlay:ro" \
  -v "$CALAMARES_PATCH_FILE:/tmp/calamares-eos-script-kdialog.patch:ro" \
  -v "$CALAMARES_DESKTOP_PATCH:/tmp/calamares-desktop-exec.patch:ro" \
  -v "$CALAMARES_WEBVIEW_SCHEME_PATCH:/tmp/calamares-webview-scheme.patch:ro" \
  -v "$CALAMARES_SRC_DIR:/tmp/endeavouros-calamares:ro" \
  -w /build \
  "$IMAGE_NAME" \
  bash -lc '
set -euo pipefail

# Use host package cache if mounted: add writable CacheDir first, read-only cache second.
if [[ -d /host-pkg-cache ]]; then
  ncache="$(ls -1 /host-pkg-cache/*.pkg.tar.zst 2>/dev/null | wc -l)"
  echo "[build] Using $ncache cached package(s) from /host-pkg-cache"
  grep -q "CacheDir.*host-pkg-cache" /etc/pacman.conf || {
    sed -i '"'"'/^\[options\]/a CacheDir = /var/cache/pacman/pkg'"'"' /etc/pacman.conf
    sed -i '"'"'/^CacheDir = \/var\/cache\/pacman\/pkg/a CacheDir = /host-pkg-cache'"'"' /etc/pacman.conf
  }
fi

# Refresh pacman sync databases so it queries the latest package versions (fixes mirror 404s)
pacman -Sy --noconfirm

PKG_DIR=/tmp/krdp-pkg
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"
cp /tmp/krdp-working-fixes.patch "$PKG_DIR/"
tar -C /tmp/krdp-overlay -czf "$PKG_DIR/krdp-overlay.tar.gz" src

KRDP_SRC_DIR=/tmp/krdp-src
rm -rf "$KRDP_SRC_DIR"

krdp_repo_urls=(
  "https://invent.kde.org/plasma/krdp.git"
  "https://github.com/KDE/krdp.git"
)

krdp_clone_ok=0
for repo in "${krdp_repo_urls[@]}"; do
  echo "[krdp-source] Attempting clone from: $repo (ref: ${KRDP_TAG:-<default branch>})"
  if [[ -n "${KRDP_TAG:-}" ]]; then
    clone_cmd=(git clone --depth 1 --branch "$KRDP_TAG" "$repo" "$KRDP_SRC_DIR")
  else
    clone_cmd=(git clone --depth 1 "$repo" "$KRDP_SRC_DIR")
  fi
  if "${clone_cmd[@]}"; then
    krdp_clone_ok=1
    echo "[krdp-source] Using source remote: $repo"
    break
  fi
done

if [[ "$krdp_clone_ok" -ne 1 ]]; then
  echo "[krdp-source] Failed to clone KRDP from all configured remotes" >&2
  exit 1
fi

tar -C /tmp -czf "$PKG_DIR/krdp-src.tar.gz" krdp-src

cat > "$PKG_DIR/PKGBUILD" <<'"'"'EOF'"'"'
pkgname=krdp
pkgver=0
epoch=1
pkgrel=1
pkgdesc="Library and examples for creating an RDP server (patched)"
arch=(x86_64)
url="https://kde.org/plasma-desktop/"
license=(LGPL-2.0-or-later)
depends=(freerdp gcc-libs glibc kcmutils kconfig kcoreaddons kcrash kguiaddons ki18n kpipewire kstatusnotifieritem libxkbcommon pam qt6-base qtkeychain-qt6 systemd-libs wayland kirigami kdeclarative)
makedepends=(extra-cmake-modules git plasma-wayland-protocols qt6-wayland)
source=("krdp-src.tar.gz" "krdp-working-fixes.patch" "krdp-overlay.tar.gz")
sha256sums=("SKIP" "SKIP" "SKIP")

pkgver() {
  cd krdp-src
  local base
  base="$(sed -n '\''s/^set(PROJECT_VERSION \"\\(.*\\)\")/\\1/p'\'' CMakeLists.txt | head -n1)"
  if [[ -z "$base" ]]; then
    base="0"
  fi
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf "%s.r%s.g%s" "$base" "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
  else
    printf "%s.r0.glocal" "$base"
  fi
}

prepare() {
  cd krdp-src
  # Overlay RdpConnection.cpp first so patch sees it as already applied (avoids hunk offset
  # failures when upstream line numbers change). Then apply patch for all other files.
  tar -xf "${srcdir}/krdp-overlay.tar.gz" -C .
  patch_ret=0
  patch -Np1 -i "${srcdir}/krdp-working-fixes.patch" || patch_ret=$?
  if [ "$patch_ret" -eq 1 ] && [ -f src/RdpConnection.cpp.rej ]; then
    rej_count=$(ls src/*.rej 2>/dev/null | wc -l)
    if [ "$rej_count" -eq 1 ]; then
      rm -f src/RdpConnection.cpp.rej
      return 0
    fi
  fi
  [ "$patch_ret" -ne 0 ] && return "$patch_ret"
}

build() {
  cmake -B build -S krdp-src \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=/usr/lib \
    -DBUILD_TESTING=OFF
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
cp /tmp/calamares-eos-script-kdialog.patch "$CALAMARES_PKG_DIR/"
cp /tmp/calamares-desktop-exec.patch "$CALAMARES_PKG_DIR/"
cp /tmp/calamares-webview-scheme.patch "$CALAMARES_PKG_DIR/"
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
depends=(qt6-svg qt6-webengine yaml-cpp networkmanager upower kcoreaddons kconfig ki18n kservice kwidgetsaddons kpmcore squashfs-tools rsync pybind11 cryptsetup doxygen dmidecode gptfdisk hwinfo kparts polkit-qt6 python solid qt6-tools libpwquality qt6-declarative ckbcomp kirigami kdeclarative kcmutils kwin qt6-5compat boost-libs)
makedepends=(cmake extra-cmake-modules gawk python-jsonschema python-pyaml python-unidecode)
provides=(calamares)
conflicts=(calamares-git)
source=("calamares-src.tar.gz" "calamares-eos-script-kdialog.patch" "calamares-desktop-exec.patch" "calamares-webview-scheme.patch")
sha256sums=("SKIP" "SKIP" "SKIP" "SKIP")

pkgver() {
  cd calamares-src
  local version
  version="$(sed -n '\''s/^set(CALAMARES_VERSION_SHORT[[:space:]]*\"\\([^\"]*\\)\")/\\1/p'\'' CMakeLists.txt | head -n1)"
  if [[ -z "$version" ]]; then
    version="0"
  fi
  printf "%s.r%s.g%s" "$version" "$(git rev-list --count HEAD 2>/dev/null || echo 0)" "$(git rev-parse --short HEAD 2>/dev/null || echo local)"
}

prepare() {
  cd calamares-src
  patch -Np1 -i "${srcdir}/calamares-eos-script-kdialog.patch"
  patch -Np1 -i "${srcdir}/calamares-desktop-exec.patch"
  patch -Np1 -i "${srcdir}/calamares-webview-scheme.patch"
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
    summaryq tracking welcomeq"
  cmake --build build
}

package() {
  DESTDIR="${pkgdir}" cmake --install build
  install -dm 0755 "${pkgdir}/etc"
  cp -rp "${srcdir}/calamares-src/data/eos" "${pkgdir}/etc/calamares"
}
EOF

chown -R builder:builder "$CALAMARES_PKG_DIR"
# Run in new session so makepkg does not receive SIGHUP from su login shell (signal 1)
setsid su - builder -c "cd $CALAMARES_PKG_DIR && makepkg -sf --noconfirm" </dev/null
cp -f "$CALAMARES_PKG_DIR"/calamares-*.pkg.tar.zst /build/airootfs/root/packages/
ls -1 /build/airootfs/root/packages/calamares-*.pkg.tar.zst
'

if [[ "$SKIP_ISO_BUILD" -eq 1 ]]; then
  echo "Patched KRDP + custom Calamares packages prepared under: $ISO_DIR/airootfs/root/packages"
  exit 0
fi

# Optional: use host package cache for mkarchiso (profile pacman.conf gets CacheDir so pacstrap uses cache)
CACHE_MOUNT_ISO=()
PACMAN_CONF_BACKUP=""
if [[ -d "$PKG_CACHE_DIR" ]] && compgen -G "$PKG_CACHE_DIR"/*.pkg.tar.zst >/dev/null 2>&1; then
  CACHE_MOUNT_ISO=(-v "$PKG_CACHE_DIR:/host-pkg-cache:ro")
  echo "Using package cache for mkarchiso: $PKG_CACHE_DIR"
  if ! grep -q "CacheDir.*host-pkg-cache" "$ISO_DIR/pacman.conf" 2>/dev/null; then
    PACMAN_CONF_BACKUP="$ISO_DIR/pacman.conf.bak.$$"
    cp -a "$ISO_DIR/pacman.conf" "$PACMAN_CONF_BACKUP"
    sed -i '/^\[options\]/a CacheDir = /var/cache/pacman/pkg' "$ISO_DIR/pacman.conf"
    sed -i '/^CacheDir = \/var\/cache\/pacman\/pkg/a CacheDir = /host-pkg-cache' "$ISO_DIR/pacman.conf"
    restore_pacman_conf() {
      [[ -n "$PACMAN_CONF_BACKUP" ]] && [[ -f "$PACMAN_CONF_BACKUP" ]] && mv -f "$PACMAN_CONF_BACKUP" "$ISO_DIR/pacman.conf"
    }
    trap restore_pacman_conf EXIT
  fi
fi

"${DOCKER_CMD[@]}" run --rm --privileged \
  "${CACHE_MOUNT_ISO[@]}" \
  -v "$ISO_DIR:/build" \
  -v "$BOOT_OVERLAY_DIR:/boot-overlay:ro" \
  -v "$CALAMARES_OVERLAY_DIR:/calamares-overlay:ro" \
  -w /build \
  "$IMAGE_NAME" \
  bash -lc '
set -euo pipefail
if [[ -d /host-pkg-cache ]]; then
  echo "[mkarchiso] Package cache at /host-pkg-cache ($(ls -1 /host-pkg-cache/*.pkg.tar.zst 2>/dev/null | wc -l) packages); profile pacman.conf uses it as first CacheDir"
fi

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

# Refresh package metadata once here so package fallback checks are reliable.
pacman --config /build/pacman.conf -Sy --noconfirm >/dev/null

# EndeavourOS package rename compatibility:
# if eos-settings-plasma is no longer published, switch all references to eos-settings-kde.
if grep -R -q --exclude-dir=.git --exclude-dir=work --exclude-dir=out -- "eos-settings-plasma" /build; then
  if ! pacman --config /build/pacman.conf -Si eos-settings-plasma >/dev/null 2>&1; then
    if pacman --config /build/pacman.conf -Si eos-settings-kde >/dev/null 2>&1; then
      while IFS= read -r file; do
        sed -i "s/eos-settings-plasma/eos-settings-kde/g" "$file"
        echo "[container-pre-prepare] Rewrote package reference in: $file"
      done < <(grep -R -I -l --exclude-dir=.git --exclude-dir=work --exclude-dir=out -- "eos-settings-plasma" /build)
    else
      echo "[container-pre-prepare] Neither eos-settings-plasma nor eos-settings-kde is available in configured repos" >&2
      exit 1
    fi
  fi
fi

# Fix ownership for bind-mounted working tree so non-root prepare hooks can write safely.
chown -R builder:builder /build

su - builder -c "cd /build && ./prepare.sh"

# Do not stage Calamares overlay here: the custom calamares package (from
# /build/airootfs/root/packages) installs the same files; staging would cause
# "conflicting files" and abort the chroot pacman -U.

apply_overlay_in_build() {
  local phase="$1"
  local -a candidates=()
  local replaced=0

  while IFS= read -r cfg; do
    candidates+=("$cfg")
  done < <(find /build -type f -name "syslinux.cfg" 2>/dev/null || true)

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    echo "[$phase] No syslinux.cfg candidates found under /build"
    return 0
  fi

  for cfg in "${candidates[@]}"; do
    if [[ "$cfg" == */syslinux/syslinux.cfg ]] || grep -Eq '^[[:space:]]*[^#].*whichsys\.c32' "$cfg"; then
      cp -f /boot-overlay/syslinux/syslinux.cfg "$cfg"
      replaced=$((replaced + 1))
    fi
  done

  echo "[$phase] Applied overlay to $replaced syslinux.cfg file(s)"
  for cfg in "${candidates[@]}"; do
    if grep -Eq '^[[:space:]]*[^#].*whichsys\.c32' "$cfg"; then
      echo "[$phase] $cfg still references whichsys.c32"
    else
      echo "[$phase] $cfg is clean (no whichsys.c32)"
    fi
  done
}

# Apply boot overlay after prepare.sh so mkarchiso sees our syslinux.cfg.
apply_overlay_in_build "container-post-prepare"

rm -rf /build/work /build/out
cd /build && ./mkarchiso -v .

  if grep -R --include="syslinux.cfg" -nE '\''^[[:space:]]*[^#].*whichsys\.c32'\'' /build/work >/tmp/whichsys-work-hits 2>/dev/null; then
    echo "[container-post-mkarchiso] whichsys.c32 still present in work tree:"
    cat /tmp/whichsys-work-hits
  else
    echo "[container-post-mkarchiso] no whichsys.c32 matches found in /build/work syslinux.cfg files"
  fi

  # Validate Calamares configuration in the work tree (pre-squash state)
  AIROOTFS_DIR="/build/work/x86_64/airootfs"
  CALAMARES_ETC="$AIROOTFS_DIR/etc/calamares"
  missing=0
  if [[ ! -f "$CALAMARES_ETC/modules/eos_script_ssh_setup.conf" ]]; then
    echo "[container-post-mkarchiso] Validation failed: missing $CALAMARES_ETC/modules/eos_script_ssh_setup.conf" >&2
    missing=$((missing + 1))
  fi
  if [[ ! -f "$CALAMARES_ETC/remote-setup.html" ]]; then
    echo "[container-post-mkarchiso] Validation failed: missing $CALAMARES_ETC/remote-setup.html (webview page)" >&2
    missing=$((missing + 1))
  fi
  if ! grep -Eq "config:[[:space:]]*eos_script_ssh_setup\.conf" "$CALAMARES_ETC/settings_online.conf"; then
    echo "[container-post-mkarchiso] Validation failed: settings_online.conf missing eos_script_ssh_setup module entry" >&2
    missing=$((missing + 1))
  fi
  if ! grep -q "GITHUB_USER\|ENABLE_SSHD\|ENABLE_RDP" "$CALAMARES_ETC/scripts/ssh_setup_script.sh"; then
    echo "[container-post-mkarchiso] Validation failed: ssh_setup_script.sh missing expected remote-setup logic" >&2
    missing=$((missing + 1))
  fi
  if [[ ! -f "$CALAMARES_ETC/modules/shellprocess_copy_calamares_scripts.conf" ]]; then
    echo "[container-post-mkarchiso] Validation failed: missing shellprocess_copy_calamares_scripts.conf" >&2
    missing=$((missing + 1))
  fi
  if [[ ! -f "$CALAMARES_ETC/modules/webview@remote_setup.conf" ]]; then
    echo "[container-post-mkarchiso] Validation failed: missing webview@remote_setup.conf" >&2
    missing=$((missing + 1))
  fi
  if ! grep -Eq "webview@remote_setup\.conf|config:.*webview.*remote_setup" "$CALAMARES_ETC/settings_online.conf"; then
    echo "[container-post-mkarchiso] Validation failed: settings_online.conf missing webview@remote_setup instance" >&2
    missing=$((missing + 1))
  fi
  if [[ $missing -gt 0 ]]; then
    echo "[container-post-mkarchiso] $missing validation failure(s). Aborting." >&2
    exit 1
  fi
  echo "[container-post-mkarchiso] Calamares configuration validated successfully in work tree"
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
  if grep -Eq '^[[:space:]]*[^#].*whichsys\.c32' <<< "$iso_syslinux_cfg"; then
    echo "ISO validation failed: boot/syslinux/syslinux.cfg still references whichsys.c32" >&2
    echo "Extracted boot/syslinux/syslinux.cfg from ISO (first 20 lines):" >&2
    printf "%s\n" "$iso_syslinux_cfg" | sed -n "1,20p" >&2
    trace_syslinux_candidates "$ISO_DIR" "host-post-build"
    exit 1
  fi
  echo "ISO build complete: $latest_iso"
else
  echo "ISO build finished but no ISO found under $ISO_DIR/out" >&2
  exit 1
fi
