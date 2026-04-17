# C792 HDMI-to-CSI + HyperHDR Ambilight on Raspberry Pi 5
## Complete Setup Guide from Fresh Raspberry Pi OS Lite

**Hardware:**
- Raspberry Pi 5
- C792 HDMI-to-CSI capture module (TC358743 chip)
- 22-pin FFC cable connected to **CAM/DISP 1** (the port closest to the USB-C power)
- WLED LED strip (this guide uses IP `192.168.178.16`, 210 LEDs, UDP port 21324)

**Software versions used:**
- OS: Raspberry Pi OS Lite (Debian Trixie, arm64), kernel `6.12.x+rpt-rpi-2712`
- HyperHDR: `22.0.0~trixie~beta1`
- WLED: `0.15.4`

---

## Step 1 — Boot firmware overlay (`/boot/firmware/config.txt`)

Enable SPI (for LED strip output) and add the TC358743 overlay with 4-lane CSI-2.

```
# In /boot/firmware/config.txt, uncomment the SPI line:
dtparam=spi=on

# And in the [all] section, add:
dtoverlay=tc358743-pi5,4lane
```

`dtparam=spi=on` enables SPI0 (`/dev/spidev0.0`), needed for driving WS2812 / SK6812 LED strips.

The `4lane` parameter is required for the Pi 5 / C792 combination — without it only
2 lanes are used and the capture will fail with EPIPE errors.

---

## Step 2 — Install packages

```bash
sudo apt update
sudo apt install -y \
    v4l-utils \
    media-ctl \
    ffmpeg \
    v4l2loopback-dkms \
    python3
```

---

## Step 3 — Install HyperHDR

Download and install the Debian Trixie arm64 package from the HyperHDR releases page:
```
https://github.com/awawa-dev/HyperHDR/releases
```

```bash
# Example (check for latest version):
wget https://github.com/awawa-dev/HyperHDR/releases/download/v22.0.0.0beta1/hyperhdr_22.0.0~trixie~beta1_arm64.deb
sudo dpkg -i hyperhdr_22.0.0~trixie~beta1_arm64.deb
sudo apt-get install -f   # fix any missing deps
```

---

## Step 4 — v4l2loopback configuration

The loopback device is needed because HyperHDR filters out `/dev/video0` (it has the
`V4L2_CAP_META_CAPTURE` flag which HyperHDR treats as a non-capture device). We create
a virtual `/dev/video10` that ffmpeg feeds with the UYVY frames from the real device.

**`/etc/modprobe.d/v4l2loopback.conf`**
```
options v4l2loopback devices=1 video_nr=10 card_label="TC358743-Capture" exclusive_caps=1
```

**`/etc/modules-load.d/v4l2loopback.conf`**
```
v4l2loopback
```

---

## Step 5 — Create the working directory and EDID generator

```bash
sudo mkdir -p /etc/hyperhdr
```

**`/etc/hyperhdr/gen-edid.py`**

This script generates a valid 128-byte EDID binary that the TC358743 presents to the
HDMI source, advertising 1920×1080 @ 60 Hz.

```python
#!/usr/bin/env python3
"""
Generate a valid 128-byte EDID binary for the TC358743 HDMI-to-CSI bridge.
Advertises 1920x1080 @ 60Hz to the connected HDMI source.
"""
import os

os.makedirs('/etc/hyperhdr', exist_ok=True)

edid = bytearray([
    # Header (8)
    0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00,
    # Manufacturer "RPI" compressed (2) + product (2) + serial (4)
    0x52, 0x62, 0x88, 0x88, 0x00, 0x00, 0x00, 0x00,
    # Week 0, Year 29 (=2019), EDID 1.3
    0x00, 0x1D, 0x01, 0x03,
    # Digital input, size undefined, gamma 2.2, RGB preferred timing
    0x80, 0x00, 0x00, 0x78, 0x0A,
    # Color characteristics (10 bytes)
    0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54,
    # Established timings (3) - none
    0x00, 0x00, 0x00,
    # Standard timing IDs (16) - all unused
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    # DTD1: 1920x1080@60Hz (18 bytes)
    0x02, 0x3A, 0x80, 0x18, 0x71, 0x38, 0x2D, 0x40,
    0x58, 0x2C, 0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1E,
    # DTD2: Monitor range limits
    0x00, 0x00, 0x00, 0xFD, 0x00, 0x18, 0x3C, 0x18,
    0x50, 0x0F, 0x00, 0x0A, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
    # DTD3: Monitor name "TC358743"
    0x00, 0x00, 0x00, 0xFC, 0x00,
    0x54, 0x43, 0x33, 0x35, 0x38, 0x37, 0x34, 0x33,
    0x0A, 0x20, 0x20, 0x20, 0x20,
    # DTD4: Dummy descriptor
    0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    # Extension count=0, checksum placeholder
    0x00, 0x00,
])

assert len(edid) == 128
edid[127] = (256 - sum(edid[:127]) % 256) % 256
assert sum(edid) % 256 == 0

out_path = '/etc/hyperhdr/tc358743-edid.bin'
with open(out_path, 'wb') as f:
    f.write(bytes(edid))
print(f"EDID written: {out_path}  ({len(edid)} bytes, checksum=0x{edid[127]:02X})")
```

