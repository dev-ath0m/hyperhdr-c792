#!/usr/bin/env python3
"""Mirror the Pi's LED instances as UDP-raw "slave" instances on the PC's Hyperion.

The PC computes the LED colours from its screen with the same LED layout as each
Pi instance and sends only the colours (UDP raw) to udp-keepalive.py on the Pi
(port BASE_PORT + instance id), which feeds the Pi's rawUdpServer. Needs
HYPER_HDR_PC_TOKEN in secrets.yaml.

  sync-pc-slaves.py            create/update the slave instances on the PC
  sync-pc-slaves.py --dry-run  show what would be sent
  sync-pc-slaves.py --remove   delete the slave instances from the PC
"""
import argparse
import copy
import json
import re
import socket
import sqlite3

DB = "/home/pi/.config/HyperHDR/db/hyperhdr.db"
SECRETS = "/home/pi/secrets.yaml"
PC = ("192.168.178.56", 19444)
PI_HOST = "192.168.178.8"
BASE_PORT = 5700               # udp-keepalive.py relay port = BASE_PORT + instance id (-> rawUdpServer 5600 + id)
PI_INSTANCES = (1, 2, 3, 4)
PREFIX = "Pi "


class Api:
    def __init__(self):
        token = re.search(r"^\s*HYPER_HDR_PC_TOKEN\s*:\s*[\"']?([^\"'\s#]+)",
                          open(SECRETS).read(), re.M).group(1)
        self.s = socket.create_connection(PC, timeout=5)
        self.s.settimeout(15)
        self.f = self.s.makefile("rw")
        self.tan = 100
        self.call({"command": "authorize", "subcommand": "login", "token": token})

    def call(self, cmd):
        self.tan += 1
        self.f.write(json.dumps({**cmd, "tan": self.tan}) + "\n")
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if r.get("tan") == self.tan:
                break
        if not r.get("success"):
            raise RuntimeError(f"{cmd.get('command')}/{cmd.get('subcommand')}: {r.get('error')} {r.get('errorData')}")
        return r

    def instances(self):
        info = self.call({"command": "serverinfo"})["info"]
        return {i["friendly_name"]: i["instance"] for i in info["instance"]}


def pi_layouts():
    db = sqlite3.connect(DB)
    out = []
    for i in PI_INSTANCES:
        name = db.execute("SELECT friendly_name FROM instances WHERE instance=?", (i,)).fetchone()[0]
        leds = json.loads(db.execute(
            "SELECT config FROM settings WHERE type='leds' AND hyperhdr_instance=?", (i,)).fetchone()[0])
        leds = [{k: v for k, v in led.items() if k in ("hmin", "hmax", "vmin", "vmax")} for led in leds]
        out.append((i, PREFIX + name, leds))
    return out


def neutral_color(base):
    c = copy.deepcopy(base)
    adj = c["channelAdjustment"][0]
    adj.update({
        "brightness": 100, "brightnessCompensation": 0, "brightnessGain": 1,
        "gammaRed": 1.0, "gammaGreen": 1.0, "gammaBlue": 1.0,
        "saturationGain": 1, "backlightThreshold": 0, "backlightColored": False,
        "white": [255, 255, 255], "red": [255, 0, 0], "green": [0, 255, 0], "blue": [0, 0, 255],
        "temperature": 6600,
    })
    return c


def slave_settings(pi_id, leds, base):
    smoothing = copy.deepcopy(base["smoothing"])
    smoothing["enable"] = False
    border = copy.deepcopy(base["blackborderdetector"])
    border["enable"] = False
    device = {
        "type": "udpraw", "host": PI_HOST, "port": BASE_PORT + pi_id,
        "hardwareLedCount": len(leds), "colorOrder": "rgb", "latchTime": 0, "autoStart": True,
        "enableAttempts": 6, "enableAttemptsInterval": 15,
    }
    return {
        "leds": leds, "device": device, "smoothing": smoothing, "blackborderdetector": border,
        "color": neutral_color(base["color"]), "instCapture": copy.deepcopy(base["instCapture"]),
        "foregroundEffect": {**base["foregroundEffect"], "enable": False},
        "backgroundEffect": {**base["backgroundEffect"], "enable": False},
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--remove", action="store_true")
    args = ap.parse_args()

    layouts = pi_layouts()
    if args.dry_run:
        for pi_id, name, leds in layouts:
            print(f"{name}: {len(leds)} LEDs -> {PI_HOST}:{BASE_PORT + pi_id}")
        return

    api = Api()
    existing = api.instances()

    if args.remove:
        for _, name, _ in layouts:
            if name in existing:
                api.call({"command": "instance", "subcommand": "deleteInstance", "instance": existing[name]})
                print(f"removed {name}")
        return

    base = api.call({"command": "config", "subcommand": "getconfig"})["info"]["instances"][0]["settings"]
    for pi_id, name, leds in layouts:
        if name not in existing:
            api.call({"command": "instance", "subcommand": "createInstance", "name": name})
            existing = api.instances()
        inst = existing[name]
        api.call({"command": "config", "subcommand": "setconfig",
                  "config": {"instances": [{"id": inst, "settings": slave_settings(pi_id, leds, base)}]}})
        api.call({"command": "instance", "subcommand": "startInstance", "instance": inst})
        print(f"synced {name} (PC instance {inst}): {len(leds)} LEDs -> {PI_HOST}:{BASE_PORT + pi_id}")


if __name__ == "__main__":
    main()
