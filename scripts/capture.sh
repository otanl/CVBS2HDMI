#!/usr/bin/env bash
# Program a bitstream and immediately capture its serial output.
#
# Doing both in one shot matters: openFPGALoader claims the FTDI device over
# libusb, and on macOS that intermittently leaves the UART interface dead until
# the cable is replugged.  Every replug therefore buys a limited number of
# programming runs, so waste none of them.
#
#   scripts/capture.sh <make-target> <seconds> <output-file> [port]
set -euo pipefail

target="${1:-dumpbig-program}"
secs="${2:-30}"
out="${3:-/tmp/tang-capture.txt}"
port="$(python3 "$(dirname "$0")/tang_port.py" "${4:-}")"

echo "port: ${port}"
make "${target}" >/dev/null
python3 "$(dirname "$0")/read_raw.py" "${port}" "${secs}" > "${out}"

echo "captured $(wc -c < "${out}") bytes to ${out}"
grep -c '^#END' "${out}" 2>/dev/null | sed 's/^/complete dumps: /' || true
grep -E '^(ADC|NTSC|HDMI)' "${out}" 2>/dev/null | tail -2 || true
