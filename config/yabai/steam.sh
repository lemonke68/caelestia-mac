#!/usr/bin/env sh
# yabai window_created signal for Steam Helper (Steam's CEF UI process).
#   main window ("Steam")  -> workspace 5, alone and full screen (min width 1010pt)
#   anything else (dialogs) -> floating, centred, on the main window's workspace
# CEF sets the title a moment after the window appears, so wait for it first.

wid="$YABAI_WINDOW_ID"
[ -n "$wid" ] || exit 0
sleep 0.3

title=$(yabai -m query --windows --window "$wid" | jq -r .title)

if [ "$title" = "Steam" ]; then
    while [ "$(yabai -m query --spaces --display | jq length)" -lt 5 ]; do yabai -m space --create; done
    yabai -m window "$wid" --space 5
    yabai -m space --focus 5
    yabai -m window --focus "$wid"
    exit 0
fi

main_space=$(yabai -m query --windows | jq -r '[.[] | select(.app == "Steam Helper" and .title == "Steam")][0].space // empty')
[ "$(yabai -m query --windows --window "$wid" | jq -r '."is-floating"')" = "true" ] || yabai -m window "$wid" --toggle float
[ -n "$main_space" ] && yabai -m window "$wid" --space "$main_space" && yabai -m space --focus "$main_space"
yabai -m window "$wid" --grid 6:6:1:1:4:4
yabai -m window --focus "$wid"
