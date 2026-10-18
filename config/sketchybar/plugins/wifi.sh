#!/bin/bash

source "$HOME/.config/sketchybar/colors.sh"

if ipconfig getifaddr en0 >/dev/null 2>&1; then
  sketchybar --set "$NAME" icon="$(glyph F05A9)" icon.color=$TEXT
else
  sketchybar --set "$NAME" icon="$(glyph F05AA)" icon.color=$TEXT_DIM
fi
