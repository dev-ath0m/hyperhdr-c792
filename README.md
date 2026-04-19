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

This script generates a valid 256-byte EDID (2 blocks) that the TC358743 presents
to the HDMI source.  Block 0 advertises 1920×1080 @ 60 Hz.  Block 1 is a CEA-861
extension with an HDMI Vendor Specific Data Block and YCbCr 4:2:2 + 4:4:4 support.
Without the CEA extension, HDMI sources treat the TC358743 as a DVI display and
force RGB output, which causes a purple tint (BT.601/BT.709 matrix mismatch).

```python
#!/usr/bin/env python3
"""
Generate a 256-byte EDID (2 blocks) for the TC358743 HDMI-to-CSI bridge.

Block 0: Base EDID — 1080p60 preferred timing.
Block 1: CEA-861 extension — advertises YCbCr 4:2:2 + 4:4:4 support,
         HDMI Vendor Specific Data Block (so source treats us as HDMI,
         not DVI which only supports RGB), common 1080p/720p video codes,
         and basic PCM audio.

This forces HDMI sources (e.g. Fire TV) to output YCbCr instead of RGB,
which avoids the purple-tint BT.601/BT.709 matrix mismatch on 1080p.
"""
import os, sys

os.makedirs('/etc/hyperhdr', exist_ok=True)

def checksum(block):
    """Calculate EDID block checksum (makes sum of all 128 bytes = 0 mod 256)."""
    return (256 - sum(block[:127]) % 256) % 256

# ─── Block 0: Base EDID ─────────────────────────────────────────────
block0 = bytearray([
    # Header (8 bytes)
    0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00,
    # Manufacturer "Rb" (2) + product 0x8888 (2) + serial (4)
    0x52, 0x62, 0x88, 0x88, 0x00, 0x00, 0x00, 0x00,
    # Week 0, Year 29 (=2019), EDID 1.3
    0x00, 0x1D, 0x01, 0x03,
    # Digital input (0x80), size undefined, gamma 2.2, features
    0x80, 0x00, 0x00, 0x78, 0x0A,
    # Color characteristics (10 bytes)
    0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54,
    # Established timings (3) — none
    0x00, 0x00, 0x00,
    # Standard timing IDs (16) — all unused
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    # DTD1: 1920x1080 @ 60 Hz (148.5 MHz) — preferred timing (18 bytes)
    0x02, 0x3A, 0x80, 0x18, 0x71, 0x38, 0x2D, 0x40,
    0x58, 0x2C, 0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1E,
    # DTD2: Monitor range limits (18 bytes)
    0x00, 0x00, 0x00, 0xFD, 0x00, 0x18, 0x3C, 0x18,
    0x50, 0x0F, 0x00, 0x0A, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
    # DTD3: Monitor name "TC358743" (18 bytes)
    0x00, 0x00, 0x00, 0xFC, 0x00,
    0x54, 0x43, 0x33, 0x35, 0x38, 0x37, 0x34, 0x33,
    0x0A, 0x20, 0x20, 0x20, 0x20,
    # DTD4: Dummy descriptor (18 bytes)
    0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    # Extension count = 1 (CEA block follows)
    0x01,
    # Checksum placeholder
    0x00,
])
assert len(block0) == 128
block0[127] = checksum(block0)
assert sum(block0) % 256 == 0

# ─── Block 1: CEA-861 Extension ─────────────────────────────────────
# Build data blocks first, then assemble the full 128-byte block.

# Video Data Block (VDB) — tag 2
# SVDs: native 1080p60, plus 1080p50/25/30/24, 720p60/50
svds = [
    0x90,  # 16 | 0x80 = 1080p60 (native)
    0x1F,  # 31 = 1080p50
    0x20,  # 32 = 1080p24
    0x21,  # 33 = 1080p25
    0x22,  # 34 = 1080p30
    0x04,  #  4 = 720p60
    0x13,  # 19 = 720p50
]
vdb = bytearray([(0x02 << 5) | len(svds)] + svds)  # tag=2, length=7

# Audio Data Block (ADB) — tag 1
# PCM stereo, 32/44.1/48 kHz, 16-bit
adb = bytearray([
    (0x01 << 5) | 3,  # tag=1, length=3
    0x09,              # PCM, 2 channels (1+1)
    0x07,              # 32+44.1+48 kHz
    0x01,              # 16-bit
])

# HDMI Vendor Specific Data Block (VSDB) — tag 3
# IEEE OUI 00-0C-03 (HDMI Licensing) stored little-endian
# Physical address 1.0.0.0
vsdb = bytearray([
    (0x03 << 5) | 5,  # tag=3, length=5
    0x03, 0x0C, 0x00, # OUI (LE)
    0x10, 0x00,        # Physical address 1.0.0.0
])

data_blocks = vdb + adb + vsdb
dtd_offset = 4 + len(data_blocks)  # offset from start of block to DTDs (or padding)

# CEA header (4 bytes)
cea_header = bytearray([
    0x02,        # CEA extension tag
    0x03,        # Revision 3
    dtd_offset,  # DTD offset
    0x30,        # YCbCr 4:4:4 + YCbCr 4:2:2 supported, 0 native DTDs
])

block1 = cea_header + data_blocks
# Pad to 127 bytes (byte 127 = checksum)
block1 += bytearray(127 - len(block1))
assert len(block1) == 127
block1.append(0x00)  # checksum placeholder
block1[127] = checksum(block1)
assert len(block1) == 128
assert sum(block1) % 256 == 0

# ─── Write EDID ─────────────────────────────────────────────────────
edid = bytes(block0 + block1)
assert len(edid) == 256

out_path = '/etc/hyperhdr/tc358743-edid.bin'
with open(out_path, 'wb') as f:
    f.write(edid)

print(f"EDID written: {out_path}  ({len(edid)} bytes)")
print(f"  Block 0 checksum: 0x{block0[127]:02X}")
print(f"  Block 1 checksum: 0x{block1[127]:02X}")
print(f"  CEA flags: YCbCr 4:4:4 + 4:2:2, HDMI VSDB, {len(svds)} video codes")
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

### Dynamic framerate helper scripts

Some HDMI sources (e.g. Fire TV with "Match original frame rate" enabled) switch
refresh rates on the fly — 60 fps for menus, 24 fps for movies, 50 fps for PAL
content.  When this happens the TC358743 pixel clock changes (148.5 MHz → 74.25 MHz
for 24p) and the capture pipeline must adapt.  The two scripts below detect the
current framerate from the TC358743 DV timings and pass it to ffmpeg / v4l2loopback
automatically.

**`/etc/hyperhdr/tc358743-relay.sh`**

```bash
#!/usr/bin/env bash
# Detect current framerate from TC358743 and exec ffmpeg with it.
set -uo pipefail

