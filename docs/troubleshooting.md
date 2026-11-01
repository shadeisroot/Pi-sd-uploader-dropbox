# Troubleshooting

Start with:

```bash
sudo sd-uploader status     # settings, light, Dropbox, card, last result
sudo sd-uploader logs       # the last card's full log
sudo sd-uploader logs -f    # follow live while you insert a card
```

Older runs are in `/var/log/sd-uploader/`. The system log keeps earlier boots too: `journalctl -b -1 -u 'sd-uploader*'`.

## Nothing happens when a card goes in

- **Is the reader seen?** `lsblk -o NAME,SIZE,FSTYPE,TRAN`: the card should appear as e.g. `sda1` with `vfat` or `exfat` and `usb`. If you see `sda` with `0B` and no `sda1`, the card isn't detected: take it out and push it fully back in.
- **Is the card's format supported?** Only FAT32 (`vfat`) and exFAT trigger an upload. Cards formatted by a camera are one of these.
- **Did the service start?** `systemctl list-units 'sd-uploader@*'` and `journalctl -u 'sd-uploader@*' -n 50`.
- **Run it by hand** to see every step: `sudo sd-uploader run --dry-run`.

## Red light

The log's last `ERROR:` line says why. Nothing is deleted on an error.

| Message | Meaning and fix |
|---|---|
| `can't reach Dropbox` | No internet, or Dropbox isn't connected. Check the network and `sudo sd-uploader status`. Reinsert the card. |
| `Dropbox is full` | Free up space (or lower `MIN_FREE_GB`), then reinsert the card. |
| `the card was pulled out before the end` | Reinsert it; finished files are skipped. |
| `upload failed (rclone exit …)` | Usually the network dropped. The lines above say more. Reinsert to resume. |
| `files changed on the card since they were hashed` | Something wrote to the card during the run. Nothing was deleted; reinsert to start fresh. |
| `the card in the reader is not the one that was uploaded` | Cards were swapped during the run. Nothing was deleted. |
| `FAIL: N of M files did not verify` | Dropbox doesn't hold an exact copy. The `FAIL:` lines list them. Nothing was deleted; reinsert to retry. |
| `no usable date for …` | A photo or video with no valid date at all. Check that file's dates with `exiftool`. |

## Dropbox

- **Connection lost / token revoked:** `sudo sd-uploader connect`.
- **Error in the browser when running `rclone authorize`:** for the App-folder setup, check the app's **Redirect URI** is exactly `http://localhost:53682/` (with the slash), that you clicked **Submit** on the Permissions tab, and that the key and secret aren't swapped.
- **Where are my photos?** App folder: `Dropbox/Apps/<your app name>/`. Quick setup: `Dropbox/SD Uploader/`.
- **Sharing with family:** App folders can't be shared as a folder with other users, but you can create a view-only **share link** to the app folder (or one year inside it). New uploads show up in the same link.

## The light

- **No light at all:** `sudo sd-uploader test-leds`. If the service isn't running, `journalctl -u sd-uploader-status`.
- **One colour missing:** that LED is the wrong way round, on the wrong pin, or its plug came off (cases often push them off). Shut down before moving wires.
- **Wrong colour for the state:** two wires are swapped. Compare with the [wiring table](hardware.md#wiring-the-leds).

## Times and dates

- **Photos in the wrong month:** the folder comes from the date **the camera** wrote. Check the camera's clock.
- **Log file names have odd times right after boot:** the Pi has no clock battery and gets the time from the internet a few seconds after boot. Photo folders aren't affected; they come from the photos.

## Starting over

```bash
sudo ./uninstall.sh --purge && sudo ./install.sh && sudo sd-uploader setup
```
