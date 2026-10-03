# TangADC — composite NTSC to HDMI (Tang Nano 20K + AD9280)

English | [日本語](README.ja.md)

**v0.1**

TangADC digitises composite NTSC video with an 8-bit ADC (AD9280), decodes it in colour on the
Tang Nano 20K's FPGA, and sends it to the on-board HDMI connector as 640×480p. There is no frame
buffer. Everything is built with an open-source toolchain (Yosys / nextpnr-himbaechel / Apicula /
openFPGALoader / Icarus Verilog); development was done on macOS.

## Features

- Colour NTSC decoding (240p and 480i) to 640×480p HDMI (DVI-compatible)
- 25.2 MSPS, one sample per clock, with no multipliers or ALU cells; the colour burst's phase
  is measured on every line with a CORDIC
- 240p, as most game consoles send it, holds still: the output frame switches between 524 and
  525 lines to match
- A broken or missing input is shown as noise, never as a black screen
- S2 zooms the picture 1.5 times and crops the border (a ring buffer of lines, no frame buffer)
- Eight glitch effects on the knobs of an M5Stack Unit 8Angle, each breaking a stage of the
  decoder itself
- Regression tests in simulation for every feature (`make test`)

Not supported: PAL, audio, black-level correction for 7.5 IRE setup.

## Hardware

- **Tang Nano 20K** (GW2AR-LV18QN88C8/I7)
- **Carrier board**: an AD9280ARS and its input circuit, taking the Tang Nano 20K in a DIP-40
  socket
  - Input: RCA → 75 Ω termination → ESD protection → 1 µF AC coupling → 20 Ω + 100 pF → AIN
  - AD9280: internal 2 V reference, single-ended input (0..2 V), clocked at 25.2 MHz by the FPGA
  - DC restoration is digital (black level measured on the front porch); the analog clamp is
    not used
  - Powered from the Tang Nano 20K's 3.3 V, with separate analog and digital rails through
    ferrite beads
- **Optional**: M5Stack Unit 8Angle (Grove J4/J5, I²C)

The carrier board's KiCad 10 project is in `hardware/`: schematic, PCB, and the JLCPCB
production files (BOM, placement, gerbers) of the board as built and measured.

Pin assignment (the single source is `constraints/tangnano20k_adc_probe.cst`):

| Signal | FPGA pin | | Signal | FPGA pin |
|---|---|---|---|---|
| `adc_clk` | 73 | | `adc_d[4]` | 29 |
| `adc_clamp` | 74 | | `adc_d[5]` | 30 |
| `adc_d[0]` | 27 | | `adc_d[6]` | 75 |
| `adc_d[1]` | 28 | | `adc_d[7]` | 77 |
| `adc_d[2]` | 72 | | `adc_otr` | 71 |
| `adc_d[3]` | 76 | | I²C SCL / SDA | 48 / 49 |

The data bus is not in physical pin order. The board's revision history, and the pins that must
not be used, are in `docs/pcb-respin.md` (Japanese).

**Caution**: pin 3 of the Grove connectors is 5 V. A device that pulls I²C up to 5 V puts 5 V
on the FPGA's pins. The 8Angle pulls up to its own 3.3 V and is safe.

**Caution**: ADC bits 0, 1, 4 and 5 (pins 27..30) share an I/O bank with HDMI. Stock Apicula
packs those inputs as LVDS receivers, so every build must go through `scripts/gowin_pack_io.py`
(the Makefile does).

## Usage

### Installing the tools (once)

```sh
./scripts/setup-macos.sh
make check-tools
```

This installs the OSS CAD Suite into `.tools/oss-cad-suite`; your shell's PATH and macOS
settings are left alone.

### Building and loading

```sh
make ntsc                # build
make ntsc-program        # load into SRAM (lost at power-off)
make ntsc-flash          # write to flash (kept across power cycles)
```

`make program` loads not the HDMI decoder but the ADC probe used to bring up a board (see below).

### Buttons and LEDs

- **S1**: toggles the diagnostic view (waveform and bars). The black-and-white cells showing the
  ADC interface's state appear only at the bottom of this view.
- **S2**: toggles the 1.5× zoom, which scales up the middle of the picture and crops the border
  (for sources such as game consoles whose picture sits small inside a wide border). Both axes
  scale alike, so the aspect ratio is kept. After a switch the picture slides into place over
  about 1.5 seconds.
