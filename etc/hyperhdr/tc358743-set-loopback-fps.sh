#!/usr/bin/env bash
# Set the v4l2loopback advertised framerate to match the detected signal.
sleep 1

for m in /dev/media*; do
    drv=$(media-ctl -d "$m" --print-topology 2>/dev/null | grep "^driver " | head -1 | awk '{print $2}')
    if [[ "$drv" == "rp1-cfe" ]]; then
        SUBDEV=$(media-ctl -d "$m" -e "tc358743 11-000f" 2>/dev/null || true)
        [[ -n "$SUBDEV" && -c "$SUBDEV" ]] && break
    fi
done

FPS=60
if [[ -n "${SUBDEV:-}" && -c "${SUBDEV:-}" ]]; then
    TMP=$(v4l2-ctl -d "$SUBDEV" --query-dv-timings 2>/dev/null || true)
    RAW=$(echo "$TMP" | grep -oP '\(\K[0-9.]+(?= frames)' | head -1)
    if [[ -n "$RAW" ]]; then
        FPS=${RAW%%.*}
        [[ "$FPS" -lt 1 ]] 2>/dev/null && FPS=60
    fi
fi

v4l2-ctl -d /dev/video10 --set-parm "$FPS"
echo "Loopback set to ${FPS}fps"
