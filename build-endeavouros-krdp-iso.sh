#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_DIR="${SCRIPT_DIR}/endeavouros-iso-build"
# Package cache root. Must be in a world-traversable path because pacman 7
# uses the unprivileged 'alpm' user (DownloadUser) for downloads; that user
# cannot traverse /home/<user>/ (mode 700) to reach a nested cache dir.
# Override via env:  PKG_CACHE_DIR=/other/path ./build-endeavouros-krdp-iso.sh
PKG_CACHE_DIR="${PKG_CACHE_DIR:-/var/cache/eos-krdp-build}"
WORK_DIR="$PKG_CACHE_DIR/work"
OUT_DIR="$PKG_CACHE_DIR/out"
KRDP_SRC_DIR="${SCRIPT_DIR}/build-src/deps/krdp"
CALAMARES_SRC_DIR="${SCRIPT_DIR}/build-src/deps/endeavouros-calamares"
SKIP_ISO_BUILD=0
CLEAN_BUILD=0

usage() {
  cat <<'EOF'
Usage:
  ./build-endeavouros-krdp-iso.sh [--clean] [--skip-iso-build]

Options:
  --clean            Delete build cache directories ($PKG_CACHE_DIR) before building.
  --skip-iso-build   Build and cache patched KRDP + custom Calamares packages only.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      CLEAN_BUILD=1
      shift
      ;;
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
require_cmd makepkg
require_cmd sudo
require_cmd bsdtar
require_cmd mkarchiso

if [[ $EUID -eq 0 ]]; then
  echo "Run as a regular user (not root). This script uses sudo where needed." >&2
  exit 1
fi

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

# Ensure all submodules are initialised and checked out.
git -C "$SCRIPT_DIR" submodule update --init --recursive

# Submodule health checks
git -C "$ISO_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "EndeavourOS-ISO submodule not initialised at: $ISO_DIR" >&2
  exit 1
}
git -C "$KRDP_SRC_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "KRDP submodule not initialised at: $KRDP_SRC_DIR" >&2
  exit 1
}
git -C "$CALAMARES_SRC_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "Calamares submodule not initialised at: $CALAMARES_SRC_DIR" >&2
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

# Temporary build directory; cleaned automatically on exit.
BUILD_TMP=$(mktemp -d /tmp/eos-krdp-build.XXXXXX)

# ---------------------------------------------------------------------------
# Sudo: authenticate once, disable passwd_timeout, keep token alive.
# passwd_timeout=0 makes sudo wait indefinitely for a password if it ever
# needs to re-prompt during the build (e.g. after a very long package step).
# ---------------------------------------------------------------------------
echo "[sudo] This build requires root access. Please enter your password:"
sudo -v
echo "Defaults:$(id -un) passwd_timeout=0" \
  | sudo tee /etc/sudoers.d/99-eos-build-no-timeout > /dev/null
# Refresh the token every 60 s so it never expires mid-build.
( while true; do sleep 60; sudo -n -v 2>/dev/null || true; done ) &
_SUDO_KEEPALIVE_PID=$!

