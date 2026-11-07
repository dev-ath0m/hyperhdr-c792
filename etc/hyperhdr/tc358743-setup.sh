#!/usr/bin/env bash
# TC358743 (C792 CSI-HDMI capture module) setup script
# Raspberry Pi 5 — 4-lane CSI-2, CAM/DISP 1 (rp1-cfe)

set -euo pipefail

EDID_FILE="/etc/hyperhdr/tc358743-edid.bin"
LOG_TAG="tc358743-setup"
WIDTH=1920
HEIGHT=1080

log() { echo "[$LOG_TAG] $*"; }
err() { echo "[$LOG_TAG] ERROR: $*" >&2; }

# 1. Regenerate EDID binary if missing
if [ ! -f "$EDID_FILE" ]; then
    log "Generating EDID binary..."
    python3 /etc/hyperhdr/gen-edid.py || { err "EDID generation failed"; exit 1; }
fi

# 2. Find the rp1-cfe media device dynamically
log "Finding rp1-cfe media device..."
MEDIA_DEV=""
for m in /dev/media*; do
    driver=$(media-ctl -d "$m" --print-topology 2>/dev/null | grep "^driver " | head -1 | awk '{print $2}')
    if [ "$driver" = "rp1-cfe" ]; then
        MEDIA_DEV="$m"
        break
    fi
done
if [ -z "$MEDIA_DEV" ]; then err "rp1-cfe media device not found."; exit 1; fi
log "Media device: $MEDIA_DEV"

# 3. Find the TC358743 capture video node
CAPTURE_DEV=$(media-ctl -d "$MEDIA_DEV" --print-topology 2>/dev/null \
    | grep -A1 "rp1-cfe-csi2_ch0" | grep -o '/dev/video[0-9]*' | head -1 || echo "/dev/video0")
log "Capture device: $CAPTURE_DEV"

# 4. Find TC358743 subdevice
log "Waiting for TC358743 subdevice..."
SUBDEV=""
for i in $(seq 1 30); do
    SUBDEV=$(media-ctl -d "$MEDIA_DEV" -e "tc358743 11-000f" 2>/dev/null || true)
    [ -n "$SUBDEV" ] && [ -c "$SUBDEV" ] && break
    sleep 1
done
if [ -z "$SUBDEV" ] || [ ! -c "$SUBDEV" ]; then
    err "TC358743 subdevice not found after 30s."; exit 1
fi
log "TC358743 subdevice: $SUBDEV"

# 5. Load EDID
log "Loading EDID onto $SUBDEV..."
v4l2-ctl --device="$SUBDEV" --set-edid=file="$EDID_FILE",format=raw

# 6. Enable the capture link
log "Enabling capture link..."
media-ctl -d "$MEDIA_DEV" -l '"csi2":4->"rp1-cfe-csi2_ch0":0[1]' 2>/dev/null || true

# 7. Wait for a stable HDMI signal
log "Waiting for stable HDMI signal (up to 60 s)..."
TIMINGS_FOUND=0
PREV_W=0; PREV_H=0
for i in $(seq 1 60); do
    if v4l2-ctl --device="$SUBDEV" --query-dv-timings 2>/dev/null | grep -q "Active width"; then
        TMP=$(v4l2-ctl --device="$SUBDEV" --query-dv-timings 2>/dev/null)
        W=$(echo "$TMP" | grep "Active width"  | grep -o '[0-9]*' | head -1)
        H=$(echo "$TMP" | grep "Active height" | grep -o '[0-9]*' | head -1)
        if [ "$W" = "$PREV_W" ] && [ "$H" = "$PREV_H" ] && [ -n "$W" ]; then
            TIMINGS_FOUND=1
            WIDTH=$W; HEIGHT=$H
            break
        fi
        PREV_W=$W; PREV_H=$H
    fi
    sleep 1
done

if [ "$TIMINGS_FOUND" -eq 1 ]; then
    log "Stable HDMI signal: ${WIDTH}x${HEIGHT} — applying timings."
    v4l2-ctl --device="$SUBDEV" --set-dv-bt-timings query
