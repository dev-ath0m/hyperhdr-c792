#!/usr/bin/env python3
"""UDP relay: PC -> Pi raw-UDP receivers, with keep-alive.

The PC only sends LED colours when the picture changes, but HyperHDR drops a raw-UDP
source after ~3 s of silence. This relays each packet from port RELAY_BASE+i to the
Pi's rawUdpServer (RAW_BASE+i) and, while the PC is online (/tmp/pc-online), re-sends
the last packet once per second so a static screen keeps its colours.
"""
import os
import select
import socket
import time

PI_INSTANCES = (1, 2, 3, 4)
RELAY_BASE = 5700              # PC sends here
RAW_BASE = 5600                # HyperHDR rawUdpServer ports
FLAG = "/tmp/pc-online"        # written by pc-priority.service
KEEPALIVE = 1.0


def main():
    socks = {}
    for i in PI_INSTANCES:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("0.0.0.0", RELAY_BASE + i))
        socks[s] = i
    out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    last = {}                  # instance -> (packet, time sent)

    while True:
        ready, _, _ = select.select(list(socks), [], [], KEEPALIVE / 2)
        now = time.monotonic()
        for s in ready:
            pkt, _ = s.recvfrom(4096)
            i = socks[s]
            out.sendto(pkt, ("127.0.0.1", RAW_BASE + i))
            last[i] = (pkt, now)
        if os.path.exists(FLAG):
            for i, (pkt, sent) in last.items():
                if now - sent >= KEEPALIVE:
                    out.sendto(pkt, ("127.0.0.1", RAW_BASE + i))
                    last[i] = (pkt, now)
        else:
            last.clear()


if __name__ == "__main__":
    main()
