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

This script generates **two** valid 256-byte EDIDs that the TC358743 presents
to the HDMI source.  Block 0 advertises 1920×1080 @ 60 Hz.  Block 1 is a CEA-861
extension with an HDMI Vendor Specific Data Block:

- **`tc358743-edid.bin`** — YCbCr 4:2:2 + 4:4:4 support (encourages YCbCr output)
- **`tc358743-edid-rgb.bin`** — RGB only, but still HDMI (not DVI)

Both include an HDMI VSDB so sources treat the TC358743 as an HDMI sink, not DVI.
The primary EDID (`tc358743-edid.bin`) is loaded at boot.  The RGB variant exists
as a fallback if a source refuses to send YCbCr.

```python
#!/usr/bin/env python3
"""
Generate 256-byte EDIDs for the TC358743 HDMI-to-CSI bridge.

Produces TWO EDID files:
  1. tc358743-edid.bin       - CEA-861 with YCbCr 4:2:2 + 4:4:4 + HDMI VSDB
  2. tc358743-edid-rgb.bin   - CEA-861 with HDMI VSDB but RGB-only (no YCbCr)

Both have the same Block 0 (1080p60 preferred) and Block 1 CEA extension
with HDMI Vendor Specific Data Block (so source treats us as HDMI, not DVI).
The YCbCr variant encourages sources to send YCbCr; the RGB variant accepts
RGB from sources that insist on it.

The relay script (tc358743-relay.sh) automatically applies BT.601->BT.709
color correction when the source sends RGB, so both EDIDs produce correct
colors.
"""
import os, sys

os.makedirs('/etc/hyperhdr', exist_ok=True)

def checksum(block):
    """Calculate EDID block checksum (makes sum of all 128 bytes = 0 mod 256)."""
    return (256 - sum(block[:127]) % 256) % 256

# --- Block 0: Base EDID -----------------------------------------------------
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
    # Established timings (3) - none
    0x00, 0x00, 0x00,
    # Standard timing IDs (16) - all unused
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    # DTD1: 1920x1080 @ 60 Hz (148.5 MHz) - preferred timing (18 bytes)
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

# --- Block 1: CEA-861 Extension (shared data blocks) ------------------------
# Video Data Block (VDB) - tag 2
svds = [
    0x90,  # 16 | 0x80 = 1080p60 (native)
    0x1F,  # 31 = 1080p50
    0x20,  # 32 = 1080p24
    0x21,  # 33 = 1080p25
    0x22,  # 34 = 1080p30
    0x04,  #  4 = 720p60
    0x13,  # 19 = 720p50
]
vdb = bytearray([(0x02 << 5) | len(svds)] + svds)

# Audio Data Block (ADB) - tag 1: PCM stereo, 32/44.1/48 kHz, 16-bit
adb = bytearray([(0x01 << 5) | 3, 0x09, 0x07, 0x01])

# HDMI Vendor Specific Data Block (VSDB) - tag 3
# IEEE OUI 00-0C-03 (HDMI Licensing), physical address 1.0.0.0
vsdb = bytearray([(0x03 << 5) | 5, 0x03, 0x0C, 0x00, 0x10, 0x00])

data_blocks = vdb + adb + vsdb

def make_cea_block(ycbcr_flags):
    """Build a 128-byte CEA-861 block.
    ycbcr_flags: 0x00 = RGB only, 0x30 = YCbCr 4:4:4 + 4:2:2
    """
    dtd_offset = 4 + len(data_blocks)
    cea_header = bytearray([0x02, 0x03, dtd_offset, ycbcr_flags])
    blk = cea_header + data_blocks
    blk += bytearray(127 - len(blk))
    assert len(blk) == 127
    blk.append(0x00)
    blk[127] = checksum(blk)
    assert len(blk) == 128 and sum(blk) % 256 == 0
    return blk

# --- Generate both EDIDs ----------------------------------------------------
variants = [
    ('tc358743-edid.bin',     0x30, 'YCbCr 4:4:4 + 4:2:2'),
    ('tc358743-edid-rgb.bin', 0x00, 'RGB only'),
]

for filename, flags, desc in variants:
    block1 = make_cea_block(flags)
    edid = bytes(block0 + block1)
    assert len(edid) == 256
    out_path = f'/etc/hyperhdr/{filename}'
    with open(out_path, 'wb') as f:
        f.write(edid)
    print(f"EDID written: {out_path}  ({len(edid)} bytes)")
    print(f"  Block 0 checksum: 0x{block0[127]:02X}")
    print(f"  Block 1 checksum: 0x{block1[127]:02X}")
    print(f"  CEA flags: {desc}, HDMI VSDB, {len(svds)} video codes")
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
# We request colorspace:rec709 but the TC358743 driver hardcodes smpte170m
# regardless — this is harmless; the actual YUV→RGB conversion is handled
# by HyperHDR's LUT table (see Step 8 for disabling HDR tone mapping).
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

# 12. Detect and record initial input color space for the relay
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

The relay has two modes based on the color space state file (`/tmp/tc358743-colorspace`):

- **YCbCr input** (default): `-vcodec copy` passthrough, ~9% CPU. HyperHDR's
  LUT table handles UYVY→RGB conversion directly.
- **RGB input**: The TC358743 hardware converts RGB→UYVY using BT.601
  coefficients, but 1080p content uses BT.709. The relay applies
  `scale=480:270,colormatrix=bt601:bt709,scale=1920:1080` to fix the color
  matrix. The downscale-upscale keeps CPU usage manageable (~15% vs ~92% at
  full resolution).

**`/etc/hyperhdr/tc358743-relay.sh`**

```bash
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

