# m5-colorbars — NTSC colour bar generator for decoder calibration

Turns an M5Stack ATOM (ESP32-PICO-D4) with the RCA unit into a composite
colour bar source, so the CVBS2HDMI decoder can be checked against known values
instead of by eye.

Output is on **G26** (DAC channel 2), which is where the M5Stack RCA unit sits.
LovyanGFX's `Panel_CVBS` generates the signal; ESP32-S2/S3/C3 are not
supported by it, but the ATOM's ESP32-PICO-D4 is.

Pattern: 75% colour bars (white, yellow, cyan, green, magenta, red, blue,
black) across the top three quarters, and a 16-step grey staircase along the
bottom for checking luma gain and linearity separately from chroma.

## Build and flash

```sh
. ~/esp/esp-idf/export.sh
cd tools/m5-colorbars
idf.py set-target esp32
idf.py build
idf.py -p /dev/cu.usbserial-XXXXXXXX flash
```

The ATOM enumerates as a CH9102 bridge (`Hades2001 / M5stack` in `ioreg`), so
its port is *not* one of the Tang's two `usbserial-2025...` nodes. Pass it
explicitly — several of this project's scripts pick the last matching port and
will otherwise grab the wrong one.

## Signal type

`USE_NTSC_J` in `main/main.cpp` selects between NTSC-J (0 IRE setup, black
equals blanking) and NTSC (7.5 IRE setup). It defaults to NTSC-J because it
keeps level arithmetic simple when calibrating, and because it is what
Japanese equipment expects.
