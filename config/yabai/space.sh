#!/usr/bin/env sh
# Hyprland-style workspaces: spaces are created on demand.
#   space.sh focus N   switch to space N
#   space.sh move N    move focused window to space N and follow it
# Without the scripting addition (basic mode) yabai can neither create nor focus spaces:
# focus falls back to the macOS ctrl + N shortcut, and moving windows is not possible.

action="$1"
target="$2"

count=$(yabai -m query --spaces --display | jq length)
while [ "$count" -lt "$target" ]; do
    yabai -m space --create 2>/dev/null || break
    count=$((count + 1))
done

case "$action" in
    focus)
        yabai -m space --focus "$target" 2>/dev/null || ~/.local/bin/rice-shell space-key "$target"
        ;;
    move)
        wid=$(yabai -m query --windows --window | jq -r .id)
        yabai -m window --space "$target"
        yabai -m space --focus "$target"
        [ -n "$wid" ] && yabai -m window --focus "$wid"
        ;;
esac