- **LEDs** (active low): 0 heartbeat, 1 PLL locked, 2 horizontal sync locked, 3 vertical sync
  seen, 4 and 5 the luma gain step

An input that cannot be synced (a broken signal, a wrong standard, an unplugged cable) does not
black out the screen: the signal is shown as it arrives, as noise, and a good signal is locked
again as soon as it returns. 240p (262 lines every field, 60.05 Hz), as most game consoles send
it, is shown by measuring the field length and switching the output frame between 525 and 524
lines.

### M5Stack Unit 8Angle (glitch effects)

Connect an M5Stack Unit 8Angle to Grove J4 or J5 and its eight knobs and switch are read
continuously over I²C (address 0x43, 100 kHz). Near the bottom of the S1 diagnostic view, each
knob is drawn as a cyan bar, the switch as a green block, and a red block shows while the unit
is not answering. `make sim-angle8` checks the reader against a model of the unit.

The eight knobs control **glitch effects**. They do not post-process the image; each one breaks
a stage of the decoder itself. A knob turned fully left is off, and with all knobs left the
picture is the clean one. The effects are enabled with the switch in the green position (as the
diagnostic view shows it).

Knobs 1..4 break **where lines go and their shape**, 5..8 break **colour**; each group is in the
order the signal passes through the decoder.

| Knob | What breaks |
|---|---|
| 1 | Sync slicing: dark parts of the picture read as sync, so the picture decides where lines start |
| 2 | Horizontal hold: real syncs are ignored and the line timing free-runs off frequency (sideways drift, diagonal tearing) |
| 3 | Line stretch: lines at random are stretched to twice the width or squeezed to half, leaving an older line behind |
| 4 | Line buffer: lines stop being updated, and old lines smear downwards |
| 5 | ADC bus faults: the faults this board really had, in order (pair misreads → stuck bits → crossed wiring) |
| 6 | Colour reference collapse: the burst is measured inside the picture and the oscillator drifts, so the hue jumps and rainbow stripes roll |
| 7 | Colour matrix overflow: the YUV→RGB gain is raised and the clipping removed, so bright and saturated parts fold into their complements (neon, solarised) |
| 8 | HDMI link failure: first the lanes skew, splitting red, green and blue sideways with a per-line shiver; past half way, blocks of a few lines lose a colour lane or misread it (inverted and so on). Worked out in the FPGA as the monitor would show it, so the link never drops |

`make sim-video-glitch` checks that each effect breaks the picture and that the picture is clean
again once the effect is removed. `make sim-link` checks, line by line, that the HDMI link
failure breaks the picture only in the ways it is allowed to.

### Sources with no sync step

A signal whose sync tip sits at blanking level (an early M5 setup, for example) needs a build
with different window positions. It is not switched automatically.

```sh
make ntsc-legacy
make ntsc-legacy-program
```

On a source with a sync step, the default (`LEGACY_TIMING=0`) measured 0.43% dropped rows and
colour on 120/120 frames, against 47.8% and 0/120 for `LEGACY_TIMING=1` (2026-09-24, same seed).

### Going back to a known-good version

The version verified on 2026-09-26 (tag `good-2026-09-26`) is kept as a bitstream,
`bitstreams/ntsc_good_2026-09-26.fs.gz`, so it can be written back whatever happens to the
sources or the toolchain.

```sh
make restore-flash       # write it to flash (kept across power cycles)
make restore-program     # load it into SRAM only (to try it)
git checkout good-2026-09-26   # the sources as they were
```

## Tests

```sh
make test                # everything (a few minutes)
make sim-video           # NTSC-J 75% bars, three fields, vertical interval included
make sim-zoom            # the 1.5× zoom (240p and interlaced, with a negative control)
make sim-video-glitch    # each glitch effect breaks the picture, and removing it restores it
make sim-link            # the HDMI link failure effect
make sim-hdmi            # TMDS encoding, line buffer races, start-up and video timing
```

`make test` includes negative controls: each bench also has to recognise a deliberately broken
setup as broken.

## Development and diagnostics

The decisions and measurements made during development are recorded in `CLAUDE.md`. When the
hardware behaves unexpectedly, search there first.

### Picture quality

```sh
make sim-reference       # every phase, ±100 ppm, half-wave burst, signal loss
make sim-tracking        # colour phase from the first line after 24 lines without burst
make sim-video-weak      # small sync amplitude
make sim-video-mono      # monochrome input with no burst
make sim-video-late      # recovery from a horizontal sync that arrives late
```