# Read color space from state file (written by setup/monitor scripts)
CS=$(cat /tmp/tc358743-colorspace 2>/dev/null || echo "unknown")

if [[ "$CS" == "rgb" ]]; then
    # RGB input: TC358743 hardware converts RGB→UYVY using BT.601 coefficients,
    # but HyperHDR's LUT expects BT.709 YUV. Scale down to reduce CPU, apply
    # colormatrix correction, then scale back to 1080p for the loopback device.
    log "RGB input (${FPS}fps) — applying BT.601→BT.709 color correction"
    exec /usr/bin/ffmpeg \
        -f v4l2 -input_format uyvy422 -video_size 1920x1080 -framerate "$FPS" \
        -i /dev/video0 \
        -vf "scale=480:270,colormatrix=bt601:bt709,scale=1920:1080" \
        -pix_fmt uyvy422 \
        -f v4l2 /dev/video10
else
    # YCbCr input: passthrough — TC358743 keeps native YCbCr encoding,
    # HyperHDR's LUT handles it directly (SDR table 2 or HDR table 1).
    log "YCbCr input (${FPS}fps) — copy mode"
    exec /usr/bin/ffmpeg \
        -f v4l2 -input_format uyvy422 -video_size 1920x1080 -framerate "$FPS" \
        -i /dev/video0 \
        -vcodec copy \
        -f v4l2 /dev/video10
fi
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

This service combines five adaptation mechanisms:

1. **Source-change listener:** A background V4L2 `source_change` event listener
   detects when the HDMI source switches refresh rate (e.g. Fire TV: 60 fps menus →
   24 fps movies → 50 fps PAL content).
2. **Periodic watchdog:** Every 15 seconds, queries HyperHDR's JSON API to check
   that VIDEOGRABBER is `active=True` and LEDDEVICE is ON. After 2 consecutive
   failures, triggers the 3-step restart.
3. **Color space monitor:** Reads the TC358743 `--log-status` to detect whether
   the HDMI source is sending RGB or YCbCr. If the color space changes, it updates
   `/tmp/tc358743-colorspace` and triggers a relay restart so ffmpeg uses the
   correct pipeline (copy for YCbCr, colormatrix for RGB).
4. **HDR monitor:** Detects BT.2020 colorimetry in the AVI InfoFrame, which
   indicates HDR/WCG content (HDR10, HLG). Toggles HyperHDR's `hdrToneMapping`
   via the JSON API to select the correct LUT table — **no service restart needed**.
   - SDR signal (ITU709) → `HDR=0` → Table 2 (SDR YUV): passthrough
   - HDR signal (BT.2020) → `HDR=1` → Table 1 (HDR YUV): PQ/HLG→SDR tone mapping
5. **Streaming guard:** Before executing a 3-step restart, checks whether a network
   streaming client is connected to HyperHDR's Flatbuffers port (19400). If a
   connection is active, the restart is **deferred** — the reason is queued in
   `RESTART_PENDING` and the restart executes automatically on the next watchdog
   cycle after all streaming clients disconnect. This prevents ambilight LED
   interruptions while another application (e.g. Home Assistant, a second HyperHDR
   instance) is receiving the frame stream.

Color space and source changes use the 3-step restart sequence:
`stop HyperHDR → restart relay (fresh ffmpeg) → start HyperHDR`
HDR toggling is instant (API call only) and does not require a restart.
Restarts are deferred while streaming clients are connected (mechanism 5).

