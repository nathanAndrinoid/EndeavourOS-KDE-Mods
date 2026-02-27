# Consolidate refs: Important files for install ISO problems

This document embeds the exact contents of the project’s custom files that matter for the main issues (pacstrap, “no servers configured”, pacman keyring in target, os-prober for other OSes, Calamares config, remote setup, build). Use it as a single reference.

**Custom files included:** `iso-hooks/run_before_squashfs.sh`, `iso-hooks/get_country.sh`; `calamares-overlay/data/eos/scripts/` — `fix_pacman_servers.sh`, `fix_keyring.sh`, `fix_osprober.sh`, `cleaner_script.sh`, `ssh_setup_script.sh`; `calamares-overlay/data/eos/modules/` — shellprocess and eos_script configs, `webview@remote_setup.conf`, `shellprocess_write_remote_setup_config.conf`, `eos_script_ssh_setup.conf`; `settings_online.conf`; `build-endeavouros-krdp-iso.sh` — `stage_calamares_overlay`, container mirrorlist fallback, and post-mkarchiso Calamares validation (exact excerpts).

---

## 1. Live ISO: mirrorlist and custom packages (pacstrap phase)

**Problem:** Pacstrap fails with “no servers configured” if the live system’s `/etc/pacman.d/mirrorlist` has no `Server` lines when the ISO is built. Custom `.pkg.tar.zst` packages under `airootfs/root/packages/` are installed into the live ISO then deleted; the Calamares offline path and `ssh_setup_script.sh` need them in `/usr/share/packages`.

**Fix:** (1) **Custom package staging:** Before `pacman -U` and `rm -rf /root/packages/`, copy `*.pkg.tar.zst` into `/usr/share/packages`. (2) After the “replace mirrorlist with original again” block, a **final mirrorlist safety check** ensures both `mirrorlist` and `endeavouros-mirrorlist` have at least one `Server=` line; if not, known-good fallback servers are written. The ISO never ships with empty mirrorlists.

### iso-hooks/run_before_squashfs.sh

```bash
#!/usr/bin/env bash

# Made by Fernando "maroto"
# Run anything in the filesystem right before being "mksquashed"
# ISO-NEXT specific cleanup removals and additions (08-2021 + 10-2021) @killajoe and @manuel
# refining and changes november 2021 @killajoe and @manuel

script_path=$(readlink -f "${0%/*}")
work_dir="work"

# Adapted from AIS. An excellent bit of code!
# all path must be in quotation marks "path/to/file/or/folder" for now.

arch_chroot() {
    arch-chroot "${script_path}/${work_dir}/x86_64/airootfs" /bin/bash -c "${1}"
}

do_merge() {

# Build the chroot script with a quoted heredoc so variables/commands
# are evaluated inside the chroot, not by the host shell.
chroot_script=$(cat << 'CHROOT_EOF'

echo "##############################"
echo "# start chrooted commandlist #"
echo "##############################"

cd "/root"

echo "---> Init & Populate keys --->"
pacman-key --init
pacman-key --populate archlinux endeavouros
pacman -Syy

echo "---> backup bash configs from skel to replace after liveuser creation --->"
mkdir -p "/root/filebackups/"
cp -af "/etc/skel/"{".bashrc",".bash_profile"} "/root/filebackups/"

echo "---> Install liveuser skel (in case of conflicts use overwrite) --->"
pacman -U --noconfirm --overwrite "/etc/skel/.bash_profile","/etc/skel/.bashrc" -- "/root/endeavouros-skel-liveuser/"*".pkg.tar.zst"
echo "---> start validate skel files --->"
ls /etc/skel/.*
ls /etc/skel/
echo "---> end validate skel files --->"

echo "---> Prepare livesession settings and user --->"
sed -i 's/#\(en_US\.UTF-8\)/\1/' "/etc/locale.gen"
locale-gen
ln -sf "/usr/share/zoneinfo/UTC" "/etc/localtime"

echo "---> Set root permission and shell --->"
usermod -s /usr/bin/bash root

echo "---> Create liveuser --->"
useradd -m -p "" -g 'liveuser' -G 'sys,rfkill,wheel,uucp,nopasswdlogin,adm,tty' -s /bin/bash liveuser
cp "/root/liveuser.png" "/var/lib/AccountsService/icons/liveuser"
rm "/root/liveuser.png"

echo "---> Remove liveuser skel to clean for target skel --"
pacman -Rns --noconfirm -- "endeavouros-skel-liveuser"
rm -rf "/root/endeavouros-skel-liveuser"

echo "---> setup theming for root user --->"
cp -a "/root/root-theme" "/root/.config"
rm -R "/root/root-theme"

echo "---> Add builddate to motd --->"
cat "/usr/lib/endeavouros-release" >> "/etc/motd"
echo "------------------" >> "/etc/motd"

echo "---> Install locally built packages on ISO (place packages under airootfs/root/packages) --->"
echo "--> content of /root/packages:"
ls "/root/packages/"
echo "end of content of /root/packages. <---"

echo "---> generating actual ranked mirrorlist to fetch packages for offline install---> "
echo "---> back up original to replace later---> "
cp "/etc/pacman.d/mirrorlist" "/etc/pacman.d/mirrorlist.later"
mkdir -p "/etc/pacman.d/"
echo "---> generate mirrorlist safely ---> "
# Source project-managed get_country helper if present inside the chroot.
if [[ -f "/root/get_country.sh" ]]; then
  # shellcheck source=/dev/null
  source "/root/get_country.sh"
fi
COUNTRY="$(get_country)"

if [[ -n "$COUNTRY" ]]; then
  reflector \
    --country "$COUNTRY" \
    --protocol "https" \
    --sort "rate" \
    --latest "10" \
    --save "/etc/pacman.d/mirrorlist"
else
  reflector \
    --protocol "https" \
    --sort "rate" \
    --latest "20" \
    --save "/etc/pacman.d/mirrorlist"
fi

echo "---> generate mirrorlist done ---> "

# Copy custom packages to /usr/share/packages so the Calamares offline
# installer and ssh_setup_script.sh can find them after squashfs.
# This directory already exists from the pacman -Sw step later, but
# create it now in case package ordering changes.
mkdir -p "/usr/share/packages"
cp -v "/root/packages/"*".pkg.tar.zst" "/usr/share/packages/" 2>/dev/null || true

pacman -Sy
pacman -U --noconfirm --needed -- "/root/packages/"*".pkg.tar.zst"
rm -rf "/root/packages/"

echo "---> Enable systemd services in case needed --->"
echo " --> per default now in airootfs/etc/systemd/system/multi-user.target.wants"
#systemctl enable NetworkManager.service systemd-timesyncd.service bluetooth.service firewalld.service
#systemctl enable vboxservice.service vmtoolsd.service vmware-vmblock-fuse.service
#systemctl enable intel.service
systemctl set-default multi-user.target

echo "---> Set wallpaper for live-session and original for installed system --->"
mv "/root/endeavouros-wallpaper.png" "/etc/calamares/files/endeavouros-wallpaper.png"
mv "/root/livewall.png" "/usr/share/endeavouros/backgrounds/endeavouros-wallpaper.png"
chmod 644 "/usr/share/endeavouros/backgrounds/"*".png"

echo "---> install bash configs back into /etc/skel for offline install target --->"
cp -af "/root/filebackups/"{".bashrc",".bash_profile"} "/etc/skel/"

echo "---> remove blacklisting nouveau out of ISO (nvidia-utls blacklist configs) --->"
rm "/usr/lib/modprobe.d/nvidia-utils.conf"
rm "/usr/lib/modules-load.d/nvidia-utils.conf"

echo "---> get needed packages for offline installs --->"
mkdir -p "/usr/share/packages"
pacman -Syy
pacman -Sw --noconfirm --cachedir "/usr/share/packages" grub eos-dracut kernel-install-for-dracut os-prober xf86-video-intel nvidia-open nvidia-hook nvidia-utils nvidia-inst broadcom-wl

echo "---> Clean pacman log and package cache --->"
rm "/var/log/pacman.log"
# pacman -Scc seem to fail so:
rm -rf "/var/cache/pacman/pkg/"

echo "---> replace mirrorlist with original again (if valid) --->"
if [[ -f /etc/pacman.d/mirrorlist.later ]] && \
   grep -qE "^[[:space:]]*Server[[:space:]]*=" /etc/pacman.d/mirrorlist.later; then
  mv /etc/pacman.d/mirrorlist.later /etc/pacman.d/mirrorlist
else
  echo "---> original mirrorlist missing or without servers; keeping generated mirrorlist --->"
  rm -f /etc/pacman.d/mirrorlist.later
fi

echo "---> final mirrorlist safety check --->"
if ! grep -qE '^[[:space:]]*Server[[:space:]]*=' /etc/pacman.d/mirrorlist; then
  echo "---> WARNING: mirrorlist has no Server lines after restore! Writing fallback --->"
  cat > /etc/pacman.d/mirrorlist <<'FALLBACK'
# Fallback servers written by run_before_squashfs.sh safety check
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
FALLBACK
fi

if ! grep -qE '^[[:space:]]*Server[[:space:]]*=' /etc/pacman.d/endeavouros-mirrorlist 2>/dev/null; then
  echo "---> WARNING: endeavouros-mirrorlist has no Server lines! Writing fallback --->"
  cat > /etc/pacman.d/endeavouros-mirrorlist <<'FALLBACK'
# Fallback servers written by run_before_squashfs.sh safety check
Server = https://mirror.alpix.eu/endeavouros/repo/$repo/$arch
Server = https://us.mirror.endeavouros.com/endeavouros/repo/$repo/$arch
FALLBACK
fi

echo "---> create package versions file --->"
pacman -Qs | grep "/calamares " | cut -c7- > iso_package_versions
pacman -Qs | grep "/firefox " | cut -c7- >> iso_package_versions
pacman -Qs | grep "/linux " | cut -c7- >> iso_package_versions
pacman -Qs | grep "/mesa " | cut -c7- >> iso_package_versions
pacman -Qs | grep "/xorg-server " | cut -c7- >> iso_package_versions
pacman -Qs | grep "/nvidia-utils " | cut -c7- >> iso_package_versions
mv "iso_package_versions" "/home/liveuser/"

echo "############################"
echo "# end chrooted commandlist #"
echo "############################"

CHROOT_EOF
)
arch_chroot "$chroot_script"
}

#################################
########## STARTS HERE ##########
#################################

do_merge
```

