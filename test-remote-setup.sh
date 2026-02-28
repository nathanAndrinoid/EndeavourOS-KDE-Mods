#!/usr/bin/env bash
# test-remote-setup.sh
#
# Build-time tests validating SSH/RDP Calamares installer script behaviour.
#
# Coverage:
#   1. Settings sequence — eos_remote + ssh_setup_script in both install modes
#   2. Script static analysis — required patterns present in script sources
#   3. SSH functional — sshd config written + service enabled when checked
#   4. RDP functional — krdp first-boot service + config written when checked
#   5. KWallet PAM functional — nullok present when SDDM autologin is active
#   6. Offline service restore — sshd re-enabled after _clean_archiso() wipe
#
# No root required.  Functional tests create a mktemp fake root and override
# system commands (pacman, systemctl, id, getent …) as shell functions.

set -euo pipefail

CALAMARES_SRC="build-src/deps/endeavouros-calamares"
SCRIPTS_DIR="$CALAMARES_SRC/data/eos/scripts"
SSH_SCRIPT="$SCRIPTS_DIR/ssh_setup_script.sh"
CLEANER_SCRIPT="$SCRIPTS_DIR/chrooted_cleaner_script.sh"
SETTINGS_OFFLINE="$CALAMARES_SRC/data/eos/settings_offline.conf"
SETTINGS_ONLINE="$CALAMARES_SRC/data/eos/settings_online.conf"

pass=0
fail=0
_pass() { echo "  PASS: $*";  ((pass++)) || true; }
_fail() { echo "  FAIL: $*" >&2; ((fail++)) || true; }

# ── fake-root helpers ─────────────────────────────────────────────────────────

_FAKE_ROOTS=()

_new_root() {
    local d
    d="$(mktemp -d)"
    _FAKE_ROOTS+=("$d")
    mkdir -p \
        "$d/etc/pam.d" \
        "$d/etc/ssh/sshd_config.d" \
        "$d/etc/sddm.conf.d" \
        "$d/etc/systemd/system/multi-user.target.wants" \
        "$d/usr/share/wayland-sessions" \
        "$d/usr/local/bin" \
        "$d/var/lib" \
        "$d/home/testuser" \
        "$d/tmp"
    # Minimal /etc/pam.d/sddm for _insert_pam_line_after_section_start
    printf 'auth\t\trequired\tpam_unix.so try_first_pass\n' > "$d/etc/pam.d/sddm"
    printf 'session\t\trequired\tpam_unix.so\n'            >> "$d/etc/pam.d/sddm"
    touch "$d/usr/share/wayland-sessions/plasma.desktop"
    touch "$d/home/testuser/.bashrc"
    echo "$d"
}

_cleanup_roots() {
    local r
    for r in "${_FAKE_ROOTS[@]+"${_FAKE_ROOTS[@]}"}"; do rm -rf "$r"; done
}
trap _cleanup_roots EXIT

# Rewrite absolute paths in a script to target a fake root, and strip the
# trailing "Main "$@"" line so sourcing the output only loads function defs.
#
# sddm note: /etc/sddm.conf.d/ and /etc/sddm.conf are handled by a single
# expression (s|/etc/sddm|…|g) to avoid cascading.  With two separate
# expressions, expression 2 (/etc/sddm.conf\b) would re-match the
# already-substituted prefix inside /root/etc/sddm.conf.d/, doubling the root.
_patch_script() {
    local script="$1" root="$2"
    sed \
        -e "s|/etc/pam\.d/|${root}/etc/pam.d/|g" \
        -e "s|/etc/ssh/|${root}/etc/ssh/|g" \
        -e "s|/etc/sddm|${root}/etc/sddm|g" \
        -e "s|/etc/systemd/system/|${root}/etc/systemd/system/|g" \
        -e "s|/etc/eos-installer-remote\.conf|${root}/etc/eos-installer-remote.conf|g" \
        -e "s|/usr/share/wayland-sessions/|${root}/usr/share/wayland-sessions/|g" \
        -e "s|/usr/local/bin/|${root}/usr/local/bin/|g" \
        -e "s|/var/lib/eos-|${root}/var/lib/eos-|g" \
        -e "s|/tmp/eos-installer-ssh\.conf|${root}/tmp/eos-installer-ssh.conf|g" \
        "$script" \
        | head -n -1   # drop final "Main "$@"" line
}

