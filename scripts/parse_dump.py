#!/usr/bin/env python3
"""Extract raw sample dumps from a captured serial log.

Rows are validated individually rather than trusting the #DUMP/#END framing:
the UART link drops bytes often enough that a report line can land in the
middle of a dump, and a whole capture should not be thrown away for it.
"""
import re
import sys

# Three or four hex digits of address: the probe emits four, the video
# design three.
ROW = re.compile(r'^([0-9A-F]{3,4})((?: [0-9A-F]{2}){16})$')


def dumps(text, expect=None):
    """Yield sample lists, one per complete dump found in `text`."""
    out, cur, nextaddr = [], [], 0
    for line in text.splitlines():
        m = ROW.match(line.strip())
        if not m:
            continue
        addr = int(m.group(1), 16)
        vals = [int(x, 16) for x in m.group(2).split()]
        if addr == 0:
            if cur:
                out.append(cur)
            cur, nextaddr = [], 0
        if addr != nextaddr:          # a row was lost; drop this dump
            cur, nextaddr = [], -1
            continue
        cur.extend(vals)
        nextaddr = addr + 16
    if cur:
        out.append(cur)
    if expect is not None:
        out = [d for d in out if len(d) == expect]
    return out


if __name__ == "__main__":
    text = open(sys.argv[1]).read()
    n = int(sys.argv[2]) if len(sys.argv) > 2 else None
    ds = dumps(text, n)
    print(f"{len(ds)} dump(s): " + ", ".join(str(len(d)) for d in ds[:10]))
