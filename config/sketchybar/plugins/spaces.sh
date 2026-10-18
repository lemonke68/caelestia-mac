#!/bin/bash
# Draws only existing spaces of the current display.
# Focused: filled accent pill. Occupied: normal text. Empty: faded text.

source "$HOME/.config/sketchybar/colors.sh"

spaces=$(yabai -m query --spaces --display 2>/dev/null) || exit 0

args=()
for i in $(seq 1 10); do
  info=$(jq -c --argjson i "$i" '.[] | select(.index == $i)' <<<"$spaces")
  if [ -z "$info" ]; then
    args+=(--set space.$i drawing=off)
    continue
  fi

  focused=$(jq -r '."has-focus"' <<<"$info")
  windows=$(jq -r '.windows | length' <<<"$info")

  if [ "$focused" = "true" ]; then
    args+=(--set space.$i drawing=on background.drawing=on label.color=$ON_ACCENT)
  elif [ "$windows" -gt 0 ]; then
    args+=(--set space.$i drawing=on background.drawing=off label.color=$TEXT)
  else
    args+=(--set space.$i drawing=on background.drawing=off label.color=$TEXT_FAINT)
  fi
done

sketchybar "${args[@]}"
