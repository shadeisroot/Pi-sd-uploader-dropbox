#!/usr/bin/env bash
# End-to-end test: a fake camera card (a FAT32 or exFAT image on a loop device)
# is uploaded to a local folder standing in for Dropbox, verified, and cleared.
# Uses the real offload.sh. Needs root (loop device, mount), exiftool, rclone,
# mkfs.vfat and mkfs.exfat. Touches nothing outside a temporary folder.
#
#   sudo tests/e2e.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OFFLOAD="$ROOT/src/offload.sh"
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0" >&2; exit 2; }

# A 1x1 pixel JPEG. Each test photo gets its own EXIF date, so its own content.
JPEG='/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA='

T=$(mktemp -d)
LOOP=""
cleanup() {
  mountpoint -q "$T/setup" && umount "$T/setup"
  mountpoint -q "$T/mnt" && umount "$T/mnt"
  [ -n "$LOOP" ] && losetup -d "$LOOP"
  rm -rf "$T"
}
trap cleanup EXIT

export SD_UPLOADER_CONF="$T/test.conf" SD_UPLOADER_RUN="$T/run" \
  SD_UPLOADER_LOGS="$T/logs" SD_UPLOADER_MNT="$T/mnt" \
  RCLONE_CONFIG="$T/rclone.conf" REMOTE="$T/dropbox"
printf 'MIN_FREE_GB=0\nLED_BACKEND=none\n' > "$SD_UPLOADER_CONF"
: > "$RCLONE_CONFIG"   # an empty rclone config: the test only uses local folders

FAILS=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { local what=$1; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }
last_log() { local logs=("$SD_UPLOADER_LOGS"/run-*.log); echo "${logs[-1]}"; }
log_has() { grep -q -- "$1" "$(last_log)"; }
state_is() { [ "$(cat "$SD_UPLOADER_RUN/state" 2>/dev/null)" = "$1" ]; }
remote_has() { [ -f "$REMOTE/$1" ]; }
card_files() { mount -o ro,iocharset=utf8 "$LOOP" "$T/setup"; (cd "$T/setup" && find . -type f | sort); umount "$T/setup"; }
remote_hashes() { rclone lsf -R --files-only --hash dropbox --format hp "$REMOTE" | sort; }
# offload ENV... -- ARGS: run the uploader with extra settings, keep its exit code.
offload() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  rc=0
  env "${envs[@]}" "$OFFLOAD" "$@" "$LOOP" > "$T/out.txt" 2>&1 || rc=$?
}

make_card() {   # make_card vfat|exfat: a fresh card image with test files
  rm -rf "$REMOTE" "$SD_UPLOADER_LOGS" "$SD_UPLOADER_RUN" "$T/card.img"
  truncate -s 64M "$T/card.img"
  if [ "$1" = vfat ]; then mkfs.vfat -n CAMERA "$T/card.img" >/dev/null
  else mkfs.exfat -L CAMERA "$T/card.img" >/dev/null; fi
  [ -n "$LOOP" ] && losetup -d "$LOOP"
  LOOP=$(losetup -f --show "$T/card.img")
  mkdir -p "$T/setup" "$T/mnt"
  mount -o iocharset=utf8 "$LOOP" "$T/setup"
  local c="$T/setup/DCIM"
  mkdir -p "$c/100CANON" "$c/101CANON" "$T/setup/MISC"
  photo() { base64 -d <<< "$JPEG" > "$c/$1"; exiftool -q -overwrite_original -DateTimeOriginal="$2" "$c/$1"; }
  photo 100CANON/IMG_0001.JPG "2024:05:17 10:00:00"
  photo 100CANON/IMG_0002.JPG "2024:05:18 11:00:00"
  photo 100CANON/IMG_0003.JPG "2023:12:31 23:59:00"
  photo "100CANON/Sommer på Ærø (1).JPG" "2024:05:17 12:00:00"
  photo "100CANON/Dad's pic; final.jpeg" "2024:05:17 13:00:00"
  cp "$c/100CANON/IMG_0001.JPG" "$c/101CANON/IMG_0001.JPG"   # identical copy
  printf 'no metadata in here' > "$c/100CANON/MVI_0004.MOV"     # no date: uses the file's date
  touch -d '2022-02-03 12:00' "$c/100CANON/MVI_0004.MOV"
  echo 'camera notes' > "$c/100CANON/README.TXT"                 # not a photo: never touched
  echo '<x/>' > "$T/setup/MISC/info.xml"
  echo 'mac junk' > "$c/100CANON/._IMG_0001.JPG"                 # hidden: ignored
  umount "$T/setup"
  # Already in "Dropbox": a different photo with the same name as IMG_0002.
  mkdir -p "$REMOTE/2024/05"
  echo 'someone else' > "$REMOTE/2024/05/IMG_0002.JPG"
}

