#!/usr/bin/env python3
"""Read the board's serial report.

macOS resets a /dev/cu.* port to its 9600-baud default every time the last
file descriptor is closed, so `stty -f PORT 115200` followed by `cat PORT`
silently reads at the wrong rate.  This sets the speed on the descriptor it
then reads from, which is the only way to make it stick.
"""
import glob
import os
import select
import sys
import termios

BAUD = termios.B115200


def pick_port(argv):
    if len(argv) > 1:
        return argv[1]
    ports = sorted(glob.glob("/dev/cu.usbserial-*"))
    if not ports:
        sys.exit("error: no /dev/cu.usbserial-* found; pass the port explicitly")
    # Two interfaces are exposed; the higher-numbered one is the UART.
    return ports[-1]


def main():
    port = pick_port(sys.argv)
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = 0
    a[1] = 0
    a[2] = (a[2] & ~(termios.CSIZE | termios.PARENB | termios.CSTOPB
                     | termios.CRTSCTS)) | termios.CS8 | termios.CREAD | termios.CLOCAL
    a[3] = 0
    a[4] = BAUD
    a[5] = BAUD
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)

    print(f"# {port} @ 115200 8N1 -- Ctrl-C to stop", file=sys.stderr)
    try:
        while True:
            if select.select([fd], [], [], 0.5)[0]:
                data = os.read(fd, 4096)
                if data:
                    sys.stdout.write(data.decode("ascii", "replace"))
                    sys.stdout.flush()
    except KeyboardInterrupt:
        pass
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
