#!/usr/bin/env python3
"""Pick the Tang Nano's UART port.

The board exposes two /dev/cu.usbserial-<serial><iface> nodes and the UART is
the higher-numbered one.  Naively taking the last matching port breaks as soon
as anything else is plugged in -- an M5Stack ATOM enumerates as
/dev/cu.usbserial-AD526BEB00, which sorts after the Tang's numeric serial and
silently becomes the wrong target.  Identify the board properly instead.
"""
import glob
import re
import subprocess
import sys


def tang_serials():
    """Serial numbers of Sipeed USB Debuggers currently attached."""
    try:
        out = subprocess.run(["ioreg", "-p", "IOUSB", "-w0", "-l"],
                             capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return []
    serials, vendor_seen = [], False
    for line in out.splitlines():
        if '"USB Vendor Name" = "SIPEED"' in line:
            vendor_seen = True
        m = re.search(r'"USB Serial Number" = "([^"]+)"', line)
        if m and vendor_seen:
            serials.append(m.group(1))
            vendor_seen = False
    return serials


def find(explicit=None):
    if explicit:
        return explicit
    ports = sorted(glob.glob("/dev/cu.usbserial-*"))
    for serial in tang_serials():
        matching = [p for p in ports if serial in p]
        if matching:
            return matching[-1]          # UART is the higher interface
    if not ports:
        sys.exit("error: no /dev/cu.usbserial-* found")
    return ports[-1]


if __name__ == "__main__":
    print(find(sys.argv[1] if len(sys.argv) > 1 else None))