else
    log "No stable signal in 60 s — trying late detection..."
    if v4l2-ctl --device="$SUBDEV" --query-dv-timings 2>/dev/null | grep -q "Active width"; then
        TMP=$(v4l2-ctl --device="$SUBDEV" --query-dv-timings 2>/dev/null)
        LATE_W=$(echo "$TMP" | grep "Active width"  | grep -o '[0-9]*' | head -1)
        LATE_H=$(echo "$TMP" | grep "Active height" | grep -o '[0-9]*' | head -1)
        if [ -n "$LATE_W" ] && [ "$LATE_W" -gt 0 ] 2>/dev/null; then
            WIDTH=$LATE_W; HEIGHT=$LATE_H
            log "Late signal: ${WIDTH}x${HEIGHT} — applying timings."
            v4l2-ctl --device="$SUBDEV" --set-dv-bt-timings query 2>/dev/null || true
        else
            log "No signal — forcing 1080p60 DV timings."
            v4l2-ctl --device="$SUBDEV" --set-dv-bt-timings \
                pixelclock=148500000,width=1920,hfp=88,hs=44,hbp=148,\
height=1080,vfp=4,vs=5,vbp=36,interlaced=0,polarities=0 \
                2>/dev/null || true
        fi
    else
        log "No signal — forcing 1080p60 DV timings."
        v4l2-ctl --device="$SUBDEV" --set-dv-bt-timings \
            pixelclock=148500000,width=1920,hfp=88,hs=44,hbp=148,\
height=1080,vfp=4,vs=5,vbp=36,interlaced=0,polarities=0 \
            2>/dev/null || true
    fi
fi

# 8. Set TC358743 source pad format
log "Setting pad formats: UYVY8_1X16 ${WIDTH}x${HEIGHT}..."
media-ctl -d "$MEDIA_DEV" \
    --set-v4l2 '"tc358743 11-000f":0[fmt:UYVY8_1X16/'"${WIDTH}x${HEIGHT}"' field:none colorspace:rec709]' \
    2>/dev/null || true

# 9. csi2 sink pad 0
media-ctl -d "$MEDIA_DEV" \
    --set-v4l2 '"csi2":0[fmt:UYVY8_1X16/'"${WIDTH}x${HEIGHT}"' field:none colorspace:rec709]' \
    2>/dev/null || true

# 10. csi2 source pad 4
media-ctl -d "$MEDIA_DEV" \
    --set-v4l2 '"csi2":4[fmt:UYVY8_1X16/'"${WIDTH}x${HEIGHT}"' field:none colorspace:rec709]' \
    2>/dev/null || true

# 11. Set capture video node format
log "Setting $CAPTURE_DEV format: UYVY ${WIDTH}x${HEIGHT}..."
v4l2-ctl --device="$CAPTURE_DEV" \
    --set-fmt-video=width="${WIDTH}",height="${HEIGHT}",pixelformat=UYVY 2>/dev/null || true

log "Setup complete. Media=$MEDIA_DEV  Subdev=$SUBDEV  Capture=$CAPTURE_DEV"
v4l2-ctl --device="$CAPTURE_DEV" --get-fmt-video 2>/dev/null | grep -i "width\|height\|pixel" || true

# 12. Detect and record initial input color space
CS=$(v4l2-ctl -d "$SUBDEV" --log-status 2>&1 | grep "Input color space:" | sed 's/.*Input color space: //' || echo "unknown")
if [[ "$CS" == *"RGB"* ]]; then
    echo "rgb" > /tmp/tc358743-colorspace && chmod 666 /tmp/tc358743-colorspace
    log "Input color space: RGB — relay will apply color correction"
elif [[ "$CS" == *"YCbCr"* ]]; then
    echo "ycbcr" > /tmp/tc358743-colorspace && chmod 666 /tmp/tc358743-colorspace
    log "Input color space: YCbCr — no color correction needed"
else
    echo "unknown" > /tmp/tc358743-colorspace && chmod 666 /tmp/tc358743-colorspace
    log "Input color space: unknown ($CS) — defaulting to no correction"
fi