# Run ssh_setup_script.sh Main in a subshell with a fake root + mocked cmds.
#   $1  fake root dir
#   $2  content for the installer config file (eos-installer-ssh.conf)
#   $@  extra flags forwarded to Main (e.g. --online)
_run_ssh_main() {
    local root="$1" config="$2"; shift 2
    rm -f "$root/tmp/systemctl.log"
    printf '%s\n' "$config" > "$root/tmp/eos-installer-ssh.conf"
    local patched
    patched="$(_patch_script "$SSH_SCRIPT" "$root")"
    (
        pacman()       { case "$1" in -Q) return 0 ;; -S) return 0 ;; esac; }
        systemctl()    { printf 'systemctl %s\n' "$*" >> "$root/tmp/systemctl.log"; }
        id()           { case "${1:-}" in -u) echo 1000 ;; *) echo testuser ;; esac; }
        getent()       { echo "testuser:x:1000:1000::/home/testuser:/bin/bash"; }
        openssl()      { return 0; }
        loginctl()     { return 0; }
        hostname()     { echo testhost; }
        firewall-cmd() { return 0; }
        runuser()      { shift 2; "$@" 2>/dev/null || true; }
        curl()         { return 1; }
        wget()         { return 1; }
        export -f pacman systemctl id getent openssl loginctl hostname \
                  firewall-cmd runuser curl wget
        eval "$patched"
        # Stub out host-path detection so tests don't depend on the build host
        # having sddm installed.  Autologin conf is pre-created by tests that
        # need it; functions under test here are sshd/krdp, not sddm autologin.
        _configure_default_sddm_autologin() {
            systemctl enable display-manager.service
        }
        Main --user=testuser "$@"
    )
}

# Run ssh_setup_script.sh Main with specific packages "installed".
# $1=root $2=config $3=space-separated installed-pkg list $@=extra Main flags
_run_ssh_main_pkgs() {
    local root="$1" config="$2" pkgs="$3"; shift 3
    rm -f "$root/tmp/systemctl.log"
    printf '%s\n' "$config" > "$root/tmp/eos-installer-ssh.conf"
    local patched
    patched="$(_patch_script "$SSH_SCRIPT" "$root")"
    (
        pacman() {
            case "$1" in
                -Q) local p; for p in $pkgs; do [ "$p" = "${2:-}" ] && return 0; done; return 1 ;;
                -S) return 0 ;;
            esac
        }
        systemctl()    { printf 'systemctl %s\n' "$*" >> "$root/tmp/systemctl.log"; }
        id()           { case "${1:-}" in -u) echo 1000 ;; *) echo testuser ;; esac; }
        getent()       { echo "testuser:x:1000:1000::/home/testuser:/bin/bash"; }
        openssl()      { return 0; }
        loginctl()     { return 0; }
        hostname()     { echo testhost; }
        firewall-cmd() { return 0; }
        runuser()      { shift 2; "$@" 2>/dev/null || true; }
        curl()         { return 1; }
        wget()         { return 1; }
        export -f pacman systemctl id getent openssl loginctl hostname \
                  firewall-cmd runuser curl wget
        eval "$patched"
        _configure_default_sddm_autologin() {
            systemctl enable display-manager.service
        }
        Main --user=testuser "$@"
    )
}

# Run _check_install_mode (offline branch) from chrooted_cleaner_script.sh.
# Destructive functions are no-op'd; _restore_installer_services stays live.
#   $1  fake root dir
_run_offline_cleanup() {
    local root="$1"
    rm -f "$root/tmp/systemctl.log"
    local patched
    patched="$(_patch_script "$CLEANER_SCRIPT" "$root")"
    (
        pacman() {
            case "$1" in
                -Q) [ "${2:-}" = "openssh" ] && return 0 || return 1 ;;
            esac
        }
        systemctl() { printf 'systemctl %s\n' "$*" >> "$root/tmp/systemctl.log"; }
        chown()     { return 0; }
        device-info() { echo ""; }   # bare metal — no VM detected
        lspci()     { echo ""; }
        export -f pacman systemctl chown device-info lspci
        eval "$patched"
        # Override destructive / side-effecting functions after sourcing
        _clean_archiso()                   { : ; }
        _clean_offline_packages()          { : ; }
        _sed_stuff()                       { : ; }
        _manage_nvidia_packages()          { : ; }
        _manage_other_graphics_drivers()   { : ; }
        _install_extra_drivers_to_target() { : ; }
        _install_more_firmware()           { : ; }
        _misc_cleanups()                   { : ; }
        _run_hotfix_end()                  { : ; }
        _show_info_about_installed_system(){ : ; }
        _virt_remove()                     { : ; }
        _install_needed_packages()         { : ; }
        INSTALL_TYPE="offline"
        NEW_USER="testuser"
        _CHROOTED_HAS_CONNECTION="no"
        _check_install_mode
    )
}