```bash
sudo chmod +x /etc/hyperhdr/gen-edid.py
sudo python3 /etc/hyperhdr/gen-edid.py
```

---

## Step 6 — TC358743 setup script

This script runs at boot to configure the V4L2 media pipeline:
- Loads the EDID onto the TC358743
- Enables the CSI-2 capture link
- Detects the HDMI input timings (with double-detection to avoid race conditions)
- Falls back to forced 1080p60 if no signal is present at boot
- Sets pad formats and the capture device format to UYVY 1920×1080

**`/etc/hyperhdr/tc358743-setup.sh`**

```bash
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

# 2. Find the rp1-cfe media device dynamically (can be media0, media1, etc.)
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

# 5. Load EDID so the HDMI source advertises supported modes
log "Loading EDID onto $SUBDEV..."
v4l2-ctl --device="$SUBDEV" --set-edid=file="$EDID_FILE",format=raw

# 6. Enable the capture link: csi2:4 -> rp1-cfe-csi2_ch0
log "Enabling capture link..."
media-ctl -d "$MEDIA_DEV" -l '"csi2":4->"rp1-cfe-csi2_ch0":0[1]' 2>/dev/null || true

# 7. Wait for a stable HDMI signal with TWO consecutive matching detections
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
    # Try one last time — signal may have arrived just after the 60 s window
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
# NOTE: do NOT use /0 stream specifier — causes field:none to be dropped silently
log "Setting pad formats: UYVY8_1X16 ${WIDTH}x${HEIGHT}..."
media-ctl -d "$MEDIA_DEV" \
    --set-v4l2 '"tc358743 11-000f":0[fmt:UYVY8_1X16/'"${WIDTH}x${HEIGHT}"' field:none colorspace:smpte170m]' \
    2>/dev/null || true

# 9. csi2 sink pad 0
media-ctl -d "$MEDIA_DEV" \
    --set-v4l2 '"csi2":0[fmt:UYVY8_1X16/'"${WIDTH}x${HEIGHT}"' field:none colorspace:smpte170m]' \
    2>/dev/null || true

# 10. csi2 source pad 4
media-ctl -d "$MEDIA_DEV" \
    --set-v4l2 '"csi2":4[fmt:UYVY8_1X16/'"${WIDTH}x${HEIGHT}"' field:none colorspace:smpte170m]' \
    2>/dev/null || true

# 11. Set capture video node format
log "Setting $CAPTURE_DEV format: UYVY ${WIDTH}x${HEIGHT}..."
v4l2-ctl --device="$CAPTURE_DEV" \
    --set-fmt-video=width="${WIDTH}",height="${HEIGHT}",pixelformat=UYVY 2>/dev/null || true

log "Setup complete. Media=$MEDIA_DEV  Subdev=$SUBDEV  Capture=$CAPTURE_DEV"
v4l2-ctl --device="$CAPTURE_DEV" --get-fmt-video 2>/dev/null | grep -i "width\|height\|pixel" || true
```

```bash
sudo chmod +x /etc/hyperhdr/tc358743-setup.sh
```

---

## Step 7 — Systemd services

### 7a. TC358743 setup service

Runs the setup script once at boot before any capture services start.