PNG captures of the HDMI output can be scored with the Python standard library and FFmpeg:

```sh
python3 scripts/video_quality.py 'build/cap*.png' --rows 20:350 --start 24 --bar-width 80
```

It reports, separately, rows in luma order, rows with a dark first bar, rows with colour, RGB
saturation, and row-to-row colour variation. The grey staircase in the bottom quarter is left out;
compare only captures of the same region and test pattern. The first capture after programming
is affected by the link and the vertical position re-acquiring, so always capture twice and score
the second, the same way for both sides of a comparison. Frames with no signal are counted too.
Bars in luma order do not prove that hue or amplitude is right.

With no UART, ADC values can be measured from the waveform view on HDMI:

```sh
make ntsc-scope-program             # starts in the full-range waveform and diagnostic view
# compare a phase: make ntsc-scope-program NTSC_SCOPE_PHASE=4
./scripts/live_capture.sh build/scope_new 120 8 --scope-mode 0 --phase 2
python3 scripts/scope_trace.py build/scope_new_012.png --trace-only --require-mode 0
# check the display path with a known ramp: make ntsc-scope-program NTSC_SCOPE_RAMP=2
make ntsc-program                   # back to the normal picture
```

To look at a signal that has no usable sync, capture raw ADC data without waiting for sync:

```sh
make ntsc-scope-program NTSC_SCOPE_RAMP=3 NTSC_SCOPE_FREERUN=1
./scripts/live_capture.sh build/raw_free_new 12 3 --scope-mode 3 --phase 2
python3 scripts/scope_trace.py build/raw_free_new_012.png --trace-only --require-mode 3
```

The normal capture waits for sync, and when none is found its buffer is never written, so zeros
that were never captured can be mistaken for measurements. `NTSC_SCOPE_FREERUN=1` captures every
66 ms or so regardless of sync, and the build gets its own name. `make sim-scope-freerun` checks
that all 2048 points are captured and re-captured with no sync, and that the sync-waiting mode
does not capture.

The waveform is drawn at 640×480 with three samples a pixel, and values are recovered from the
height of the red and white trace. The diagnostic build's vertical axis shows all 256 codes; to
read the S1 view of the normal build, pass `--legacy-scale` (there, codes above about 150 are
hidden behind the bars at the top). Ambiguous columns are dropped. This is an approximate
measurement from the screen, not a dump of every sample. Rows 200..207 of the diagnostic view
carry the mode, the ADC phase and a frame counter. `live_capture.sh` always captures at least
twice and checks the mode, the phase and that the counter advances; each time it sets aside the
first 120 frames as warm-up and measures the requested number after them. It never filters out
bad frames from the measured run. Each attempt is kept in its own folder and existing images are
never overwritten (use a new prefix). On the normal picture only pixel changes are checked:
without the diagnostic counter, a still picture cannot be told from a frozen capture, nor the
loaded bitstream identified. Amplitudes of oscillating parts are not validated; use
`--trace-only`, and do not use these readings to set colour gain.

### Recording the input and replaying it in simulation

The waveform view shows one sample in three; this records 32768 consecutive raw ADC samples
(about 20 lines) exactly, without the UART.

```sh
make ntsc-tape-program                                  # record once, freeze, show as grey cells
python3 scripts/live_capture.py build/tape 12 8
python3 scripts/tape_decode.py build/tape.hex build/tape_0*.png   # vote across 12 frames
python3 scripts/tape_trim.py build/tape.hex sim/my_tape.hex 18    # cut to an even number of lines
./scripts/tool iverilog -g2012 -s replay_tb -o build/replay_tb \
    src/ntsc_capture.v src/adc_front.v src/sync_lpf.v src/burst_nco.v src/cordic_atan.v \
    src/chroma_sincos.v sim/gowin_prim_sim.v sim/replay_tb.v
./scripts/tool vvp build/replay_tb +stim=sim/my_tape.hex +nsamp=<samples> +lines=400 +out=build/replay.txt
python3 scripts/replay_quality.py build/replay.txt --png build/replay.png  # same scale as the board
python3 scripts/tape_reference.py sim/my_tape.hex                          # floating-point reference decode
```

`replay_quality.py --frames 'build/cap_*.png'` scores captures from the board on the same scale.
`make sim-tape` checks the recording display and its decoder end to end against a known memory
image.

