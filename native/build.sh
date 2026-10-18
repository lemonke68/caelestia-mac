#!/bin/sh
# Build the native helpers into ../bin and (re)start the wallpaper launchd agent.
#   rice-wallpaper  common/ + wallpaper/   wallpaper daemon
#   rice-picker     common/ + picker/      coverflow wallpaper picker (alt + I)
set -e
cd "$(dirname "$0")"

swiftc() { xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.4" "$@"; }

swiftc -o ../bin/rice-wallpaper common/*.swift wallpaper/main.swift
swiftc -o ../bin/rice-picker common/*.swift picker/main.swift
. ../lib/sign.sh
rice_sign ../bin/rice-wallpaper ../bin/rice-picker

label=com.mac-rice.wallpaper
plist="$HOME/Library/LaunchAgents/$label.plist"
bin="$(cd ../bin && pwd)/rice-wallpaper"

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$bin</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>/tmp/rice-wallpaper.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
# bootout is asynchronous; wait until the old agent is gone
while launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; do sleep 0.2; done
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "built rice-wallpaper, rice-picker; wallpaper agent restarted"
