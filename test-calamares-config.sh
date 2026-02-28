#!/usr/bin/env bash
# test-calamares-config.sh
#
# Build-time validation for Calamares configuration consistency.
# Run from the repository root before building the ISO.
#
# Catches:
#   1. Scripts at /etc/calamares/scripts/* with runInTarget:true that are not
#      copied into the chroot by cleaner_script.sh — causes fatal "No such file
#      or directory" mid-install (e.g. ssh_setup_script.sh, chrooted_cleaner_script.sh)
#   2. scriptPath values referencing scripts under /etc/calamares/scripts/ that
#      don't exist in data/eos/scripts/
#   3. Custom plugin QML files (eos_remote) using Kirigami.ScrollablePage or
#      Kirigami.Page as root — these trigger Primitives.IconPropertiesGroup
#      type-registry conflicts when the plugin .so loads Kirigami in a separate
#      context from the main Calamares binary

set -euo pipefail

CALAMARES_SRC="build-src/deps/endeavouros-calamares"
MODULES_DIR="$CALAMARES_SRC/data/eos/modules"
SCRIPTS_DIR="$CALAMARES_SRC/data/eos/scripts"
# Plugin modules compiled as SHARED_LIB (separate .so, isolated Kirigami context)
PLUGIN_QML_DIRS=("$CALAMARES_SRC/src/modules/eos_remote")
CLEANER="$SCRIPTS_DIR/cleaner_script.sh"

pass=0
fail=0

_pass() { echo "  PASS: $*"; ((pass++)) || true; }
_fail() { echo "  FAIL: $*" >&2; ((fail++)) || true; }

# ── 1. runInTarget /etc/calamares/scripts/* are copied into the chroot ──────
#
# Scripts in /etc/calamares/scripts/ exist on the live ISO but NOT in the
# pacstrap'd target.  cleaner_script.sh runs outside the chroot and must copy
# them before the chroot job runs.
#
# Scripts in /tmp/* are user-provided files already copied by cleaner_script.sh
# from /home/liveuser/ — they don't need a separate existence check.

echo "=== Test 1: runInTarget /etc/calamares/scripts/* are copied to chroot ==="

