#!/usr/bin/env sh
# Caelestia special workspaces via yabai scratchpads.
#   scratch.sh <label>   show/hide the scratchpad window, launching its app if needed
# Labels are assigned by rules in yabairc.

label="$1"

yabai -m window --toggle "$label" && exit 0

case "$label" in
    term)  open -na kitty --args --title kitty-dropdown ;;
    music) open -a Spotify ;;
    *)     exit 1 ;;
esac
