#!/usr/bin/env python3
"""Disable the HDMI capture on all instances while the PC's HyperHDR is online.

The PC forwards its screen over Flatbuffers, which only sends on screen change and
can drop/reconnect on Wi-Fi. Whenever the stream briefly disappears, HyperHDR falls
back to the Fire TV capture. This service keeps VIDEOGRABBER off for as long as the
PC is online, and re-enables it once the PC has been unreachable for a while.
"""
import json
import os
import re
import socket
import time

PC = ("192.168.178.56", 19444)
SECRETS = "/home/pi/secrets.yaml"   # HYPER_HDR_PC_TOKEN
API = ("127.0.0.1", 19444)
FLAG = "/tmp/pc-online"        # read by tc358743-monitor.sh
INSTANCES = range(5)
INTERVAL = 5
OFFLINE_AFTER = 3              # failed probes in a row before the capture is re-enabled


def rpc(f, cmd, want):
    f.write(json.dumps(cmd) + "\n")
    f.flush()
    while True:
        line = f.readline()
        if not line:
            raise ConnectionError("closed")
        r = json.loads(line)
        if r.get("command") == want:
            return r


def pc_token():
    m = re.search(r"^\s*HYPER_HDR_PC_TOKEN\s*:\s*[\"']?([^\"'\s#]+)", open(SECRETS).read(), re.M)
    return m.group(1)


def pc_online():
    try:
        s = socket.create_connection(PC, timeout=2)
        s.settimeout(3)
        f = s.makefile("rw")
        rpc(f, {"command": "authorize", "subcommand": "login", "token": pc_token(), "tan": 1}, "authorize-login")
        info = rpc(f, {"command": "serverinfo", "tan": 2}, "serverinfo")["info"]
        s.close()
        return any(c["name"] == "GRABBER" and c["enabled"] for c in info["components"])
    except (OSError, ValueError, KeyError, AttributeError):
        return False


def apply_capture(enabled):
    s = socket.create_connection(API, timeout=3)
    s.settimeout(5)
    f = s.makefile("rw")
    for i in INSTANCES:
        rpc(f, {"command": "instance", "subcommand": "switchTo", "instance": i, "tan": 1}, "instance-switchTo")
        info = rpc(f, {"command": "serverinfo", "tan": 2}, "serverinfo")["info"]
        cur = {c["name"]: c["enabled"] for c in info["components"]}.get("VIDEOGRABBER")
        if cur is not None and cur != enabled:
            rpc(f, {"command": "componentstate",
                    "componentstate": {"component": "VIDEOGRABBER", "state": enabled}, "tan": 3},
                "componentstate")
            print(f"instance {i}: VIDEOGRABBER -> {enabled}", flush=True)
    s.close()


def main():
    online, fails = False, 0
    while True:
        if pc_online():
            if not online:
                print("PC online: capture off", flush=True)
            online, fails = True, 0
        else:
            fails += 1
            if online and fails >= OFFLINE_AFTER:
                online = False
                print("PC offline: capture on", flush=True)
        if online:
            open(FLAG, "w").close()
        elif os.path.exists(FLAG):
            os.remove(FLAG)
        try:
            apply_capture(not online)
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
