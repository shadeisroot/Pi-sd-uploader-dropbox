#!/usr/bin/env bash
# sd-uploader: upload a camera card to Dropbox, sorted into folders by shooting
# date, verify every file by its Dropbox content hash, and only then delete
# exactly the verified files from the card (if DELETE=on).
#
#   offload.sh [--dry-run] [DEVICE]      e.g. offload.sh /dev/sda1
#
# Normally started by udev + systemd when a card is inserted (sd-uploader@.service),
# or by hand with `sudo sd-uploader run`. --dry-run only plans: nothing is
# uploaded or deleted. Without DEVICE it uses the card in the USB reader.
# Exit code 0 = PASS (every file is in Dropbox with the right hash), 1 = FAIL.
set -Eeuo pipefail

# --- Settings ------------------------------------------------------------------
# The environment wins over the config file (handy for tests and one-off runs).
CONF="${SD_UPLOADER_CONF:-/etc/sd-uploader/sd-uploader.conf}"
RUN_DIR="${SD_UPLOADER_RUN:-/run/sd-uploader}"
LOG_DIR="${SD_UPLOADER_LOGS:-/var/log/sd-uploader}"
MNT="${SD_UPLOADER_MNT:-/mnt/sd-uploader}"
export RCLONE_CONFIG="${RCLONE_CONFIG:-/var/lib/sd-uploader/rclone.conf}"

# setting KEY DEFAULT: read KEY=value from the config file. No shell code is run.
setting() {
  local key=$1 val
  [ -n "${!key:-}" ] && return
  val=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=//p" "$CONF" 2>/dev/null | tail -n1)
  val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/')
  printf -v "$key" '%s' "${val:-$2}"
}
setting REMOTE dropbox:
setting FOLDER_FORMAT %Y/%m
setting DELETE dry-run
setting MIN_FREE_GB 1
setting TRANSFERS 4

# Fail within minutes, not hang, when the internet drops.
export RCLONE_CONTIMEOUT=20s RCLONE_TIMEOUT=2m RCLONE_RETRIES=3 RCLONE_LOW_LEVEL_RETRIES=5
# Photo and video types to upload. Anything else on the card is listed in the log, not uploaded.
EXTS="jpg jpeg heic heif png tif tiff dng cr2 cr3 crw nef nrw arw srf sr2 orf rw2 raf pef srw x3f
      mov mp4 m4v avi mts m2ts mpg 3gp mxf insv insp wav"

DRY_RUN=0
DEV=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    /dev/*) DEV="$arg" ;;
    *) echo "usage: offload.sh [--dry-run] [DEVICE]" >&2; exit 2 ;;
  esac
done

bad_setting() { echo "sd-uploader: bad setting in $CONF: $*" >&2; exit 2; }
# shellcheck disable=SC2153  # DELETE is set by setting() above
case "$DELETE" in on|off|dry-run) ;; *) bad_setting "DELETE=$DELETE (use on, off or dry-run)" ;; esac
[[ $MIN_FREE_GB =~ ^[0-9]+$ ]] || bad_setting "MIN_FREE_GB=$MIN_FREE_GB (whole GiB)"
[[ $TRANSFERS =~ ^[1-9][0-9]?$ ]] || bad_setting "TRANSFERS=$TRANSFERS (1-99)"
[[ $FOLDER_FORMAT =~ ^[A-Za-z0-9%/_\ -]+$ && $FOLDER_FORMAT != /* && $FOLDER_FORMAT != *..* ]] \
  || bad_setting "FOLDER_FORMAT=$FOLDER_FORMAT (letters, digits, / _ - space and %Y %m %d)"
MIN_FREE=$((MIN_FREE_GB * 1024 ** 3))

# Dropbox path for a folder: "dropbox:" + "2026/07", or "dropbox:Camera" + "/2026/07".
remote_path() { case "$REMOTE" in *: | */) echo "$REMOTE$1" ;; *) echo "$REMOTE/$1" ;; esac; }

# --- Logging, lock, cleanup ----------------------------------------------------
mkdir -p "$LOG_DIR" "$RUN_DIR"
RUN_ID=$(date +%Y%m%d-%H%M%S)
LOG="$LOG_DIR/run-$RUN_ID.log"
MANIFEST="$LOG_DIR/run-$RUN_ID.manifest.tsv"
DELETED="$LOG_DIR/run-$RUN_ID.deleted.txt"
exec > >(tee -a "$LOG") 2>&1
# If tee is stopped first (service stop), keep going instead of dying on the
# next log line, so cleanup still runs.
trap '' PIPE
log() { echo "$(date +%H:%M:%S) $*"; }
die() { log "ERROR: $*"; exit 1; }
size() { numfmt --to=iec --suffix=B "$1"; }   # 1234567 -> 1.2MB
# Status light: write the state for sd-uploader-status (via a temp file, so it
# never reads half a word). A dry run leaves the light alone.
led() {
  [ "$DRY_RUN" = 1 ] && return
  echo "$1" > "$RUN_DIR/state.tmp" && mv "$RUN_DIR/state.tmp" "$RUN_DIR/state"
}