This avoids the systemd circular dependency (the relay service has
`Before=hyperhdr@pi.service`, so `systemctl restart hyperhdr` alone cannot
restart the relay as an `ExecStartPre`).

**`/etc/hyperhdr/tc358743-monitor.sh`**

The full script is shown below. Key implementation details:

- `get_signal_status()` calls `--log-status` once per cycle; both `detect_color_space()`
  and `detect_hdr()` reuse the cached output to avoid duplicate kernel calls.
- `detect_hdr()` greps for `BT.2020` in the AVI InfoFrame — HDR10 and HLG both use
  BT.2020 colorimetry, while SDR uses ITU709.
- `set_hyperhdr_hdr_mode()` sends `{"command":"videomodehdr","HDR":0|1}` via raw
  TCP to port 19444 — this toggles the LUT table instantly without restarting.
- After a 3-step restart, `do_restart()` waits 5 seconds for HyperHDR to initialize,
  then re-checks the HDR state and toggles if needed (since the DB defaults to SDR).
- `is_streaming_active()` uses `ss` to check for ESTABLISHED TCP connections on
  HyperHDR's Flatbuffers port (19400). `try_restart()` wraps `do_restart()` — if
  streaming is active, the restart reason is saved in `RESTART_PENDING` and the
  main loop re-checks every watchdog cycle until clients disconnect.