### iso-hooks/get_country.sh

```bash
#!/usr/bin/env bash

# Project-managed get_country for use inside the ISO build chroot.
# Inlined by run_before_squashfs.sh so the function is available when the
# chrooted commands run during mkarchiso.

get_country() {
  for url in \
    "https://ipapi.co/country_code" \
    "https://ifconfig.co/country-iso" \
    "https://ipinfo.io/country"; do

    code="$(curl -fs "$url" 2>/dev/null | grep -oE '^[A-Z]{2}$')"
    [[ -n "$code" ]] && echo "$code" && return
  done
}
```

### iso-hooks/packages.x86_64 (excerpt: base + ISO + EndeavourOS Calamares)

```
# BASE
## Base system
iptables-nft
base
base-devel
archlinux-keyring
endeavouros-mirrorlist
endeavouros-keyring
...
# ISO
## Live iso specific
arch-install-scripts
iso-create-ml
...
reflector
...
# ENDEAVOUROS REPO
## Calamares EndeavourOS
```

*(Full file: 260 lines; includes base, hardware, network, desktop, browser, fonts, endeavouros-branding, eos-*, welcome, yay, etc.)*

---

## 2. Target root pacman config (“packages” step)

**Problem:** After pacstrap, the packages module runs `pacman -Sy` in the target chroot and fails with “no servers configured” if target `pacman.conf` or included mirrorlists have no servers. Root causes: (1) script only ensured `Include` lines existed but never verified the included files had `Server=` lines; (2) `Include` was written with host-absolute paths (e.g. `/tmp/calamares-root-xxxx/etc/pacman.d/mirrorlist`), which pacman inside the chroot cannot resolve.

**Fix:** The script now (1) **fixes host-absolute Include paths** (e.g. `/tmp/calamares-root-xxxx/etc/...` → `/etc/...`) so pacman inside the chroot can resolve them; (2) ensures repo sections have Include lines; (3) validates that included mirrorlist files actually contain `Server=` lines; (4) uses a three-tier fallback per file: use target file if it has servers → else copy from live system → else write known-good hardcoded servers; (5) runs final validation and logs server counts and repo sections to stderr for Calamares logs.

### calamares-overlay/data/eos/scripts/fix_pacman_servers.sh

```bash
#!/usr/bin/env bash
# Ensure [core], [extra], [multilib], and [endeavouros] in the target root's
# /etc/pacman.conf have Include lines AND that the included mirrorlist files
# actually contain Server= entries so pacman -Sy works in the chroot.
#
# Usage: fix_pacman_servers.sh <ROOT>
#   ROOT = target mount point (e.g. /tmp/calamares-root-xxxx).
# Run from host (dontChroot: true); ROOT is passed by Calamares.

set -euo pipefail

ROOT="${1:-}"
if [[ -z "$ROOT" ]] || [[ ! -d "$ROOT" ]]; then
  echo "==> fix_pacman_servers: missing or invalid ROOT (target mount point)." >&2
  exit 1
fi

pacman_conf="${ROOT}/etc/pacman.conf"
mirrorlist="${ROOT}/etc/pacman.d/mirrorlist"
eos_mirrorlist="${ROOT}/etc/pacman.d/endeavouros-mirrorlist"

# Live system paths (host)
live_mirrorlist="/etc/pacman.d/mirrorlist"
live_eos_mirrorlist="/etc/pacman.d/endeavouros-mirrorlist"

# Known-good fallback servers
FALLBACK_ARCH_SERVERS=(
  "Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"
  "Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch"
)
FALLBACK_EOS_SERVERS=(
  "Server = https://mirror.alpix.eu/endeavouros/repo/\$repo/\$arch"
  "Server = https://us.mirror.endeavouros.com/endeavouros/repo/\$repo/\$arch"
)

if [[ ! -f "$pacman_conf" ]]; then
  echo "==> fix_pacman_servers: $pacman_conf not found, skipping." >&2
  exit 0
fi

# --- Step 1: Ensure Include lines use chroot-relative paths ---
# Fix any Include lines that contain the host-side ROOT prefix.
# e.g. Include = /tmp/calamares-root-xxxx/etc/pacman.d/mirrorlist
# becomes Include = /etc/pacman.d/mirrorlist
if grep -qE "^[[:space:]]*Include[[:space:]]*=.*calamares-root" "$pacman_conf"; then
  echo "==> fix_pacman_servers: fixing host-absolute Include paths"
  sed -i -E "s|Include[[:space:]]*=[[:space:]]*/tmp/calamares-root-[^/]*/|Include = /|g" "$pacman_conf"
fi

# --- Helper: check if a file has at least one Server= line ---
has_servers() {
  local file="$1"
  [[ -f "$file" ]] && grep -qE '^[[:space:]]*Server[[:space:]]*=' "$file"
}

# --- Helper: ensure a mirrorlist file has servers ---
# Try: 1) already has servers → done
#      2) copy from live system
#      3) write hardcoded fallback
ensure_mirrorlist_has_servers() {
  local target_file="$1"
  local live_file="$2"
  shift 2
  local -a fallback_lines=("$@")

  if has_servers "$target_file"; then
    echo "==> fix_pacman_servers: $target_file already has Server lines."
    return 0
  fi

  echo "==> fix_pacman_servers: $target_file missing or has no Server lines."

  # Try copying from live system
  if has_servers "$live_file"; then
    echo "==> fix_pacman_servers: copying $live_file -> $target_file"
    mkdir -p "$(dirname "$target_file")"
    cp -f "$live_file" "$target_file"
    return 0
  fi

  # Write hardcoded fallback
  echo "==> fix_pacman_servers: live $live_file also empty; writing fallback servers to $target_file"
  mkdir -p "$(dirname "$target_file")"
  printf '# Fallback servers written by fix_pacman_servers.sh\n' > "$target_file"
  for line in "${fallback_lines[@]}"; do
    printf '%s\n' "$line" >> "$target_file"
  done
}

# --- Step 2: Ensure repo sections have Include lines ---
for repo in core extra multilib; do
  if grep -q "^\[$repo\]" "$pacman_conf"; then
    if ! awk -v r="[$repo]" '
          $0==r {in_repo=1; next}
          /^\[/ {in_repo=0}
          in_repo && /^[[:space:]]*(Server|Include)[[:space:]]*=/{found=1}
          END {exit !found}
        ' "$pacman_conf"; then
      echo "==> fix_pacman_servers: adding Include for [$repo]"
      sed -i "/^\[$repo\]/a Include = /etc/pacman.d/mirrorlist" "$pacman_conf"
    fi
  fi
done

if grep -q "^\[endeavouros\]" "$pacman_conf"; then
  if ! awk '
        /^\[endeavouros\]/{in_repo=1; next}
        /^\[/ {in_repo=0}
        in_repo && /^[[:space:]]*(Server|Include)[[:space:]]*=/{found=1}
        END {exit !found}
      ' "$pacman_conf"; then
    echo "==> fix_pacman_servers: adding Include for [endeavouros]"
    sed -i "/^\[endeavouros\]/a Include = /etc/pacman.d/endeavouros-mirrorlist" "$pacman_conf"
  fi
fi

# --- Step 3: Ensure mirrorlist files have servers ---

ensure_mirrorlist_has_servers "$mirrorlist" "$live_mirrorlist" "${FALLBACK_ARCH_SERVERS[@]}"
ensure_mirrorlist_has_servers "$eos_mirrorlist" "$live_eos_mirrorlist" "${FALLBACK_EOS_SERVERS[@]}"

# --- Step 4: Final validation ---

echo "==> fix_pacman_servers: final validation"

fail=0
for f in "$mirrorlist" "$eos_mirrorlist"; do
  if has_servers "$f"; then
    count=$(grep -cE '^[[:space:]]*Server[[:space:]]*=' "$f")
    echo "==> fix_pacman_servers: OK - $f has $count server(s)"
  else
    echo "==> fix_pacman_servers: FAIL - $f still has no servers!" >&2
    fail=1
  fi
done

# Dump pacman.conf repo blocks for debugging (stderr so Calamares log captures it)
echo "==> fix_pacman_servers: pacman.conf repo sections:" >&2
grep -E '^\[|^[[:space:]]*(Server|Include)[[:space:]]*=' "$pacman_conf" >&2 || true

if [[ "$fail" -ne 0 ]]; then
  echo "==> fix_pacman_servers: WARNING - at least one mirrorlist has no servers; pacman -Sy may fail." >&2
  # Don't exit 1 here — let pacman try and give a clearer error if needed
fi

exit 0
```

