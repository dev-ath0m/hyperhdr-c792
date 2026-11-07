#!/usr/bin/env bash
# Re-applies the white-balance "cct" correction to the RGBW WLED strips.
# This fork's preset-save is broken (presets.json never actually gets written),
# so WLED forgets `cct` on every reboot/power-loss — this script restores it.
# See install.md Step 8d.

TARGET_CCT=255
DEVICES=(192.168.178.15 192.168.178.14)  # TV, Soundbar

for ip in "${DEVICES[@]}"; do
    current=$(curl -s --max-time 3 "http://$ip/json/state" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['seg'][0]['cct'])" 2>/dev/null)
    if [[ -n "$current" && "$current" != "$TARGET_CCT" ]]; then
        curl -s --max-time 3 -X POST "http://$ip/json/state" -H "Content-Type: application/json" \
            -d "{\"seg\":[{\"cct\":$TARGET_CCT}]}" > /dev/null
        echo "[wled-cct-fix] $ip: cct was '$current', set to $TARGET_CCT"
    fi
done