# ── 1. Calamares settings sequence ────────────────────────────────────────────

echo "=== Test 1: eos_remote page in both settings files ==="

grep -qE "^[[:space:]]*-[[:space:]]*eos_remote$" "$SETTINGS_OFFLINE" \
    && _pass "settings_offline.conf: eos_remote in show sequence" \
    || _fail "settings_offline.conf: eos_remote missing from show sequence"

grep -qE "^[[:space:]]*-[[:space:]]*eos_remote$" "$SETTINGS_ONLINE" \
    && _pass "settings_online.conf: eos_remote in show sequence" \
    || _fail "settings_online.conf: eos_remote missing from show sequence"

echo ""
echo "=== Test 2: ssh_setup_script in exec sequence of both settings files ==="

grep -q "eos_script@ssh_setup_script" "$SETTINGS_OFFLINE" \
    && _pass "settings_offline.conf: eos_script@ssh_setup_script in exec" \
    || _fail "settings_offline.conf: eos_script@ssh_setup_script missing from exec"

grep -q "eos_script@ssh_setup_script" "$SETTINGS_ONLINE" \
    && _pass "settings_online.conf: eos_script@ssh_setup_script in exec" \
    || _fail "settings_online.conf: eos_script@ssh_setup_script missing from exec"

# ── 2. Script static analysis ─────────────────────────────────────────────────

echo ""
echo "=== Test 3: ssh_setup_script.sh contains required SSH/RDP/KWallet logic ==="

_static_check() {
    local file="$1" desc="$2" pattern="$3"
    grep -qE "$pattern" "$file" \
        && _pass "$(basename "$file"): $desc" \
        || _fail "$(basename "$file"): $desc (pattern '$pattern' not found)"
}

_static_check "$SSH_SCRIPT" "handles ENABLE_SSHD"           "enable_sshd"
_static_check "$SSH_SCRIPT" "calls systemctl enable sshd"   "systemctl enable sshd\.service"
_static_check "$SSH_SCRIPT" "handles ENABLE_RDP"            "enable_rdp"
_static_check "$SSH_SCRIPT" "writes eos-configure-krdp service" "eos-configure-krdp\.service"
_static_check "$SSH_SCRIPT" "pam_kwallet5 auth line"        "pam_kwallet5\.so"
_static_check "$SSH_SCRIPT" "nullok for autologin path"     "nullok"
_static_check "$SSH_SCRIPT" "writes eos-installer-remote.conf" "eos-installer-remote\.conf"

echo ""
echo "=== Test 4: chrooted_cleaner_script.sh contains sshd restore logic ==="

_static_check "$CLEANER_SCRIPT" "_restore_installer_services defined" \
    "_restore_installer_services\(\)"
_static_check "$CLEANER_SCRIPT" "checks sshd marker file" \
    "99-eos-installer-auth\.conf"
_static_check "$CLEANER_SCRIPT" "re-enables sshd.service" \
    "systemctl enable sshd\.service"

# Verify _restore_installer_services is called inside the OFFLINE_MODE block
if awk '/OFFLINE_MODE\)/{f=1} f && /_restore_installer_services/{found=1; exit} /esac/{f=0}
        END{exit !found}' "$CLEANER_SCRIPT"; then
    _pass "chrooted_cleaner_script.sh: _restore_installer_services called in OFFLINE_MODE block"
else
    _fail "chrooted_cleaner_script.sh: _restore_installer_services NOT in OFFLINE_MODE block"
fi

# ── 3. SSH functional tests ───────────────────────────────────────────────────

echo ""
echo "=== Test 5: SSH checkbox checked → sshd config written ==="

R="$(_new_root)"
_run_ssh_main "$R" "ENABLE_SSHD=true" --online || true

SSHD_CONF="$R/etc/ssh/sshd_config.d/99-eos-installer-auth.conf"
[ -f "$SSHD_CONF" ] \
    && _pass "SSH enabled: sshd auth config file written" \
    || _fail "SSH enabled: sshd auth config file NOT written"

grep -q "PasswordAuthentication" "$SSHD_CONF" 2>/dev/null \
    && _pass "SSH enabled: sshd auth config contains PasswordAuthentication" \
    || _fail "SSH enabled: sshd auth config missing PasswordAuthentication"