### calamares-overlay/data/eos/modules/shellprocess_fix_pacman_servers.conf

```yaml
# Ensure target root has pacman Include lines so packages module can run pacman -Sy.
# Uses external script to avoid Calamares variable expansion; run on host with ROOT.
---
dontChroot: true
timeout: 120           # network copies, usually fast
verbose: true
script:
  - "/etc/calamares/scripts/fix_pacman_servers.sh ${ROOT}"

i18n:
  name: "Ensure pacman servers in target"
```

### Target pacman keyring (before packages@online)

**Problem:** After pacstrap, the target chroot may have an empty or broken `/etc/pacman.d/gnupg` (e.g. not writable or “Public keyring not found”). The packages module then runs `pacman -Sy` and fails with “keyring is not writable” / “required key missing from keyring” / “failed to commit transaction”. The live system’s keyring (initialized in `run_before_squashfs.sh`) does not apply to the target; the target needs its own init and populate after pacstrap and before any `pacman` run.

**Fix:** A shellprocess runs on the host right after `userpkglist` and **before** `fix_pacman_servers` with **timeout: 600**. The script: (1) **Step 0** verifies `proc`, `dev`, and `sys` are bind-mounted into the target (attempts bind-mount if missing so `arch-chroot` does not hang); (2) ensures `ROOT/etc/pacman.d/gnupg` exists and is writable; (3) seeds entropy on the host (haveged) so `pacman-key --init` does not block on `/dev/random` in the chroot; (4) runs `pacman-key --init` **only if** `pacman-key --list-keys` already fails (skips init when keyring is already healthy); (5) runs `pacman-key --populate archlinux endeavouros` (no `--refresh-keys` — populate from local keyring packages is sufficient and avoids keyserver timeouts); (6) validates with `pacman-key --list-keys`. This makes the keyring ready for `packages@online`.

### calamares-overlay/data/eos/modules/shellprocess_fix_keyring.conf

```yaml
# Ensure the target chroot has a working pacman keyring before packages@online.
# Runs on host (dontChroot: true) using the target ROOT mount point.
---
dontChroot: true
timeout: 600           # GPG init/populate can exceed default 30s
verbose: true
script:
  - "/etc/calamares/scripts/fix_keyring.sh ${ROOT}"

i18n:
  name: "Initializing pacman keyring in target"
```

### calamares-overlay/data/eos/scripts/fix_keyring.sh

```bash
#!/usr/bin/env bash
# Initialize and populate the pacman keyring inside the target chroot.
#
# Usage: fix_keyring.sh <ROOT>
#   ROOT = target mount point passed by Calamares (e.g. /tmp/calamares-root-xxxx).
#
# Why this is needed:
#   pacstrap may create /ROOT/etc/pacman.d/gnupg but not fully populate it,
#   or the keyring may be owned by the wrong user / have wrong permissions
#   inside the chroot.  The packages module then runs pacman -Sy which fails
#   with "Public keyring not found" or "required key missing from keyring".

set -euo pipefail

ROOT="${1:-}"
if [[ -z "$ROOT" ]] || [[ ! -d "$ROOT" ]]; then
  echo "==> fix_keyring: missing or invalid ROOT." >&2
  exit 1
fi

# --- Step 0: Verify chroot bind mounts ---
# Calamares's mount module should have set these up already.
# We check but do NOT blindly re-mount — that could conflict with
# Calamares's own mount management and cause unmount failures later.
for mp in proc dev sys; do
  if ! mountpoint -q "${ROOT}/${mp}" 2>/dev/null; then
    echo "==> fix_keyring: WARNING - ${ROOT}/${mp} is not mounted." >&2
    echo "==> fix_keyring: attempting bind-mount (Calamares may not have mounted it yet)" >&2
    mount --bind "/${mp}" "${ROOT}/${mp}" || {
      echo "==> fix_keyring: FATAL - could not bind-mount /${mp}." >&2
      exit 1
    }
  fi
done

GNUPG_DIR="${ROOT}/etc/pacman.d/gnupg"

# --- Step 1: Ensure the gnupg directory exists with correct permissions ---
echo "==> fix_keyring: ensuring ${GNUPG_DIR} exists and is writable"
mkdir -p "$GNUPG_DIR"
chmod 0755 "$GNUPG_DIR"

# Seed entropy so pacman-key --init doesn't block on /dev/random.
if command -v haveged &>/dev/null; then
  echo "==> fix_keyring: starting haveged for entropy"
  systemctl start haveged.service 2>/dev/null || haveged -w 1024 2>/dev/null || true
fi

# --- Step 2: Initialize only if needed ---
if arch-chroot "$ROOT" pacman-key --list-keys &>/dev/null; then
  echo "==> fix_keyring: keyring already functional, skipping --init"
else
  echo "==> fix_keyring: keyring not functional, running pacman-key --init"
  arch-chroot "$ROOT" pacman-key --init
fi

# --- Step 3: Populate with distro keys ---
# Always run --populate — it's idempotent and ensures both keyrings are present.
# Do NOT use --refresh-keys: it contacts keyservers and will timeout in offline installs.
echo "==> fix_keyring: populating archlinux and endeavouros keys"
arch-chroot "$ROOT" pacman-key --populate archlinux endeavouros

# --- Step 4: Validate ---
echo "==> fix_keyring: validating keyring"
if arch-chroot "$ROOT" pacman-key --list-keys >/dev/null 2>&1; then
  key_count=$(arch-chroot "$ROOT" pacman-key --list-keys 2>/dev/null | grep -c "^pub" || true)
  echo "==> fix_keyring: OK — keyring has ${key_count} public key(s)"
else
  echo "==> fix_keyring: FAIL — pacman-key --list-keys returned an error" >&2
  # Don't exit 1; let packages@online give the real error
fi

exit 0
```

