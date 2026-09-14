#!/usr/bin/env python3
"""Dump a serial port verbatim for N seconds.  See monitor.py for why the baud
has to be set on the descriptor being read."""
import os, select, sys, termios, time

port = sys.argv[1]
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0
fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd)
a[0] = a[1] = a[3] = 0
a[2] = (a[2] & ~(termios.CSIZE | termios.PARENB | termios.CSTOPB
                 | termios.CRTSCTS)) | termios.CS8 | termios.CREAD | termios.CLOCAL
a[4] = a[5] = termios.B115200
a[6][termios.VMIN] = a[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, a)
termios.tcflush(fd, termios.TCIOFLUSH)
buf = b""
end = time.time() + secs
while time.time() < end:
    if select.select([fd], [], [], 0.3)[0]:
        try:
            buf += os.read(fd, 8192)
        except OSError:
            pass
os.close(fd)
sys.stdout.write(buf.decode("ascii", "replace"))
