#!/usr/bin/env bash

_remote_setup_msg() {
    local type="$1"
    local msg="$2"
    echo "==> $type: $msg"
}

_bool_normalize() {
    local value="${1:-}"
    value="${value,,}"
    case "$value" in
        1|y|yes|true|on) echo "true" ;;
        *) echo "false" ;;
    esac
}

_sanitize_github_username() {
    local username="$1"
    if [[ "$username" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]]; then
        echo "$username"
    fi
}

_detect_wayland_session_file() {
    local candidate
    for candidate in plasma.desktop plasmawayland.desktop; do
        if [ -f "/usr/share/wayland-sessions/$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
    echo "plasma.desktop"
}

_configure_default_sddm_autologin() {
    local username="$1"
    local session_file
    local conf_file="/etc/sddm.conf.d/90-eos-default-autologin.conf"

    [ -n "$username" ] || return
    if [ ! -x /usr/bin/sddm ] && [ ! -f /usr/lib/systemd/system/sddm.service ]; then
        _remote_setup_msg warning "SDDM not detected; skipping default autologin bootstrap."
        return
    fi

    session_file="$(_detect_wayland_session_file)"
    install -dm 0755 /etc/sddm.conf.d
    cat > "$conf_file" <<EOF
[General]
DisplayServer=wayland

[Autologin]
User=$username
Session=$session_file
Relogin=true
EOF
    chmod 0644 "$conf_file"
    systemctl enable display-manager.service >/dev/null 2>&1 || true
    _remote_setup_msg info "Configured default SDDM autologin for user '$username'."
}

_insert_pam_line_after_section_start() {
    local pam_file="$1"
    local section="$2"
    local line="$3"
    local marker="$4"
    local tmp_file=""

    [ -f "$pam_file" ] || return 1

    if grep -Eq "^[[:space:]]*${section}[[:space:]].*${marker}" "$pam_file"; then
        return 0
    fi

    tmp_file="$(mktemp)"
    awk -v sec="$section" -v add="$line" '
        BEGIN { inserted = 0 }
        {
            print
            if (!inserted && $1 == sec) {
                print add
                inserted = 1
            }
        }
        END {
            if (!inserted) {
                print add
            }
        }
    ' "$pam_file" > "$tmp_file"

    cat "$tmp_file" > "$pam_file"
    rm -f "$tmp_file"
}

_configure_kwallet_pam_for_sddm() {
    local install_type="${1:-}"
    local pam_sddm="/etc/pam.d/sddm"
    local auth_line="auth            optional        pam_kwallet5.so"
    local session_line="session         optional        pam_kwallet5.so auto_start"

    if ! pacman -Q kwallet-pam >/dev/null 2>&1; then
        if [ "$install_type" = "online" ]; then
            _remote_setup_msg info "Installing kwallet-pam for PAM wallet integration."
            pacman -S --needed --noconfirm kwallet kwallet-pam >/dev/null 2>&1 || \
                _remote_setup_msg warning "Failed to install kwallet-pam; wallet PAM integration may be unavailable."
        fi
    fi

    if ! pacman -Q kwallet-pam >/dev/null 2>&1; then
        _remote_setup_msg warning "kwallet-pam is not installed; skipping /etc/pam.d/sddm wallet PAM setup."
        return
    fi

    if [ ! -f "$pam_sddm" ]; then
        _remote_setup_msg warning "/etc/pam.d/sddm not found; skipping wallet PAM setup."
        return
    fi

    _insert_pam_line_after_section_start "$pam_sddm" "auth" "$auth_line" "pam_kwallet5\\.so"
    _insert_pam_line_after_section_start "$pam_sddm" "session" "$session_line" "pam_kwallet5\\.so[[:space:]]+auto_start"
    _remote_setup_msg info "Configured kwallet-pam integration in /etc/pam.d/sddm."
}

_warn_kwallet_autologin_caveat() {
    if grep -Rqs "^[[:space:]]*\\[Autologin\\]" /etc/sddm.conf /etc/sddm.conf.d/*.conf 2>/dev/null; then
        _remote_setup_msg warning "SDDM autologin is enabled. kwallet-pam may not auto-unlock the wallet without a typed login password."
    fi
}

_write_sshd_auth_config() {
    local mode="$1"
    local conf_dir="/etc/ssh/sshd_config.d"
    local conf_file="$conf_dir/99-eos-installer-auth.conf"

    install -dm 0755 "$conf_dir"

    case "$mode" in
        publickey)
            cat > "$conf_file" <<'EOS_SSHD_PUBLICKEY'
# Managed by EndeavourOS Calamares installer.
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
EOS_SSHD_PUBLICKEY
            ;;
        *)
            cat > "$conf_file" <<'EOS_SSHD_PASSWORD'
# Managed by EndeavourOS Calamares installer.
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PubkeyAuthentication yes
AuthenticationMethods any
EOS_SSHD_PASSWORD
            ;;
    esac

    chmod 0644 "$conf_file"
}

_write_github_import_script() {
    install -dm 0755 /usr/local/bin
    cat > /usr/local/bin/eos-import-github-keys.sh <<'EOS_GITHUB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${1:-}"
GITHUB_USER="${2:-}"
DONE_FILE="/var/lib/eos-github-keys-imported"

[ -n "$TARGET_USER" ] || exit 0
[ -n "$GITHUB_USER" ] || exit 0

home_dir="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$home_dir" ] || exit 0

mkdir -p "$home_dir/.ssh"
chmod 700 "$home_dir/.ssh"
touch "$home_dir/.ssh/authorized_keys"
chmod 600 "$home_dir/.ssh/authorized_keys"
chown -R "$TARGET_USER:$TARGET_USER" "$home_dir/.ssh"

keys=""
if command -v curl >/dev/null 2>&1 ; then
    keys="$(curl -fsSL "https://github.com/${GITHUB_USER}.keys" 2>/dev/null || true)"
elif command -v wget >/dev/null 2>&1 ; then
    keys="$(wget -qO- "https://github.com/${GITHUB_USER}.keys" 2>/dev/null || true)"
fi

if [ -z "$keys" ] ; then
    exit 1
fi

while IFS= read -r key ; do
    [ -n "$key" ] || continue
    grep -Fqx "$key" "$home_dir/.ssh/authorized_keys" || echo "$key" >> "$home_dir/.ssh/authorized_keys"
done <<KEYS_EOF
$keys
KEYS_EOF

chown "$TARGET_USER:$TARGET_USER" "$home_dir/.ssh/authorized_keys"
touch "$DONE_FILE"

install -dm 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-eos-installer-auth.conf <<'EOS_SSHD_PUBLICKEY'
# Managed by EndeavourOS Calamares installer.
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
EOS_SSHD_PUBLICKEY
chmod 0644 /etc/ssh/sshd_config.d/99-eos-installer-auth.conf

if command -v systemctl >/dev/null 2>&1; then
    systemctl try-restart sshd.service >/dev/null 2>&1 || true
fi
EOS_GITHUB_SCRIPT
    chmod 0755 /usr/local/bin/eos-import-github-keys.sh
}

_write_github_import_service() {
    local username="$1"
    local github_username="$2"

    install -dm 0755 /etc/systemd/system
    cat > /etc/systemd/system/eos-import-github-keys.service <<EOS_GITHUB_SERVICE
[Unit]
Description=Import GitHub SSH keys for installed user
Wants=network-online.target
After=network-online.target
ConditionPathExists=!/var/lib/eos-github-keys-imported

[Service]
Type=oneshot
ExecStart=/usr/local/bin/eos-import-github-keys.sh ${username} ${github_username}

[Install]
WantedBy=multi-user.target
EOS_GITHUB_SERVICE
}

_write_krdp_setup_script() {
    install -dm 0755 /usr/local/bin
    cat > /usr/local/bin/eos-configure-krdp.sh <<'EOS_KRDP_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

log_msg() {
    local type="$1"
    local msg="$2"
    echo "==> $type: $msg"
}

bool_normalize() {
    local value="${1:-}"
    value="${value,,}"
    case "$value" in
        1|y|yes|true|on) echo "true" ;;
        *) echo "false" ;;
    esac
}

escape_unit_arg() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\$\$}"
    value="${value//%/%%}"
    printf '%s' "$value"
}

run_as_target_user() {
    local user="$1"
    shift
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$user" -- "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -u "$user" "$@"
    else
        return 1
    fi
}

run_user_systemctl() {
    local user="$1"
    local uid="$2"
    shift 2

    local runtime_dir="/run/user/$uid"
    local dbus_addr="unix:path=$runtime_dir/bus"

    if [ ! -d "$runtime_dir" ]; then
        return 1
    fi

    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$user" -- env \
            XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
            systemctl --user "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -u "$user" env \
            XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
            systemctl --user "$@"
    else
        return 1
    fi
}

detect_wayland_session_file() {
    local candidate
    for candidate in plasma.desktop plasmawayland.desktop; do
        if [ -f "/usr/share/wayland-sessions/$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
    echo "plasma.desktop"
}

configure_sddm_autologin() {
    local user="$1"
    local session_file
    local conf_file="/etc/sddm.conf.d/90-eos-krdp-autologin.conf"

    if [ ! -x /usr/bin/sddm ] && [ ! -f /usr/lib/systemd/system/sddm.service ]; then
        log_msg warning "SDDM not detected; skipping KRDP autologin bootstrap."
        return
    fi

    session_file="$(detect_wayland_session_file)"
    install -dm 0755 /etc/sddm.conf.d
    cat > "$conf_file" <<__EOS_SDDM_AUTLOGIN__
[General]
DisplayServer=wayland

[Autologin]
User=$user
Session=$session_file
Relogin=true
__EOS_SDDM_AUTLOGIN__
    chmod 0644 "$conf_file"

    systemctl enable display-manager.service >/dev/null 2>&1 || true
    log_msg info "Configured SDDM Wayland autologin for KRDP user '$user'."
}

configure_firewall_for_rdp() {
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        return
    fi

    if systemctl is-enabled firewalld.service >/dev/null 2>&1 || systemctl is-active firewalld.service >/dev/null 2>&1; then
        if firewall-cmd -q --permanent --add-port=3389/tcp >/dev/null 2>&1; then
            firewall-cmd --reload >/dev/null 2>&1 || true
            log_msg info "Opened firewall port 3389/tcp for KRDP."
        else
            log_msg warning "Failed to open firewall port 3389/tcp for KRDP."
        fi
    fi
}

main() {
    local config_file="/etc/eos-installer-remote.conf"
    local done_file="/var/lib/eos-krdp-configured"

    local enable_rdp="false"
    local rdp_password_b64=""
    local target_user=""

    [ -f "$done_file" ] && exit 0
    [ -r "$config_file" ] || exit 0

    while IFS='=' read -r key value; do
        case "$key" in
            ENABLE_RDP)
                enable_rdp="$(bool_normalize "$value")"
                ;;
            RDP_PASSWORD_B64)
                rdp_password_b64="$value"
                ;;
            TARGET_USER)
                target_user="$value"
                ;;
        esac
    done < "$config_file"

    if [ "$enable_rdp" != "true" ]; then
        rm -f "$config_file"
        touch "$done_file"
        systemctl disable eos-configure-krdp.service >/dev/null 2>&1 || true
        exit 0
    fi

    if [ -z "$target_user" ] || ! id -u "$target_user" >/dev/null 2>&1 ; then
        log_msg warning "KRDP setup skipped: target user missing."
        exit 1
    fi

    local target_uid
    local target_home
    local rdp_password
    local krdp_ssl_dir
    local krdp_cert
    local krdp_key
    local dropin_dir
    local dropin_file
    local user_esc
    local pass_esc
    local cert_esc
    local key_esc
    local bin_esc

    target_uid="$(id -u "$target_user")"
    target_home="$(getent passwd "$target_user" | cut -d: -f6)"
    [ -n "$target_home" ] || exit 1

    rdp_password="$(printf '%s' "$rdp_password_b64" | base64 -d 2>/dev/null || true)"
    if [ -z "$rdp_password" ] || [ "${#rdp_password}" -lt 8 ]; then
        log_msg warning "KRDP setup skipped: invalid RDP password payload."
        exit 1
    fi

    krdp_ssl_dir="$target_home/.config/krdp"
    krdp_cert="$krdp_ssl_dir/server.crt"
    krdp_key="$krdp_ssl_dir/server.key"
    dropin_dir="$target_home/.config/systemd/user/app-org.kde.krdpserver.service.d"
    dropin_file="$dropin_dir/installer-credentials.conf"

    install -dm 0700 "$krdp_ssl_dir"
    install -dm 0700 "$dropin_dir"
    chown -R "$target_user:$target_user" "$target_home/.config"

    if [ ! -s "$krdp_cert" ] || [ ! -s "$krdp_key" ]; then
        local host_name
        host_name="$(hostname 2>/dev/null || echo localhost)"
        if ! run_as_target_user "$target_user" openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$krdp_key" -out "$krdp_cert" \
            -subj "/CN=$host_name" \
            -addext "subjectAltName=DNS:$host_name,DNS:localhost,IP:127.0.0.1" 2>/dev/null; then
            run_as_target_user "$target_user" openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout "$krdp_key" -out "$krdp_cert" \
                -subj "/CN=$host_name" 2>/dev/null || true
        fi
        run_as_target_user "$target_user" chmod 600 "$krdp_key" || true
        run_as_target_user "$target_user" chmod 644 "$krdp_cert" || true
    fi

    user_esc="$(escape_unit_arg "$target_user")"
    pass_esc="$(escape_unit_arg "$rdp_password")"
    cert_esc="$(escape_unit_arg "$krdp_cert")"
    key_esc="$(escape_unit_arg "$krdp_key")"
    bin_esc="$(escape_unit_arg "/usr/bin/krdpserver")"

    cat > "$dropin_file" <<__DROPIN_EOF__
[Service]
Environment=MESA_LOADER_DRIVER_OVERRIDE=swrast
Environment=LIBGL_ALWAYS_SOFTWARE=1
Environment=KPIPEWIRE_FORCE_ENCODER=libx264
Environment=KRDP_ENABLE_NLA=0
Environment=KRDP_TOUCHPAD_SCROLL_INVERT=1
Environment=KRDP_TOUCHPAD_SCROLL_SCALE=0.35
Environment=KRDP_MOUSE_SCROLL_SCALE=3.0
ExecStart=
ExecStart="$bin_esc" --monitor -1 --quality 75 --certificate "$cert_esc" --certificate-key "$key_esc" -u "$user_esc" -p "$pass_esc"
__DROPIN_EOF__
    chmod 600 "$dropin_file"
    chown "$target_user:$target_user" "$dropin_file"

    configure_firewall_for_rdp
    configure_sddm_autologin "$target_user"

    if command -v loginctl >/dev/null 2>&1; then
        loginctl enable-linger "$target_user" >/dev/null 2>&1 || true
    fi
    systemctl start "user@$target_uid.service" >/dev/null 2>&1 || true

    if run_user_systemctl "$target_user" "$target_uid" daemon-reload; then
        run_user_systemctl "$target_user" "$target_uid" enable app-org.kde.krdpserver.service >/dev/null 2>&1 || true
        run_user_systemctl "$target_user" "$target_uid" restart app-org.kde.krdpserver.service >/dev/null 2>&1 || true
    else
        log_msg warning "KRDP service could not be started yet; it will use configured credentials on user session start."
    fi

    rm -f "$config_file"
    touch "$done_file"
    systemctl disable eos-configure-krdp.service >/dev/null 2>&1 || true
    log_msg info "KRDP credential setup complete."
}

main "$@"
EOS_KRDP_SCRIPT
    chmod 0755 /usr/local/bin/eos-configure-krdp.sh
}

_write_krdp_setup_service() {
    install -dm 0755 /etc/systemd/system
    cat > /etc/systemd/system/eos-configure-krdp.service <<'EOS_KRDP_SERVICE'
[Unit]
Description=Configure KRDP credentials from installer choices
After=systemd-user-sessions.service
ConditionPathExists=!/var/lib/eos-krdp-configured

[Service]
Type=oneshot
ExecStart=/usr/local/bin/eos-configure-krdp.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOS_KRDP_SERVICE
}

Main() {
    local opt
    local INSTALL_TYPE=""
    local NEW_USER=""
    local config_file=/tmp/eos-installer-ssh.conf
    local enable_sshd=false
    local import_github_keys=false
    local github_username=""
    local enable_rdp=false
    local rdp_password_b64=""
    local effective_import_github_keys=false
    local ssh_auth_mode="password"
    local github_keys_imported=false

    for opt in "$@"; do
        case "$opt" in
            --user=*)
                NEW_USER="${opt#*=}"
                ;;
            --online)
                INSTALL_TYPE="online"
                ;;
        esac
    done

    if [ -n "$NEW_USER" ] && id -u "$NEW_USER" >/dev/null 2>&1 ; then
        _configure_default_sddm_autologin "$NEW_USER"
    else
        _remote_setup_msg warning "No valid target username available; skipping default SDDM autologin bootstrap."
    fi

    _configure_kwallet_pam_for_sddm "$INSTALL_TYPE"
    _warn_kwallet_autologin_caveat

    if [ ! -r "$config_file" ] ; then
        _remote_setup_msg info "No installer remote setup config found. Skipping."
        return
    fi

    while IFS='=' read -r key value; do
        case "$key" in
            ENABLE_SSHD)
                enable_sshd="$(_bool_normalize "$value")"
                ;;
            IMPORT_GITHUB_KEYS)
                import_github_keys="$(_bool_normalize "$value")"
                ;;
            GITHUB_USERNAME)
                github_username="$value"
                ;;
            ENABLE_RDP)
                enable_rdp="$(_bool_normalize "$value")"
                ;;
            RDP_PASSWORD_B64)
                rdp_password_b64="$value"
                ;;
        esac
    done < "$config_file"

    github_username="$(_sanitize_github_username "$github_username")"
    if [ "$import_github_keys" = "true" ] && [ -z "$github_username" ] ; then
        _remote_setup_msg warning "Skipping GitHub key import due to missing or invalid username."
        import_github_keys=false
    fi

    if [ "$import_github_keys" = "true" ] ; then
        if [ -z "$NEW_USER" ] ; then
            _remote_setup_msg warning "No target username available; cannot configure GitHub key import."
            effective_import_github_keys=false
        else
            effective_import_github_keys=true
        fi
    fi

    if [ "$enable_sshd" = "true" ] ; then
        if ! pacman -Q openssh >/dev/null 2>&1 ; then
            if [ "$INSTALL_TYPE" = "online" ] ; then
                _remote_setup_msg info "Installing openssh for requested SSH server setup."
                pacman -S --needed --noconfirm openssh || _remote_setup_msg warning "Failed to install openssh."
            else
                _remote_setup_msg warning "openssh missing in offline install; cannot enable sshd."
            fi
        fi

        _write_sshd_auth_config "$ssh_auth_mode"
        _remote_setup_msg info "Configured sshd authentication mode: $ssh_auth_mode."

        if pacman -Q openssh >/dev/null 2>&1 ; then
            _remote_setup_msg info "Enabling sshd service."
            systemctl enable sshd.service || _remote_setup_msg warning "Failed to enable sshd."
        fi
    fi

    if [ "$effective_import_github_keys" = "true" ] ; then
        _remote_setup_msg info "Configuring GitHub SSH key import for user '$NEW_USER'."
        _write_github_import_script

        if /usr/local/bin/eos-import-github-keys.sh "$NEW_USER" "$github_username" ; then
            _remote_setup_msg info "Imported GitHub SSH keys during installation."
            github_keys_imported=true
        else
            _remote_setup_msg warning "Immediate GitHub SSH key import failed; will retry on first boot."
        fi

        _write_github_import_service "$NEW_USER" "$github_username"
        systemctl enable eos-import-github-keys.service || _remote_setup_msg warning "Failed to enable eos-import-github-keys.service."
    fi

    if [ "$enable_sshd" = "true" ] && [ "$github_keys_imported" = "true" ] ; then
        _write_sshd_auth_config "publickey"
        systemctl try-restart sshd.service >/dev/null 2>&1 || true
        _remote_setup_msg info "Configured sshd authentication mode: publickey."
    fi

    if [ "$enable_rdp" = "true" ] ; then
        if [ -z "$NEW_USER" ] ; then
            _remote_setup_msg warning "No target username available; cannot configure KRDP credentials."
        else
            if ! pacman -Q krdp >/dev/null 2>&1 ; then
                if [ "$INSTALL_TYPE" = "online" ] ; then
                    _remote_setup_msg info "Installing KRDP runtime packages."
                    pacman -S --needed --noconfirm krdp xdg-desktop-portal-kde pipewire pipewire-pulse || \
                        _remote_setup_msg warning "Failed to install one or more KRDP runtime packages."
                else
                    _remote_setup_msg warning "KRDP package missing in offline install; cannot configure KRDP credentials."
                fi
            fi

            if pacman -Q krdp >/dev/null 2>&1 ; then
                _remote_setup_msg info "Scheduling KRDP credential setup for first boot."
                cat > /etc/eos-installer-remote.conf <<EOS_REMOTE_CONFIG
ENABLE_RDP=true
RDP_PASSWORD_B64=$rdp_password_b64
TARGET_USER=$NEW_USER
EOS_REMOTE_CONFIG
                chmod 600 /etc/eos-installer-remote.conf
                _write_krdp_setup_script
                _write_krdp_setup_service
                systemctl enable eos-configure-krdp.service || _remote_setup_msg warning "Failed to enable eos-configure-krdp.service."
            fi
        fi
    fi

    rm -f "$config_file"
    _remote_setup_msg info "Installer remote access setup complete."
}

Main "$@"
