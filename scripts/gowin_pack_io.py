#!/usr/bin/env python3
"""gowin_pack, with single-ended inputs in a true-LVDS bank typed as themselves.

Apicula configures every input buffer with its *bank's* IO_TYPE, not its own,
and a bank holding a true LVDS output has that forced to LVDS25.  On this board
bank 5 holds the HDMI clock lane (pins 33/34) and ADC bits 0, 1, 4 and 5 (pins
27..30), so those four LVCMOS33 inputs were packed as LVDS receivers: each
A/B pin pair compared against the other.  Measured on the raw 126 MHz reads,
bits 0 and 1 were wrong on 2..3 reads of every ten whenever both were low, and
the four bits flipped hundreds of times a line away from any real transition;
the four bank-1 bits read perfectly throughout.  Packed by this script, the
same routed design reads all eight bits cleanly: no isolated glitch in 32768
reads.

Only IBUFs that carry their own IO_TYPE, in a bank with a true LVDS output,
are changed; everything else goes through Apicula untouched, so for a design
without such a bank the bitstream is identical.  Same arguments as gowin_pack.
"""
import sys

from apycula import gowin_pack as gp

_original = gp.Device.process_IBUF
_retyped = []


def _process_ibuf(self, bank_desc, bel):
    own = bel.cell.attrs.get('IO_TYPE')
    if not (bank_desc.has_true_lvds_outputs and own and not bel.is_diff_io()):
        return _original(self, bank_desc, bel)
    av = self.set_io_attrvals(bel, self.default_ibuf_attrs)
    self.chipdb.get_iob_attr_val(gp.AttrVal("IO_TYPE", own), av)
    self.chipdb.get_iob_attr_val(gp.AttrVal("BANK_VCCIO", bank_desc._vcc_ios[own]), av)
    _retyped.append("X%dY%d/IOB%s %s" % (bel.x, bel.y, bel.idx_str, own))
    return self.get_iob_fuses(bel.x, bel.y, bel.idx_str, av)


def main():
    gp.Device.process_IBUF = _process_ibuf
    gp.main()
    if _retyped:
        print("gowin_pack_io: %d input(s) in true-LVDS banks packed as their own IO_TYPE: %s"
              % (len(_retyped), ", ".join(_retyped)), file=sys.stderr)


if __name__ == "__main__":
    main()
