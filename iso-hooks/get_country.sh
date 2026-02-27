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

