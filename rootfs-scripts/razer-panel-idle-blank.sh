#!/bin/bash
set -euo pipefail

IDLE_SECONDS="${RAZER_PANEL_IDLE_SECONDS:-60}"
sleep "$IDLE_SECONDS"

if [ -w /sys/class/graphics/fb0/blank ]; then
    echo 1 > /sys/class/graphics/fb0/blank || true
fi

for backlight in /sys/class/backlight/*; do
    [ -w "$backlight/brightness" ] || continue
    echo 0 > "$backlight/brightness" || true
done
