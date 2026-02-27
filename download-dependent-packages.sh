#!/usr/bin/env bash
# Pre-download all packages and source files required by the build.
# Run this once before build-endeavouros-krdp-iso.sh to enable fully offline/fast builds.
#
# Usage:
#   ./download-dependent-packages.sh [--skip-iso-pkgs]
#
# Options:
#   --skip-iso-pkgs   Skip downloading the ~300 ISO packages (only build deps + ckbcomp).
#
# NOTE: The cache must live in a world-traversable path (not under a mode-700 home
# directory) because pacman 7 downloads packages as the unprivileged 'alpm' user.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Must match the default in build-endeavouros-krdp-iso.sh.
PKG_CACHE_DIR="${PKG_CACHE_DIR:-/var/cache/eos-krdp-build}"
ISO_DIR="${SCRIPT_DIR}/endeavouros-iso-build"

SKIP_ISO_PKGS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-iso-pkgs) SKIP_ISO_PKGS=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--skip-iso-pkgs]"
      exit 0
      ;;
    *) echo "Unexpected argument: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -eq 0 ]]; then
  echo "Run as a regular user (not root). This script uses sudo where needed." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Submodule init (need packages.x86_64 from the ISO submodule)
# ---------------------------------------------------------------------------
git -C "$SCRIPT_DIR" submodule update --init --recursive

# ---------------------------------------------------------------------------
# Create cache directories
# ---------------------------------------------------------------------------
# pacman/  → root:root 755 so the 'alpm' download user can traverse the path.
# sources/ → user-owned so makepkg (running as current user) can read/write.
sudo install -dm755 "$PKG_CACHE_DIR/pacman"
sudo install -dm755 -o "$(id -u)" -g "$(id -g)" "$PKG_CACHE_DIR/sources"
echo "[download] Cache directory: $PKG_CACHE_DIR"

# ---------------------------------------------------------------------------
# Ensure EndeavourOS mirrorlist exists (needed for ISO-profile repo downloads)
# ---------------------------------------------------------------------------
if [[ ! -s /etc/pacman.d/endeavouros-mirrorlist ]] || \
   ! grep -qE '^[[:space:]]*Server[[:space:]]*=' /etc/pacman.d/endeavouros-mirrorlist 2>/dev/null; then
  echo "[download] Writing /etc/pacman.d/endeavouros-mirrorlist..."
  sudo tee /etc/pacman.d/endeavouros-mirrorlist > /dev/null <<'EOF'
Server = https://mirror.alpix.eu/endeavouros/repo/$repo/$arch
Server = https://us.mirror.endeavouros.com/endeavouros/repo/$repo/$arch
EOF
fi

# ---------------------------------------------------------------------------
# Refresh package databases
# ---------------------------------------------------------------------------
echo "[download] Refreshing system package databases..."
sudo pacman -Sy --noconfirm --cachedir "$PKG_CACHE_DIR/pacman" >/dev/null

echo "[download] Refreshing ISO-profile package databases (includes EndeavourOS repo)..."
sudo pacman --config "$ISO_DIR/pacman.conf" -Sy --noconfirm \
  --cachedir "$PKG_CACHE_DIR/pacman" >/dev/null

# ---------------------------------------------------------------------------
# Build dependency packages
#   ckbcomp is intentionally excluded: it is not in the Arch repos; its source
#   file is fetched separately via curl below.
# ---------------------------------------------------------------------------

# KRDP PKGBUILD deps
KRDP_DEPENDS=(
  freerdp gcc-libs glibc kcmutils kconfig kcoreaddons kcrash kguiaddons ki18n
  kpipewire kstatusnotifieritem libxkbcommon pam qt6-base qtkeychain-qt6
  systemd-libs wayland kirigami kdeclarative
)
KRDP_MAKEDEPENDS=(
  extra-cmake-modules git plasma-wayland-protocols qt6-wayland
)

# Calamares PKGBUILD deps (ckbcomp excluded — not in repos)
CAL_DEPENDS=(
  qt6-svg qt6-webengine yaml-cpp networkmanager upower kcoreaddons kconfig ki18n
  kservice kwidgetsaddons kpmcore squashfs-tools rsync pybind11 cryptsetup doxygen
  dmidecode gptfdisk hwinfo kparts polkit-qt6 python solid qt6-tools libpwquality
  qt6-declarative kirigami kdeclarative kcmutils kwin qt6-5compat boost-libs
)
CAL_MAKEDEPENDS=(
  cmake extra-cmake-modules gawk python-jsonschema python-pyaml python-unidecode
)

readarray -t BUILD_PKGS < <(
  printf '%s\n' \
    "${KRDP_DEPENDS[@]}" \
    "${KRDP_MAKEDEPENDS[@]}" \
    "${CAL_DEPENDS[@]}" \
    "${CAL_MAKEDEPENDS[@]}" \
  | sort -u
)

echo "[download] Downloading ${#BUILD_PKGS[@]} unique build dependency packages..."
sudo pacman -Sw --noconfirm --cachedir "$PKG_CACHE_DIR/pacman" "${BUILD_PKGS[@]}"

# ---------------------------------------------------------------------------
# ISO packages (uses ISO pacman.conf so EndeavourOS repo is included)
# ---------------------------------------------------------------------------
if [[ "$SKIP_ISO_PKGS" -eq 0 ]]; then
  readarray -t ISO_PKGS < <(
    grep -v '^\s*#' "$ISO_DIR/packages.x86_64" | grep -v '^\s*$' | awk '{print $1}'
  )

  echo "[download] Downloading ${#ISO_PKGS[@]} ISO packages (EndeavourOS + Arch repos)..."
  sudo pacman --config "$ISO_DIR/pacman.conf" \
    -Sw --noconfirm --cachedir "$PKG_CACHE_DIR/pacman" \
    "${ISO_PKGS[@]}"
else
  echo "[download] Skipping ISO packages (--skip-iso-pkgs)."
fi

# ---------------------------------------------------------------------------
# ckbcomp source file (not a pacman package — fetched from Debian Salsa)
# ---------------------------------------------------------------------------
CKBCOMP_CACHED="$PKG_CACHE_DIR/sources/ckbcomp"
if [[ -f "$CKBCOMP_CACHED" ]]; then
  echo "[download] ckbcomp source already cached at: $CKBCOMP_CACHED"
else
  echo "[download] Downloading ckbcomp source..."
  curl -fL --retry 3 \
    -o "$CKBCOMP_CACHED" \
    "https://salsa.debian.org/installer-team/console-setup/-/raw/master/Keyboard/ckbcomp"
  chmod +x "$CKBCOMP_CACHED"
  echo "[download] ckbcomp cached at: $CKBCOMP_CACHED"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
PKG_COUNT="$(find "$PKG_CACHE_DIR/pacman" -maxdepth 1 -name '*.pkg.tar.*' | wc -l)"
echo ""
echo "[download] Done. Cache summary:"
echo "  Pacman packages : $PKG_COUNT files in $PKG_CACHE_DIR/pacman/"
echo "  Source files    : $(ls -1 "$PKG_CACHE_DIR/sources/" | wc -l) file(s) in $PKG_CACHE_DIR/sources/"
echo ""
echo "  Run ./build-endeavouros-krdp-iso.sh to build using the cache."