**With the M5 as the source, correctly decoded bars are not in luma order** (the M5 itself sends
yellow < cyan, green < magenta, red < blue). To evaluate with the M5, compare `replay_quality.py`'s
hue error and line-to-line variation with `tape_reference.py`'s values instead of
`video_quality.py`'s "correct rows".

## ADC probe (for bringing up a board, 27 MSPS)

A separate design for the first check on a new board: that the ADC's data is captured correctly.

Measured in step 1:

```
ADC ph=2 tog=FF min=96 max=255 thr=115 ln=1716 lmin=1715 lmax=1717 ok=15734 lns=15734 vs=60 otr=0 lk=1
```

A raw waveform (taken with `make autodump-program`, saved as `sim/ntsc_line_capture.hex`):

| Quantity | Measured | NTSC | Error |
| --- | --- | --- | --- |
| Sync tip | code 98 (±1) | — | — |
| Sync width | 4.59 us | 4.70 us | -2.3% |
| Blanking | code 133.9 | — | — |
| Sync to blanking | 282 mV | 286 mV | **-1.3%** |
| Burst start | 5.19 us after the sync edge | 5.3 us | — |
| Burst length | 2.52 us / **9.02 cycles** | 2.51 us / 9 cycles | **+0.2%** |
| Line period | **1716** samples | 1716.05 | — |

Counting exactly nine burst cycles shows that the sample clock and the subcarrier are in the right
time relation, and an amplitude error of -1.3% shows that the gain is right.

### Simulating

A synthetic NTSC signal goes through a behavioural model of the AD9280 and the line period is
measured.

```sh
make sim           # positive: must measure ln=1716
make sim-badphase  # negative: a wrong sampling phase must be reported as broken
```

The negative case exists to show that `ln=1716` is not a value that comes out whatever goes in.

### Loading it and measuring

```sh
make program   # load into SRAM (lost at power-off)
make monitor   # read the report
```

One line a second at 115200 8N1:

```
ADC ph=2 tog=FF min=79 max=205 thr=94 ln=1716 lmin=1716 lmax=1717 ok=15720 lns=15734 vs=60 otr=0
```

| Field | Meaning | Healthy value |
| --- | --- | --- |
| `ph` | sampling phase; 0..3 = 0 / 9.3 / 18.5 / 27.8 ns after the adc_clk rising edge | `2` |
| `tog` | OR of the bits that changed during the window | `FF` |
| `min` | lowest code → the sync tip level | about 70..90 |
| `max` | highest code → peak white | about 190..215 |
| `thr` | the sync slicing threshold actually used | min + a few tens |
| `ln` | the latest line period (samples) | **1716** |
| `lmin` / `lmax` | range of accepted line periods | 1716..1717 |
| `ok` | lines whose period is within 1700..1732 | about `lns` |
| `lns` | accepted lines | about 15734 |
| `vs` | vertical syncs detected | about 60 |
| `otr` | samples the AD9280 flagged as over range | `0` |

**`ln=1716` is the decisive one.** One NTSC line (15734.264 Hz) sampled at 27 MHz is

```
27e6 / 15734.264 = 1716.05 samples
```

so a steady 1716 proves at once that **the ADC clock, the data bus's bit order and the sampling
phase are all right**. No other single figure says that much.

#### Buttons (probe)

* **S2 (pin 87)**: advance the sampling phase by one. If `ln` does not appear, try all four.
* **S1 (pin 88)**: dump 2048 raw samples from a sync edge in hex, for checking the bit order by
  eye. The sync tip (a run of low values), then the back porch, then the picture should be
  visible.

#### Diagnostic LEDs (active low, probe)

| LED | Meaning |
| --- | --- |
| 0 | heartbeat (the design is running) |
| 1 | PLL locked |
| 2 | line period in range |
| 3 | vertical sync detected |
| 4 | over range detected (input too large) |
| 5 | a data bit never changes (bad wiring and so on) |

### The analog clamp is off by default

The AD9280's clamp (CLAMP/CLAMPIN) is **not used**: on this board it does more harm than good.
C2 at 1 µF is larger than the AD9280's clamp amplifier is designed for, so each pulse leaves a
transient longer than a line, which spoils the next sync edge. Measured:

| Clamp | Result |
| --- | --- |
| off (default) | `ok = lns = 15734`, `vs=60`, `ln=1716`, perfect |
| gated on sync lock | about 72% good lines, lock oscillating at 1 Hz, `vs` erratic |

Without the clamp the input still biases itself inside the conversion range (sync tip at 98,
white at about 225, 30 codes below 255). The decoder measures the porch and restores DC
digitally. The sync tip is not the black level, so do not subtract it from the picture.