echo ""
echo "=== Test 6: SSH checkbox checked → sshd.service enabled ==="

grep -q "systemctl enable sshd" "$R/tmp/systemctl.log" 2>/dev/null \
    && _pass "SSH enabled: systemctl enable sshd.service called" \
    || _fail "SSH enabled: systemctl enable sshd.service NOT called"

echo ""
echo "=== Test 7: SSH checkbox unchecked → sshd config NOT written ==="

R="$(_new_root)"
_run_ssh_main "$R" "ENABLE_SSHD=false" --online || true

[ ! -f "$R/etc/ssh/sshd_config.d/99-eos-installer-auth.conf" ] \
    && _pass "SSH disabled: sshd auth config not written" \
    || _fail "SSH disabled: sshd auth config was written (should not be)"

! grep -q "systemctl enable sshd" "$R/tmp/systemctl.log" 2>/dev/null \
    && _pass "SSH disabled: systemctl enable sshd NOT called" \
    || _fail "SSH disabled: systemctl enable sshd was called (should not be)"

echo ""
echo "=== Test 8: SSH key-only auth mode when GitHub keys imported ==="

R="$(_new_root)"
_run_ssh_main "$R" \
    "$(printf 'ENABLE_SSHD=true\nIMPORT_GITHUB_KEYS=false\n')" \
    --online || true

SSHD_CONF="$R/etc/ssh/sshd_config.d/99-eos-installer-auth.conf"
# Without successful key import, auth mode stays "password"
grep -q "PasswordAuthentication yes" "$SSHD_CONF" 2>/dev/null \
    && _pass "SSH: password auth mode written when no keys imported" \
    || _fail "SSH: expected PasswordAuthentication yes in auth config"

# ── 4. RDP / KRDP functional tests ───────────────────────────────────────────

echo ""
echo "=== Test 9: RDP checkbox checked → eos-installer-remote.conf written ==="

# Password "testpass1" base64-encoded
RDP_PASS_B64="dGVzdHBhc3Mx"

R="$(_new_root)"
_run_ssh_main "$R" \
    "$(printf 'ENABLE_RDP=true\nRDP_PASSWORD_B64=%s\n' "$RDP_PASS_B64")" \
    --online || true

[ -f "$R/etc/eos-installer-remote.conf" ] \
    && _pass "RDP enabled: eos-installer-remote.conf written" \
    || _fail "RDP enabled: eos-installer-remote.conf NOT written"

grep -q "ENABLE_RDP=true" "$R/etc/eos-installer-remote.conf" 2>/dev/null \
    && _pass "RDP enabled: ENABLE_RDP=true in remote config" \
    || _fail "RDP enabled: ENABLE_RDP=true not found in remote config"

grep -q "TARGET_USER=testuser" "$R/etc/eos-installer-remote.conf" 2>/dev/null \
    && _pass "RDP enabled: TARGET_USER written to remote config" \
    || _fail "RDP enabled: TARGET_USER missing from remote config"

echo ""
echo "=== Test 10: RDP checkbox checked → first-boot service enabled ==="

grep -q "systemctl enable eos-configure-krdp.service" \
    "$R/tmp/systemctl.log" 2>/dev/null \
    && _pass "RDP enabled: eos-configure-krdp.service enabled" \
    || _fail "RDP enabled: eos-configure-krdp.service NOT enabled"

echo ""
echo "=== Test 11: RDP checkbox checked → first-boot script written and executable ==="

KRDP_SCRIPT="$R/usr/local/bin/eos-configure-krdp.sh"
[ -f "$KRDP_SCRIPT" ] \
    && _pass "RDP enabled: eos-configure-krdp.sh written" \
    || _fail "RDP enabled: eos-configure-krdp.sh NOT written"

[ -x "$KRDP_SCRIPT" ] \
    && _pass "RDP enabled: eos-configure-krdp.sh is executable" \
    || _fail "RDP enabled: eos-configure-krdp.sh is NOT executable"

KRDP_SVC="$R/etc/systemd/system/eos-configure-krdp.service"
[ -f "$KRDP_SVC" ] \
    && _pass "RDP enabled: eos-configure-krdp.service unit file written" \
    || _fail "RDP enabled: eos-configure-krdp.service unit file NOT written"

grep -q "ConditionPathExists=!.*eos-krdp-configured" \
    "$KRDP_SVC" 2>/dev/null \
    && _pass "RDP service: ConditionPathExists done-file guard present" \
    || _fail "RDP service: ConditionPathExists done-file guard missing"

