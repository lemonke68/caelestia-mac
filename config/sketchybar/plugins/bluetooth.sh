#!/bin/bash
# Bluetooth icon: off / on / a device connected. Click opens the rice-shell popout.

source "$HOME/.config/sketchybar/colors.sh"
BLUEUTIL=/opt/homebrew/bin/blueutil

if [ "$($BLUEUTIL -p)" = "0" ]; then
  sketchybar --set "$NAME" icon="$(glyph F00B2)" icon.color=$TEXT_DIM
elif [ "$($BLUEUTIL --connected | wc -l | tr -d ' ')" -gt 0 ]; then
  sketchybar --set "$NAME" icon="$(glyph F00B1)" icon.color=$ACCENT
else
  sketchybar --set "$NAME" icon="$(glyph F00AF)" icon.color=$TEXT
fi