`make clampgated-program` brings the clamp back for experiments.

### Builds for isolating faults

For suspecting the analog side. The RTL is the same; only a constraint or a parameter differs.

```sh
make pullup-program    # weak pull-ups on the ADC inputs; min=max=255 means the ADC is not driving the bus
make clampon-program   # CLAMP held on: AIN pinned to CLAMPIN, measurable with no video
make clampoff-program  # CLAMP held off (for comparison)
make clkhigh-program   # adc_clk held at 3.3 V → TP4 should read about 3.3 V
make clklow-program    # adc_clk held at 0 V → TP4 should read about 0 V
make clkslow-program   # adc_clk at about 1 Hz → TP4 swings 0 ↔ 3.3 V on a meter
make program           # back to normal
```

`clk=` at the end of the report shows which clock mode the loaded bitstream has.

#### The pull test: finding a floating pin without touching the board

The most effective technique of the bring-up. Build the same design three ways, with no pull,
pull-up and pull-down, and compare the reported codes in binary. **A ~50 kΩ internal pull cannot
move a pin the ADC is really driving.** A bit that follows the pull is an open joint; a bit that
resists it is connected, one pin at a time.

```sh
make program && make monitor          # no pull
make pullup-program && make monitor   # pull-up
make pulldown-program && make monitor # pull-down
```

**The trap**: a test point measures the net, not the pin. TP4 shows a healthy clock even if the
AD9280's pin 15 is lifted, and FB2 shows 3.3 V even if pin 2 is. The pull test gets round this
electrically for every pin the FPGA can read.

If `min`/`max` stay at 0 with `clampon`, the cause is not the video signal but the ADC's
conversion, its reference or the clamp circuit. If the bus does not move with `clkslow` either,
the ADC is not responding to its clock.

#### AVDD and DRVDD come from different pins

Easy to miss: the AD9280's analog and digital supplies come from **different pins of the Tang
Nano**.

```
Tang Nano DIP pad 19 → +3V3 → FB1 → +3V3A → U1 pin 28 AVDD
Tang Nano DIP pad 25 →        FB2 → +3V3D → U1 pin 2  DRVDD
```

So **a healthy TP2 (VREF) does not prove that DRVDD is there**: VREF depends on AVDD alone.
Without DRVDD the digital outputs are never driven and the bus is dead. FB1 and FB2 are leaded
parts, easy to probe at both ends.

## HDMI output pitfalls

**Never put `DRIVE=` or `BANK_VCCIO=` on an LVDS25 constraint.** Sipeed's `.cst` for Gowin EDA
carries `DRIVE=3.5 BANK_VCCIO=3.3`; brought into the open-source flow, it builds, meets timing,
and produces a link **no sink locks to**, with no warning. Apicula's own
`examples/tangnano20k.cst` uses only `IO_TYPE=LVDS25 PULL_MODE=NONE`.

**The 20K's HDMI pins are true LVDS.** The 9K's are emulated, so `ELVDS_OBUF`/`LVDS25E` ported
as-is is rejected outright by Apicula. Use `TLVDS_OBUF`/`LVDS25`, with P on the pair's IOBA pin
and N on its IOBB pin (33/34, 35/36, 37/38, 39/40).

**Pass the pixel clock to `--freq`.** nextpnr applies `--freq` to every clock it does not
otherwise know, so passing the serial clock (135) fails the TMDS encoder's combinational path on
a timing violation that does not exist.

### When nothing comes out, compare with a known-good bitstream

Faster than reasoning. Load Sipeed's prebuilt `.fs` (fetched with `gh`) and you know at once
whether the board, cable and sink are fine. Build Apicula's `examples/DVI` with the same flow and
you also know that the open-source toolchain can drive this board's TLVDS; what is left is the
difference from your own sources.

## Common problems

* **The report is garbled**: macOS resets a `/dev/cu.*` port to 9600 baud when its last
  descriptor closes, so `stty -f PORT 115200` followed by `cat PORT` loses the setting.
  `make monitor` (`scripts/monitor.py`) sets the speed on the descriptor it reads from.
* **The board is not found**: use a USB-C cable that carries data, and connect directly, without
  a hub.
* **`unable to open ftdi device`**: close anything using the board's USB device (a serial
  monitor, for instance) and reconnect.
* **Starting over**: `make clean`, then `make build`.

## License

MIT License. See `LICENSE`.