echo ""
echo "=== Test 12: RDP checkbox unchecked → no krdp artifacts created ==="

R="$(_new_root)"
_run_ssh_main "$R" "ENABLE_RDP=false" --online || true

[ ! -f "$R/etc/eos-installer-remote.conf" ] \
    && _pass "RDP disabled: eos-installer-remote.conf not written" \
    || _fail "RDP disabled: eos-installer-remote.conf was written (should not be)"

[ ! -f "$R/usr/local/bin/eos-configure-krdp.sh" ] \
    && _pass "RDP disabled: eos-configure-krdp.sh not written" \
    || _fail "RDP disabled: eos-configure-krdp.sh was written (should not be)"

! grep -q "eos-configure-krdp" "$R/tmp/systemctl.log" 2>/dev/null \
    && _pass "RDP disabled: eos-configure-krdp.service NOT enabled" \
    || _fail "RDP disabled: eos-configure-krdp.service was enabled (should not be)"

# ── 5. KWallet PAM functional tests ──────────────────────────────────────────

echo ""
echo "=== Test 13: KWallet PAM — nullok added when SDDM autologin is active ==="

R="$(_new_root)"
# Create an autologin conf as _configure_default_sddm_autologin would write
cat > "$R/etc/sddm.conf.d/90-eos-default-autologin.conf" <<'EOF'
[General]
DisplayServer=wayland

[Autologin]
User=testuser
Session=plasma.desktop
Relogin=true
EOF

_run_ssh_main_pkgs "$R" "" "openssh kwallet kwallet-pam" --online || true

grep -q "pam_kwallet5.so nullok" "$R/etc/pam.d/sddm" 2>/dev/null \
    && _pass "KWallet autologin: pam_kwallet5.so nullok in /etc/pam.d/sddm" \
    || _fail "KWallet autologin: pam_kwallet5.so nullok NOT in /etc/pam.d/sddm"

echo ""
echo "=== Test 14: KWallet PAM — nullok absent without autologin ==="

R="$(_new_root)"
# No autologin conf → no autologin detected
_run_ssh_main_pkgs "$R" "" "openssh kwallet kwallet-pam" --online || true

grep -q "pam_kwallet5.so" "$R/etc/pam.d/sddm" 2>/dev/null \
    && _pass "KWallet no-autologin: pam_kwallet5.so line present" \
    || _fail "KWallet no-autologin: pam_kwallet5.so line missing entirely"

# nullok must NOT be present when there is no autologin
! grep -q "pam_kwallet5.so nullok" "$R/etc/pam.d/sddm" 2>/dev/null \
    && _pass "KWallet no-autologin: nullok correctly absent" \
    || _fail "KWallet no-autologin: nullok incorrectly present"

echo ""
echo "=== Test 15: KWallet PAM — skipped gracefully when kwallet-pam absent ==="

R="$(_new_root)"
# Only openssh installed; kwallet-pam absent and install_type=offline so no -S
_run_ssh_main_pkgs "$R" "" "openssh" "" || true   # offline (no --online flag)

# File must still exist and not be corrupted
[ -f "$R/etc/pam.d/sddm" ] \
    && _pass "KWallet absent offline: /etc/pam.d/sddm preserved" \
    || _fail "KWallet absent offline: /etc/pam.d/sddm missing"

# pam_kwallet5 lines should NOT be injected
! grep -q "pam_kwallet5" "$R/etc/pam.d/sddm" 2>/dev/null \
    && _pass "KWallet absent offline: no pam_kwallet5 injected" \
    || _fail "KWallet absent offline: pam_kwallet5 injected without package"

# ── 6. Offline service restoration ───────────────────────────────────────────

echo ""
echo "=== Test 16: Offline restore — sshd re-enabled when marker exists ==="

R="$(_new_root)"
# Simulate ssh_setup_script having written the marker + been wiped by _clean_archiso
touch "$R/etc/ssh/sshd_config.d/99-eos-installer-auth.conf"

_run_offline_cleanup "$R" || true

grep -q "systemctl enable sshd.service" "$R/tmp/systemctl.log" 2>/dev/null \
    && _pass "Offline restore: sshd.service re-enabled after cleanup" \
    || _fail "Offline restore: sshd.service NOT re-enabled (should be)"

echo ""
echo "=== Test 17: Offline restore — sshd NOT enabled when marker absent ==="

