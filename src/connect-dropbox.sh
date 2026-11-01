#!/usr/bin/env bash
# Connect sd-uploader to Dropbox. The login is stored in
# /var/lib/sd-uploader/rclone.conf (root only). Run via `sudo sd-uploader connect`.
set -euo pipefail
CONF="${SD_UPLOADER_CONF:-/etc/sd-uploader/sd-uploader.conf}"
export RCLONE_CONFIG="${RCLONE_CONFIG:-/var/lib/sd-uploader/rclone.conf}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { echo "Error: $*" >&2; exit 1; }

# set_conf KEY VALUE: change KEY=... in the config file, or add it.
set_conf() {
  if grep -q "^[[:space:]]*${1}[[:space:]]*=" "$CONF"; then
    sed -i "s|^[[:space:]]*${1}[[:space:]]*=.*|$1=$2|" "$CONF"
  else
    echo "$1=$2" >> "$CONF"
  fi
}

install -d -m 700 "$(dirname "$RCLONE_CONFIG")"

bold "Connect to Dropbox"
cat <<'EOF'

How should the Pi get into your Dropbox?

  1) App folder (recommended)
     The Pi can only see one folder, Dropbox/Apps/<your app name>/, never the
     rest of your Dropbox. Needs a free Dropbox "app" (about 5 minutes, once).

  2) Quick
     Uses rclone's own Dropbox app. No extra setup, but the Pi gets access to
     your whole Dropbox. Photos go to Dropbox/SD Uploader/.

EOF
read -rp "Choose 1 or 2 [1]: " choice
choice=${choice:-1}
[[ $choice =~ ^[12]$ ]] || die "choose 1 or 2"

KEY="" SECRET=""
if [ "$choice" = 1 ]; then
  cat <<'EOF'

Create the Dropbox app (on any computer):
  1. Open https://www.dropbox.com/developers/apps and click "Create app"
  2. Choose "Scoped access", then "App folder", and give it a name
     (e.g. "SD Uploader"). Photos will go to Dropbox/Apps/<that name>/
  3. Permissions tab: tick files.metadata.read, files.metadata.write,
     files.content.read and files.content.write, then click "Submit"
  4. Settings tab: under "Redirect URIs" add  http://localhost:53682/  (with the
     slash at the end) and click "Add"
  5. Copy the "App key" and "App secret" from the Settings tab

EOF
  read -rp "App key: " KEY
  read -rsp "App secret (hidden): " SECRET; echo
  [ -n "$KEY" ] && [ -n "$SECRET" ] || die "the app key and secret are both needed"
  authorize="rclone authorize \"dropbox\" \"$KEY\" \"$SECRET\""
else
  authorize='rclone authorize "dropbox"'
fi

cat <<EOF

Now log in. The Pi has no web browser, so this step runs on your computer:
  1. Install rclone there if needed: https://rclone.org/install/
  2. Run this in a terminal on that computer:

       $authorize

  3. A browser opens: log in to Dropbox and click "Allow"
  4. The terminal prints a long line that starts with {"access_token":
     Copy that whole line {...} and paste it here.

EOF
read -rsp "Paste the token (hidden), then press Enter: " TOKEN; echo
TOKEN=$(printf '%s' "$TOKEN" | tr -d '\r\n' | grep -o '{.*}' || true)
[ -n "$TOKEN" ] || die "that didn't look like a token: it should start with { and end with }"

rclone config delete dropbox >/dev/null 2>&1 || true
if [ -n "$KEY" ]; then
  rclone config create dropbox dropbox client_id "$KEY" client_secret "$SECRET" \
    token "$TOKEN" --non-interactive >/dev/null
else
  rclone config create dropbox dropbox token "$TOKEN" --non-interactive >/dev/null
fi
chmod 600 "$RCLONE_CONFIG"
unset KEY SECRET TOKEN

# Full access: keep the photos in their own folder instead of the Dropbox root.
if [ "$choice" = 2 ]; then
  set_conf REMOTE '"dropbox:SD Uploader"'
else
  set_conf REMOTE 'dropbox:'
fi

echo
echo "Testing the connection..."
if free=$(rclone about dropbox: --json 2>/dev/null | sed -n 's/.*"free": *\([0-9]*\).*/\1/p') && [ -n "$free" ]; then
  bold "Connected to Dropbox: $(numfmt --to=iec --suffix=B "$free") free."
else
  die "connected, but Dropbox didn't answer. Check the internet connection and try: sudo sd-uploader connect"
fi
