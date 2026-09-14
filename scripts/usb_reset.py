#!/usr/bin/env python3
"""Reset the Tang Nano's USB bridge in software, instead of replugging it.

openFPGALoader drives the FTDI bridge through libusb, and on macOS that
intermittently leaves its UART interface wedged: JTAG still works, the design
still runs and drives HDMI, but the serial port goes silent and stays silent.
The documented fix is to unplug and replug the board, which makes every single
observation cost a physical round trip.

A USB port reset is electrically the same thing and needs no hands.
"""
import sys
import usb.core
import usb.backend.libusb1

LIB = ("../tang/.tools/oss-cad-suite/lib/"
       "libusb-1.0.0.dylib")


def backend():
    return usb.backend.libusb1.get_backend(find_library=lambda _: LIB)


def main():
    be = backend()
    if be is None:
        sys.exit("error: could not load libusb from the OSS CAD Suite")

    found = []
    for dev in usb.core.find(find_all=True, backend=be):
        try:
            maker = usb.util.get_string(dev, dev.iManufacturer) or ""
            name = usb.util.get_string(dev, dev.iProduct) or ""
        except Exception:
            maker = name = ""
        if "SIPEED" in maker.upper() or "DEBUGGER" in name.upper():
            found.append((dev, maker, name))

    if not found:
        sys.exit("error: no Sipeed USB debugger found")

    for dev, maker, name in found:
        print(f"resetting {maker} {name} "
              f"({dev.idVendor:04x}:{dev.idProduct:04x})")
        try:
            dev.reset()
            print("  reset issued")
        except Exception as exc:
            print(f"  reset failed: {exc}")
            sys.exit(1)


if __name__ == "__main__":
    main()