```bash
#!/usr/bin/env bash
# Monitor TC358743 for HDMI source changes AND watchdog HyperHDR's grabber.
#
# Five recovery/adaptation mechanisms:
# 1. V4L2 source_change events (HDMI resolution/refresh rate switch)
# 2. Periodic watchdog: checks VIDEOGRABBER active + LEDDEVICE ON via JSON API
# 3. Color space monitor: detects RGB/YCbCr input, updates state file,
#    restarts relay with correct ffmpeg pipeline (color correction for RGB)
# 4. HDR monitor: detects BT.2020 colorimetry in AVI InfoFrame, toggles
#    HyperHDR's hdrToneMapping via JSON API (selects correct LUT table,
#    no restart needed)
# 5. Streaming guard: defers 3-step restarts while a network streaming client
#    is connected to HyperHDR's Flatbuffers port (19400). The restart is
#    queued and executed once the streaming session ends.
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
STREAMING_PORT=19400    # HyperHDR Flatbuffers server port
CS_FILE="/tmp/tc358743-colorspace"
HDR_STATE="unknown"     # tracks current HyperHDR HDR mode; "unknown" forces first sync
RESTART_PENDING=""      # non-empty = reason for deferred restart

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

# Check whether a network streaming client is connected to HyperHDR's
# Flatbuffers port.  Returns 0 (true) if at least one ESTABLISHED TCP
# connection exists on STREAMING_PORT, 1 (false) otherwise.
is_streaming_active() {
    local conns
    conns=$(ss -tn state established "( sport = :${STREAMING_PORT} )" 2>/dev/null \
            | tail -n +2 | wc -l)
    [[ "$conns" -gt 0 ]]
}

# Wrapper around do_restart() that checks for active streaming first.
# If streaming is active, the restart is deferred (queued) and a message
# is logged.  Returns 0 if restart was executed, 1 if deferred.
try_restart() {
    local reason="$1"
    if is_streaming_active; then
        RESTART_PENDING="$reason"
        log "Restart DEFERRED (streaming active on port $STREAMING_PORT): $reason"
        return 1
    fi
    RESTART_PENDING=""
    do_restart "$reason"
    return 0
}

# Get TC358743 signal status (single kernel call, reuse for CS + HDR detection).
get_signal_status() {
    v4l2-ctl -d "$SUBDEV" --log-status 2>&1
}

# Detect current input color space from TC358743.
# Accepts optional pre-fetched status as $1 to avoid duplicate kernel calls.
# Returns: "rgb", "ycbcr", or "unknown" on stdout.
detect_color_space() {
    local status="${1:-}"
    [[ -z "$status" ]] && status=$(get_signal_status)
    local input_cs
    input_cs=$(echo "$status" | grep "Input color space:" | sed 's/.*Input color space: //')
    if [[ "$input_cs" == *"RGB"* ]]; then
        echo "rgb"
    elif [[ "$input_cs" == *"YCbCr"* ]]; then
        echo "ycbcr"
    else
        echo "unknown"
    fi
}

# Detect HDR from AVI InfoFrame colorimetry.
# BT.2020 colorimetry = HDR/WCG content (HDR10, HLG, etc.)
# Accepts optional pre-fetched status as $1.
# Returns: "hdr" or "sdr" on stdout.
detect_hdr() {
    local status="${1:-}"
    [[ -z "$status" ]] && status=$(get_signal_status)
    if echo "$status" | grep -qiE "BT\.2020|BT2020"; then
        echo "hdr"
    else
        echo "sdr"
    fi
}

# Check color space and restart relay if it changed.
check_and_fix_color_space() {
    local status="${1:-}"
    local live_cs stored_cs
    live_cs=$(detect_color_space "$status")
    stored_cs=$(cat "$CS_FILE" 2>/dev/null || echo "unknown")

    if [[ "$live_cs" == "unknown" ]]; then
        return 0
    fi

    if [[ "$live_cs" != "$stored_cs" ]]; then
        log "Color space changed: $stored_cs -> $live_cs — updating relay"
        echo "$live_cs" > "$CS_FILE"
        return 1  # caller should restart
    fi
    return 0
}

# Toggle HyperHDR HDR tone mapping via JSON API (instant, no restart needed).
# This selects which LUT table is used for UYVY input:
#   HDR=1 → Table 1 (HDR YUV): applies PQ/HLG→SDR tone mapping
#   HDR=0 → Table 2 (SDR YUV): passthrough for SDR content
set_hyperhdr_hdr_mode() {
    local mode="$1"  # "hdr" or "sdr"
    local hdr_val=0
    [[ "$mode" == "hdr" ]] && hdr_val=1
    python3 -c "
import socket, json
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(('127.0.0.1', $API_PORT))
    s.sendall(json.dumps({'command':'videomodehdr','HDR':$hdr_val}).encode() + b'\n')
    data = b''
    while b'\n' not in data:
        chunk = s.recv(4096)
        if not chunk: break
        data += chunk
    s.close()
    r = json.loads(data.split(b'\n')[0])
    print('OK' if r.get('success') else 'FAIL')
except Exception as e:
    print(f'ERROR: {e}')
" 2>&1
}

# Check HDR state and toggle HyperHDR if it changed (API only, no restart).
check_and_fix_hdr() {
    local live_hdr="${1:-sdr}"
    [[ "$live_hdr" == "$HDR_STATE" ]] && return 0
    log "HDR mode changed: $HDR_STATE -> $live_hdr"
    local result
    result=$(set_hyperhdr_hdr_mode "$live_hdr")
    if [[ "$result" == "OK" ]]; then
        HDR_STATE="$live_hdr"
        log "HyperHDR LUT: $([ "$live_hdr" = "hdr" ] && echo "HDR YUV (table 1)" || echo "SDR YUV (table 2)")"
    else
        log "WARNING: Failed to toggle HDR mode: $result"
    fi
}

# 3-step restart: stop HyperHDR → restart relay → start HyperHDR
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

    # After restart, re-sync HDR state with actual signal.
    # Set to "unknown" so check_and_fix_hdr always sends the API command.
    HDR_STATE="unknown"
    sleep 5
    local post_status post_hdr
    post_status=$(get_signal_status)
    post_hdr=$(detect_hdr "$post_status")
    check_and_fix_hdr "$post_hdr"
}

SUBDEV=$(find_subdev) || { log "TC358743 subdev not found, exiting."; exit 1; }
log "Monitoring $SUBDEV + watchdog (interval=${WATCHDOG_INTERVAL}s, threshold=${WATCHDOG_FAIL_COUNT})"
log "Streaming guard: restarts deferred while clients connected on port $STREAMING_PORT"

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

# Initial signal check: color space + HDR
INIT_STATUS=$(get_signal_status)
INIT_CS=$(detect_color_space "$INIT_STATUS")
INIT_HDR=$(detect_hdr "$INIT_STATUS")
STORED_CS=$(cat "$CS_FILE" 2>/dev/null || echo "unknown")

if [[ "$INIT_CS" != "unknown" && "$INIT_CS" != "$STORED_CS" ]]; then
    echo "$INIT_CS" > "$CS_FILE"
    try_restart "Initial color space mismatch ($STORED_CS -> $INIT_CS) — restarting with correct relay"
    [[ -z "$RESTART_PENDING" ]] && sleep 20
else
    log "Initial color space OK ($STORED_CS)"
    check_and_fix_hdr "$INIT_HDR"
fi

while true; do
    # Execute deferred restart if streaming has ended
    if [[ -n "$RESTART_PENDING" ]] && ! is_streaming_active; then
        NOW=$(date +%s)
        ELAPSED=$(( NOW - LAST_RESTART ))
        if (( ELAPSED >= MIN_RESTART_GAP )); then
            log "Streaming ended — executing deferred restart"
            do_restart "$RESTART_PENDING"
            RESTART_PENDING=""
            sleep 20
            continue
        fi
    fi

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
                # Update color space state before restart
                local_status=$(get_signal_status)
                local_cs=$(detect_color_space "$local_status")
                local_hdr=$(detect_hdr "$local_status")
                echo "$local_cs" > "$CS_FILE"
                try_restart "Source change: ${W}x${H} @ ${FPS}fps (color: $local_cs, $local_hdr)"
                [[ -z "$RESTART_PENDING" ]] && sleep 20
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
        # Periodic signal check (only when grabber is healthy)
        WD_STATUS=$(get_signal_status)

        # HDR toggle — API only, no restart needed
        check_and_fix_hdr "$(detect_hdr "$WD_STATUS")"

        # Color space check — may trigger relay restart
        if ! check_and_fix_color_space "$WD_STATUS"; then
            NOW=$(date +%s)
            ELAPSED=$(( NOW - LAST_RESTART ))
            if (( ELAPSED >= MIN_RESTART_GAP )); then
                try_restart "Color space changed — restarting relay with correct pipeline"
                [[ -z "$RESTART_PENDING" ]] && sleep 20
                continue
            else
                log "Color space changed but too soon to restart (${ELAPSED}s < ${MIN_RESTART_GAP}s)"
            fi
        fi
    elif [[ $RC -eq 2 ]]; then
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
`/home/pi/.hyperhdr/db/hyperhdr.db`. Configure it while the service is stopped.

> **Important:** Always `stop` HyperHDR **before** editing the database.
> HyperHDR writes its in-memory config back to the DB on shutdown, so any
> changes made while it is running will be overwritten when it stops.

```bash
sudo systemctl stop hyperhdr@pi.service