R="$(_new_root)"
# No marker → SSH was not chosen; nothing to restore

_run_offline_cleanup "$R" || true

! grep -q "systemctl enable sshd" "$R/tmp/systemctl.log" 2>/dev/null \
    && _pass "Offline restore: sshd NOT enabled when marker absent" \
    || _fail "Offline restore: sshd enabled without marker (should not be)"

# ── 7. GitHub key import validation ──────────────────────────────────────────
#
# When the user ticks "Import GitHub SSH keys" but leaves the username blank:
#   - The installer must log an error (not just a warning) and abort the import.
#   - The eos-import-github-keys.sh fetch script must always log its fetch URL
#     and log an error when GitHub returns no keys.
#
# Note: the correct GitHub endpoint for SSH public keys is
#   https://github.com/<username>.keys
# (not .certs — GitHub has no .certs endpoint for public keys).

echo ""
echo "=== Test 18: GitHub import checked + empty username → error logged ==="

R="$(_new_root)"
output="$(
    _run_ssh_main "$R" \
        "$(printf 'IMPORT_GITHUB_KEYS=true\nGITHUB_USERNAME=\n')" \
        --online 2>&1 || true
)"

echo "$output" | grep -qE "==> error:.*[Gg]it[Hh]ub.*username|[Gg]it[Hh]ub.*no valid username" \
    && _pass "GitHub import: empty username logs error" \
    || _fail "GitHub import: empty username did not produce error (output: $(echo "$output" | grep -i 'github' | head -2))"

# The import script must NOT have been written — username was rejected before
# _write_github_import_script was called.
[ ! -f "$R/usr/local/bin/eos-import-github-keys.sh" ] \
    && _pass "GitHub import: import script not written when username absent" \
    || _fail "GitHub import: import script was written despite absent username"

echo ""
echo "=== Test 19: GitHub key fetch — always logs fetch URL ==="

_static_check "$SSH_SCRIPT" \
    "eos-import-github-keys.sh logs fetch URL" \
    'echo.*==> info:.*Fetching SSH public keys'

echo ""
echo "=== Test 20: GitHub key fetch — no keys returned → error logged ==="

_static_check "$SSH_SCRIPT" \
    "eos-import-github-keys.sh logs error when no keys returned" \
    'echo.*==> error:.*No SSH public keys returned'

echo ""
echo "=== Test 21: GitHub key fetch — success logs key count ==="

_static_check "$SSH_SCRIPT" \
    "eos-import-github-keys.sh logs retrieved key count on success" \
    'echo.*==> info:.*Retrieved.*key'

echo ""
echo "=== Test 22: GitHub import failure in Main → error (not warning) ==="

_static_check "$SSH_SCRIPT" \
    "Main logs error when eos-import-github-keys.sh returns non-zero" \
    '_remote_setup_msg error.*[Gg]it[Hh]ub SSH key import failed'

echo ""
echo "=== Test 23: GitHub key fetch functional — curl failure → error on stderr ==="

# Run _run_ssh_main to write eos-import-github-keys.sh to the fake root, then
# execute the script directly with:
#   - getent mocked to return a home dir inside the fake root
#   - chown/chmod no-op'd (we're not root)
#   - curl/wget returning empty (simulating no keys on GitHub)
# This tests that the fetch URL is always logged and that an empty response
# is logged as an error.

R="$(_new_root)"
_run_ssh_main "$R" \
    "$(printf 'IMPORT_GITHUB_KEYS=true\nGITHUB_USERNAME=testgithubuser\n')" \
    --online 2>&1 || true

if [ -f "$R/usr/local/bin/eos-import-github-keys.sh" ]; then
    import_output="$(
        (
            # Export FAKE_HOME so the getent function can reference it in the
            # child bash process (where $R from the outer test is not in scope).
            export FAKE_HOME="$R/home/testuser"
            getent() { echo "testuser:x:1000:1000::${FAKE_HOME}:/bin/bash"; }
            curl()    { return 1; }
            wget()    { return 1; }
            chown()   { return 0; }
            chmod()   { return 0; }
            export -f getent curl wget chown chmod
            bash "$R/usr/local/bin/eos-import-github-keys.sh" \
                testuser testgithubuser 2>&1 || true
        )
    )"

    echo "$import_output" | grep -qE "==> info:.*Fetching SSH public keys from https://github\.com/testgithubuser\.keys" \
        && _pass "GitHub key fetch: fetch URL logged" \
        || _fail "GitHub key fetch: fetch URL not logged (got: $(printf '%s' "$import_output" | head -3))"

    echo "$import_output" | grep -qE "==> error:.*No SSH public keys returned" \
        && _pass "GitHub key fetch: no-keys result logged as error" \
        || _fail "GitHub key fetch: no-keys result not logged as error"