for conf in "$MODULES_DIR"/*.conf; do
    if ! grep -qE "^runInTarget:[[:space:]]*true" "$conf"; then
        continue
    fi

    script_path=$(grep -E "^scriptPath:" "$conf" \
        | sed "s|scriptPath:[[:space:]]*||; s|['\"]||g; s|[[:space:]]*$||" || true)
    [ -n "$script_path" ] || continue

    # Only validate scripts shipped as part of the ISO (/etc/calamares/scripts/).
    # Scripts under /tmp/ are user-provided and handled separately.
    if [[ "$script_path" != /etc/calamares/scripts/* ]]; then
        continue
    fi

    conf_name=$(basename "$conf")
    script_name=$(basename "$script_path")

    # Script must exist in data/eos/scripts/ (the source that gets installed to the ISO)
    if [ -f "$SCRIPTS_DIR/$script_name" ]; then
        _pass "$conf_name: '$script_name' exists in scripts dir"
    else
        _fail "$conf_name: '$script_name' missing from '$SCRIPTS_DIR'"
    fi

    # cleaner_script.sh must copy it into the target before the chroot job runs
    if grep -q "$script_name" "$CLEANER"; then
        _pass "$conf_name: cleaner_script.sh copies '$script_name' to target"
    else
        _fail "$conf_name: cleaner_script.sh does NOT copy '$script_name' to target" \
              "— chroot job will fail with 'No such file or directory'"
    fi
done

# ── 2. All /etc/calamares/scripts/* scriptPath values resolve ───────────────

echo ""
echo "=== Test 2: all /etc/calamares/scripts/* scriptPath values exist ==="

for conf in "$MODULES_DIR"/*.conf; do
    script_path=$(grep -E "^scriptPath:" "$conf" \
        | sed "s|scriptPath:[[:space:]]*||; s|['\"]||g; s|[[:space:]]*$||" || true)
    [ -n "$script_path" ] || continue
    [[ "$script_path" == /etc/calamares/scripts/* ]] || continue

    conf_name=$(basename "$conf")
    script_name=$(basename "$script_path")

    if [ -f "$SCRIPTS_DIR/$script_name" ]; then
        _pass "$conf_name: '$script_name' found"
    else
        _fail "$conf_name: '$script_name' not found in '$SCRIPTS_DIR'"
    fi
done

# ── 3. Custom plugin QML does not use Kirigami.Page as root ─────────────────
#
# Calamares loads custom plugin modules (SHARED_LIB) into an isolated .so.
# When the plugin's QRC instantiates Kirigami.ScrollablePage or Kirigami.Page,
# those types require Kirigami's Primitives submodule.  If Primitives was
# already registered by the main Calamares binary (for upstream modules like
# usersq/summaryq), the plugin gets a second registration with incompatible
# QMLTYPE_N* IDs, yielding:
#
#   Cannot assign object of type "Primitives.IconPropertiesGroup"
#   to property of type "IconPropertiesGroup_QMLTYPE_110*"
#
# Upstream modules (usersq, summaryq, …) are built into the main binary and
# load before the plugin, so they are not affected.  Only plugin directories
# listed in PLUGIN_QML_DIRS need this check.

echo ""
echo "=== Test 3: custom plugin QML root element is not Kirigami.Page ==="

for dir in "${PLUGIN_QML_DIRS[@]}"; do
    while IFS= read -r -d '' qml; do
        qml_name=$(basename "$qml")

        # Find first non-comment, non-import, non-blank line = root element
        root_line=$(grep -v -E "^[[:space:]]*(//|/\*|\*|import|$)" "$qml" | head -1 || true)

        if echo "$root_line" | grep -qE "^[[:space:]]*Kirigami\.(ScrollablePage|Page)[[:space:]\{]"; then
            _fail "$qml_name: root is '$root_line'" \
                  "— use QtQuick.Controls.Page + ScrollView to avoid Kirigami Primitives conflict"
        else
            _pass "$qml_name: root element OK"
        fi
    done < <(find "$dir" -name "*.qml" -print0 2>/dev/null)
done

# ── 4. os-prober in the ISO package list ────────────────────────────────────
#
# Calamares calls runOsprober() during the partitioning phase to detect
# dual-boot OSes (Windows, other Linux, etc.).  If os-prober is not installed
# in the live session, Calamares logs:
#   OsproberEntryList PartUtils::runOsprober … ERROR: os-prober cannot start.
# and presents an empty "Other OS" list, breaking dual-boot detection.

echo ""
echo "=== Test 4: os-prober present in packages.x86_64 ==="

PACKAGES_X86_64="endeavouros-iso-build/packages.x86_64"
if grep -qxF 'os-prober' "$PACKAGES_X86_64"; then
    _pass "packages.x86_64: os-prober present (Calamares dual-boot detection)"
else
    _fail "packages.x86_64: os-prober missing — Calamares cannot detect other OSes"
fi

# ── 5. services-systemd.conf correctness for KDE-only ISO ───────────────────
#
# Trying to enable display managers that are not installed produces
# "Failed to enable unit: Unit gdm.service does not exist" warnings.
# pacman-init.service is live-session-only and never present on an installed
# system; trying to disable it produces a similar warning.
# ModemManager must be enabled so NetworkManager doesn't log DBus errors.

echo ""
echo "=== Test 5: services-systemd.conf — KDE-only ISO correctness ==="

SERVICES_CONF="$MODULES_DIR/services-systemd.conf"

for dm in gdm lightdm lxdm ly greetd; do
    if grep -q "${dm}\.service" "$SERVICES_CONF"; then
        _fail "services-systemd.conf: ${dm}.service present — not installed in KDE ISO, causes enable warnings"
    else
        _pass "services-systemd.conf: ${dm}.service absent (correct for KDE-only ISO)"
    fi
done

if grep -q "sddm\.service" "$SERVICES_CONF"; then
    _pass "services-systemd.conf: sddm.service present (required for KDE)"
else
    _fail "services-systemd.conf: sddm.service missing"
fi

if grep -q "ModemManager\.service" "$SERVICES_CONF"; then
    _pass "services-systemd.conf: ModemManager.service present (prevents NetworkManager DBus errors)"
else
    _fail "services-systemd.conf: ModemManager.service missing — NetworkManager logs activation failures"
fi

if grep -q "pacman-init" "$SERVICES_CONF"; then
    _fail "services-systemd.conf: pacman-init listed — unit doesn't exist on installed system"
else
    _pass "services-systemd.conf: pacman-init absent (correct — live-session only)"
fi

# ── 6. RemoteConfig.h — setters must be Q_INVOKABLE ─────────────────────────
#
# eos_remote.qml calls setters as JavaScript functions, e.g.:
#   onCheckedChanged: config.setEnableSshd(checked)
# Q_PROPERTY WRITE only enables property-assignment syntax (config.foo = val).
# Calling the setter as a function requires Q_INVOKABLE; without it QML logs:
#   TypeError: Property 'setEnableSshd' of object RemoteConfig … is not a function

echo ""
echo "=== Test 6: RemoteConfig.h — setters are Q_INVOKABLE for QML method calls ==="

REMOTE_CONFIG_H="$CALAMARES_SRC/src/modules/eos_remote/RemoteConfig.h"
for setter in setEnableSshd setImportGithubKeys setGithubUsername setEnableRdp setRdpPassword; do
    if grep -qE "Q_INVOKABLE[[:space:]]+void[[:space:]]+${setter}" "$REMOTE_CONFIG_H"; then
        _pass "RemoteConfig.h: ${setter} is Q_INVOKABLE"
    else
        _fail "RemoteConfig.h: ${setter} missing Q_INVOKABLE — QML config.${setter}() calls will throw TypeError"
    fi
done

# ── 7. mkinitcpio.conf.d drop-in for libseccomp ──────────────────────────────
#
# Without libseccomp.so in the initramfs, systemd-udevd logs on every boot:
#   System call bpf cannot be resolved as libseccomp is not available
# The drop-in in mkinitcpio.conf.d/ is included in the squashfs and used by
# Calamares's initcpio module when regenerating the installed system's initramfs.

echo ""
echo "=== Test 7: mkinitcpio.conf.d — libseccomp drop-in for installed system ==="

SECCOMP_DROPIN="endeavouros-iso-build/airootfs/etc/mkinitcpio.conf.d/99-eos-libseccomp.conf"
if [ -f "$SECCOMP_DROPIN" ]; then
    _pass "mkinitcpio.conf.d: 99-eos-libseccomp.conf exists"
    if grep -qE "^BINARIES=.*libseccomp" "$SECCOMP_DROPIN"; then
        _pass "mkinitcpio.conf.d: BINARIES includes libseccomp.so"
    else
        _fail "mkinitcpio.conf.d: libseccomp.so not found in BINARIES"
    fi
else
    _fail "mkinitcpio.conf.d: 99-eos-libseccomp.conf missing — first-boot bpf syscall warning persists"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
