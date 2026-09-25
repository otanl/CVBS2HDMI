#!/usr/bin/env python3
"""Fail if the HDMI decoder contains a signed comparison.

Apicula miscompiles signed comparison on the GW2A depending only on placement
(YosysHQ/apicula#541).  A grep for `$signed(...) >` is not a check: it said
"none" while eleven remained -- comparisons between values merely declared
signed, and against a signed integer such as `P_BAND * 256`.  This asks Yosys
instead: elaborate the design and list every $lt/$le/$gt/$ge cell whose
operands are signed.

    python3 scripts/check_signed_compare.py
"""
import json
import os
import subprocess
import sys
import tempfile

RTL = ("top_ntsc_hdmi ntsc_capture sync_lpf burst_nco cordic_atan chroma_sincos "
       "video_timing video_line_store line_buffer hdmi_out tmds_encoder rpll_126 "
       "ntsc_status uart_tx").split()


def main():
    files = " ".join("src/%s.v" % name for name in RTL)
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "elab.json")
        subprocess.run(["./scripts/tool", "yosys", "-q", "-p",
                        "read_verilog %s; hierarchy -top top_ntsc_hdmi; proc; "
                        "opt_clean; write_json %s" % (files, out)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        design = json.load(open(out))
    total, signed = 0, []
    for module in design["modules"].values():
        for cell in module.get("cells", {}).values():
            if cell["type"] not in ("$lt", "$le", "$gt", "$ge"):
                continue
            total += 1
            p = cell["parameters"]
            if int(str(p.get("A_SIGNED", "0")), 2) or int(str(p.get("B_SIGNED", "0")), 2):
                signed.append(cell["attributes"].get("src", "?"))
    if total == 0:
        raise SystemExit("no comparison cells found at all -- the check is broken")
    if signed:
        print("signed comparisons (apicula#541):")
        for src in signed:
            print("   ", src)
        sys.exit(1)
    print("RESULT PASS: %d comparison cells, none signed" % total)


if __name__ == "__main__":
    main()