**`/etc/systemd/system/tc358743-setup.service`**
```ini
[Unit]
Description=TC358743 HDMI-to-CSI Capture Device Setup (C792 on CAM/DISP 1)
After=local-fs.target
Before=hyperhdr@pi.service

[Service]
Type=oneshot
ExecStart=/etc/hyperhdr/tc358743-setup.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### 7b. ffmpeg relay service

Bridges `/dev/video0` (rp1-cfe, has `V4L2_CAP_META_CAPTURE`) to `/dev/video10`
(v4l2loopback, seen by HyperHDR as a clean capture device).
Re-runs the setup script as `ExecStartPre` in case the HDMI source was not ready
during the initial boot setup run. The `ExecStartPost` sets the loopback device's
advertised framerate to 60 fps — without this, v4l2loopback defaults to 30 fps and
HyperHDR will only capture at 30 fps regardless of the ffmpeg input framerate.

**`/etc/systemd/system/tc358743-relay.service`**
```ini
[Unit]
Description=TC358743 V4L2 relay: video0 (rp1-cfe) → video10 (HyperHDR loopback)
After=tc358743-setup.service
Requires=tc358743-setup.service
Before=hyperhdr@pi.service

[Service]
Type=simple
ExecStartPre=/bin/sleep 2
ExecStartPre=/etc/hyperhdr/tc358743-setup.sh
ExecStart=/usr/bin/ffmpeg \
  -f v4l2 -input_format uyvy422 -video_size 1920x1080 -framerate 60 \
  -i /dev/video0 \
  -vcodec copy \
  -f v4l2 /dev/video10
ExecStartPost=/bin/bash -c 'sleep 1 && v4l2-ctl -d /dev/video10 --set-parm 60'
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### 7c. HyperHDR drop-in — dependency and readiness wait

Ensures HyperHDR starts only after video10 is fully initialized by ffmpeg.
Without this, HyperHDR may enumerate video10 before ffmpeg has set it up as a
`Video Capture` device and fall back to a different device.

```bash
sudo mkdir -p /etc/systemd/system/hyperhdr@pi.service.d
```

**`/etc/systemd/system/hyperhdr@pi.service.d/tc358743.conf`**
```ini
[Unit]
After=tc358743-setup.service tc358743-relay.service
Requires=tc358743-setup.service tc358743-relay.service

[Service]
ExecStartPre=/bin/bash -c 'for i in $(seq 1 30); do v4l2-ctl -d /dev/video10 --info 2>/dev/null | grep -q "Video Capture" && exit 0; sleep 1; done; echo "video10 not ready after 30s"; exit 1'
```

### 7d. Enable all services

```bash
sudo systemctl daemon-reload
sudo systemctl enable tc358743-setup.service
sudo systemctl enable tc358743-relay.service
sudo systemctl enable hyperhdr@pi.service
```

---

## Step 8 — HyperHDR database configuration

After the first HyperHDR start the SQLite database is created at
`/home/pi/.hyperhdr/db/hyperhdr.db`. Configure it while the service is stopped:

```bash
sudo systemctl stop hyperhdr@pi.service

DB="/home/pi/.hyperhdr/db/hyperhdr.db"

# Video grabber: use video10, UYVY encoding, 60fps, HDR tone mapping on
sqlite3 "$DB" "UPDATE settings SET config = json_patch(config, '{
  \"device\": \"TC358743-Capture (video10)\",
  \"videoEncoding\": \"UYVY\",
  \"fps\": 60,
  \"hdrToneMapping\": true,
  \"autoSignalDetection\": false,
  \"qFrame\": false,
  \"saveResources\": false
}') WHERE type='videoGrabber';"

# LED device: WLED — adjust host IP and LED count to your setup
sqlite3 "$DB" "UPDATE settings SET config = json_patch(config, '{
  \"type\": \"wled\",
  \"host\": \"192.168.178.16\",
  \"colorOrder\": \"rgb\",
  \"brightnessMax\": true,
  \"brightnessMaxLevel\": 255,
  \"maxRetry\": 60,
  \"refreshTime\": 20,
  \"restoreOriginalState\": true
}') WHERE type='device';"

sudo systemctl start hyperhdr@pi.service
```