for fs in vfat exfat; do
  printf '\n\033[1m%s card\033[0m\n' "$fs"
  make_card "$fs"
  before=$(card_files)

  offload MIN_FREE_GB=999999 --
  check "Dropbox full: fails" [ "$rc" = 1 ]
  check "Dropbox full: says so" log_has "Dropbox is full"
  check "Dropbox full: uploads nothing" [ "$(find "$REMOTE" -type f | wc -l)" = 1 ]
  check "Dropbox full: light red" state_is error

  offload -- --dry-run
  check "--dry-run: passes" [ "$rc" = 0 ]
  check "--dry-run: uploads nothing" [ "$(find "$REMOTE" -type f | wc -l)" = 1 ]
  check "--dry-run: leaves the light alone" state_is error

  offload DELETE=dry-run --
  check "upload: PASS" log_has "PASS: all 7 files"
  check "upload: sorted by shooting date" remote_has 2024/05/IMG_0001.JPG
  check "upload: other year" remote_has 2023/12/IMG_0003.JPG
  check "upload: awkward names" remote_has "2024/05/Sommer på Ærø (1).JPG"
  check "upload: no date -> file date" remote_has 2022/02/MVI_0004.MOV
  check "upload: name clash renamed" remote_has 2024/05/IMG_0002_2.JPG
  check "upload: never overwrites" grep -qx 'someone else' "$REMOTE/2024/05/IMG_0002.JPG"
  check "upload: identical copy uploaded once" [ "$(find "$REMOTE" -name 'IMG_0001*' | wc -l)" = 1 ]
  check "upload: non-photos not uploaded" [ -z "$(find "$REMOTE" -name 'README*' -o -name 'info*' -o -name '._*')" ]
  check "dry-run delete: lists 7 files" log_has "would delete these 7 files"
  check "dry-run delete: card unchanged" [ "$(card_files)" = "$before" ]
  check "light green" state_is "done"

  offload DELETE=dry-run --
  check "second run: nothing to upload" log_has "plan: 0 to upload"

  hashes=$(remote_hashes)
  offload DELETE=on --
  check "delete: PASS first" log_has "PASS: all 7 files"
  check "delete: deleted 7" log_has "deleted 7 files"
  after=$(card_files)
  check "delete: photos gone" [ -z "$(grep -iE '\.(jpe?g|mov)$' <<< "$after" | grep -v '/\._')" ]
  check "delete: other files kept" grep -q 'README.TXT' <<< "$after"
  check "delete: hidden files kept" grep -q '\._IMG_0001.JPG' <<< "$after"
  check "delete: Dropbox unchanged" [ "$(remote_hashes)" = "$hashes" ]
  check "delete: light green" state_is "done"

  offload DELETE=on --
  check "empty card: nothing to do" log_has "no photo or video files"
  check "empty card: passes" [ "$rc" = 0 ]
done

echo
if [ "$FAILS" -eq 0 ]; then printf '\033[32mAll tests passed.\033[0m\n'
else printf '\033[31m%s test(s) failed.\033[0m Last output:\n' "$FAILS"; cat "$T/out.txt"; exit 1; fi