LOG_TAG="tc358743-relay"
log() { echo "[$LOG_TAG] $*"; }

# Find subdev dynamically
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

log "Detected ${FPS}fps — starting ffmpeg relay"
exec /usr/bin/ffmpeg \
    -f v4l2 -input_format uyvy422 -video_size 1920x1080 -framerate "$FPS" \
    -i /dev/video0 \
    -vcodec copy \
    -f v4l2 /dev/video10
```

**`/etc/hyperhdr/tc358743-set-loopback-fps.sh`**

```bash
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
```

```bash
sudo chmod +x /etc/hyperhdr/tc358743-relay.sh /etc/hyperhdr/tc358743-set-loopback-fps.sh
```

### LEDDEVICE auto-enable script

HyperHDR does **not** persist the LEDDEVICE component state across restarts — every
instance starts with LEDDEVICE=OFF, which also prevents the video grabber from
producing frames.  This script is called by `ExecStartPost` (Step 7c) to enable
LEDDEVICE on all instances via the JSON API once HyperHDR is fully initialized.

The main difficulty is timing: HyperHDR's API port opens and returns `success: true`
**before** the instance backends are ready.  Commands sent during that window are
silently ignored.  The script therefore waits for the `LEDDEVICE` component to
appear in `serverinfo`, adds an extra 5-second settling delay, reconnects with a
fresh socket, and retries once if the first attempt fails.

**`/etc/hyperhdr/enable-leds.sh`**

```bash
#!/usr/bin/env bash
# Wait for HyperHDR to fully initialize, then enable LEDDEVICE on all instances.
exec python3 -u - << 'PYEOF'
import socket, json, time, sys

