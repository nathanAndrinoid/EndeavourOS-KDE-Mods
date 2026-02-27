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

