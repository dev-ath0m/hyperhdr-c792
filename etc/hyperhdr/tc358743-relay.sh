#!/usr/bin/env bash
set -uo pipefail
LOG_TAG="tc358743-relay"
log() { echo "[$LOG_TAG] $*"; }
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

CS=$(cat /tmp/tc358743-colorspace 2>/dev/null || echo "unknown")

if [[ "$CS" == "rgb" ]]; then
    log "RGB input (${FPS}fps) — applying BT.601→BT.709 color correction"
    exec /usr/bin/ffmpeg \
        -f v4l2 -input_format uyvy422 -video_size 1920x1080 -framerate "$FPS" \
        -i /dev/video0 \
        -vf "scale=480:270,colormatrix=bt601:bt709,scale=1920:1080" \
        -pix_fmt uyvy422 \
        -f v4l2 /dev/video10
else
    log "YCbCr input (${FPS}fps) — copy mode"
    exec /usr/bin/ffmpeg \
        -f v4l2 -input_format uyvy422 -video_size 1920x1080 -framerate "$FPS" \
        -i /dev/video0 \
        -vcodec copy \
        -f v4l2 /dev/video10
fi