DB="/home/pi/.hyperhdr/db/hyperhdr.db"

# Video grabber: use video10, UYVY encoding, auto-detect fps, HDR tone mapping OFF
# fps=0 means "use whatever the device reports" — this lets the dynamic relay
# scripts (Step 6) control the actual framerate without a DB change.
#
# IMPORTANT: hdrToneMapping defaults to false in the DB so HyperHDR starts
# with the SDR YUV LUT (table 2).  The monitor script (Step 7d) automatically
# detects BT.2020 colorimetry (HDR) and toggles hdrToneMapping at runtime
# via the JSON API — no service restart needed.
#
# HyperHDR's 144 MB LUT file (lut_lin_tables.3d) contains 3 tables:
#   Table 0: HDR RGB,  Table 1: HDR YUV,  Table 2: SDR YUV
# hdrToneMapping=false → Table 2 (SDR): BT.709 UYVY→RGB passthrough
# hdrToneMapping=true  → Table 1 (HDR): PQ/HLG→SDR tone mapping
sqlite3 "$DB" "UPDATE settings SET config = json_patch(config, '{
  \"device\": \"TC358743-Capture (video10)\",
  \"videoEncoding\": \"UYVY\",
  \"fps\": 0,
  \"hdrToneMapping\": false,
  \"hdrToneMappingMode\": 0,
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
automatically detects color space changes and restarts the relay.  Check the
current input color space:
```bash
v4l2-ctl -d /dev/v4l-subdev2 --log-status 2>&1 | grep "Input color space"
# Expected: "YCbCr 709 limited range" (NOT "RGB limited range")
```

### Orange appears red / blue is too dark (wrong colors, not purple)
This is caused by HyperHDR using the wrong LUT table for the input signal.
HyperHDR's 144 MB LUT (`lut_lin_tables.3d`) has 3 tables: HDR RGB (index 0),
HDR YUV (index 1), SDR YUV (index 2).

- **SDR content with `hdrToneMapping=true`**: Uses HDR YUV table (index 1) which
  applies HDR-to-SDR tone mapping to already-SDR pixels → orange→red, blue shift.
- **HDR content with `hdrToneMapping=false`**: Uses SDR YUV table (index 2) which
  passes through raw PQ/HLG values → washed-out highlights.

The monitor script (Step 7d) handles this automatically by detecting BT.2020
colorimetry in the AVI InfoFrame and toggling `hdrToneMapping` via the JSON API.
Check the current state:
```bash
journalctl -u tc358743-monitor.service -n 20 | grep -i hdr
```

