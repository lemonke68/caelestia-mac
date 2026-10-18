#!/bin/bash

source "$HOME/.config/sketchybar/colors.sh"

if [ "$SENDER" = "volume_change" ]; then
  volume="$INFO"
else
  volume=$(osascript -e 'output volume of (get volume settings)')
fi

case $volume in
  0) code=F0581 ;;
  [1-9]|[1-2][0-9]) code=F057F ;;
  [3-5][0-9]|6[0-5]) code=F0580 ;;
  *) code=F057E ;;
esac

sketchybar --set "$NAME" icon="$(glyph $code)" label="${volume}%"
