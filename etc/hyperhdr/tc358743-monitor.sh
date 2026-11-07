#!/usr/bin/env bash
# Monitor TC358743 for HDMI source changes AND watchdog HyperHDR's grabber.
set -uo pipefail

LOG_TAG="tc358743-monitor"
SETTLE_TIME=3
MIN_RESTART_GAP=30
WATCHDOG_INTERVAL=15
WATCHDOG_FAIL_COUNT=2
SIGNAL_CHECK_EVERY=4   # only run the (expensive, dmesg-spamming) --log-status check every Nth watchdog cycle
API_PORT=19444
STREAMING_PORT=19400
CS_FILE="/tmp/tc358743-colorspace"
PC_FLAG="/tmp/pc-online"       # set by pc-priority.service while the PC stream is active
HDR_STATE="unknown"
RESTART_PENDING=""

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

has_hdmi_signal() {
    local timings
    timings=$(v4l2-ctl -d "$SUBDEV" --query-dv-timings 2>/dev/null || true)
    local w
    w=$(echo "$timings" | grep "Active width" | grep -o '[0-9]*' | head -1)
    [[ -n "$w" && "$w" -gt 0 ]] 2>/dev/null
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
    elif led_on and not grab_active:
        print(f'LEDDEVICE={led_on} GRAB_active={grab_active}')
        sys.exit(3)
    else:
        print(f'LEDDEVICE={led_on} GRAB_active={grab_active}')
        sys.exit(1)
except Exception as e:
    print(f'API error: {e}')
    sys.exit(2)
" 2>&1
}

is_streaming_active() {
    local conns
    conns=$(ss -tn state established "( sport = :${STREAMING_PORT} )" 2>/dev/null \
            | tail -n +2 | wc -l)
    [[ "$conns" -gt 0 ]]
}

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

get_signal_status() {
    v4l2-ctl -d "$SUBDEV" --log-status 2>&1
}

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

detect_hdr() {
    local status="${1:-}"
    [[ -z "$status" ]] && status=$(get_signal_status)
    if echo "$status" | grep -qiE "BT\.2020|BT2020"; then
        echo "hdr"
    else
        echo "sdr"
    fi
}

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
        return 1
    fi
    return 0
}

set_hyperhdr_hdr_mode() {
    local mode="$1"
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
SIGNAL_CHECK_COUNTER=0
EVENT_FLAG="/tmp/tc358743-source-change"
rm -f "$EVENT_FLAG"

(
    while true; do
        v4l2-ctl -d "$SUBDEV" --wait-for-event=source_change \
                               --poll-for-event=source_change 2>/dev/null
        touch "$EVENT_FLAG"
    done
) &
EVENT_PID=$!
trap "kill $EVENT_PID 2>/dev/null; exit 0" EXIT TERM INT

sleep 30

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

    if [[ -f "$EVENT_FLAG" ]]; then
        rm -f "$EVENT_FLAG"
        if [[ -f "$PC_FLAG" ]]; then
            log "Source change ignored (PC stream active, capture disabled)"
            continue
        fi
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

    RESULT=$(check_grabber_healthy)
    RC=$?
    if [[ -f "$PC_FLAG" && $RC -ne 2 ]]; then
        # pc-priority.service keeps the grabber off while the PC streams; that is not a fault
        FAIL_COUNT=0
    elif [[ $RC -eq 0 ]]; then
        FAIL_COUNT=0
        SIGNAL_CHECK_COUNTER=$(( SIGNAL_CHECK_COUNTER + 1 ))
        if (( SIGNAL_CHECK_COUNTER >= SIGNAL_CHECK_EVERY )); then
            SIGNAL_CHECK_COUNTER=0
            WD_STATUS=$(get_signal_status)
            check_and_fix_hdr "$(detect_hdr "$WD_STATUS")"
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
        fi
    elif [[ $RC -eq 2 ]]; then
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        log "Watchdog: API not reachable — failure ${FAIL_COUNT}/${WATCHDOG_FAIL_COUNT}"
        if (( FAIL_COUNT >= WATCHDOG_FAIL_COUNT )); then
            NOW=$(date +%s)
            ELAPSED=$(( NOW - LAST_RESTART ))
            if (( ELAPSED >= MIN_RESTART_GAP )); then
                try_restart "Watchdog: HyperHDR unreachable for ${FAIL_COUNT} consecutive checks"
                [[ -z "$RESTART_PENDING" ]] && sleep 20
                FAIL_COUNT=0
                continue
            else
                log "Watchdog: too soon to restart (${ELAPSED}s < ${MIN_RESTART_GAP}s)"
            fi
        fi
    else
        if has_hdmi_signal; then
            FAIL_COUNT=$(( FAIL_COUNT + 1 ))
            log "Watchdog: unhealthy with HDMI signal ($RESULT) — failure ${FAIL_COUNT}/${WATCHDOG_FAIL_COUNT}"
            if (( FAIL_COUNT >= WATCHDOG_FAIL_COUNT )); then
                NOW=$(date +%s)
                ELAPSED=$(( NOW - LAST_RESTART ))
                if (( ELAPSED >= MIN_RESTART_GAP )); then
                    try_restart "Watchdog: unhealthy for ${FAIL_COUNT} checks despite HDMI signal present"
                    [[ -z "$RESTART_PENDING" ]] && sleep 20
                    FAIL_COUNT=0
                    continue
                else
                    log "Watchdog: too soon to restart (${ELAPSED}s < ${MIN_RESTART_GAP}s)"
                fi
            fi
        else
            if (( FAIL_COUNT > 0 )); then
                FAIL_COUNT=0
            fi
        fi
    fi

    sleep "$WATCHDOG_INTERVAL"
done
