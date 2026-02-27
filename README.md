# Custom EndeavourOS ISO — KDE Wayland + KRDP + SSH

This repo builds a **custom EndeavourOS ISO** based on the official image, with KDE on Wayland, a patched KRDP stack for RDP, and installer-driven setup for OpenSSH and GitHub SSH keys.

---
 
## What’s different in this ISO

Compared to a stock EndeavourOS ISO, this build applies the following changes.

### 1. Desktop: Wayland KDE

- **kwin** (Wayland) is used instead of **kwin-x11**.
- **plasma-x11-session** is dropped; the live and installed session are Wayland.
- **qt6-wayland** and **plasma-wayland-protocols** are added.

### 2. KRDP (RDP) with custom patch

- The ISO ships **KRDP** (KDE RDP server) built from source with a local patch.
- **Patch:** `patches/krdp-working-fixes.patch` — input, touchpad, and scroll fixes.
- During install, Calamares can ask whether to **configure KRDP and set an RDP password**; the installed system gets SDDM autologin so an RDP session is available after boot.

### 3. Calamares: SSH and GitHub keys

- The installer uses a **custom Calamares** configuration and scripts from `calamares-overlay/`.
- During install it can ask to:
  - **Enable the OpenSSH server** on the installed system.
  - **Import GitHub SSH public keys** for the created user (by GitHub username).
  - **Configure KRDP** and set a dedicated RDP password (see above).
- Those choices are applied on the target system by `calamares-overlay` scripts (e.g. `ssh_setup_script.sh`, `cleaner_script.sh`).

### 4. Other

- **openssh** (and related packages) are included so SSH and key import work.
- **ckbcomp** is built from upstream and bundled (keyboard map tool used by Calamares).

---

## How to build the custom ISO

**Prerequisites:** Docker, ~25 GB free space, network. See [building-kde-iso.md](building-kde-iso.md#prerequisites) for Docker install.

```bash
git clone <this-repo-url> eos-krdp-iso
cd eos-krdp-iso
./build-endeavouros-krdp-iso.sh
```

Output: `endeavouros-iso-build/out/*.iso`

To only build and cache the patched KRDP and custom Calamares packages (no ISO):

```bash
./build-endeavouros-krdp-iso.sh --skip-iso-build
```

---

## What the repo contains (for the custom build)

| Path | Role |
|------|------|
| `build-endeavouros-krdp-iso.sh` | Build entrypoint: clones EndeavourOS-ISO and Calamares, applies overlay and patch, runs mkarchiso. |
| `patches/krdp-working-fixes.patch` | KRDP source patch applied when building the krdp package. |
| `calamares-overlay/` | Custom Calamares data overlaid on upstream: `data/eos/scripts/` (e.g. `cleaner_script.sh`, `ssh_setup_script.sh`), `data/eos/modules/eos_script_ssh_setup.conf`, and `data/eos/settings_online.conf` / `settings_offline.conf`. |
| `boot-overlay/syslinux/syslinux.cfg` | Legacy (BIOS) Syslinux entry used when the cloned profile still references `whichsys.c32`; a supported ISO-only config so the build passes validation without reimplementing boot logic. |

The script creates (and `.gitignore` excludes) `endeavouros-iso-build/` (EndeavourOS-ISO clone) and `build-src/deps/endeavouros-calamares/` (Calamares clone + overlay). Do not remove or ignore `patches/`, `calamares-overlay/`, or `boot-overlay/` if you want to keep the customizations.

---

## More documentation

- **[building-kde-iso.md](building-kde-iso.md)** — Prerequisites, manual steps, troubleshooting, post-install.
- **[RDP_WORKING_SETUP.md](RDP_WORKING_SETUP.md)** — Using KRDP after install.