else
    _fail "GitHub key fetch: eos-import-github-keys.sh was not written by Main"
    _fail "GitHub key fetch: (skipped — script missing)"
fi

# Verify the outer Main also logs an error on script failure (not just a warning).
outer_output="$(
    _run_ssh_main "$R" \
        "$(printf 'IMPORT_GITHUB_KEYS=true\nGITHUB_USERNAME=testgithubuser\n')" \
        --online 2>&1 || true
)"
echo "$outer_output" | grep -qE "==> error:.*[Gg]it[Hh]ub SSH key import failed" \
    && _pass "GitHub key fetch: outer Main logs error on fetch failure" \
    || _fail "GitHub key fetch: outer Main did not log error on fetch failure"

# ── 8. _virt_remove install guard ─────────────────────────────────────────────
#
# On online installs, VM packages (open-vm-tools, gtkmm3, virtualbox-guest-utils,
# etc.) are not installed in the target chroot.  _virt_remove() used to call
# `pacman -Rns` unconditionally, producing:
#   error: target not found: open-vm-tools
# The fix wraps each removal in _is_pkg_installed() so only present packages
# are removed.

echo ""
echo "=== Test 24: _virt_remove guards against removing uninstalled packages ==="

# Static check: the function body must call _is_pkg_installed (or equivalent)
# before invoking pacman -Rns, preventing errors on online/bare-metal installs.
if awk '/_virt_remove\(\)/,/^\}/' "$CLEANER_SCRIPT" \
       | grep -qE "_is_pkg_installed|pacman -Q"; then
    _pass "chrooted_cleaner_script.sh: _virt_remove checks installation before removal"
else
    _fail "chrooted_cleaner_script.sh: _virt_remove has no install guard — pacman -Rns errors on online installs"
fi

# Functional check: _virt_remove must not call pacman -Rns for a package
# that isn't installed (pacman -Q returns 1 for it).
R="$(_new_root)"
(
    # Track whether pacman -Rns was called for "fake-absent-pkg"
    called_rns=0
    pacman() {
        case "$1" in
            -Q) return 1 ;;   # every package "not installed"
            -Rns|-Rs|-R)
                called_rns=1
                echo "UNEXPECTED pacman remove called" >&2
                return 0
                ;;
        esac
    }
    systemctl()    { :; }
    device-info()  { echo ""; }
    lspci()        { echo ""; }
    export -f pacman systemctl device-info lspci

    patched="$(_patch_script "$CLEANER_SCRIPT" "$R")"
    eval "$patched"

    _virt_remove open-vm-tools gtkmm3 xf86-input-vmmouse virtualbox-guest-utils

    if [ "$called_rns" -eq 0 ]; then
        echo "  PASS: _virt_remove: no pacman -Rns called for absent packages"
        exit 0
    else
        echo "  FAIL: _virt_remove: pacman -Rns was called for absent packages" >&2
        exit 1
    fi
) && ((pass++)) || ((fail++)) || true

# ── 9. RDP empty-password guard (session-3 fix) ────────────────────────────────
#
# When enable_rdp=true but rdp_password_b64 is empty, Main() now logs an error
# and disables the RDP path rather than writing an unusable eos-installer-remote.conf.
# This guard fires when the C++ GlobalStorage fallback failed entirely (e.g. usersq
# hadn't run yet, or the user has no login password set).

echo ""
echo "=== Test 25: empty RDP password → error logged, eos-installer-remote.conf NOT written ==="

R="$(_new_root)"
rdp_empty_out="$(
    _run_ssh_main "$R" \
        "$(printf 'ENABLE_RDP=true\nRDP_PASSWORD_B64=\n')" \
        --online 2>&1 || true
)"

echo "$rdp_empty_out" | grep -qE "==> error:.*KRDP was requested but no RDP password" \
    && _pass "empty RDP password: error logged by Main" \
    || _fail "empty RDP password: error NOT logged (got: $(printf '%s' "$rdp_empty_out" | head -5))"

[ ! -f "$R/etc/eos-installer-remote.conf" ] \
    && _pass "empty RDP password: eos-installer-remote.conf NOT written" \
    || _fail "empty RDP password: eos-installer-remote.conf WAS written (should not be)"

