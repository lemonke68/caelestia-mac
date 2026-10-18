#!/bin/sh
# Build rice-shell into ../bin and (re)start its launchd agent.
set -e
cd "$(dirname "$0")"

# Built as an .app bundle: macOS only grants Location (Wi-Fi network names, weather) and
# audio capture (visualiser) to apps. bin/rice-shell stays the CLI, as a symlink.
app=../bin/RiceShell.app
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.4" -o "$app/Contents/MacOS/rice-shell" Sources/*.swift ../native/common/*.swift
# Stable signature: TCC grants (Accessibility, Bluetooth, …) survive rebuilds. Same cert as yabai.
. ../lib/sign.sh
rice_sign "$app"
ln -sfn RiceShell.app/Contents/MacOS/rice-shell ../bin/rice-shell

label=com.mac-rice.shell
plist="$HOME/Library/LaunchAgents/$label.plist"
bin="$(cd ../bin && pwd)/RiceShell.app/Contents/MacOS/rice-shell"

cat > "$plist" <<PLIST
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
    <string>/tmp/rice-shell.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
while launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; do sleep 0.2; done
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "built rice-shell; agent restarted"
