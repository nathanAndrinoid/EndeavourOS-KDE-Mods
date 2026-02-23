#!/usr/bin/env bash

# Made by fernandomaroto for EndeavourOS and Portergos
# Adapted from AIS. An excellent bit of code!
# ISO-NEXT specific cleanup removals and additions (08-2021) @killajoe and @manuel
# 01-2022 passing in root path and username as params - @dalto
# 04-2022 re-organized code - @manuel

# Anything to be executed outside chroot need to be here.

_cleaner_msg() {            # use this function to provide all user messages (info, warning, error, ...)
    local type="$1"
    local msg="$2"
    echo "==> $type: $msg"
}

_CopyFileToTarget() {
    # Copy a file to target

    local file="$1"
    local targetdir="$2"

    if [ ! -r "$file" ] ; then
        _cleaner_msg warning "file '$file' does not exist."
        return
    fi
    if [ ! -d "$targetdir" ] ; then
        _cleaner_msg warning "folder '$targetdir' does not exist."
        return
    fi
    _cleaner_msg info "copying $(basename "$file") to target"
    cp "$file" "$targetdir"
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

_password_is_valid() {
    local password="$1"
    [ "${#password}" -ge 8 ]
}

_prompt_installer_remote_options() {
    local config_file=/tmp/eos-installer-ssh.conf
    local enable_sshd=false
    local import_github_keys=false
    local github_username=""
    local enable_rdp=false
    local rdp_password=""
    local rdp_password_confirm=""
    local rdp_password_b64=""
    local response=""

    if [ -r "$config_file" ] ; then
        return
    fi

    if command -v kdialog >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ] ; then
        if kdialog --title "EndeavourOS Installer" \
            --yes-label "Enable" --no-label "Skip" \
            --yesno "Enable OpenSSH server on the installed system?" ; then
            enable_sshd=true
        fi

        if kdialog --title "EndeavourOS Installer" \
            --yes-label "Import" --no-label "Skip" \
            --yesno "Import GitHub public SSH keys for the installed user?" ; then
            import_github_keys=true
            github_username="$(kdialog --title "EndeavourOS Installer" \
                --inputbox "GitHub username for SSH key import:" 2>/dev/null || true)"
        fi

        if kdialog --title "EndeavourOS Installer" \
            --yes-label "Configure" --no-label "Skip" \
            --yesno "Configure KRDP and set a dedicated RDP password?" ; then
            enable_rdp=true
            rdp_password="$(kdialog --title "EndeavourOS Installer" \
                --password "Enter RDP password (minimum 8 characters):" 2>/dev/null || true)"
            rdp_password_confirm="$(kdialog --title "EndeavourOS Installer" \
                --password "Confirm RDP password:" 2>/dev/null || true)"
        fi
    elif [ -t 0 ] ; then
        read -r -p "Enable OpenSSH server on the installed system? [y/N] " response
        if [[ "$response" =~ ^[Yy]$ ]] ; then
            enable_sshd=true
        fi

        response=""
        read -r -p "Import GitHub public SSH keys for the installed user? [y/N] " response
        if [[ "$response" =~ ^[Yy]$ ]] ; then
            import_github_keys=true
            read -r -p "GitHub username for SSH key import: " github_username
        fi

        response=""
        read -r -p "Configure KRDP and set a dedicated RDP password? [y/N] " response
        if [[ "$response" =~ ^[Yy]$ ]] ; then
            enable_rdp=true
            read -r -s -p "Enter RDP password (minimum 8 characters): " rdp_password
            echo
            read -r -s -p "Confirm RDP password: " rdp_password_confirm
            echo
        fi
    else
        _cleaner_msg warning "No interactive prompt available. Using remote access defaults."
    fi

    github_username="${github_username//[[:space:]]/}"
    github_username="$(_sanitize_github_username "$github_username")"
    if [ "$import_github_keys" = "true" ] && [ -z "$github_username" ] ; then
        _cleaner_msg warning "GitHub SSH key import selected but username is empty or invalid. Skipping key import."
        import_github_keys=false
    fi

    if [ "$enable_rdp" = "true" ] ; then
        if [ "$rdp_password" != "$rdp_password_confirm" ] ; then
            _cleaner_msg warning "RDP password confirmation did not match. Skipping KRDP setup."
            enable_rdp=false
            rdp_password=""
        elif ! _password_is_valid "$rdp_password" ; then
            _cleaner_msg warning "RDP password must be at least 8 characters. Skipping KRDP setup."
            enable_rdp=false
            rdp_password=""
        else
            rdp_password_b64="$(printf '%s' "$rdp_password" | base64 | tr -d '\n')"
        fi
    fi

    cat > "$config_file" << EOF
ENABLE_SSHD=$(_bool_normalize "$enable_sshd")
IMPORT_GITHUB_KEYS=$(_bool_normalize "$import_github_keys")
GITHUB_USERNAME=$github_username
ENABLE_RDP=$(_bool_normalize "$enable_rdp")
RDP_PASSWORD_B64=$rdp_password_b64
EOF
    chmod 0600 "$config_file"
}

