#!/bin/bash

source "$HOME/.config/sketchybar/colors.sh"

batt=$(pmset -g batt)
percent=$(grep -Eo '[0-9]+%' <<<"$batt" | tr -d '%')
# Desktop Macs (mini, Studio, iMac) have no battery: hide the item
if [ -z "$percent" ]; then
  sketchybar --set "$NAME" drawing=off
  exit 0
fi

# nf-md-battery_10 … battery (U+F007A … U+F0079)
case $percent in
  100|9[5-9]) code=F0079 ;;
  9[0-4]|8[5-9]) code=F0082 ;;
  8[0-4]|7[5-9]) code=F0081 ;;
  7[0-4]|6[5-9]) code=F0080 ;;
  6[0-4]|5[5-9]) code=F007F ;;
  5[0-4]|4[5-9]) code=F007E ;;
  4[0-4]|3[5-9]) code=F007D ;;
  3[0-4]|2[5-9]) code=F007C ;;
  2[0-4]|1[5-9]) code=F007B ;;
  *) code=F007A ;;
esac

color=$TEXT
if grep -q 'AC Power' <<<"$batt"; then
  code=F0084
  color=$ACCENT
elif [ "$percent" -le 15 ]; then
  color=$RED
fi

sketchybar --set "$NAME" icon="$(glyph $code)" icon.color=$color label="${percent}%"