---

## 2b. OS-prober (detecting other operating systems)

**Problem:** Calamares reports “os-prober cannot start” / “os-prober gave no output” because inside the installer context os-prober cannot access block devices or conflicts with existing mounts. GRUB then fails to add menu entries for other OSes. The default shellprocess timeout (30s) is too short when scanning multiple drives.

**Fix:** A shellprocess runs **on the host** (where `/dev` is fully available) right before `eos_bootloader` with **timeout: 300**. The script: (1) sets `GRUB_DISABLE_OS_PROBER=false` in the target’s `/etc/default/grub`; (2) runs `os-prober` on the host; (3) **filters out the target’s own partitions** (via `findmnt -R "$ROOT"`) so the newly installed EndeavourOS is not added as a duplicate "other OS" entry; (4) caches the filtered output in the target’s `/var/lib/os-prober/cached-os-list`; (5) installs a wrapper `/usr/local/bin/os-prober-cached` that uses the cache if real os-prober returns nothing; (6) installs `31_os-prober-cached` in `/etc/grub.d/` which uses **`search --fs-uuid`** (resolving device UUID with `blkid` at grub-mkconfig time). Target-device filter uses **exact line match** (`grep -qxF`) so e.g. `/dev/sda1` does not match `/dev/sda10`. If `blkid` cannot resolve a UUID, that entry is **skipped** with a warning instead of writing a broken menuentry. Chain/efi entries use `chainloader /EFI/Microsoft/Boot/bootmgfw.efi`; linux entries use `root=UUID=...` and a note to run `grub-mkconfig` after first boot for full entries.

### calamares-overlay/data/eos/modules/shellprocess_fix_osprober.conf

```yaml
# Run os-prober on the host (where block devices are accessible) and
# write results into target GRUB config so grub-mkconfig picks them up.
---
dontChroot: true
timeout: 300           # scanning multiple drives/partitions can exceed 30s
verbose: true
script:
  - "/etc/calamares/scripts/fix_osprober.sh ${ROOT}"

i18n:
  name: "Detecting other operating systems"
```

### calamares-overlay/data/eos/scripts/fix_osprober.sh

```bash
#!/usr/bin/env bash
# Run os-prober from the HOST (where /dev is fully available) and inject
# results into the target so grub-mkconfig picks up other OSes.
#
# Usage: fix_osprober.sh <ROOT>
#
# Why host-side:
#   os-prober needs raw access to block devices (/dev/sda*, /dev/nvme*).
#   Inside an arch-chroot the bind-mounted /dev may be incomplete or
#   os-prober may conflict with Calamares's own mounts.  Running on the
#   host avoids both problems.

set -euo pipefail

ROOT="${1:-}"
if [[ -z "$ROOT" ]] || [[ ! -d "$ROOT" ]]; then
  echo "==> fix_osprober: missing or invalid ROOT." >&2
  exit 1
fi

grub_default="${ROOT}/etc/default/grub"

# --- Step 1: Ensure os-prober is installed on the live system ---
if ! command -v os-prober &>/dev/null; then
  echo "==> fix_osprober: os-prober not found on live system, skipping." >&2
  exit 0
fi

# --- Step 2: Ensure GRUB_DISABLE_OS_PROBER=false in target ---
if [[ -f "$grub_default" ]]; then
  if grep -q "^GRUB_DISABLE_OS_PROBER=" "$grub_default"; then
    sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$grub_default"
    echo "==> fix_osprober: set GRUB_DISABLE_OS_PROBER=false (replaced existing)"
  elif grep -q "^#.*GRUB_DISABLE_OS_PROBER=" "$grub_default"; then
    sed -i 's/^#.*GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$grub_default"
    echo "==> fix_osprober: set GRUB_DISABLE_OS_PROBER=false (uncommented)"
  else
    echo "GRUB_DISABLE_OS_PROBER=false" >> "$grub_default"
    echo "==> fix_osprober: set GRUB_DISABLE_OS_PROBER=false (appended)"
  fi
else
  echo "==> fix_osprober: WARNING - ${grub_default} not found, GRUB may not be installed yet" >&2
fi

# --- Step 3: Run os-prober on the host ---
echo "==> fix_osprober: running os-prober on host..."
osprober_output=""
osprober_output="$(os-prober 2>/dev/null)" || true

# Filter out the target's own partitions so we don't add a duplicate GRUB entry for the OS we're installing.
target_devices="$(findmnt -rno SOURCE -R "$ROOT" 2>/dev/null | sed 's/\[.*\]//' | sort -u)"
if [[ -n "$target_devices" ]] && [[ -n "$osprober_output" ]]; then
  filtered=""
  while IFS= read -r line; do
    dev="${line%%:*}"
    if echo "$target_devices" | grep -qxF "$dev"; then
      echo "==> fix_osprober: skipping target device $dev"
    else
      filtered+="${line}"$'\n'
    fi
  done <<< "$osprober_output"
  osprober_output="${filtered%$'\n'}"
fi

if [[ -z "$osprober_output" ]]; then
  echo "==> fix_osprober: no non-target operating systems found."
  exit 0
fi

echo "==> fix_osprober: os-prober found:"
echo "$osprober_output" | while IFS= read -r line; do
  echo "    $line"
done

# --- Step 4: Cache os-prober results for grub-mkconfig ---
osprober_cache_dir="${ROOT}/var/lib/os-prober"
mkdir -p "$osprober_cache_dir"

osprober_wrapper="${ROOT}/usr/local/bin/os-prober-cached"
mkdir -p "${ROOT}/usr/local/bin"
cat > "$osprober_wrapper" <<'WRAPPER'
#!/bin/bash
# Wrapper: try real os-prober first; if it gives no output, use cached results.
real_output="$(/usr/bin/os-prober 2>/dev/null)" || true
if [[ -n "$real_output" ]]; then
  echo "$real_output"
else
  cache="/var/lib/os-prober/cached-os-list"
  [[ -f "$cache" ]] && cat "$cache"
fi
WRAPPER
chmod +x "$osprober_wrapper"

echo "$osprober_output" > "${osprober_cache_dir}/cached-os-list"
echo "==> fix_osprober: cached os-prober results to ${osprober_cache_dir}/cached-os-list"

# --- Step 5: Create a 31_os-prober-cached grub.d entry as fallback ---
grub_d="${ROOT}/etc/grub.d"
mkdir -p "$grub_d"

cat > "${grub_d}/31_os-prober-cached" <<'GRUB_SCRIPT'
#!/bin/bash
# Auto-generated by fix_osprober.sh — fallback OS entries from host-side os-prober.

CACHE="/var/lib/os-prober/cached-os-list"
[[ -f "$CACHE" ]] || exit 0

. /usr/share/grub/grub-mkconfig_lib 2>/dev/null || true

while IFS=: read -r device title ostype boottype; do
  [[ -z "$device" ]] && continue
  title="${title:-Unknown OS on $device}"

  # Resolve UUID at grub-mkconfig time (device may have a different name post-install)
  dev_uuid="$(blkid -s UUID -o value "$device" 2>/dev/null || true)"
  if [[ -z "$dev_uuid" ]]; then
    # Device not accessible — skip rather than write a broken entry.
    echo "# WARNING: Could not resolve UUID for $device ($title) — skipping" >&2
    continue
  fi

  case "$boottype" in
    chain|efi)
      cat <<EOF
menuentry '${title}' --class windows --class os \$menuentry_id_option 'osprober-chain-${dev_uuid}' {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root ${dev_uuid}
    chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
EOF
      ;;
    linux)
      cat <<EOF
menuentry '${title} (run update-grub for full entry)' --class gnu-linux --class os \$menuentry_id_option 'osprober-linux-${dev_uuid}' {
    search --no-floppy --fs-uuid --set=root ${dev_uuid}
    # Kernel/initrd paths vary by distro. Run: sudo grub-mkconfig -o /boot/grub/grub.cfg
    linux /boot/vmlinuz root=UUID=${dev_uuid} ro
    initrd /boot/initrd.img
}
EOF
      ;;
  esac
done < "$CACHE"
GRUB_SCRIPT

chmod +x "${grub_d}/31_os-prober-cached"
echo "==> fix_osprober: installed ${grub_d}/31_os-prober-cached"

exit 0
```