To manually toggle at runtime:
```python
# Via HyperHDR's raw TCP JSON API (port 19444):
import socket, json
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('127.0.0.1', 19444))
# HDR=0 for SDR content, HDR=1 for HDR content
s.sendall(json.dumps({"command":"videomodehdr","HDR":0}).encode() + b'\n')
s.close()
```

The DB default should be `false` (SDR) — the monitor script enables HDR dynamically:
```bash
sqlite3 /home/pi/.hyperhdr/db/hyperhdr.db \
  "SELECT json_extract(config, '\$.hdrToneMapping'), json_extract(config, '\$.hdrToneMappingMode') FROM settings WHERE type='videoGrabber';"
# Expected: 0|0  (false=SDR default, monitor toggles at runtime)
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
    │  ffmpeg relay (tc358743-relay.sh → auto-detects fps, -vcodec copy)
    ▼
/dev/video10  (v4l2loopback "TC358743-Capture", clean capture device)
    │  V4L2, UYVY 1920×1080 @ dynamic fps (24/50/60)
    ▼
HyperHDR  (hyperhdr@pi.service)
    │  LUT table (auto-selected by monitor script):
    │    SDR signal → Table 2 (SDR YUV, BT.709 passthrough)
    │    HDR signal → Table 1 (HDR YUV, PQ/HLG→SDR tone mapping)
    │  LED zone sampling
    ▼
WLED  (UDP DRGB)
    │
    ▼
LED strip

tc358743-monitor.sh
    │  Listens for V4L2 source_change events
    │  Watchdog: polls JSON API every 15s (VIDEOGRABBER + LEDDEVICE)
    │  Color space monitor: detects RGB↔YCbCr, restarts relay with correct pipeline
    │  HDR monitor: detects BT.2020 colorimetry, toggles LUT table via API (instant)
    │  Streaming guard: defers restarts while Flatbuffers clients connected (port 19400)
    │  On failure → 3-step restart: stop HyperHDR → restart relay → start HyperHDR
```

---

## Appendix — VS Code remote development on `/`

### Prevent runaway CPU from file indexing

If you connect to the Pi via VS Code Remote-SSH and open the workspace at `/`,
VS Code's file indexer (ripgrep) will try to scan the entire filesystem — including
`/proc`, `/sys`, and `/dev` — pegging all CPU cores indefinitely (300%+ CPU for
hours).

Use **machine-level settings** rather than a workspace `/.vscode/settings.json`
(which would require root to create at `/`).  This file applies to all workspaces
on this VS Code Server instance:

**`/home/pi/.vscode-server/data/Machine/settings.json`**
```json
{
  "files.watcherExclude": {
    "/proc/**": true,
    "/sys/**": true,
    "/dev/**": true,
    "/run/**": true,
    "/tmp/**": true,
    "/var/**": true,
    "/snap/**": true,
    "/boot/**": true,
    "/lost+found/**": true,
    "/media/**": true,
    "/mnt/**": true
  },
  "search.exclude": {
    "/proc/**": true,
    "/sys/**": true,
    "/dev/**": true,
    "/run/**": true,
    "/var/**": true,
    "/boot/**": true,
    "/snap/**": true
  },
  "files.exclude": {
    "/proc/**": true,
    "/sys/**": true,
    "/dev/**": true,
    "/run/**": true
  }
}
```

This keeps `/home`, `/etc`, and `/opt` visible and searchable while preventing
runaway CPU usage from indexing pseudo-filesystems.

### Allow VS Code (pi user) to edit root-owned scripts

The scripts in `/etc/hyperhdr/` are owned by `root:root`.  VS Code runs as `pi`,
so edits via the editor silently fail to save (the buffer appears modified but the
on-disk file stays unchanged).  POSIX ACLs grant `pi` write access without changing
ownership:

```bash
sudo apt install -y acl
sudo setfacl -R -m u:pi:rwX /etc/hyperhdr
sudo setfacl -R -d -m u:pi:rwX /etc/hyperhdr
```

- `-R` applies recursively to all existing files
- `-d` sets a **default ACL** so new files created in the directory automatically
  inherit `u:pi:rwX`
- Root still owns everything — no security change for other users

Verify with:
```bash
getfacl /etc/hyperhdr
# Should show: user:pi:rwx  and  default:user:pi:rwx
```

To remove all ACLs later (revert to normal permissions):
```bash
sudo setfacl -R -b /etc/hyperhdr
```
