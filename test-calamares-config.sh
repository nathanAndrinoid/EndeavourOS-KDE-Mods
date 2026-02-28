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

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