---

## 3. Calamares settings and sequence

**Problem:** Shellprocess jobs that embed shell in YAML can trigger “Missing variables”; sequence mis-indentation breaks YAML. The shellprocess module **defaults to a 30-second timeout** — any script that runs longer (e.g. keyring init, os-prober on many drives) is killed and the install fails. **All** shellprocess configs in this overlay set an explicit `timeout:` so slow or network-dependent steps have enough time.

**Order in exec:** `shellprocess@fix_keyring` (keyring init in target) then `shellprocess@fix_pacman_servers` immediately before `packages@online`; for remote setup: `shellprocess@write_remote_setup_config` then `eos_script@cleaner_script` (cleaner skips prompt when target config exists), then `shellprocess@copy_calamares_scripts`, then `eos_script@ssh_setup_script`; `shellprocess@fix_osprober` immediately before `eos_bootloader` so grub-mkconfig sees other OSes.

### calamares-overlay/data/eos/settings_online.conf

```yaml
# SPDX-FileCopyrightText: no
# SPDX-License-Identifier: CC0-1.0
#
# Configuration file for EndeavourOS Calamares online installs
---

modules-search: [ local ]

instances:
- id:       online
  module:   packages
  config:   packages_online.conf

- id:       online
  module:   welcome
  config:   welcome_online.conf

- id:       cleaner_script
  module:   eos_script
  config:   eos_script_cleaner.conf

- id:       chrooted_cleaner_script
  module:   eos_script
  config:   eos_script_chrooted_cleaner.conf

- id:       user_commands
  module:   eos_script
  config:   eos_script_user_commands.conf

- id:       ssh_setup_script
  module:   eos_script
  config:   eos_script_ssh_setup.conf

- id:       copy_calamares_scripts
  module:   shellprocess
  config:   shellprocess_copy_calamares_scripts.conf

- id:       fix_pacman_servers
  module:   shellprocess
  config:   shellprocess_fix_pacman_servers.conf

- id:       fix_keyring
  module:   shellprocess
  config:   shellprocess_fix_keyring.conf

- id:       fix_osprober
  module:   shellprocess
  config:   shellprocess_fix_osprober.conf

- id:       copyfiles
  module:   shellprocess
  config:   shellprocess_copyfiles.conf

- id:       xfcewall
  module:   shellprocess
  config:   shellprocess_xfcewall.conf

- id:       write_remote_setup_config
  module:   shellprocess
  config:   shellprocess_write_remote_setup_config.conf

- id:       remote_setup
  module:   webview
  config:   webview@remote_setup.conf

sequence:
- show:
  - welcome@online
  - locale
  - keyboard
  - packagechooser
  - netinstall
  - packagechooserq
  - partition
  - usersq
  - webview@remote_setup
  - summary
- exec:
  - partition
  - mount
  - pacstrap
  - machineid
  - locale
  - keyboard
  - localecfg
  - usersq
  - networkcfg
  - userpkglist
  - shellprocess@fix_keyring
  - shellprocess@fix_pacman_servers
  - packages@online
  - luksbootkeyfile
  - dracutlukscfg
  - fstab
  - shellprocess@xfcewall
  - displaymanager
  - hwclock
  - shellprocess@write_remote_setup_config   # Writes config to target (dontChroot: true)
  - eos_script@cleaner_script
  - shellprocess@copy_calamares_scripts
  - eos_script@ssh_setup_script              # Runs in target chroot, reads /tmp/eos-remote-setup.conf
  - eos_script@chrooted_cleaner_script
  - hardwaredetect
  - shellprocess@fix_osprober
  - eos_bootloader
  - grubcfg
  - windowsbootentry
  - bootloader
  - services-systemd
  - eos_script@user_commands
  - preservefiles
  - shellprocess@copyfiles
  - umount
- show:
  - finished

branding: endeavouros

prompt-install: true

dont-chroot: false

oem-setup: false

disable-cancel: false

disable-cancel-during-exec: false

hide-back-and-next-during-exec: true

quit-at-end: false
```

### calamares-overlay/data/eos/modules/shellprocess_copy_calamares_scripts.conf

```yaml
# SPDX-FileCopyrightText: no
# SPDX-License-Identifier: CC0-1.0
#
# Copy Calamares scripts from live system to target so eos_script (e.g. ssh_setup_script)
# can run inside the chroot. Required for online installs; offline uses unpackfs/fixes.
---
dontChroot: true
timeout: 60            # local cp, very fast
verbose: true

script:
 - "mkdir -p ${ROOT}/etc/calamares && cp -a /etc/calamares/scripts ${ROOT}/etc/calamares/"

i18n:
 name: "Copy Calamares scripts to target"
 name[de]: "Calamares-Skripte ins Ziel kopieren"
 name[fr]: "Copier les scripts Calamares vers la cible"
 name[es]: "Copiar scripts de Calamares al destino"
 name[it]: "Copia script Calamares nel target"
 name[pt_BR]: "Copiar scripts do Calamares para o destino"
```

---

## 4. Remote setup and GitHub SSH keys

**Problem:** Remote page choices (SSH, GitHub keys, RDP) must be written for eos_script. The shellprocess runs on the host (`dontChroot: true`) and writes to the **target** at `${ROOT}/tmp/eos-remote-setup.conf`. To avoid "Missing variables" when the user skips the webview, use **`variables:`** fallbacks and **`@@VAR@@`** substitution (Calamares merges GlobalStorage on top of `variables:`). **YAML compliance:** The script block must use **echo statements** (not a heredoc) so every line is indented under the YAML key; unindented heredoc body causes yaml-cpp "illegal map value" at line 44 and Calamares fails to load the module at startup. **Cleaner script:** `eos_script@cleaner_script` runs *after* `shellprocess@write_remote_setup_config`; in `_copy_files()` it checks `${target}/tmp/eos-remote-setup.conf` with `[[ -s ... ]]` — if the file exists and is non-empty (Calamares webview path), it skips the interactive prompt and does not overwrite; otherwise it runs `_prompt_installer_remote_options` and copies host `/tmp/eos-remote-setup.conf` into the target. **ssh_setup_script.sh** reads the same config path, uses `GITHUB_USER` (and falls back to `GITHUB_USERNAME` if set by cleaner_script), adds firewall rules via **offline zone XML** (`_add_firewall_rule_offline`) because `firewall-cmd --permanent` needs D-Bus and fails in chroot, uses **`VALID_COUNT=$((VALID_COUNT + 1))`** (not `((VALID_COUNT++))`) to avoid `set -e` exit on the first key, prefers a **local KRDP package** in `/usr/share/packages` over the repo, and sets the RDP password via a **first-boot autostart script** (D-Bus/KDE Wallet not available in chroot). Handles missing/empty values and exits 0 when the user skips or has no GitHub keys.

### calamares-overlay/data/eos/modules/shellprocess_write_remote_setup_config.conf