# Only one run at a time.
exec 9> "$RUN_DIR/offload.lock"
flock -n 9 || die "another upload is already running"

WORK=$(mktemp -d)   # plan tree of symlinks + lists
WE_MOUNTED=0
DONE_OK=0
DELETING=0
cleanup() {
  trap - ERR   # cleanup's own checks are not failed steps
  if [ "$DONE_OK" != 1 ]; then
    if [ "$DELETING" = 1 ]; then
      log "ERROR: stopped while deleting. Every file was verified in Dropbox first, so nothing is lost; the rest stay on the card."
    elif [ -n "$DEV" ] && [ ! -b "$DEV" ]; then
      log "ERROR: the card was pulled out before the end. Nothing was deleted."
    fi
    led error
  fi
  [ "$WE_MOUNTED" = 1 ] && umount "$MNT" 2>/dev/null
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT
trap 'log "ERROR: step failed (line $LINENO): $BASH_COMMAND"' ERR
trap 'log "ERROR: stopped by a signal"; exit 1' TERM INT HUP
# Blue from the start: hashing a full card takes a while before any upload begins.
led uploading

# --- 1. Find and mount the card (read-only) ----------------------------------
if [ -z "$DEV" ]; then
  # Card readers show empty slots as 0-byte drives, so look for partitions on USB drives.
  cards=()
  for p in /sys/block/sd*/sd*[0-9]; do
    [ -e "$p" ] || continue
    d="/dev/${p##*/}"
    udevadm info -q property -n "$d" | grep -x 'ID_BUS=usb' >/dev/null && cards+=("$d")
  done
  [ "${#cards[@]}" -eq 1 ] || die "found ${#cards[@]} cards (${cards[*]:-none}); name one, e.g. /dev/sda1"
  DEV="${cards[0]}"
fi
[ -b "$DEV" ] || die "$DEV is not a block device"

log "card: $DEV  $(blkid -o export "$DEV" | grep -E '^(LABEL|UUID|TYPE)=' | tr '\n' ' ')"
CARD_UUID=$(blkid -s UUID -o value "$DEV")
if [ "$(findmnt -rno SOURCE "$MNT" || true)" = "$DEV" ]; then
  log "already mounted at $MNT"
else
  findmnt -rn "$MNT" >/dev/null && die "$MNT is in use by another device"
  mkdir -p "$MNT"
  # iocharset=utf8: file names like "Sommer på Ærø.jpg" read correctly on FAT32 too.
  mount -o ro,nosuid,nodev,noexec,iocharset=utf8 "$DEV" "$MNT"
  WE_MOUNTED=1
  log "mounted read-only at $MNT"
fi
findmnt -rno OPTIONS "$MNT" | grep -qE '(^|,)ro(,|$)' || die "$MNT is not read-only"

# --- 2. List the photo and video files, with their dates ---------------------
ext_args=()
for e in $EXTS; do ext_args+=(-ext "$e"); done
# One exiftool pass: path, size in bytes, and the three possible dates.
exiftool -q -q -r -T -i HIDDEN "${ext_args[@]}" -d '%Y-%m-%d' \
  -FilePath -FileSize# -DateTimeOriginal -CreateDate -FileModifyDate "$MNT" \
  | sort > "$WORK/files.tsv" || true
if [ ! -s "$WORK/files.tsv" ]; then
  # e.g. a card that was already offloaded: nothing to do, so safe to remove.
  log "no photo or video files on the card: nothing to do"
  DONE_OK=1
  led "done"
  exit 0
fi

# Size and time stamp of every file, checked again just before deleting.
snapshot() { cut -f1 "$WORK/files.tsv" | xargs -d '\n' stat -c $'%s %Y\t%n' -- 2>&1 || true; }
snapshot > "$WORK/stat.before"

find "$MNT" -type f ! -path '*/.*' | sort > "$WORK/all.txt"
cut -f1 "$WORK/files.tsv" | sort | comm -23 "$WORK/all.txt" - > "$WORK/other.txt"
log "found $(wc -l < "$WORK/files.tsv") photo/video files, $(wc -l < "$WORK/other.txt") other files (not uploaded)"
while read -r f; do log "  not uploaded (not a photo/video type): ${f#"$MNT"/}"; done < "$WORK/other.txt"

# --- 3. Reach Dropbox -----------------------------------------------------------
# Retry for about 2 minutes, e.g. while the router restarts.
free_bytes=""
for try in 1 2 3 4 5 6; do
  free_bytes=$(rclone about "$REMOTE" --json --retries 1 2>/dev/null \
    | sed -n 's/.*"free": *\([0-9]*\).*/\1/p') || true
  [ -n "$free_bytes" ] && break
  log "can't reach Dropbox (try $try of 6)"
  [ "$try" -lt 6 ] && sleep 20
done
[ -n "$free_bytes" ] || die "can't reach Dropbox: no internet, or not connected (sudo sd-uploader setup)? Nothing was uploaded or deleted."
card_bytes=$(awk -F'\t' '{ s += $2 } END { print s + 0 }' "$WORK/files.tsv")
log "card files: $(size "$card_bytes"), Dropbox free: $(size "$free_bytes")"

# --- 4. Hash every file (Dropbox's content hash, computed on the Pi) ----------
log "hashing files on the card..."
cut -f1 "$WORK/files.tsv" | sed "s#^$MNT/##" > "$WORK/rel.txt"
rclone hashsum dropbox "$MNT" --files-from "$WORK/rel.txt" > "$WORK/hashes.txt"
declare -A HASH
while read -r h rel; do HASH["$rel"]=$h; done < "$WORK/hashes.txt"

# --- 5. Plan: date folder, skip identical files, rename clashes ----------------
valid_date() { [[ $1 =~ ^(199[0-9]|20[0-9]{2})-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]; }
folder_for() {      # 2026-07-14 -> FOLDER_FORMAT with %Y %m %d filled in
  local f=${FOLDER_FORMAT//%Y/${1:0:4}}
  f=${f//%m/${1:5:2}}
  echo "${f//%d/${1:8:2}}"
}

declare -A LOADED   # folders already listed from Dropbox
declare -A TAKEN    # "folder/name" -> hash   (in Dropbox, or planned)
declare -A SAME     # "folder|hash" -> name   (identical content in that folder)
load_folder() {     # read what is already in a Dropbox folder
  local dir=$1 name h
  [ -n "${LOADED[$dir]:-}" ] && return
  LOADED[$dir]=1
  while IFS=$'\t' read -r name h; do
    TAKEN["$dir/$name"]=$h
    SAME["$dir|$h"]=$name
  done < <(rclone lsf --files-only --hash dropbox --format ph --separator $'\t' "$(remote_path "$dir")" 2>/dev/null || true)
}

mkdir -p "$WORK/plan"
: > "$MANIFEST"
n_up=0 n_skip=0 n_ren=0 n_fallback=0 up_bytes=0
while IFS=$'\t' read -r path size dto cdate mdate; do
  rel=${path#"$MNT"/}
  h=${HASH[$rel]:-}
  [ -n "$h" ] || die "no hash for $rel"

  if valid_date "$dto"; then date=$dto; src=exif
  elif valid_date "$cdate"; then date=$cdate; src=created
  elif valid_date "$mdate"; then date=$mdate; src=file-date; n_fallback=$((n_fallback + 1))
  else die "no usable date for $rel"
  fi
  dir=$(folder_for "$date")
  load_folder "$dir"

  base=${rel##*/}
  if [ -n "${SAME[$dir|$h]:-}" ]; then
    action=skip; name=${SAME[$dir|$h]}; n_skip=$((n_skip + 1))
  else
    name=$base; i=2
    while [ -n "${TAKEN[$dir/$name]:-}" ]; do
      if [[ $base == *.* ]]; then name="${base%.*}_$i.${base##*.}"; else name="${base}_$i"; fi
      i=$((i + 1))
    done
    if [ "$name" = "$base" ]; then action=upload; else action=rename; n_ren=$((n_ren + 1)); fi
    n_up=$((n_up + 1)); up_bytes=$((up_bytes + size))
    TAKEN["$dir/$name"]=$h
    SAME["$dir|$h"]=$name
    mkdir -p "$WORK/plan/$dir"
    ln -s "$path" "$WORK/plan/$dir/$name"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$action" "$rel" "$dir/$name" "$h" "$src" >> "$MANIFEST"
done < "$WORK/files.tsv"

log "plan: $n_up to upload ($(size "$up_bytes"), $n_ren renamed), $n_skip already in Dropbox"
[ "$n_fallback" -eq 0 ] || log "note: $n_fallback file(s) had no shooting date; used the file's date"
awk -F'\t' '{ printf "  %-7s %-28s -> %s\n", $1, $2, $3 }' "$MANIFEST"

# Room for what actually has to go up (skipped files need no space). All or nothing.
[ "$up_bytes" -lt $((free_bytes - MIN_FREE)) ] \
  || die "Dropbox is full: need $(size "$up_bytes"), only $(size "$free_bytes") free (keeping $(size "$MIN_FREE") spare). Nothing was uploaded or deleted."

if [ "$DRY_RUN" = 1 ]; then
  log "dry run: nothing uploaded or deleted. Manifest: $MANIFEST"
  exit 0
fi

# --- 6. Upload ----------------------------------------------------------------
if [ "$n_up" -gt 0 ]; then
  log "uploading..."
  # --copy-links follows the plan's symlinks to the card; --immutable refuses to
  # change any file that already exists in Dropbox (never overwrite).
  # rclone's exit code goes via a file, so the progress filter can't hide it.
  { rclone copy --copy-links --immutable --transfers "$TRANSFERS" \
      --stats 30s --stats-one-line -v "$WORK/plan" "$REMOTE" 2>&1
    echo $? > "$WORK/upload.rc"
  } | grep -vE 'Copied \(new\)$|Committing uploads' || true
  rc=$(cat "$WORK/upload.rc")
  [ "$rc" -eq 0 ] || die "upload failed (rclone exit $rc). Nothing was deleted."
fi

# --- 7. Verify every file against Dropbox --------------------------------------
log "verifying..."
declare -A REMOTE_HASH
while read -r dir; do
  while IFS=$'\t' read -r name h; do REMOTE_HASH["$dir/$name"]=$h; done \
    < <(rclone lsf --files-only --hash dropbox --format ph --separator $'\t' "$(remote_path "$dir")")
done < <(cut -f3 "$MANIFEST" | xargs -d '\n' -n1 dirname | sort -u)
fails=0
while IFS=$'\t' read -r action rel dest h src; do
  if [ "${REMOTE_HASH[$dest]:-}" != "$h" ]; then
    log "  FAIL: $rel -> $dest (Dropbox has ${REMOTE_HASH[$dest]:-nothing})"
    fails=$((fails + 1))
  fi
done < "$MANIFEST"

total=$(wc -l < "$MANIFEST")
if [ "$fails" -ne 0 ]; then
  log "FAIL: $fails of $total files did not verify. The card is untouched."
  exit 1
fi
log "PASS: all $total files are in Dropbox with matching hashes"
log "manifest: $MANIFEST"

# --- 8. Delete the verified files from the card -------------------------------
# Only the files in this run's manifest, each one just verified in Dropbox.
# Folders and files that aren't photos/videos stay on the card.
if [ ! -b "$DEV" ]; then
  # Everything is safe in Dropbox, but the card is already out: light off.
  log "the card was already pulled out; all files were verified anyway. Nothing was deleted."
  DONE_OK=1
  led idle
  exit 0
fi
if [ "$DELETE" = off ]; then
  log "delete: off (DELETE=off in $CONF). The card is untouched."
else
  # Same card, and every file exactly as it was when it was hashed?
  [ "$(blkid -s UUID -o value "$DEV")" = "$CARD_UUID" ] \
    || die "the card in the reader is not the one that was uploaded. Nothing was deleted."
  snapshot > "$WORK/stat.now"
  if ! cmp -s "$WORK/stat.before" "$WORK/stat.now"; then
    diff "$WORK/stat.before" "$WORK/stat.now" | sed -n 's/^> /  changed: /p' | head -20
    die "files changed on the card since they were hashed. Nothing was deleted."
  fi
  while IFS=$'\t' read -r action rel dest h src; do
    case "$rel" in /*|../*|*/../*|"") die "bad path in manifest: '$rel'. Nothing was deleted." ;; esac
  done < "$MANIFEST"

  if [ "$DELETE" = dry-run ]; then
    log "delete (dry run): would delete these $total files ($(size "$card_bytes")) from the card:"
    cut -f2 "$MANIFEST" | sed 's/^/  would delete: /'
    log "nothing was deleted. To delete for real: set DELETE=on in $CONF"
  else
    log "deleting $total verified files ($(size "$card_bytes")) from the card..."
    DELETING=1
    mount -o remount,rw "$MNT"
    : > "$DELETED"
    while IFS=$'\t' read -r action rel dest h src; do
      rm -- "$MNT/$rel"
      echo "$rel" >> "$DELETED"
    done < "$MANIFEST"
    sync
    mount -o remount,ro "$MNT"
    DELETING=0
    log "deleted $(wc -l < "$DELETED") files; folders and other files kept. List: $DELETED"
  fi
fi
# Green only now: everything is uploaded, verified, deleted and written to the card.
DONE_OK=1
led "done"
