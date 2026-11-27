#!/bin/sh
# Installs (or updates) the FanCurve helper as a launchd daemon. Runs as root.
# Usage: install-helper.sh <path-to-fancurved> <owner-uid>
set -eu
SRC="$1"
OWNER="$2"
LABEL="com.fancurve.helper"
DST="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

case "$OWNER" in ''|*[!0-9]*) echo "bad uid" >&2; exit 1 ;; esac
[ -f "$SRC" ] || { echo "helper not found: $SRC" >&2; exit 1; }

launchctl bootout "system/$LABEL" 2>/dev/null || true
mkdir -p /Library/PrivilegedHelperTools
cp "$SRC" "$DST.new"
chown root:wheel "$DST.new"
chmod 755 "$DST.new"
mv -f "$DST.new" "$DST"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DST</string><string>--owner</string><string>$OWNER</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>/var/log/fancurve-helper.log</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
launchctl bootstrap system "$PLIST"