> **Note:** The LED layout (position of each LED around the screen) is configured
> through the HyperHDR web UI at `http://<pi-ip>:8090`. Navigate to
> **Configuration → LED Hardware** and set the count to match your WLED strip (e.g. 210).

---

## Step 9 — WLED configuration

In the WLED web UI (`http://<wled-ip>/`) or `/json/cfg` API:

- **LED count** must match exactly what is set in HyperHDR (e.g. 210)
- **Live data** must be enabled: `Config → Sync Interfaces → Realtime → Receive UDP`
  should be checked
- **Live timeout**: Set to 25 seconds (avoids the strip freezing on the last received
  color permanently if HyperHDR stops). Can be set via API:
  ```bash
  curl -X POST http://192.168.178.16/json/cfg \
    -H "Content-Type: application/json" \
    -d '{"if":{"live":{"timeout":25}}}'
  ```

---

## Step 10 — Reboot and verify

```bash
sudo reboot
```

After boot, verify the pipeline:

```bash
# 1. Check all services are running
systemctl status tc358743-setup.service tc358743-relay.service hyperhdr@pi.service

# 2. Check video10 loopback is active (ffmpeg is feeding it)
v4l2-ctl -d /dev/video10 --info | grep "Video Capture"

# 3. Check WLED is receiving live data
curl -s http://<wled-ip>/json/info | python3 -c \
  "import json,sys;d=json.load(sys.stdin);print('fps:',d['leds']['fps'],'live:',d['live'])"
# Expected: fps: >0  live: True

# 4. Check HyperHDR is processing video
curl -s -X POST http://127.0.0.1:8090/json-rpc \
  -d '{"command":"serverinfo","tan":1}' | python3 -c \
  "import json,sys;d=json.load(sys.stdin)['info'];[print(p) for p in d['priorities']]"
# Expected: VIDEOGRABBER at priority 240, visible: True
```

---

## Troubleshooting

### ffmpeg fails with `VIDIOC_STREAMON: Broken pipe`
DV timings mismatch. The TC358743 source pad is at a different resolution than
expected (often 640×480 default). The setup script handles this automatically by
forcing 1080p60 timings when no stable signal is detected. Check the logs:
```bash
journalctl -u tc358743-relay.service -n 50
```

### HyperHDR doesn't see video10 / picks wrong device
Race condition — HyperHDR started before ffmpeg fully initialized the loopback.
The `ExecStartPre` wait loop in the drop-in (Step 7c) prevents this.
```bash
journalctl -u hyperhdr@pi.service -n 50 | grep -i "v4l2\|device\|video"
```

### WLED strip frozen on one color, ignores new data (`lor: 2`)
WLED is in permanent live override freeze mode. Reboot the WLED device to clear it,
or reduce the live timeout (Step 9) so it exits automatically.

### HyperHDR outputs wrong/muted colors from HDR content
The LUT file at `/home/pi/.hyperhdr/lut_lin_tables.3d` (144 MB) is auto-generated
by HyperHDR on first start. Ensure `HDR = True` in the components list via the API:
```bash
curl -s -X POST http://127.0.0.1:8090/json-rpc \
  -d '{"command":"serverinfo","tan":1}' | python3 -c \
  "import json,sys;d=json.load(sys.stdin)['info'];print([c for c in d['components'] if c['name']=='HDR'])"
```

### Multiple HyperHDR instances running
If you ever ran HyperHDR manually in a terminal for testing, kill the stray process:
```bash
sudo kill $(pgrep hyperhdr)
sudo systemctl start hyperhdr@pi.service
```

---

## Architecture overview

```
HDMI source
    │  HDMI
    ▼
C792 module (TC358743 chip)
    │  4-lane CSI-2, UYVY8_1X16
    ▼
/dev/video0  (rp1-cfe capture node, has V4L2_CAP_META_CAPTURE)
    │  ffmpeg relay (tc358743-relay.service)
    ▼
/dev/video10  (v4l2loopback "TC358743-Capture", clean capture device)
    │  V4L2, UYVY 1920×1080 @ 60fps
    ▼
HyperHDR  (hyperhdr@pi.service)
    │  HDR→SDR tone mapping via LUT
    │  LED zone sampling (210 LEDs)
    ▼
WLED  (UDP DRGB, 192.168.178.16:21324, ~50fps)
    │
    ▼
LED strip
```