PORT = 19444
MAX_WAIT = 60

def connect():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(('127.0.0.1', PORT))
    return s

def send_cmd(s, cmd):
    s.sendall(json.dumps(cmd).encode() + b'\n')
    data = b''
    while b'\n' not in data:
        chunk = s.recv(4096)
        if not chunk:
            return {}
        data += chunk
    return json.loads(data.split(b'\n')[0])

# Wait for HyperHDR API to be ready AND instances to be initialized
# We verify by checking that instance 0 has components listed
for attempt in range(MAX_WAIT):
    try:
        s = connect()
        r = send_cmd(s, {'command': 'serverinfo', 'tan': 1})
        if r.get('success'):
            comps = r.get('info', {}).get('components', [])
            # Wait until we see LEDDEVICE in components (means instances are init'd)
            comp_names = [c['name'] for c in comps]
            if 'LEDDEVICE' in comp_names:
                break
        s.close()
    except (ConnectionRefusedError, OSError, socket.timeout):
        try: s.close()
        except: pass
    time.sleep(1)
else:
    print("[enable-leds] HyperHDR not ready after 60s, giving up")
    sys.exit(0)

# Extra wait for all instance backends to finish initializing
time.sleep(5)

# Reconnect fresh (old connection may have stale state)
try: s.close()
except: pass

s = connect()

# Enable LEDDEVICE on all instances
for inst in range(4):
    send_cmd(s, {'command': 'instance', 'subcommand': 'switchTo', 'instance': inst, 'tan': 1})
    time.sleep(0.5)
    send_cmd(s, {'command': 'componentstate', 'componentstate': {'component': 'LEDDEVICE', 'state': True}, 'tan': 2})
    time.sleep(0.5)

# Verify instance 0
time.sleep(1)
send_cmd(s, {'command': 'instance', 'subcommand': 'switchTo', 'instance': 0, 'tan': 1})
time.sleep(0.3)
r = send_cmd(s, {'command': 'serverinfo', 'tan': 3})
comps = {c['name']: c['enabled'] for c in r.get('info', {}).get('components', [])}
led_on = comps.get('LEDDEVICE', False)

if not led_on:
    # Retry after more time
    print("[enable-leds] First attempt failed, retrying in 5s...")
    time.sleep(5)
    for inst in range(4):
        send_cmd(s, {'command': 'instance', 'subcommand': 'switchTo', 'instance': inst, 'tan': 1})
        time.sleep(0.5)
        send_cmd(s, {'command': 'componentstate', 'componentstate': {'component': 'LEDDEVICE', 'state': True}, 'tan': 2})
        time.sleep(0.5)

s.close()
print("[enable-leds] LEDDEVICE enabled on all instances")
PYEOF
```

```bash
sudo chmod +x /etc/hyperhdr/enable-leds.sh
```

> **Note:** Adjust the `range(4)` if you have a different number of HyperHDR instances.

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
during the initial boot setup run.

The `ExecStart` calls the relay helper script (Step 6) which auto-detects the
current framerate from the TC358743 DV timings — so it works at 24, 50, or 60 fps
without any manual changes. The `ExecStartPost` similarly sets v4l2loopback's
advertised framerate to match (without this, v4l2loopback defaults to 30 fps and
HyperHDR will only capture at 30 fps).

`KillSignal=SIGKILL` is intentional: ffmpeg blocks on V4L2 reads and ignores
SIGTERM when the HDMI signal is in flux, which would stall service restarts and
leave the loopback device in a broken state.

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
ExecStart=/etc/hyperhdr/tc358743-relay.sh
ExecStartPost=/etc/hyperhdr/tc358743-set-loopback-fps.sh
KillSignal=SIGKILL
TimeoutStopSec=5
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### 7c. HyperHDR drop-in — dependency, readiness wait, and LEDDEVICE auto-enable

Ensures HyperHDR starts only after video10 is fully initialized by ffmpeg.
Without this, HyperHDR may enumerate video10 before ffmpeg has set it up as a
`Video Capture` device and fall back to a different device.

The `ExecStartPost` calls `enable-leds.sh` (Step 6) which waits for HyperHDR's
JSON API to be fully initialized and then enables LEDDEVICE on all instances.
This is needed because HyperHDR does not persist the LEDDEVICE component state
across restarts — all instances start with LEDDEVICE=OFF, which also prevents
the video grabber from producing frames.

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
ExecStartPost=/etc/hyperhdr/enable-leds.sh
```