_manage_broadcom_wifi_driver() {
    local pkgname=broadcom-wl
    local targetfile=/tmp/$chroot_path/tmp/$pkgname.txt

    # detecting broadcom hardware
    if lsmod | grep -q "brcmfmac\|b43\|wl" \
      || lspci -nn | grep -qi "14e4:43"; then

        # check in addition if  broadcom-wl is installed on the live-system
        if pacman -Q broadcom-wl &>/dev/null; then
            echo "yes" > "$targetfile"
        else
            echo "Broadcom hardware found, but broadcom-wl not installed in live system" >&2
        fi

    fi
}

_copy_files(){
    local config_file
    local target=/tmp/$chroot_path            # $target refers to the / folder of the installed system

    if [ -r /home/liveuser/setup.url ] ; then
        # Is this needed anymore?
        # /home/liveuser/setup.url contains the URL to personal setup.sh
        local URL="$(cat /home/liveuser/setup.url)"
        if (wget -q -O /home/liveuser/setup.sh "$URL") ; then
            _cleaner_msg info "copying setup.sh to target"
            cp /home/liveuser/setup.sh $target/tmp/   # into /tmp/setup.sh of chrooted
        fi
    fi

    # copy user_commands.bash to target
    _CopyFileToTarget /home/liveuser/user_commands.bash $target/tmp

    # Ask for remote access setup (SSH + GitHub keys + KRDP password) and pass choices into target.
    _prompt_installer_remote_options
    _CopyFileToTarget /tmp/eos-installer-ssh.conf $target/tmp

    # copy hotfix-end.bash to target
    _CopyFileToTarget /usr/share/endeavouros/hotfix/hotfixes/hotfix-end.bash $target/tmp

    # copy 30-touchpad.conf Xorg config file
    _cleaner_msg info "copying 30-touchpad.conf to target"
    mkdir -p $target/usr/share/X11/xorg.conf.d
    cp /usr/share/X11/xorg.conf.d/30-touchpad.conf  $target/usr/share/X11/xorg.conf.d/

    # copy locally built KRDP package for target-side override after package install
    if /usr/bin/ls /usr/share/packages/krdp-*.pkg.tar.zst >/dev/null 2>&1 ; then
        _cleaner_msg info "copying local patched KRDP package(s) to target"
        mkdir -p "$target/usr/share/packages"
        cp /usr/share/packages/krdp-*.pkg.tar.zst "$target/usr/share/packages/"
    else
        _cleaner_msg warning "no local KRDP package found under /usr/share/packages"
    fi

    # copy extra drivers from /opt/extra-drivers to target's /opt/extra-drivers
    if [ -n "$(/usr/bin/ls /opt/extra-drivers/*.zst 2>/dev/null)" ] ; then
        _cleaner_msg info "copying extra drivers to target"
        mkdir -p $target/opt/extra-drivers || _cleaner_msg warning "creating folder /opt/extra-drivers on target failed."
        cp /opt/extra-drivers/*.zst $target/opt/extra-drivers/ || _cleaner_msg warning "copying drivers to /opt/extra-drivers on target failed."
    fi

    _manage_broadcom_wifi_driver

    # copy endeavouros-release file
    local file=/usr/lib/endeavouros-release
    if [ -r $file ] ; then
        if [ ! -r $target$file ] ; then
            _cleaner_msg info "copying $file to target"
            rsync -vaRI $file $target
        fi
    else
        _cleaner_msg warning "$FUNCNAME: file $file does not exist in the ISO, copy to target failed!"
    fi
}

Main() {
    _cleaner_msg info "cleaner_script.sh started."

    local ROOT_PATH="" NEW_USER=""
    local i

    # parse the options
    for i in "$@"; do
        case $i in
            --root=*)
                ROOT_PATH="${i#*=}"
                shift
                ;;
            --user=*)
                NEW_USER="${i#*=}"
                shift
                ;;
            --online)
                INSTALL_TYPE="online"
                shift
                ;;
        esac
    done

    if [ -n "$ROOT_PATH" ] ; then
        chroot_path="${ROOT_PATH#/tmp/}"
    else
        # "else" needed no more?
        if [ -f /tmp/chrootpath.txt ]
        then
            chroot_path=$(echo ${ROOT_PATH} |sed 's/\/tmp\///')
        else
            chroot_path=$(lsblk |grep "calamares-root" |awk '{ print $NF }' |sed -e 's/\/tmp\///' -e 's/\/.*$//' |tail -n1)
        fi
    fi

    if [ -z "$chroot_path" ] ; then
        _cleaner_msg "FATAL ERROR" "cleaner_script.sh: chroot_path is empty!"
        return  # no point in continuing here
    fi
    # [ -z "$NEW_USER" ] && _cleaner_msg "error" "cleaner_script.sh: new username is unknown!"

    # Copy any file from live environment to new system
    _copy_files

    _cleaner_msg info "cleaner_script.sh done."
}


Main "$@"