# ── 10. First-boot KRDP script must use log_msg error for invalid password ─────
#
# The embedded eos-configure-krdp.sh previously used log_msg warning for an
# invalid/missing RDP password payload — that was silent in monitoring tools.
# The fix promotes it to log_msg error so the condition is never missed.

echo ""
echo "=== Test 26: _write_krdp_setup_script uses log_msg error for invalid password ==="

if awk '/_write_krdp_setup_script\(\)/,/^_write_krdp_setup_service/' "$SSH_SCRIPT" \
       | grep -qE "log_msg[[:space:]]+error.*KRDP setup"; then
    _pass "_write_krdp_setup_script: log_msg error present for invalid RDP password"
else
    _fail "_write_krdp_setup_script: log_msg error missing — first-boot KRDP failure is silent"
fi

if awk '/_write_krdp_setup_script\(\)/,/^_write_krdp_setup_service/' "$SSH_SCRIPT" \
       | grep -qE "log_msg[[:space:]]+warning.*KRDP setup skipped.*invalid RDP"; then
    _fail "_write_krdp_setup_script: old log_msg warning still present for invalid password"
else
    _pass "_write_krdp_setup_script: old log_msg warning removed (correct)"
fi

# ── 11. QML login-password fallback InlineMessage ─────────────────────────────
#
# eos_remote.qml must show an Information-type InlineMessage when the RDP
# checkbox is checked but the password field is empty, telling the user their
# login password will be used (matching the C++ onLeave() fallback behaviour).

echo ""
echo "=== Test 27: eos_remote.qml shows login-password fallback message for empty RDP password ==="

QML_FILE="$CALAMARES_SRC/src/modules/eos_remote/eos_remote.qml"

grep -q "your user login password will be used" "$QML_FILE" \
    && _pass "eos_remote.qml: login-password fallback text present" \
    || _fail "eos_remote.qml: login-password fallback text missing"

grep -q "MessageType.Information" "$QML_FILE" \
    && _pass "eos_remote.qml: Information-type InlineMessage present for RDP fallback" \
    || _fail "eos_remote.qml: Information-type InlineMessage missing for RDP fallback"

# ── 12. First-boot eos-configure-krdp.sh errors on empty password conf ─────────
#
# Run the embedded first-boot script (written by _write_krdp_setup_script) against
# an eos-installer-remote.conf with an empty RDP_PASSWORD_B64.  The script must
# log an error and exit; it must NOT attempt to create directories or self-disable.

echo ""
echo "=== Test 28: first-boot eos-configure-krdp.sh errors on empty RDP password ==="

R="$(_new_root)"
# Write the first-boot krdp script into the fake root using a valid-password run.
RDP_PASS_B64="dGVzdHBhc3Mx"   # "testpass1"
_run_ssh_main "$R" \
    "$(printf 'ENABLE_RDP=true\nRDP_PASSWORD_B64=%s\n' "$RDP_PASS_B64")" \
    --online > /dev/null 2>&1 || true

KRDP_SCRIPT="$R/usr/local/bin/eos-configure-krdp.sh"

if [ ! -f "$KRDP_SCRIPT" ]; then
    _fail "first-boot empty-password: eos-configure-krdp.sh was not written (prerequisite failed)"
    _fail "first-boot empty-password: (skipped — script missing)"
else
    # Replace the remote conf with one that has an empty password.
    printf 'ENABLE_RDP=true\nRDP_PASSWORD_B64=\nTARGET_USER=testuser\n' \
        > "$R/etc/eos-installer-remote.conf"
    chmod 600 "$R/etc/eos-installer-remote.conf"

    krdp_out="$(
        (
            # FAKE_HOME must be exported so getent's body can reference it in
            # the child bash process where $R is not in scope.
            export FAKE_HOME="$R/home/testuser"
            id()       { case "${1:-}" in -u) echo 1000 ;; *) echo testuser ;; esac; }
            getent()   { echo "testuser:x:1000:1000::${FAKE_HOME}:/bin/bash"; }
            systemctl(){ :; }
            export -f id getent systemctl
            bash "$KRDP_SCRIPT" 2>&1 || true
        )
    )"

    echo "$krdp_out" | grep -qE "==> error:.*KRDP setup:.*no valid RDP password" \
        && _pass "first-boot empty-password: error logged by eos-configure-krdp.sh" \
        || _fail "first-boot empty-password: error NOT logged (got: $(printf '%s' "$krdp_out" | head -5))"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