> **Note:** You cannot add `ExecStartPre=systemctl restart tc358743-relay.service`
> here because the relay has `Before=hyperhdr@pi.service`, creating a circular
> dependency.  Instead, the monitor/watchdog service (Step 7d) handles relay
> restarts using the 3-step sequence: stop HyperHDR → restart relay → start
> HyperHDR.

### 7d. HDMI source-change monitor + watchdog service

This service combines two recovery mechanisms:

1. **Source-change listener:** A background V4L2 `source_change` event listener
   detects when the HDMI source switches refresh rate (e.g. Fire TV: 60 fps menus →
   24 fps movies → 50 fps PAL content).
2. **Periodic watchdog:** Every 15 seconds, queries HyperHDR's JSON API to check
   that VIDEOGRABBER is `active=True` and LEDDEVICE is ON. After 2 consecutive
   failures, triggers the 3-step restart.
3. **Color space check:** Reads the TC358743 `--log-status` to verify the HDMI
   source is sending YCbCr (not RGB). If RGB is detected, it toggles HPD by
   clearing and reloading the EDID, forcing the source to re-read the CEA-861
   extension and switch to YCbCr.

Both recovery paths use the same 3-step sequence:
`stop HyperHDR → restart relay (fresh ffmpeg) → start HyperHDR`

This avoids the systemd circular dependency (the relay service has
`Before=hyperhdr@pi.service`, so `systemctl restart hyperhdr` alone cannot
restart the relay as an `ExecStartPre`).

**`/etc/hyperhdr/tc358743-monitor.sh`**