```yaml
# SPDX-FileCopyrightText: no
# SPDX-License-Identifier: CC0-1.0
#
# Reads remote access choices from Calamares GlobalStorage
# (set by webview@remote_setup) and writes a config file to the
# target filesystem at /tmp/eos-remote-setup.conf.
#
# Runs on the host (dontChroot: true) because we need ${ROOT}
# to address the mounted target partition.
#
# Uses variables: + @@VAR@@ so missing GlobalStorage keys (e.g. user
# skipped the webview) do not cause "Missing variables" abort.
---
dontChroot: true
timeout: 30
verbose: true

# ── CRITICAL: Fallback defaults ─────────────────────────────────
# Calamares 3.3+ merges GlobalStorage ON TOP of this map.
# If the webview was skipped or never interacted with, these
# defaults prevent the "Missing variables" abort.
variables:
  eos_remote_use_ssh:           "false"
  eos_remote_use_github:        "false"
  eos_remote_github_username:   ""
  eos_remote_use_rdp:           "false"
  eos_remote_rdp_password_b64:  ""

# ── Write config to target ──────────────────────────────────────
# Uses @@VAR@@ syntax (resolved from variables map + GlobalStorage).
# Replaced heredoc with echo statements to comply with strict YAML
# indentation requirements, preventing parser crashes.
script:
  - command: |-
      mkdir -p "${ROOT}/tmp"
      echo 'ENABLE_SSHD="@@eos_remote_use_ssh@@"' > "${ROOT}/tmp/eos-remote-setup.conf"
      echo 'IMPORT_GITHUB_KEYS="@@eos_remote_use_github@@"' >> "${ROOT}/tmp/eos-remote-setup.conf"
      echo 'GITHUB_USER="@@eos_remote_github_username@@"' >> "${ROOT}/tmp/eos-remote-setup.conf"
      echo 'ENABLE_RDP="@@eos_remote_use_rdp@@"' >> "${ROOT}/tmp/eos-remote-setup.conf"
      echo 'RDP_PASSWORD_B64="@@eos_remote_rdp_password_b64@@"' >> "${ROOT}/tmp/eos-remote-setup.conf"
      chmod 0600 "${ROOT}/tmp/eos-remote-setup.conf"

i18n:
  name: "Writing remote access configuration..."
  name[de]: "Schreibe Remote-Zugriffskonfiguration..."
  name[fr]: "Écriture de la configuration d'accès distant..."
  name[es]: "Escribiendo configuración de acceso remoto..."
```

### calamares-overlay/data/eos/modules/webview@remote_setup.conf

```yaml
# SPDX-FileCopyrightText: no
# SPDX-License-Identifier: CC0-1.0
#
# Remote access options page (SSH, GitHub keys, KRDP).
# Page calls syncToGlobalStorage() on load so GlobalStorage has safe defaults
# if the user clicks Next without touching anything. write_remote_setup_config
# reads GlobalStorage (with variables: fallback) and writes /tmp/eos-remote-setup.conf.
#
# Filename webview@remote_setup.conf follows Calamares instance naming so the module
# is found even if the instances: block is not loaded (e.g. wrong settings file).
---
url: "file:///etc/calamares/remote-setup.html"
label:
  sidebar: "Remote Access"

i18n:
  name: "Configure remote access..."
```

### calamares-overlay/data/eos/modules/eos_script_ssh_setup.conf

```yaml
# SPDX-FileCopyrightText: no
# SPDX-License-Identifier: CC0-1.0
#
# eos_script_ssh_setup.conf
# Runs INSIDE the target chroot (default dontChroot: false).
# Applies SSH, GitHub key import, and KRDP settings from webview choices.
---
scriptPath: "/etc/calamares/scripts/ssh_setup_script.sh"
runInTarget: true
includeRoot: false
includeUser: true
isOnline: true
userOutput: false

i18n:
  name: "Applying remote access setup choices"
  name[de]: "Remote-Zugriffsoptionen anwenden"
  name[fi]: "Sovelletaan etakäytön asetukset"
  name[fr]: "Application des choix d'accès distant"
  name[it]: "Applicazione opzioni accesso remoto"
  name[es]: "Aplicar opciones de acceso remoto"
  name[ru]: "Применение параметров удаленного доступа"
  name[zh_CN]: "应用远程访问设置"
  name[ja]: "リモートアクセス設定を適用"
  name[sv]: "Tillämpar inställningar för fjärråtkomst"
  name[pt_BR]: "Aplicando escolhas de acesso remoto"
  name[tr]: "Uzak erişim ayarları uygulanıyor"
  name[ro]: "Aplicarea opțiunilor de acces la distanță"
  name[ko]: "원격 액세스 설정 적용"
  name[cs]: "Použití nastavení vzdáleného přístupu"
```

### calamares-overlay/data/eos/scripts/ssh_setup_script.sh

