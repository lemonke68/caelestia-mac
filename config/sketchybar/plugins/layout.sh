#!/bin/bash
# Keyboard layout: EN / RU (caelestia shows Hypr.kbLayout in the status icons)

source "$HOME/.config/sketchybar/colors.sh"

name=$(defaults read ~/Library/Preferences/com.apple.HIToolbox.plist AppleSelectedInputSources 2>/dev/null \
  | grep -E '"KeyboardLayout Name"|"Input Mode"' | head -1)
case "$name" in
  *Russian*) label="RU" ;;
  *) label="EN" ;;
esac
sketchybar --set "$NAME" label="$label"