```bash
#!/usr/bin/env bash
# Monitor TC358743 for HDMI source changes AND watchdog HyperHDR's grabber.
#
# Three recovery mechanisms:
# 1. V4L2 source_change events (HDMI refresh rate switch)
# 2. Periodic watchdog: checks VIDEOGRABBER active + LEDDEVICE ON via JSON API
# 3. Color space check: detects RGB input and forces YCbCr via EDID HPD toggle
#
# Recovery uses the 3-step sequence that avoids systemd circular dependencies:
#   stop HyperHDR → restart relay (fresh ffmpeg) → start HyperHDR

set -uo pipefail

LOG_TAG="tc358743-monitor"
SETTLE_TIME=3
MIN_RESTART_GAP=30      # minimum seconds between restarts
WATCHDOG_INTERVAL=15    # seconds between grabber health checks
WATCHDOG_FAIL_COUNT=2   # consecutive failures before triggering restart
API_PORT=19444
EDID_FILE="/etc/hyperhdr/tc358743-edid.bin"

log() { echo "[$LOG_TAG] $*"; }

find_subdev() {
    for m in /dev/media*; do
        local drv
        drv=$(media-ctl -d "$m" --print-topology 2>/dev/null \
              | grep "^driver " | head -1 | awk '{print $2}')
        if [[ "$drv" == "rp1-cfe" ]]; then
            local sd
            sd=$(media-ctl -d "$m" -e "tc358743 11-000f" 2>/dev/null || true)
            [[ -n "$sd" && -c "$sd" ]] && { echo "$sd"; return 0; }
        fi
    done
    return 1
}

check_grabber_healthy() {
    python3 -c "
import socket, json, sys
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(('127.0.0.1', $API_PORT))
    s.sendall(json.dumps({'command':'serverinfo','tan':1}).encode() + b'\n')
    data = b''
    while b'\n' not in data:
        chunk = s.recv(4096)
        if not chunk: break
        data += chunk
    r = json.loads(data.split(b'\n')[0])
    s.close()
    comps = {c['name']: c['enabled'] for c in r.get('info',{}).get('components',[])}
    pris = r.get('info',{}).get('priorities',[])
    grab = [p for p in pris if p.get('componentId') == 'VIDEOGRABBER']
    grab_active = grab[0].get('active', False) if grab else False
    led_on = comps.get('LEDDEVICE', False)
    if grab_active and led_on:
        sys.exit(0)
    else:
        print(f'LEDDEVICE={led_on} GRAB_active={grab_active}')
        sys.exit(1)
except Exception as e:
    print(f'API error: {e}')
    sys.exit(2)
" 2>&1
}

# Check if the HDMI source is sending RGB instead of YCbCr.
# Returns 0 if color space is OK (YCbCr), 1 if wrong (RGB), 2 if unknown.
check_color_space() {
    local status
    status=$(v4l2-ctl -d "$SUBDEV" --log-status 2>&1)
    local input_cs
    input_cs=$(echo "$status" | grep "Input color space:" | sed 's/.*Input color space: //')
    if [[ -z "$input_cs" ]]; then
        return 2
    elif [[ "$input_cs" == *"RGB"* ]]; then
        log "Wrong color space detected: $input_cs (expected YCbCr)"
        return 1
    else
        return 0
    fi
}

# Toggle HPD by clearing and reloading the EDID, forcing the source to
# re-read our CEA-861 extension which advertises YCbCr support.
fix_color_space() {
    log "Fixing color space: HPD toggle (clear EDID → wait 5s → reload EDID)..."
    systemctl stop hyperhdr@pi.service 2>&1 || true
    systemctl stop tc358743-relay.service 2>&1 || true
    v4l2-ctl -d "$SUBDEV" --clear-edid 2>&1 || true
    sleep 5
    v4l2-ctl -d "$SUBDEV" --set-edid=file="$EDID_FILE",format=raw 2>&1 || true
    log "EDID reloaded — waiting 8s for source to renegotiate..."
    sleep 8
    v4l2-ctl -d "$SUBDEV" --set-dv-bt-timings query 2>&1 || true
    sleep 2
    # Verify
    local new_cs
    new_cs=$(v4l2-ctl -d "$SUBDEV" --log-status 2>&1 | grep "Input color space:" | sed 's/.*Input color space: //')
    log "Color space after fix: $new_cs"
    # Restart relay + HyperHDR
    log "Restarting relay + HyperHDR..."
    systemctl restart tc358743-relay.service 2>&1 || log "WARNING: relay restart failed!"
    sleep 3
    systemctl start hyperhdr@pi.service 2>&1 || log "WARNING: HyperHDR start failed!"
    LAST_RESTART=$(date +%s)
    FAIL_COUNT=0
    log "Color space fix complete."
}

# 3-step restart: stop HyperHDR → restart relay → start HyperHDR
# This avoids the systemd circular dependency (relay has Before=hyperhdr)
# and ensures HyperHDR always gets a fresh v4l2loopback device.
do_restart() {
    local reason="$1"
    log "$reason"
    log "Step 1/3: stopping hyperhdr@pi.service..."
    systemctl stop hyperhdr@pi.service 2>&1 || true
    log "Step 2/3: restarting tc358743-relay.service (fresh ffmpeg)..."
    systemctl restart tc358743-relay.service 2>&1 || log "WARNING: relay restart failed!"
    sleep 3
    log "Step 3/3: starting hyperhdr@pi.service..."
    systemctl start hyperhdr@pi.service 2>&1 || log "WARNING: HyperHDR start failed!"
    LAST_RESTART=$(date +%s)
    FAIL_COUNT=0
    log "Restart complete."
}

SUBDEV=$(find_subdev) || { log "TC358743 subdev not found, exiting."; exit 1; }
log "Monitoring $SUBDEV + watchdog (interval=${WATCHDOG_INTERVAL}s, threshold=${WATCHDOG_FAIL_COUNT})"

LAST_RESTART=0
FAIL_COUNT=0
EVENT_FLAG="/tmp/tc358743-source-change"
rm -f "$EVENT_FLAG"

# Background: listen for V4L2 source_change events and touch a flag file
(
    while true; do
        v4l2-ctl -d "$SUBDEV" --wait-for-event=source_change \
                               --poll-for-event=source_change 2>/dev/null
        touch "$EVENT_FLAG"
    done
) &
EVENT_PID=$!
trap "kill $EVENT_PID 2>/dev/null; exit 0" EXIT TERM INT

# Initial grace period: let HyperHDR finish starting
sleep 30

# Initial color space check after grace period
if check_color_space; then
    log "Initial color space OK"
else
    RC=$?
    if [[ $RC -eq 1 ]]; then
        fix_color_space
        sleep 20
    fi
fi

while true; do
    # Check for source_change event
    if [[ -f "$EVENT_FLAG" ]]; then
        rm -f "$EVENT_FLAG"
        NOW=$(date +%s)
        ELAPSED=$(( NOW - LAST_RESTART ))
        if (( ELAPSED >= MIN_RESTART_GAP )); then
            log "Source change detected — waiting ${SETTLE_TIME}s..."
            sleep "$SETTLE_TIME"
            TMP=$(v4l2-ctl -d "$SUBDEV" --query-dv-timings 2>/dev/null || true)
            W=$(echo "$TMP" | grep "Active width"  | grep -o '[0-9]*' | head -1)
            H=$(echo "$TMP" | grep "Active height" | grep -o '[0-9]*' | head -1)
            FPS=$(echo "$TMP" | grep -oP '\(\K[0-9.]+(?= frames)' || echo "?")
            if [[ -n "$W" && -n "$H" ]]; then
                # After source change, check color space too
                if check_color_space; then
                    do_restart "Source change: ${W}x${H} @ ${FPS}fps"
                else
                    RC=$?
                    if [[ $RC -eq 1 ]]; then
                        log "Source change: ${W}x${H} @ ${FPS}fps — AND wrong color space"
                        fix_color_space
                    else
                        do_restart "Source change: ${W}x${H} @ ${FPS}fps"
                    fi
                fi
                sleep 20
                continue
            else
                log "No signal after source change — will retry."
            fi
        else
            log "Ignoring source_change (${ELAPSED}s < ${MIN_RESTART_GAP}s since last restart)"
        fi
    fi

    # Watchdog: check grabber health
    RESULT=$(check_grabber_healthy)
    RC=$?
    if [[ $RC -eq 0 ]]; then
        FAIL_COUNT=0
        # Periodic color space check (only when grabber is healthy)
        if ! check_color_space; then
            CS_RC=$?
            if [[ $CS_RC -eq 1 ]]; then
                NOW=$(date +%s)
                ELAPSED=$(( NOW - LAST_RESTART ))
                if (( ELAPSED >= MIN_RESTART_GAP )); then
                    fix_color_space
                    sleep 20
                    continue
                else
                    log "Wrong color space but too soon to fix (${ELAPSED}s < ${MIN_RESTART_GAP}s)"
                fi
            fi
        fi
    elif [[ $RC -eq 2 ]]; then
        # API not reachable — HyperHDR might be down or restarting
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        log "Watchdog: API not reachable — failure ${FAIL_COUNT}/${WATCHDOG_FAIL_COUNT}"
        if (( FAIL_COUNT >= WATCHDOG_FAIL_COUNT )); then
            NOW=$(date +%s)
            ELAPSED=$(( NOW - LAST_RESTART ))
            if (( ELAPSED >= MIN_RESTART_GAP )); then
                do_restart "Watchdog: HyperHDR unreachable for ${FAIL_COUNT} consecutive checks"
                sleep 20
                FAIL_COUNT=0
                continue
            else
                log "Watchdog: too soon to restart (${ELAPSED}s < ${MIN_RESTART_GAP}s)"
            fi
        fi
    else
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        log "Watchdog: unhealthy ($RESULT) — failure ${FAIL_COUNT}/${WATCHDOG_FAIL_COUNT}"
        if (( FAIL_COUNT >= WATCHDOG_FAIL_COUNT )); then
            NOW=$(date +%s)
            ELAPSED=$(( NOW - LAST_RESTART ))
            if (( ELAPSED >= MIN_RESTART_GAP )); then
                do_restart "Watchdog: grabber stuck for ${FAIL_COUNT} consecutive checks"
                sleep 20
                FAIL_COUNT=0
                continue
            else
                log "Watchdog: too soon to restart (${ELAPSED}s < ${MIN_RESTART_GAP}s)"
            fi
        fi
    fi

    sleep "$WATCHDOG_INTERVAL"
done
```

