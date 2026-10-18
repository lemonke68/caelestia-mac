#!/bin/bash

sketchybar --set "$NAME" label="$(LC_TIME=ru_RU.UTF-8 date '+%a %d %b  %H:%M')"
