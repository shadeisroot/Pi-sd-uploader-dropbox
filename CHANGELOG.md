# Changelog

## Unreleased
- Fix: after a power cut, `sd-uploader status` and `logs` could show an older run as the last one (the clock is behind until it syncs). They now pick the most recently written log, and a run never reuses an existing log name
- Docs: "Keeping it up to date": automatic security updates for the system, deliberate updates for SD Uploader

## 1.0.0 – 2026-11-01
First public release.

- Upload a camera card to Dropbox when it's inserted, sorted into date folders from each file's EXIF date
- Verify every file by its Dropbox content hash before calling a card done
- Delete exactly the verified files from the card (`DELETE=dry-run` by default)
- Never overwrites: identical files are skipped, name clashes get `_2`, `_3`, …
- Status light: three GPIO LEDs, the Pi's onboard LED, or none
- `sd-uploader` command: `setup`, `status`, `logs`, `run`, `test-leds`
- Guided Dropbox connection, App-folder access recommended
- Handles a full Dropbox, no internet, a card pulled out mid-run, and power cuts
- End-to-end test on FAT32 and exFAT card images, run in CI