```bash
sudo chmod +x /etc/hyperhdr/tc358743-monitor.sh
```

**`/etc/systemd/system/tc358743-monitor.service`**

> **Important:** The monitor must **not** have `Requires=tc358743-relay.service`.
> During the 3-step restart, the monitor restarts the relay (Step 2/3).  If it had
> `Requires`, systemd would kill the monitor itself when the relay restarts, so
> Step 3 (start HyperHDR) would never execute.  Use `After=` only so the monitor
> survives relay restarts.  `Restart=always` ensures it comes back even if killed
> for any other reason.

```ini
[Unit]
Description=TC358743 HDMI source-change monitor + watchdog (auto-recovers grabber)
After=tc358743-relay.service

[Service]
Type=simple
ExecStart=/etc/hyperhdr/tc358743-monitor.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### 7e. Enable all services

```bash
sudo systemctl daemon-reload
sudo systemctl enable tc358743-setup.service
sudo systemctl enable tc358743-relay.service
sudo systemctl enable tc358743-monitor.service
sudo systemctl enable hyperhdr@pi.service
```

---

## Step 8 — HyperHDR database configuration

After the first HyperHDR start the SQLite database is created at
`/home/pi/.hyperhdr/db/hyperhdr.db`. Configure it while the service is stopped:

```bash
sudo systemctl stop hyperhdr@pi.service

