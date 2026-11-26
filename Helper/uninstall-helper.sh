#!/bin/sh
# Removes the FanCurve helper. Fans go back to macOS control when it stops. Runs as root.
LABEL="com.fancurve.helper"
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL" /var/run/fancurve.sock
