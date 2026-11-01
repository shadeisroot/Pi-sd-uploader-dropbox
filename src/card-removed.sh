#!/usr/bin/env bash
# Runs when a card is pulled out of the reader: card-removed.sh <partition>
# Started by the udev rule through sd-uploader-removed@<partition>.service.
set -uo pipefail
DEV="/dev/$1"
STATE="${SD_UPLOADER_RUN:-/run/sd-uploader}/state"

# The card is gone, so drop any mount of it (lazy: it can't be read any more anyway).
for target in $(findmnt -rno TARGET -S "$DEV"); do
  umount -l "$target" && echo "unmounted $target"
done

state=$(cat "$STATE" 2>/dev/null || echo idle)
case "$state" in
  done) sd-uploader led idle ;;
  # Pulled while working: stop the upload now and show red, instead of letting
  # it run on from cached data and fail minutes later. Putting the card back in
  # starts again and skips what's already in Dropbox.
  uploading)
    systemctl stop "sd-uploader@$1.service"
    sd-uploader led error ;;
  # error: stay red until the next card, so a failure isn't missed.
esac
echo "card $1 removed, state was $state"