DB="/home/pi/.hyperhdr/db/hyperhdr.db"

# Video grabber: use video10, UYVY encoding, auto-detect fps, HDR tone mapping on
# fps=0 means "use whatever the device reports" — this lets the dynamic relay
# scripts (Step 6) control the actual framerate without a DB change.
sqlite3 "$DB" "UPDATE settings SET config = json_patch(config, '{
  \"device\": \"TC358743-Capture (video10)\",
  \"videoEncoding\": \"UYVY\",
  \"fps\": 0,
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
systemctl status tc358743-setup.service tc358743-relay.service tc358743-monitor.service hyperhdr@pi.service

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

### Purple/magenta tint on LED output
The HDMI source (e.g. Fire TV) is sending **RGB** instead of **YCbCr**.  The
TC358743 converts RGB→UYVY using BT.601 coefficients, but 1080p content expects
BT.709 — this matrix mismatch causes a purple overlay.

The EDID (Step 5) includes a CEA-861 extension that advertises YCbCr support and
an HDMI VSDB, which tells the source to use YCbCr.  The monitor/watchdog (Step 7d)
automatically detects RGB input and toggles HPD to force the source to re-read
the EDID.  Check the current input color space:
```bash
v4l2-ctl -d /dev/v4l-subdev2 --log-status 2>&1 | grep "Input color space"
# Expected: "YCbCr 709 limited range" (NOT "RGB limited range")
```
If it says RGB, the monitor will fix it within 30 seconds.  To fix manually:
```bash
sudo v4l2-ctl -d /dev/v4l-subdev2 --clear-edid
sleep 5
sudo v4l2-ctl -d /dev/v4l-subdev2 --set-edid=file=/etc/hyperhdr/tc358743-edid.bin,format=raw
```

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

### HyperHDR shows "no signal" after HDMI source changes refresh rate
The HDMI source (e.g. Fire TV) switched from 60 fps to 24 fps or vice versa.
The `tc358743-monitor.service` handles this automatically — check it is running:
```bash
systemctl status tc358743-monitor.service
journalctl -u tc358743-monitor.service -n 20
```
If HyperHDR still shows no signal, the old ffmpeg process may have gotten stuck.
Restart the entire pipeline:
```bash
sudo systemctl restart tc358743-relay.service
sleep 5
sudo systemctl restart hyperhdr@pi.service
```
The relay service uses `KillSignal=SIGKILL` to prevent ffmpeg from hanging on
stale V4L2 reads during signal transitions.

