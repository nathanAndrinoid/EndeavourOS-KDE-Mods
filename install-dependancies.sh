#!/usr/bin/env bash
# Install dependencies needed to build the EndeavourOS KDE ISO.
# Run this on the host before ./build-endeavouros-krdp-iso.sh
# Supports: Arch Linux, EndeavourOS, Debian/Ubuntu, Fedora.

set -euo pipefail

detect_distro() {
  if [[ -f /etc/arch-release ]]; then
    echo "arch"
  elif [[ -f /etc/debian_version ]]; then
    echo "debian"
  elif [[ -f /etc/fedora-release ]]; then
    echo "fedora"
  else
    echo "unknown"
  fi
}

install_arch() {
  echo "Installing dependencies (Arch/EndeavourOS)..."
  sudo pacman -Sy --noconfirm --needed \
    git \
    docker \
    python3 \
    rsync \
    libarchive  # provides bsdtar for ISO validation
  echo "Enabling and starting Docker service..."
  sudo systemctl enable --now docker 2>/dev/null || true
  if [[ -n "${SUDO_USER:-}" ]]; then
    echo "Adding $SUDO_USER to docker group..."
    sudo usermod -aG docker "$SUDO_USER"
    echo "User $SUDO_USER added to docker group. Log out and back in (or run 'newgrp docker') so docker works without sudo."
  else
    echo "Add your user to the 'docker' group to run without sudo: sudo usermod -aG docker \$USER"
    echo "Then log out and back in, or run: newgrp docker"
  fi
}

install_debian() {
  echo "Installing dependencies (Debian/Ubuntu)..."
  sudo apt-get update
  sudo apt-get install -y \
    git \
    docker.io \
    python3 \
    rsync \
    libarchive-tools  # provides bsdtar
  sudo systemctl enable --now docker 2>/dev/null || true
  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo usermod -aG docker "$SUDO_USER"
    echo "User $SUDO_USER added to docker group. Log out and back in (or run 'newgrp docker')."
  else
    echo "Add your user to the 'docker' group: sudo usermod -aG docker \$USER ; then log out and back in."
  fi
}

install_fedora() {
  echo "Installing dependencies (Fedora)..."
  sudo dnf install -y \
    git \
    docker \
    python3 \
    rsync \
    bsdtar
  sudo systemctl enable --now docker 2>/dev/null || true
  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo usermod -aG docker "$SUDO_USER"
    echo "User added to docker group. Log out and back in (or run 'newgrp docker')."
  else
    echo "Add your user to the 'docker' group: sudo usermod -aG docker \$USER ; then log out and back in."
  fi
}

DISTRO="$(detect_distro)"
case "$DISTRO" in
  arch)   install_arch ;;
  debian) install_debian ;;
  fedora) install_fedora ;;
  *)      echo "Unsupported distro. Install manually: git, docker, python3, rsync, bsdtar (libarchive/libarchive-tools)." ; exit 1 ;;
esac

echo ""
echo "Dependencies installed."
echo "  - If you were added to the docker group, log out and back in (or run: newgrp docker)."
echo "  - Then run: ./build-endeavouros-krdp-iso.sh"
echo "  - Build needs ~25 GB free space and network (git clone, Docker pull, archiso)."
