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

for attempt in range(MAX_WAIT):
    try:
        s = connect()
        r = send_cmd(s, {'command': 'serverinfo', 'tan': 1})
        if r.get('success'):
            comps = r.get('info', {}).get('components', [])
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

time.sleep(5)

try: s.close()
except: pass

s = connect()

for inst in range(4):
    send_cmd(s, {'command': 'instance', 'subcommand': 'switchTo', 'instance': inst, 'tan': 1})
    time.sleep(0.5)
    send_cmd(s, {'command': 'componentstate', 'componentstate': {'component': 'LEDDEVICE', 'state': True}, 'tan': 2})
    time.sleep(0.5)

time.sleep(1)
send_cmd(s, {'command': 'instance', 'subcommand': 'switchTo', 'instance': 0, 'tan': 1})
time.sleep(0.3)
r = send_cmd(s, {'command': 'serverinfo', 'tan': 3})
comps = {c['name']: c['enabled'] for c in r.get('info', {}).get('components', [])}
led_on = comps.get('LEDDEVICE', False)

if not led_on:
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