### LEDDEVICE=OFF / LEDs not turning on after restart
HyperHDR does not persist the LEDDEVICE component state — every restart begins
with LEDDEVICE=OFF on all instances. The `enable-leds.sh` script (called by
`ExecStartPost` in the drop-in, Step 7c) handles this automatically.

Important: HyperHDR's API accepts connections and returns `success: true` for
`componentstate` commands **before** instance backends have finished initializing.
Commands sent during this window are silently ignored. If you write your own
enable script, you must wait until the `LEDDEVICE` component appears in
`serverinfo` **and** add an extra settling delay (≥ 5 s) before sending enables.

To check the current state:
```bash
python3 -c "
import socket, json
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(('127.0.0.1', 19444))
s.sendall(json.dumps({'command':'serverinfo','tan':1}).encode() + b'\n')
data = b''
while b'\n' not in data: data += s.recv(4096)
r = json.loads(data.split(b'\n')[0])
for c in r['info']['components']: print(f\"  {c['name']}: {'ON' if c['enabled'] else 'OFF'}\")
for p in r['info']['priorities']: print(f\"  priority {p['priority']}: {p.get('componentId','?')} active={p.get('active')}\")
s.close()
"
```

### VIDEOGRABBER active=False (grabber stuck)
If VIDEOGRABBER shows as ON but `active=False`, the capture thread failed to
start V4L2 streaming. This happens when HyperHDR opens a stale v4l2loopback
device (e.g. from a previous ffmpeg that was killed).

The monitor/watchdog service (Step 7d) detects this automatically and performs
the 3-step recovery. If you need to recover manually:
```bash
sudo systemctl stop hyperhdr@pi.service
sudo systemctl restart tc358743-relay.service
sleep 3
sudo systemctl start hyperhdr@pi.service
```
You cannot use a single `systemctl restart hyperhdr@pi.service` with a relay
restart in `ExecStartPre` because the relay has `Before=hyperhdr@pi.service`,
creating a circular systemd dependency.

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
    │  ffmpeg relay (tc358743-relay.sh → auto-detects fps)
    ▼
/dev/video10  (v4l2loopback "TC358743-Capture", clean capture device)
    │  V4L2, UYVY 1920×1080 @ dynamic fps (24/50/60)
    ▼
HyperHDR  (hyperhdr@pi.service)
    │  HDR→SDR tone mapping via LUT
    │  LED zone sampling
    ▼
WLED  (UDP DRGB)
    │
    ▼
LED strip

tc358743-monitor.sh
    │  Listens for V4L2 source_change events
    │  Watchdog: polls JSON API every 15s (VIDEOGRABBER + LEDDEVICE)
    │  Color space check: detects RGB → HPD toggle to force YCbCr
    │  On failure → 3-step restart: stop HyperHDR → restart relay → start HyperHDR
```

---

## Appendix — VS Code remote development on `/`

If you connect to the Pi via VS Code Remote-SSH and open the workspace at `/`,
VS Code's file indexer (ripgrep) will try to scan the entire filesystem — including
`/proc`, `/sys`, and `/dev` — pegging all CPU cores indefinitely.

Create a settings file to exclude virtual and system directories:

**`/.vscode/settings.json`**
```json
{
  "files.exclude": {
    "**/proc": true,
    "**/sys": true,
    "**/dev": true,
    "**/run": true,
    "**/snap": true,
    "**/lost+found": true
  },
  "search.exclude": {
    "**/proc": true,
    "**/sys": true,
    "**/dev": true,
    "**/run": true,
    "**/usr": true,
    "**/var": true,
    "**/snap": true,
    "**/boot": true,
    "**/lost+found": true,
    "**/node_modules": true
  }
}
```

This keeps `/home`, `/etc`, and `/opt` visible and searchable while preventing
runaway CPU usage from indexing pseudo-filesystems.