cleanup() {
  kill "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true
  sudo rm -f /etc/sudoers.d/99-eos-build-no-timeout 2>/dev/null || true
  rm -rf "$BUILD_TMP"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Clean build cache
# ---------------------------------------------------------------------------
if [[ "$CLEAN_BUILD" -eq 1 ]]; then
  echo "[clean] Removing build cache: $PKG_CACHE_DIR"
  sudo rm -rf "$PKG_CACHE_DIR"
fi

# ---------------------------------------------------------------------------
# Package cache
# ---------------------------------------------------------------------------
# Run ./download-dependent-packages.sh to pre-populate the cache.
# Even without pre-population the build works: packages are downloaded on
# demand and stored here, making subsequent runs faster.
# pacman/  → root:root 755: pacman's 'alpm' download user needs to be able to
#            traverse here; root-owned keeps it consistent with the system cache.
# sources/ → user-owned: makepkg reads/writes source files here as the current user.
sudo install -dm755 "$PKG_CACHE_DIR/pacman"
sudo install -dm755 -o "$(id -u)" -g "$(id -g)" "$PKG_CACHE_DIR/sources"

# Custom makepkg.conf: route pacman dep downloads through the cache and
# store source files (e.g. the ckbcomp script) in the cache sources dir.
MKPKG_CONF="$BUILD_TMP/makepkg.conf"
cp /etc/makepkg.conf "$MKPKG_CONF"
# PACMAN_OPTS+= appends to any flags already accumulated by arg parsing
# (e.g. --noconfirm), preserving them while adding --cachedir.
printf '\nPACMAN_OPTS+=(--cachedir "%s/pacman")\nSRCDEST="%s/sources"\nMAKEFLAGS="-j%s"\n' \
  "$PKG_CACHE_DIR" "$PKG_CACHE_DIR" "$(nproc)" >> "$MKPKG_CONF"

# ---------------------------------------------------------------------------
# KRDP
# ---------------------------------------------------------------------------
echo "[build] Building KRDP package..."
KRDP_PKG_DIR="$BUILD_TMP/krdp-pkg"
mkdir -p "$KRDP_PKG_DIR"

# Package the pre-patched KRDP submodule source.
tar -C "$KRDP_SRC_DIR" --exclude='.git' --transform 's,^\./,krdp-src/,' \
  -czf "$KRDP_PKG_DIR/krdp-src.tar.gz" .

cat > "$KRDP_PKG_DIR/PKGBUILD" <<'EOF'
pkgname=krdp
pkgver=0
epoch=1
pkgrel=1
pkgdesc="Library and examples for creating an RDP server (patched)"
arch=(x86_64)
url="https://github.com/nathanAndrinoid/krdp"
license=(LGPL-2.0-or-later)
depends=(freerdp gcc-libs glibc kcmutils kconfig kcoreaddons kcrash kguiaddons ki18n kpipewire kstatusnotifieritem libxkbcommon pam qt6-base qtkeychain-qt6 systemd-libs wayland kirigami kdeclarative)
makedepends=(extra-cmake-modules git plasma-wayland-protocols qt6-wayland)
source=("krdp-src.tar.gz")
sha256sums=("SKIP")

pkgver() {
  cd krdp-src
  local base
  base="$(sed -n 's/^set(PROJECT_VERSION \"\\(.*\\)\")/\\1/p' CMakeLists.txt | head -n1)"
  if [[ -z "$base" ]]; then
    base="0"
  fi
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf "%s.r%s.g%s" "$base" "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
  else
    printf "%s.r0.glocal" "$base"
  fi
}

build() {
  cmake -B build -S krdp-src \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=/usr/lib \
    -DBUILD_TESTING=OFF
  cmake --build build --parallel $(nproc)
}

package() {
  DESTDIR="${pkgdir}" cmake --install build
}
EOF

(cd "$KRDP_PKG_DIR" && makepkg --config "$MKPKG_CONF" -sf --noconfirm)
cp -f "$KRDP_PKG_DIR"/krdp-*.pkg.tar.zst "$ISO_DIR/airootfs/root/packages/"
ls -1 "$ISO_DIR"/airootfs/root/packages/krdp-*.pkg.tar.zst

# ---------------------------------------------------------------------------
# ckbcomp
# ---------------------------------------------------------------------------
echo "[build] Building ckbcomp package..."
CKBCOMP_PKG_DIR="$BUILD_TMP/ckbcomp-pkg"
mkdir -p "$CKBCOMP_PKG_DIR"

cat > "$CKBCOMP_PKG_DIR/PKGBUILD" <<'EOF'
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

(cd "$CKBCOMP_PKG_DIR" && makepkg --config "$MKPKG_CONF" -sf --noconfirm)
cp -f "$CKBCOMP_PKG_DIR"/ckbcomp-*.pkg.tar.zst "$ISO_DIR/airootfs/root/packages/"
ls -1 "$ISO_DIR"/airootfs/root/packages/ckbcomp-*.pkg.tar.zst

# Calamares makepkg -s resolves runtime deps via pacman; install local ckbcomp first.
sudo pacman -U --noconfirm "$CKBCOMP_PKG_DIR"/ckbcomp-*.pkg.tar.zst
pacman -Q ckbcomp

# ---------------------------------------------------------------------------
# Calamares
# ---------------------------------------------------------------------------
echo "[build] Building Calamares package..."
CAL_PKG_DIR="$BUILD_TMP/calamares-pkg"
mkdir -p "$CAL_PKG_DIR"
cp -a "$CALAMARES_SRC_DIR" "$CAL_PKG_DIR/calamares-src"
tar -C "$CAL_PKG_DIR" -czf "$CAL_PKG_DIR/calamares-src.tar.gz" calamares-src
rm -rf "$CAL_PKG_DIR/calamares-src"

cat > "$CAL_PKG_DIR/PKGBUILD" <<'EOF'
pkgname=calamares
pkgver=0
epoch=1
pkgrel=1
pkgdesc="Calamares installer for EndeavourOS (custom installer hooks)"
arch=(x86_64)
url="https://github.com/nathanAndrinoid/EndeavourOS-calamares"
license=(GPL3)
depends=(qt6-svg qt6-webengine yaml-cpp networkmanager upower kcoreaddons kconfig ki18n kservice kwidgetsaddons kpmcore squashfs-tools rsync pybind11 cryptsetup doxygen dmidecode gptfdisk hwinfo kparts polkit-qt6 python solid qt6-tools libpwquality qt6-declarative ckbcomp kirigami kdeclarative kcmutils kwin qt6-5compat boost-libs)
makedepends=(cmake extra-cmake-modules gawk python-jsonschema python-pyaml python-unidecode)
provides=(calamares)
conflicts=(calamares-git)
source=("calamares-src.tar.gz")
sha256sums=("SKIP")

pkgver() {
  cd calamares-src
  local version
  version="$(sed -n 's/^set(CALAMARES_VERSION_SHORT[[:space:]]*\"\\([^\"]*\\)\")/\\1/p' CMakeLists.txt | head -n1)"
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
    -DBUILD_TESTING=ON \
    -DBUILD_SCHEMA_TESTING=ON \
    -DSKIP_MODULES="dracut \
    dummycpp dummyprocess dummypython dummypythonqt \
    finishedq initcpio keyboardq license localeq notesqml oemid \
    openrcdmcryptcfg plymouthcfg plasmalnf services-openrc \
    summaryq tracking welcomeq"
  cmake --build build --parallel $(nproc)
  # Exclude tests that require hardware or system state not present in a
  # container build environment (real disks, locale-gen, package DB, etc.).
  ctest --test-dir build --output-on-failure \
    -E "^(localetest|packagechoosertest|partitiondevicestest|partitionconfigtest)$"
}

package() {
  DESTDIR="${pkgdir}" cmake --install build
  install -dm 0755 "${pkgdir}/etc"
  cp -rp "${srcdir}/calamares-src/data/eos" "${pkgdir}/etc/calamares"
}
EOF

(cd "$CAL_PKG_DIR" && makepkg --config "$MKPKG_CONF" -sf --noconfirm)
cp -f "$CAL_PKG_DIR"/calamares-*.pkg.tar.zst "$ISO_DIR/airootfs/root/packages/"
ls -1 "$ISO_DIR"/airootfs/root/packages/calamares-*.pkg.tar.zst

if [[ "$SKIP_ISO_BUILD" -eq 1 ]]; then
  echo "Patched KRDP + custom Calamares packages prepared under: $ISO_DIR/airootfs/root/packages"
  exit 0
fi

# ---------------------------------------------------------------------------
# ISO build
# ---------------------------------------------------------------------------

# Ensure /etc/pacman.d/endeavouros-mirrorlist exists for pacstrap inside mkarchiso.
if [[ ! -s /etc/pacman.d/endeavouros-mirrorlist ]] || \
   ! grep -qE '^[[:space:]]*Server[[:space:]]*=' /etc/pacman.d/endeavouros-mirrorlist 2>/dev/null; then
  echo "[iso-build] Writing /etc/pacman.d/endeavouros-mirrorlist..."
  sudo tee /etc/pacman.d/endeavouros-mirrorlist > /dev/null <<'EOF'
Server = https://mirror.alpix.eu/endeavouros/repo/$repo/$arch
Server = https://us.mirror.endeavouros.com/endeavouros/repo/$repo/$arch
EOF
fi

# Fix SigLevel for [endeavouros] repo in the ISO profile pacman.conf.
if grep -q "^\[endeavouros\]" "$ISO_DIR/pacman.conf"; then
  sed -i "/^\[endeavouros\]/,/^\[/ s/^SigLevel.*/SigLevel = Optional TrustAll/" "$ISO_DIR/pacman.conf"
  if ! awk '/^\[endeavouros\]/{in_repo=1;next}/^\[/{in_repo=0}in_repo && /^SigLevel[[:space:]]*=/{found=1}END{exit !found}' "$ISO_DIR/pacman.conf"; then
    sed -i "/^\[endeavouros\]/a SigLevel = Optional TrustAll" "$ISO_DIR/pacman.conf"
  fi
fi

# Refresh ISO profile package databases so rename compatibility check is reliable.
sudo pacman --config "$ISO_DIR/pacman.conf" -Sy --noconfirm \
  --cachedir "$PKG_CACHE_DIR/pacman" >/dev/null

# EndeavourOS package rename compatibility:
# if eos-settings-plasma is no longer published, switch all references to eos-settings-kde.
if grep -R -q --exclude-dir=.git --exclude-dir=work --exclude-dir=out -- "eos-settings-plasma" "$ISO_DIR"; then
  if ! pacman --config "$ISO_DIR/pacman.conf" -Si eos-settings-plasma >/dev/null 2>&1; then
    if pacman --config "$ISO_DIR/pacman.conf" -Si eos-settings-kde >/dev/null 2>&1; then
      while IFS= read -r file; do
        sed -i "s/eos-settings-plasma/eos-settings-kde/g" "$file"
        echo "[pre-prepare] Rewrote package reference in: $file"
      done < <(grep -R -I -l --exclude-dir=.git --exclude-dir=work --exclude-dir=out -- "eos-settings-plasma" "$ISO_DIR")
    else
      echo "[pre-prepare] Neither eos-settings-plasma nor eos-settings-kde is available in configured repos" >&2
      exit 1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Pre-flight ISO profile validation
# Catch missing runtime boot dependencies before the long mkarchiso run.
# ---------------------------------------------------------------------------
echo "[preflight] Validating ISO profile requirements..."
preflight_errors=0

# syslinux must be in the package list; pacstrap installs it into the airootfs
# and mkarchiso copies /usr/lib/syslinux/bios/*.c32 (including ldlinux.c32)
# into boot/syslinux/ of the ISO image.
if ! grep -qxF 'syslinux' "$ISO_DIR/packages.x86_64"; then
  echo "[preflight] FAIL: 'syslinux' is not in $ISO_DIR/packages.x86_64" \
       "(provides ldlinux.c32, isolinux.bin, menu.c32, etc.)" >&2
  preflight_errors=$((preflight_errors + 1))
fi

# os-prober must be in the package list so Calamares can detect dual-boot OSes
# during the live session partitioning phase.
if ! grep -qxF 'os-prober' "$ISO_DIR/packages.x86_64"; then
  echo "[preflight] FAIL: 'os-prober' is not in $ISO_DIR/packages.x86_64" \
       "(Calamares PartUtils::runOsprober will silently fail)" >&2
  preflight_errors=$((preflight_errors + 1))
fi

# The profile syslinux/ directory must exist and contain .cfg files so
# mkarchiso can assemble the boot menu.
if [[ ! -d "$ISO_DIR/syslinux" ]]; then
  echo "[preflight] FAIL: syslinux profile directory missing: $ISO_DIR/syslinux" >&2
  preflight_errors=$((preflight_errors + 1))
else
  cfg_count=$(find "$ISO_DIR/syslinux" -maxdepth 1 -name '*.cfg' | wc -l)
  if [[ "$cfg_count" -eq 0 ]]; then
    echo "[preflight] FAIL: no .cfg files found in $ISO_DIR/syslinux/" >&2
    preflight_errors=$((preflight_errors + 1))
  fi
fi

# profiledef.sh must declare bios.syslinux as a bootmode, otherwise mkarchiso
# will never assemble the syslinux boot directory at all.
if ! grep -qE "bios\.syslinux" "$ISO_DIR/profiledef.sh"; then
  echo "[preflight] FAIL: 'bios.syslinux' bootmode not declared in $ISO_DIR/profiledef.sh" >&2
  preflight_errors=$((preflight_errors + 1))
fi

if [[ $preflight_errors -gt 0 ]]; then
  echo "[preflight] $preflight_errors pre-flight failure(s). Aborting before mkarchiso." >&2
  exit 1
fi
echo "[preflight] ISO profile requirements OK"

echo "[iso-build] Running prepare.sh..."
(cd "$ISO_DIR" && ./prepare.sh)

echo "[iso-build] Running mkarchiso (sudo required)..."
sudo rm -rf "$WORK_DIR" "$OUT_DIR"
sudo mkdir -p "$WORK_DIR" "$OUT_DIR"

# Give mkarchiso a pacman.conf that points pacstrap at our cache.
# mkarchiso's _make_pacman_conf() picks up the CacheDir and passes it to
# pacstrap, so pre-cached packages are used without re-downloading.
ISO_PACMAN_CONF="$BUILD_TMP/iso-pacman.conf"
sed "/^\[options\]/a CacheDir = $PKG_CACHE_DIR/pacman" \
  "$ISO_DIR/pacman.conf" > "$ISO_PACMAN_CONF"
# eos-rankmirrors fires its hook when the package is installed during pacstrap.
# The build chroot has no internet at that point, producing a red but harmless
# error.  NoExtract prevents the hook file from landing on disk so it never
# fires.  The eos-rankmirrors binary itself is still installed and callable.
sed -i "/^\[options\]/a NoExtract = usr/share/libalpm/hooks/eos-rankmirrors.hook" \
  "$ISO_PACMAN_CONF"

# AIROOTFS_WORK_DIR tells run_before_squashfs.sh where the actual airootfs is;
# sudo strips env vars by default so we inject it with 'env'.
(cd "$ISO_DIR" && sudo env AIROOTFS_WORK_DIR="$WORK_DIR" ./mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" -C "$ISO_PACMAN_CONF" .)

# ---------------------------------------------------------------------------
# Post-build validation (work tree is root-owned; use sudo for reads)
# ---------------------------------------------------------------------------
CALAMARES_ETC="$WORK_DIR/x86_64/airootfs/etc/calamares"

if sudo grep -R --include="syslinux.cfg" -nE '^[[:space:]]*[^#].*whichsys\.c32' \
     "$WORK_DIR" >/tmp/whichsys-work-hits 2>/dev/null; then
  echo "[post-mkarchiso] whichsys.c32 still present in work tree:"
  cat /tmp/whichsys-work-hits
else
  echo "[post-mkarchiso] no whichsys.c32 matches found in work tree syslinux.cfg files"
fi

missing=0
sudo test -f "$CALAMARES_ETC/modules/eos_script_ssh_setup.conf" || {
  echo "[post-mkarchiso] Validation failed: missing $CALAMARES_ETC/modules/eos_script_ssh_setup.conf" >&2
  missing=$((missing + 1))
}
sudo grep -Eq "config:[[:space:]]*eos_script_ssh_setup\.conf" "$CALAMARES_ETC/settings_online.conf" 2>/dev/null || {
  echo "[post-mkarchiso] Validation failed: settings_online.conf missing eos_script_ssh_setup module entry" >&2
  missing=$((missing + 1))
}
sudo grep -Eq "config:[[:space:]]*eos_script_ssh_setup\.conf" "$CALAMARES_ETC/settings_offline.conf" 2>/dev/null || {
  echo "[post-mkarchiso] Validation failed: settings_offline.conf missing eos_script_ssh_setup module entry" >&2
  missing=$((missing + 1))
}
sudo grep -q "GITHUB_USER\|ENABLE_SSHD\|ENABLE_RDP" "$CALAMARES_ETC/scripts/ssh_setup_script.sh" 2>/dev/null || {
  echo "[post-mkarchiso] Validation failed: ssh_setup_script.sh missing expected remote-setup logic" >&2
  missing=$((missing + 1))
}
sudo grep -q "eos_remote" "$CALAMARES_ETC/settings_online.conf" 2>/dev/null || {
  echo "[post-mkarchiso] Validation failed: settings_online.conf missing eos_remote Remote page" >&2
  missing=$((missing + 1))
}
sudo grep -q "eos_remote" "$CALAMARES_ETC/settings_offline.conf" 2>/dev/null || {
  echo "[post-mkarchiso] Validation failed: settings_offline.conf missing eos_remote Remote page" >&2
  missing=$((missing + 1))
}

if [[ $missing -gt 0 ]]; then
  echo "[post-mkarchiso] $missing validation failure(s). Aborting." >&2
  exit 1
fi
echo "[post-mkarchiso] Calamares configuration validated successfully in work tree"

# ---------------------------------------------------------------------------
# Final ISO validation
# ---------------------------------------------------------------------------
latest_iso="$(ls -1t "$OUT_DIR"/*.iso 2>/dev/null | head -n1 || true)"
if [[ -n "$latest_iso" ]]; then
  iso_errors=0
  iso_manifest="$(bsdtar -tf "$latest_iso" 2>/dev/null)"

  for iso_file in \
    "boot/syslinux/isolinux.bin" \
    "boot/syslinux/ldlinux.c32" \
    "boot/syslinux/menu.c32" \
    "boot/syslinux/vesamenu.c32" \
    "boot/syslinux/libcom32.c32" \
    "boot/syslinux/libutil.c32" \
    "boot/syslinux/isohdpfx.bin"
  do
    if ! grep -qx "$iso_file" <<< "$iso_manifest"; then
      echo "ISO validation failed: $iso_file is missing in $latest_iso" >&2
      iso_errors=$((iso_errors + 1))
    fi
  done

  iso_syslinux_cfg="$(bsdtar -xOf "$latest_iso" boot/syslinux/syslinux.cfg 2>/dev/null || true)"
  if grep -Eq '^[[:space:]]*[^#].*whichsys\.c32' <<< "$iso_syslinux_cfg"; then
    echo "ISO validation failed: boot/syslinux/syslinux.cfg still references whichsys.c32" >&2
    echo "Extracted boot/syslinux/syslinux.cfg from ISO (first 20 lines):" >&2
    printf "%s\n" "$iso_syslinux_cfg" | sed -n "1,20p" >&2
    trace_syslinux_candidates "$ISO_DIR" "host-post-build"
    iso_errors=$((iso_errors + 1))
  fi

  if [[ $iso_errors -gt 0 ]]; then
    echo "ISO validation: $iso_errors failure(s). The ISO at $latest_iso is incomplete." >&2
    exit 1
  fi
  echo "ISO build complete: $latest_iso"
else
  echo "ISO build finished but no ISO found under $OUT_DIR" >&2
  exit 1
fi
