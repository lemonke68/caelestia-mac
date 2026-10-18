#!/usr/bin/env sh
# Hyprland-style fullscreen (alt + F): the focused window covers the whole screen in place.
# yabai's zoom-fullscreen alone keeps the space padding (rice-shell frame), and does nothing
# for a lone window, so the space's padding and gap go to 0 as well. The space id is kept in
# a state file; rice-shell hides its frame, bar and SketchyBar while such a space is focused.

state="$HOME/.local/state/mac-rice/fullscreen-spaces"
mkdir -p "$(dirname "$state")"
touch "$state"

space=$(yabai -m query --spaces --space | jq -r .id)
zoomed=$(yabai -m query --windows --window | jq -r '."has-fullscreen-zoom"')

if grep -qx "$space" "$state"; then
    grep -vx "$space" "$state" > "$state.tmp" || true
    mv "$state.tmp" "$state"
    [ "$zoomed" = "true" ] && yabai -m window --toggle zoom-fullscreen
    yabai -m space --padding abs:10:20:70:20 --gap abs:10   # keep in sync with yabairc
else
    echo "$space" >> "$state"
    yabai -m space --padding abs:0:0:0:0 --gap abs:0
    [ "$zoomed" = "true" ] || yabai -m window --toggle zoom-fullscreen 2>/dev/null || true
fi

~/.local/bin/rice-shell spaces-changed