```bash
#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# ssh_setup_script.sh
# Runs inside the target chroot during Calamares installation.
# Reads /tmp/eos-remote-setup.conf and configures SSH and/or KRDP.
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

CONFIG="/tmp/eos-remote-setup.conf"
LOG="/var/log/eos-remote-setup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# ── Firewalld offline helper ────────────────────────────────────
# Write firewalld rules directly to zone XML (works in chroot without D-Bus).
# Usage: _add_firewall_rule_offline "service" "ssh"
#        _add_firewall_rule_offline "port" "3389/tcp"
_add_firewall_rule_offline() {
    local rule_type="$1"  # "service" or "port"
    local rule_value="$2" # e.g. "ssh" or "3389/tcp"
    local zone_dir="/etc/firewalld/zones"
    local zone_file="${zone_dir}/public.xml"

    mkdir -p "$zone_dir"

    # If no public.xml exists, create one from the default
    if [[ ! -f "$zone_file" ]]; then
        local default_zone="/usr/lib/firewalld/zones/public.xml"
        if [[ -f "$default_zone" ]]; then
            cp "$default_zone" "$zone_file"
        else
            cat > "$zone_file" <<'ZONEXML'
<?xml version="1.0" encoding="utf-8"?>
<zone>
  <short>public</short>
  <description>Public zone</description>
</zone>
ZONEXML
        fi
    fi

    local element=""
    case "$rule_type" in
        service)
            element="<service name=\"${rule_value}\"/>"
            ;;
        port)
            local port="${rule_value%%/*}"
            local proto="${rule_value##*/}"
            element="<port protocol=\"${proto}\" port=\"${port}\"/>"
            ;;
        *)
            log "WARN: _add_firewall_rule_offline: unknown rule type '$rule_type'"
            return 1
            ;;
    esac

    # Check if the rule already exists
    if grep -qF "$element" "$zone_file" 2>/dev/null; then
        log "Firewall: Rule already present: $element"
        return 0
    fi

    # Insert before </zone>
    sed -i "s|</zone>|  ${element}\n</zone>|" "$zone_file"
    log "Firewall: Added $rule_type rule '$rule_value' to $zone_file (offline)"
}

# ── Load configuration ──────────────────────────────────────────
if [[ ! -f "$CONFIG" ]]; then
    log "WARN: Config file $CONFIG not found. Nothing to do."
    exit 0
fi

# Source the config. All values are quoted strings set by Calamares.
# shellcheck source=/dev/null
source "$CONFIG"

# Normalize: treat anything other than "true" as false.
[[ "${ENABLE_SSHD:-}" == "true" ]]          || ENABLE_SSHD="false"
[[ "${IMPORT_GITHUB_KEYS:-}" == "true" ]]    || IMPORT_GITHUB_KEYS="false"
[[ "${ENABLE_RDP:-}" == "true" ]]            || ENABLE_RDP="false"
# Support both keys (webview/shellprocess use GITHUB_USER; cleaner_script may write GITHUB_USERNAME)
[[ -z "${GITHUB_USER:-}" && -n "${GITHUB_USERNAME:-}" ]] && GITHUB_USER="$GITHUB_USERNAME"

log "Config loaded: SSH=$ENABLE_SSHD, GitHub=$IMPORT_GITHUB_KEYS, User=${GITHUB_USER:-<none>}, RDP=$ENABLE_RDP"

# ── Detect the target (non-root) user ───────────────────────────
# Calamares creates the user before this script runs. Find the
# first user with UID >= 1000 that is not "nobody".
TARGET_USER=""
TARGET_HOME=""
while IFS=: read -r uname _ uid _ _ home _; do
    if [[ "$uid" -ge 1000 && "$uname" != "nobody" ]]; then
        TARGET_USER="$uname"
        TARGET_HOME="$home"
        break
    fi
done < /etc/passwd

if [[ -z "$TARGET_USER" ]]; then
    log "ERROR: Could not detect target user. Aborting."
    exit 1
fi
log "Target user: $TARGET_USER ($TARGET_HOME)"


# ═══════════════════════════════════════════════════════════════════
#  SSH SETUP
# ═══════════════════════════════════════════════════════════════════
if [[ "$ENABLE_SSHD" == "true" ]]; then
    log "── SSH: Installing openssh..."
    pacman -S --noconfirm --needed openssh 2>&1 | tee -a "$LOG"

    # Enable sshd to start on boot
    systemctl enable sshd.service 2>&1 | tee -a "$LOG"
    log "SSH: sshd.service enabled."

    # Harden sshd_config: disable root login, disable password auth
    # if we're importing GitHub keys (key-only access).
    SSHD_CONF="/etc/ssh/sshd_config"
    SSHD_DROP="/etc/ssh/sshd_config.d/90-eos-installer.conf"
    mkdir -p /etc/ssh/sshd_config.d

    cat > "$SSHD_DROP" <<'EOF'
# Written by EndeavourOS installer - remote access setup
# To revert: delete this file and restart sshd.
PermitRootLogin no
EOF

    if [[ "$IMPORT_GITHUB_KEYS" == "true" && -n "${GITHUB_USER:-}" ]]; then
        # If importing keys, we can safely disable password authentication
        cat >> "$SSHD_DROP" <<'EOF'
PasswordAuthentication no
PubkeyAuthentication yes
EOF
        log "SSH: Password auth disabled (GitHub keys will be imported)."
    fi

    chmod 0644 "$SSHD_DROP"
    log "SSH: Drop-in config written to $SSHD_DROP"

    # ── Firewall for SSH (offline — no D-Bus in chroot) ─────────
    if command -v firewall-cmd &>/dev/null; then
        _add_firewall_rule_offline "service" "ssh"
    elif command -v ufw &>/dev/null; then
        ufw allow ssh 2>&1 | tee -a "$LOG" || true
    fi

    # ── Import GitHub keys ──────────────────────────────────────
    if [[ "$IMPORT_GITHUB_KEYS" == "true" && -n "${GITHUB_USER:-}" ]]; then
        log "SSH: Fetching keys from https://github.com/${GITHUB_USER}.keys ..."

        SSH_DIR="${TARGET_HOME}/.ssh"
        AUTH_KEYS="${SSH_DIR}/authorized_keys"

        mkdir -p "$SSH_DIR"
        chmod 0700 "$SSH_DIR"

        # Fetch with a timeout. curl is available on the live ISO.
        KEYS_URL="https://github.com/${GITHUB_USER}.keys"
        FETCHED_KEYS=""

        if FETCHED_KEYS=$(curl -fsSL --connect-timeout 10 --max-time 30 "$KEYS_URL" 2>&1); then
            if [[ -n "$FETCHED_KEYS" ]]; then
                # Validate: each line should look like an SSH public key
                VALID_COUNT=0
                while IFS= read -r line; do
                    # Skip blank lines
                    [[ -z "$line" ]] && continue
                    # Basic sanity: starts with ssh-rsa, ssh-ed25519, ecdsa-, sk-ssh-, etc.
                    if [[ "$line" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2|sk-(ssh-ed25519|ecdsa-sha2)) ]]; then
                        echo "$line" >> "$AUTH_KEYS"
                        VALID_COUNT=$((VALID_COUNT + 1))
                    else
                        log "SSH: Skipping unrecognized line: ${line:0:40}..."
                    fi
                done <<< "$FETCHED_KEYS"

                chmod 0600 "$AUTH_KEYS"
                chown -R "${TARGET_USER}:${TARGET_USER}" "$SSH_DIR"
                log "SSH: Imported $VALID_COUNT key(s) from GitHub user '${GITHUB_USER}'."
            else
                log "WARN: GitHub returned empty key list for '${GITHUB_USER}'."
            fi
        else
            log "WARN: Failed to fetch GitHub keys: $FETCHED_KEYS"
            log "WARN: SSH enabled but no keys imported. Re-enabling password auth."
            sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' "$SSHD_DROP"
        fi
    fi

    log "SSH: Setup complete."
else
    log "SSH: Skipped (not enabled by user)."
fi


# ═══════════════════════════════════════════════════════════════════
#  KRDP (KDE Remote Desktop) SETUP
# ═══════════════════════════════════════════════════════════════════
if [[ "$ENABLE_RDP" == "true" ]]; then
    log "── RDP: Installing krdp..."

    # 1. Prefer local custom package over repo version
    LOCAL_KRDP=$(find /usr/share/packages -maxdepth 1 -name "krdp-*.pkg.tar.zst" 2>/dev/null | head -n 1)
    if [[ -n "$LOCAL_KRDP" ]]; then
        log "RDP: Found local KRDP package: $LOCAL_KRDP"
        pacman -U --noconfirm --needed "$LOCAL_KRDP" 2>&1 | tee -a "$LOG"
    else
        log "RDP: No local package found, installing from repo."
        pacman -S --noconfirm --needed krdp 2>&1 | tee -a "$LOG"
    fi

    # 2. Enable the krdp systemd user service
    PRESET_DIR="${TARGET_HOME}/.config/systemd/user/default.target.wants"
    mkdir -p "$PRESET_DIR"

    KRDP_UNIT=""
    for candidate in \
        "/usr/lib/systemd/user/plasma-krdp_server.service" \
        "/usr/lib/systemd/user/plasma-remote-desktop.service" \
        "/usr/lib/systemd/user/krdp.service" \
        "/usr/lib/systemd/user/krdp-server.service"; do
        if [[ -f "$candidate" ]]; then
            KRDP_UNIT="$candidate"
            break
        fi
    done

    if [[ -n "$KRDP_UNIT" ]]; then
        UNIT_NAME=$(basename "$KRDP_UNIT")
        ln -sf "$KRDP_UNIT" "${PRESET_DIR}/${UNIT_NAME}"
        log "RDP: Enabled $UNIT_NAME via symlink."
    else
        log "WARN: Could not find krdp systemd user unit."
    fi

    # 3. Write krdprc config
    KRDP_CONF_DIR="${TARGET_HOME}/.config"
    mkdir -p "$KRDP_CONF_DIR"

    cat > "${KRDP_CONF_DIR}/krdprc" <<'EOF'
[General]
Enabled=true

[Network]
Port=3389
ListenAddress=0.0.0.0

[Security]
TLSRequired=true
EOF

    # 4. Handle password via first-boot script (D-Bus not available in chroot)
    #
    # SECURITY NOTE: The base64 password is written to a script file on disk.
    # Base64 is encoding, not encryption — this is equivalent to plaintext.
    # The script self-destructs on first login, limiting the exposure window.
    # The file permissions are set to 0700 (owner-only executable).
    #
    if [[ -n "${RDP_PASSWORD_B64:-}" ]]; then
        AUTOSTART_DIR="${TARGET_HOME}/.config/autostart"
        mkdir -p "$AUTOSTART_DIR"

        FIRST_BOOT_SCRIPT="${TARGET_HOME}/.config/krdp-first-boot.sh"

        # Heredoc unquoted so RDP_PASSWORD_B64 and paths expand when we write the script.
        cat > "$FIRST_BOOT_SCRIPT" <<FBEOF
#!/bin/bash
# KRDP first-boot password setup — self-destructs after running.
# Wait for Plasma session and D-Bus to fully initialize.
sleep 8

if command -v krdp-server &>/dev/null; then
    echo '${RDP_PASSWORD_B64}' | base64 -d | krdp-server --setpass 2>/dev/null
fi

# Self-destruct
rm -f "${FIRST_BOOT_SCRIPT}"
rm -f "${AUTOSTART_DIR}/krdp-first-boot.desktop"
FBEOF
        chmod 0700 "$FIRST_BOOT_SCRIPT"

        cat > "${AUTOSTART_DIR}/krdp-first-boot.desktop" <<DTEOF
[Desktop Entry]
Type=Application
Name=KRDP Initial Setup
Exec=${FIRST_BOOT_SCRIPT}
Hidden=false
NoDisplay=true
X-KDE-autostart-phase=1
DTEOF
        log "RDP: Created first-boot autostart for password setup."
    fi

    # 5. Firewall (offline — no D-Bus in chroot)
    if command -v firewall-cmd &>/dev/null; then
        _add_firewall_rule_offline "port" "3389/tcp"
        log "RDP: Firewall rule added for port 3389/tcp (offline)."
    elif command -v ufw &>/dev/null; then
        ufw allow 3389/tcp 2>&1 | tee -a "$LOG" || true
        log "RDP: UFW rule added for port 3389/tcp."
    fi

    # Fix ownership
    chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.config"
    chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.local" 2>/dev/null || true

    log "RDP: Setup complete."
else
    log "RDP: Skipped (not enabled by user)."
fi


# ═══════════════════════════════════════════════════════════════════
#  CLEANUP
# ═══════════════════════════════════════════════════════════════════
# Remove the config file (contains base64 password).
rm -f "$CONFIG"
log "Cleanup: Removed $CONFIG"
log "Remote access setup finished."

exit 0
```

