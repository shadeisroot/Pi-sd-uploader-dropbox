#!/usr/bin/env bash
# Remove SD Uploader.
#
#   sudo ./uninstall.sh            keep settings, Dropbox login and logs
#   sudo ./uninstall.sh --purge    remove those too
#
# Nothing in Dropbox is touched.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

systemctl disable --now sd-uploader-status.service 2>/dev/null || true
systemctl stop 'sd-uploader@*.service' 'sd-uploader-removed@*.service' 2>/dev/null || true
rm -f /etc/udev/rules.d/99-sd-uploader.rules \
  /etc/systemd/system/sd-uploader@.service \
  /etc/systemd/system/sd-uploader-removed@.service \
  /etc/systemd/system/sd-uploader-status.service \
  /etc/tmpfiles.d/sd-uploader.conf \
  /etc/systemd/journald.conf.d/zz-sd-uploader.conf \
  /usr/local/bin/sd-uploader
rm -rf /usr/local/lib/sd-uploader /run/sd-uploader
systemctl daemon-reload
udevadm control --reload
echo "SD Uploader removed. The packages it installed (exiftool, rclone, exfatprogs, gpiozero) were left in place."

if [ "$PURGE" = 1 ]; then
  rm -rf /etc/sd-uploader /var/lib/sd-uploader /var/log/sd-uploader
  echo "Settings, Dropbox login and logs removed."
else
  echo "Kept: /etc/sd-uploader (settings), /var/lib/sd-uploader (Dropbox login), /var/log/sd-uploader (logs)."
  echo "Remove them too with: sudo ./uninstall.sh --purge"
fi
