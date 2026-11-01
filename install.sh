#!/usr/bin/env bash
# Install or update SD Uploader on a Raspberry Pi (Raspberry Pi OS / Debian).
#
#   sudo ./install.sh
#
# Safe to run again to update: your settings and Dropbox login are kept.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

LIB=/usr/local/lib/sd-uploader
CONF=/etc/sd-uploader/sd-uploader.conf
step() { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

if ! command -v apt-get >/dev/null || ! command -v systemctl >/dev/null; then
  die "this needs Raspberry Pi OS (or another Debian-based system with systemd)"
fi

step "Installing packages: exiftool, rclone, exFAT tools, gpiozero"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  libimage-exiftool-perl rclone exfatprogs python3-gpiozero >/dev/null
note "rclone $(rclone version 2>/dev/null | head -n1 | awk '{print $2}'), exiftool $(exiftool -ver)"

step "Installing SD Uploader $(cat VERSION)"
install -D -m 755 src/sd-uploader /usr/local/bin/sd-uploader
install -d -m 755 "$LIB"
install -m 755 src/offload.sh src/card-removed.sh src/connect-dropbox.sh "$LIB/"
install -m 644 src/statusd.py VERSION "$LIB/"
install -m 644 systemd/sd-uploader@.service systemd/sd-uploader-removed@.service \
  systemd/sd-uploader-status.service /etc/systemd/system/
install -m 644 udev/99-sd-uploader.rules /etc/udev/rules.d/
install -m 644 system/tmpfiles.conf /etc/tmpfiles.d/sd-uploader.conf
install -D -m 644 system/journald.conf /etc/systemd/journald.conf.d/zz-sd-uploader.conf
note "command: /usr/local/bin/sd-uploader"

step "Settings"
if [ -f "$CONF" ]; then
  note "kept your settings: $CONF"
else
  install -D -m 644 config/sd-uploader.conf "$CONF"
  note "created $CONF (DELETE=dry-run: nothing is deleted until you change it)"
fi

step "Starting services"
systemd-tmpfiles --create /etc/tmpfiles.d/sd-uploader.conf
systemctl restart systemd-journald
systemctl daemon-reload
udevadm control --reload
systemctl enable -q sd-uploader-status.service
systemctl restart sd-uploader-status.service
systemctl is-active -q sd-uploader-status.service \
  || die "the status light service didn't start: journalctl -u sd-uploader-status"
note "status light: running"
note "card trigger: active (udev)"

echo
if [ -s /var/lib/sd-uploader/rclone.conf ]; then
  printf '\033[1;32mUpdated.\033[0m Check it with: sudo sd-uploader status\n'
else
  printf '\033[1;32mInstalled.\033[0m Next, connect Dropbox and test the light:\n\n    sudo sd-uploader setup\n\n'
fi
