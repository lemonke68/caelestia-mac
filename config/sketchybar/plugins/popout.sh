#!/bin/bash
# click_script: open a rice-shell popout (wifi / bluetooth) under this item.
x=$(sketchybar --query "$NAME" | jq '.bounding_rects | to_entries[0].value | .origin[0] + .size[0] / 2')
"$HOME/.local/bin/rice-shell" popout "$1" "$x"