---

## 5. Build and overlay staging

**Problem:** Overlay and hooks must be present so the ISO and Calamares see the right files (including fix_pacman_servers, mirrorlist behaviour, and remote-setup.html for the webview). Missing files must be caught at build time.

### build-endeavouros-krdp-iso.sh — stage_calamares_overlay (exact)

Verifies all required Calamares overlay files after staging; includes `remote-setup.html` so a missing webview page is caught before producing a broken ISO. Uses a bash array, counts all missing files before aborting, and sets executable permissions on scripts.

```bash
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
```

### build-endeavouros-krdp-iso.sh — container post-mkarchiso Calamares validation (exact)

Runs inside the container after mkarchiso; validates that the work tree has all required Calamares files and that `ssh_setup_script.sh` contains the expected remote-setup logic (GITHUB_USER, ENABLE_SSHD, ENABLE_RDP). Includes check for `remote-setup.html`.

```bash
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
```

### build-endeavouros-krdp-iso.sh — copying iso-hooks into ISO profile

```bash
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
    mkdir -p "$ISO_DIR/airootfs/root"
    cp -f "$ISO_HOOKS_DIR/get_country.sh" "$ISO_DIR/airootfs/root/get_country.sh"
  fi
fi
```

### build-endeavouros-krdp-iso.sh — container pre-mkarchiso mirrorlist fallback

```bash
mkdir -p /etc/pacman.d
if [[ ! -s /etc/pacman.d/mirrorlist ]] || ! grep -qE "^[[:space:]]*Server[[:space:]]*=" /etc/pacman.d/mirrorlist; then
  cat > /etc/pacman.d/mirrorlist <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
EOF
fi

cat > /etc/pacman.d/endeavouros-mirrorlist <<'EOF'
Server = https://mirror.alpix.eu/endeavouros/repo/$repo/$arch
Server = https://us.mirror.endeavouros.com/endeavouros/repo/$repo/$arch
EOF
```

*(Full build script: Docker image, KRDP/Calamares/ckbcomp build, mkarchiso run, ISO validation; stage_calamares_overlay is used when staging overlay; Calamares package installs overlay from calamares-overlay via rsync into source then package() copies data/eos to /etc/calamares.)*

---

## 6. Quick checklist for “no servers configured” and install robustness

1. **Pacstrap (live):**  
   `iso-hooks/run_before_squashfs.sh` — (1) replace mirrorlist with original if it has servers, else keep reflector output; (2) **final mirrorlist safety check** before “create package versions file”: if `mirrorlist` or `endeavouros-mirrorlist` still have no `Server=` lines, write known-good fallbacks so the ISO never ships with empty mirrorlists.

2. **Packages step (target):**  
   - **Shellprocess timeouts:** All shellprocess configs set explicit `timeout:` (fix_keyring: 600s, fix_pacman_servers: 120s, fix_osprober: 300s, copy_calamares_scripts: 60s, write_remote_setup_config: 30s) so jobs are not killed by the default 30s limit.  
   - `fix_keyring.sh` runs first (host, dontChroot): Step 0 verifies/restores proc/dev/sys bind mounts; seeds entropy (haveged) so `--init` does not block; runs `pacman-key --init` only if keyring is not already functional; then `pacman-key --populate archlinux endeavouros` (no `--refresh-keys`); validates.  
   - `fix_pacman_servers.sh` runs with correct `ROOT` (host, dontChroot): first **fixes host-absolute Include paths** (e.g. `/tmp/calamares-root-.../etc/...` → `/etc/...`), ensures repo sections have Include lines, validates that included mirrorlist files have `Server=` lines; if not, copies from live or writes hardcoded fallbacks; final validation logs server counts and repo sections to stderr.  
   - `settings_online.conf`: `shellprocess@fix_keyring` then `shellprocess@fix_pacman_servers` immediately before `packages@online`.

3. **OS-prober (other OSes):**  
   - `fix_osprober.sh` runs on the host before `eos_bootloader` (timeout 300s): sets `GRUB_DISABLE_OS_PROBER=false`, runs os-prober on host, **filters out target partitions** with exact line match (`grep -qxF`) so e.g. `/dev/sda1` does not match `/dev/sda10`. GRUB script skips entries when `blkid` cannot resolve UUID (logs warning). Caches filtered results in target `/var/lib/os-prober/cached-os-list`, installs wrapper and `31_os-prober-cached` in `/etc/grub.d/` which uses **`search --fs-uuid`** and `blkid` so GRUB entries are bootable (chain/efi: chainloader bootmgfw.efi; linux: root=UUID=... with note to run grub-mkconfig after first boot).

4. **Calamares:**  
   - No “Missing variables” from shellprocess: use `variables:` fallbacks and `@@VAR@@` substitution in the write-remote-setup shellprocess; write config to `${ROOT}/tmp/eos-remote-setup.conf` using **echo statements** (not a heredoc) so the script block satisfies strict YAML indentation and Calamares does not crash on module load (yaml-cpp "illegal map value"). Webview must call syncToGlobalStorage() on load so skipped users get all "false". **Cleaner guard:** `shellprocess@write_remote_setup_config` runs *before* `eos_script@cleaner_script`; cleaner's `_copy_files()` checks `${target}/tmp/eos-remote-setup.conf` — if non-empty, skips interactive prompt and does not overwrite. Script reads same path, `GITHUB_USER` (and `GITHUB_USERNAME` from cleaner if present), adds SSH/RDP firewall rules via **offline zone XML** (`_add_firewall_rule_offline`) because `firewall-cmd --permanent` fails in chroot (no D-Bus), uses `VALID_COUNT=$((VALID_COUNT + 1))` not `((VALID_COUNT++))` to avoid `set -e` exit on first key, prefers local KRDP in `/usr/share/packages`, and sets RDP password via first-boot autostart (8s sleep, self-destruct) because D-Bus is not available in chroot.
   - No YAML error: `sequence` list formatting correct in `settings_online.conf`.
   - Remote setup order: `shellprocess@write_remote_setup_config` → `eos_script@cleaner_script` (guard skips prompt when config exists) → `shellprocess@copy_calamares_scripts` → `eos_script@ssh_setup_script`; script handles missing config file and zero GitHub keys with exit 0 (no installer abort).
   - Build verification: `remote-setup.html` is in the required overlay list and in container post-mkarchiso validation so a missing webview page is caught at build time. `stage_calamares_overlay` reports "Missing required file" and "Overlay staged: N files verified in $target_dir".
