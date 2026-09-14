#!/usr/bin/env python3
"""Print a few seconds of the board's report and stop.  Used by the bring-up
checks; `scripts/monitor.py` is the interactive version."""
import glob, os, select, sys, termios, time

port = sys.argv[1] if len(sys.argv) > 1 else sorted(glob.glob("/dev/cu.usbserial-*"))[-1]
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0
fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd)
a[0] = a[1] = a[3] = 0
a[2] = (a[2] & ~(termios.CSIZE | termios.PARENB | termios.CSTOPB | termios.CRTSCTS)) \
       | termios.CS8 | termios.CREAD | termios.CLOCAL
a[4] = a[5] = termios.B115200
a[6][termios.VMIN] = a[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, a)
termios.tcflush(fd, termios.TCIOFLUSH)
buf = b""
end = time.time() + secs
while time.time() < end:
    if select.select([fd], [], [], 0.3)[0]:
        try: buf += os.read(fd, 4096)
        except OSError: pass
os.close(fd)
lines = [l for l in buf.decode("ascii", "replace").splitlines()[1:] if l.strip()]
prev, run = None, 0
for l in lines + [None]:
    if l == prev:
        run += 1
        continue
    if prev is not None:
        print(prev + (f"   [x{run}]" if run > 1 else ""))
    prev, run = l, 1
