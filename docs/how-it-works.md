# How it works

## The pieces

| Piece | Job |
|---|---|
| `udev/99-sd-uploader.rules` | When a FAT/exFAT partition appears on a USB drive, starts `sd-uploader@<partition>.service`. When it disappears, starts `sd-uploader-removed@<partition>.service`. |
| `sd-uploader@.service` → `offload.sh` | Does the work below. Runs as root in its own mount namespace with systemd hardening (`ProtectSystem`, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`). |
| `sd-uploader-removed@.service` → `card-removed.sh` | Card pulled out mid-run: stops the upload at once and shows red. Card pulled out after green: turns the light off. |
| `sd-uploader-status.service` → `statusd.py` | Watches `/run/sd-uploader/state` (`idle`, `uploading`, `done`, `error`) and drives the LEDs. |
| `sd-uploader` | The command people use: `setup`, `status`, `logs`, `run`, `test-leds`, `connect`, `led`. |

Card readers usually show each empty slot as a 0-byte drive, so the trigger is the card's **partition** appearing, not the reader. The kernel checks the reader for a card every couple of seconds; no polling software is needed.

## One run, step by step

1. **Find and mount the card, read-only** (`ro,nosuid,nodev,noexec`, UTF-8 file names), at `/mnt/sd-uploader`.
2. **List photos and videos** in one ExifTool pass: path, size, and three dates (`DateTimeOriginal`, `CreateDate`, file modified date). Hidden files (like macOS `._` files) are skipped. Anything that isn't a photo or video type is named in the log and left alone.
3. **Reach Dropbox** and read the free space. Retries for about 2 minutes (a router restarting), then gives up with red.
4. **Hash every file on the Pi** with Dropbox's own [content hash](https://www.dropbox.com/developers/reference/content-hash), via `rclone hashsum dropbox`.
5. **Plan** a Dropbox path for each file:
   - the folder comes from the first valid date: EXIF original date → creation date (videos) → file date, formatted with `FOLDER_FORMAT`
   - **skip** if that folder already holds a file with the same hash (also catches two identical files on one card)
   - **rename** to `name_2.ext`, `_3`, … if the name is taken by different content
   - **upload** otherwise

   The plan is written as a manifest (`action, card path, Dropbox path, hash, date source`) and built as a folder of symlinks, so everything goes up in one rclone batch.
6. **Check space.** What still has to go up must fit, with `MIN_FREE_GB` to spare. All or nothing: a card is never left half uploaded because Dropbox filled up.
7. **Upload** with `rclone copy --immutable`, which refuses to change any file that already exists in Dropbox.
8. **Verify.** List each Dropbox folder with hashes and compare **every** manifest line, uploaded and skipped alike. One mismatch: FAIL, red, card untouched.
9. **Delete** (only after PASS, depending on `DELETE`):
   - check the card in the reader is the **same card** (filesystem UUID)
   - check **every file still has the size and modification time** it had when it was hashed
   - check no manifest path leads outside the card
   - remount read-write, delete the manifest's files one by one (each recorded in `run-…deleted.txt`), `sync`, remount read-only
10. **Green.** Only now, so pulling the card on green is always safe.

## What happens when things go wrong

| Situation | Result |
|---|---|
| No internet / Dropbox unreachable | Red after ~2 minutes. Nothing uploaded or deleted. |
| Internet drops mid-upload | Short rclone timeouts: red within minutes instead of hanging. Partial uploads never show up in Dropbox. |
| Dropbox full | Red before anything is uploaded. |
| Card pulled out while working | Red within a fraction of a second. Reinsert: already-uploaded files are skipped. |
| Card pulled out while deleting (takes seconds) | Red. Everything was verified first, so nothing is lost; the rest stay on the card. |
| Power cut | The card is still in at the next boot, so the run starts again by itself. The journal survives reboots. |
| Two cards at once | The second card is turned away ("another upload is already running" in the log) without changing the light. Reinsert it once the first is green. |

## Design decisions

- **Hash on the Pi, compare with Dropbox's hash.** Verification needs no extra download: Dropbox reports the content hash of what it stored, and the Pi computed the same hash from the card. Each file is read from the card twice (hash, upload), not three times.
- **Delete by list, not by folder.** "Everything in DCIM" would also delete files the uploader skipped or didn't recognise. The manifest is the only thing that decides.
- **Folders stay.** Cameras expect their `DCIM/100XXXXX` folders. To wipe a card completely, format it in the camera.
- **Dry run first.** A fresh install never deletes until you set `DELETE=on`.
- **App folder access.** With a Dropbox App-folder app, a stolen Pi can't read or delete anything else in your Dropbox. Disconnect it any time in Dropbox → Settings → Connected apps.
- **Root, but contained.** Mounting needs root. The service runs in its own mount namespace with a read-only `/usr`, `/boot` and `/etc`, no access to `/home`, and no privilege escalation.
- **No local copy.** The verified Dropbox copy plus Dropbox's own version history is the backup. The Pi's small system card isn't a safe place for photos.

## Files on the Pi

| Path | What |
|---|---|
| `/etc/sd-uploader/sd-uploader.conf` | Settings |
| `/var/lib/sd-uploader/rclone.conf` | Dropbox login (root only) |
| `/var/log/sd-uploader/run-*.log` | One log per card, plus `.manifest.tsv` and `.deleted.txt`; deleted after 180 days |
| `/run/sd-uploader/state` | Current light state |
| `/usr/local/bin/sd-uploader`, `/usr/local/lib/sd-uploader/` | The program |
| `/etc/systemd/journald.conf.d/zz-sd-uploader.conf` | System log kept across reboots, capped at 100 MB |
