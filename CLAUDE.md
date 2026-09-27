# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Composite **NTSC → AD9280 (8-bit ADC) → Tang Nano 20K → HDMI (DVI-compatible TMDS)**.

Everything below marked *Verified* was read out of the hardware design or measured on the bench;
*Planned* means agreed but not yet built. Keep the distinction when editing.

**Milestone order** (deliberate — do not skip ahead):

1. **Prove `adc_d[7:0]` is captured correctly from the AD9280** — **done**
   (`src/adc_probe_top.v`). See *Step 1 status* below.
2. Monochrome: sync detection + luma → 480p on HDMI — **working** (`make ntsc-program`).
3. Color: burst-locked NCO, Y/C separation, YUV→RGB. *In progress — real capture in hand.*

Color decode is added *last*. Debugging a chroma PLL on top of an unverified capture path is the
main way this project can stall.

## Step 1 status — COMPLETE

`adc_probe_top` clocks the AD9280 at 27 MHz, captures the bus, and reports once a second over the
onboard USB serial. Verified in simulation both positively (`make sim` measures 1716) and
negatively (`make sim-badphase`: a sampling phase inside the AD9280's output switching window must
*not* report 1716). On hardware, with a live NTSC source:

    ADC ph=2 tog=FF min=96 max=255 thr=115 ln=1716 lmin=1715 lmax=1717
        ok=15734 lns=15734 vs=60 otr=0 clk=0 lk=1

Every accepted line period is in range, `lns` is exactly the NTSC line rate, and `vs` is exactly
the field rate. A raw capture (`make autodump-program`, saved to `sim/ntsc_line_capture.hex`)
measures:

| Quantity | Measured | NTSC | Error |
|----------|----------|------|-------|
| sync tip | code 98 (±1) | — | — |
| sync width | 4.59 us | 4.70 us | -2.3% |
| blanking | code 133.9 | — | — |
| sync → blanking | 282 mV | 285.7 mV | **-1.3%** |
| burst start | 5.19 us after the sync edge | 5.3 us | — |
| burst length | 2.52 us, **9.02 cycles** | 2.51 us, 9 cycles | **+0.2%** |
| line period | **1716** samples | 1716.05 | — |

Counting exactly nine subcarrier cycles validates the sample clock against the 3.579545 MHz
subcarrier; the -1.3% amplitude error validates the reference and gain. Sampling phase 2
(18.5 ns after the `adc_clk` edge) is correct in practice, as designed.

`sim/ntsc_line_capture.hex` is 2048 real consecutive samples starting at a sync edge. Use
`$readmemh` to replay genuine hardware video through a decoder testbench rather than only a
synthetic model.

### The analog clamp is disabled by default — deliberately

`CLAMP_MODE` defaults to 2 (off). On this board C2 is 1 uF, far larger than the AD9280's clamp
amplifier is meant to drive, so each pulse leaves a transient that outlasts the line and corrupts
the next sync edge. Measured:

| Clamp | Result |
|-------|--------|
| off (default) | `ok = lns = 15734`, `vs = 60`, `ln = 1716` — perfect |
| gated on sync lock | ~72% good lines, lock oscillates, `vs` erratic |

Gating the clamp on sync lock was added to break an earlier deadlock (an unlocked clamp pulse
lands on arbitrary video, pushes the signal out of range, and prevents the very sync detection
that would place the pulse correctly — the design wedged at code 253 forever). That fix is correct
and is kept, but the clamp still hurts, so it stays off. **Do DC restoration digitally instead**:
the sync tip is measured every line anyway, so subtract it as the black reference. The input
self-biases into range without any clamp — sync tip at 98, 100% white would be code 225, leaving
30 codes of headroom. `make clampgated-program` re-enables the analog path for experiments.

### Bisecting against reference bitstreams

When output hardware does not work, do not reason about it — get a known-good bitstream onto the
board and compare. Two references settled the HDMI bring-up in minutes after hours of guessing:

| Reference | How | What it proves |
|-----------|-----|----------------|
| `sipeed/TangNano-20K-example` `hdmi/hdmi.fs` | `gh api ... --jq .download_url`, then `openFPGALoader -b tangnano20k` | The board, cable and sink are fine (it displayed) — so the fault was ours |
| Apicula `examples/DVI` built locally | fetch `DVI/{dvi-example,pll480,tmds-channel}.v` + `examples/tangnano20k.cst`, build with the same flow | The open-source flow *can* drive TLVDS on this board, and the sink accepts 480p |

The second one is the valuable one: it is the same toolchain, so any difference is in our sources.
Diffing our constraints against `tangnano20k.cst` found the `DRIVE`/`BANK_VCCIO` bug immediately.
Apicula's DVI example is otherwise structurally identical to `src/hdmi_out.v` — rPLL, `CLKDIV`
`DIV_MODE="5"`, `OSER10` per data lane, pixel clock straight to the clock lane, `TLVDS_OBUF` — so
it is the right template to check against. (Amusingly its PLL still carries
`DEVICE = "GW1N-9C"` on a GW2A part and works anyway; that defparam does not appear to matter.)

Both bitstreams are worth keeping around. An unexplained "no signal" is one `openFPGALoader` away
from being attributed to the right side of the cable.

### The pull-test matrix — telling an open pin from a driven one

The most useful technique found during bring-up, and it needs no probe on the board. Build the
same design with `PULL_MODE=NONE` / `UP` / `DOWN` on the ADC inputs (`make program`,
`make pullup-program`, `make pulldown-program` — all three derive from the one authoritative
`.cst`) and compare the reported code in binary. A ~50 kOhm internal pull cannot move a pin the
AD9280 is really driving, so a bit that follows the pull is an **open joint** and a bit that
resists it is **connected**.

This is what finally localised the fault. The board arrived with the AD9280 unresponsive; the
matrix showed the package was only partly soldered, and after reflowing the pins it identified
came good. Note the trap the whole investigation turned on: **a test point measures the net, not
the pin.** TP4 reads a healthy clock even if AD9280 pin 15 is lifted, and FB2 reads 3.3 V even if
pin 2 is. The pull test is the electrical way around that for any pin the FPGA can read.

## Step 2 status — monochrome NTSC on HDMI works

`src/top_ntsc_hdmi.v`. One rPLL at 135 MHz does everything: `CLKDIV` by five gives the 27 MHz
pixel clock, and a mod-5 counter gives the 27 MHz ADC sample clock with five capture phases.
Reports once a second on the serial port:

    NTSC lk=1 sl=1 per=06B4 fps=3C lps=07AEC blk=84 g=0 ph=4 H <16 bins>

`sl=1` and `per=0x6B4` (1716) say the capture is locked and correct; `fps`/`lps` say the HDMI
timing is correct; `blk` is the measured black level; `H` is a 16-bin histogram of the raw
active-video samples.

Things worth knowing before changing it:

- **Only one rPLL can be used.** Apicula cannot pack two on this device — it dies with
  `UnboundLocalError: cannot access local variable 'offx'` in `get_pll_bels`. Hence the mod-5
  sample clock off the 135 MHz domain instead of a separate 108 MHz PLL. This is also why
  `ntsc_capture` runs at 135 MHz rather than 108.
- **Synthesise with `-nodsp`.** The luma gain otherwise infers a `MULT9X9` that Apicula cannot
  pack (`KeyError: 'IRBY_IREG0BL_0'`). The gains are constants, built from shift-adds.
- **The sampling phase is measured, continuously** (`AUTO_PHASE`, since 2026-09-25; now
  `adc_front`'s rotation calibration, see *The decoder on the pixel clock*). A fixed
  phase is placement-dependent and was the cause of colour that came and went between rebuilds;
  see *The sampling instant moves with every placement* below. Do not go back to a constant.
- **The analog clamp is not used**; DC restoration is digital, from the back porch at ccnt
  216..248. See the clamp note above for why.
- **Bob line doubling is implicit.** 480p has twice the line rate of 480i, so each captured line
  is read out of the two-bank line buffer twice before the capture side swaps banks.
- Vertical position is locked by resetting the output frame on the detected field, at a line
  boundary only (`vsync_align` in `video_timing`) — monitors tolerate a varying frame far better
  than a varying line.

Open: the histogram's absolute counts do not add up to a full field's worth of samples, so treat
its *shape* as meaningful and its *totals* as not yet trustworthy. The levels it reports agree
with the raw capture (black ~131) and that is what it is currently used for.

### Getting sync to lock — what actually went wrong

Five separate bugs, none of which produced a distinctive symptom on its own. All
were found the same way: by putting two quantities on screen whose relationship
is known in advance, and seeing the relationship violated.

**Found and forced line counts must sum to the line rate.** `real_count` and
`force_count` are drawn as two bars on the same scale, so together they should
exactly fill it. They summed to 189%, which can only mean the flywheel was
starting two lines for every real one. Nothing in the individual numbers said
so — 90% found looked like success. This single cross-check found three of the
five bugs and is the most useful thing in the design.

**Never learn the period from a counter that forced starts also reset.** It
feeds back on itself: one forced start shortens the measured interval, the
estimate shrinks, the next force comes earlier, and the estimate walks to its
floor. With the floor at `P_NOM - 800` it landed on almost exactly half a line —
the one wrong value that looks stable, because it puts a forced start in the
middle of every real line and stays there. Measure from a counter reset only by
genuine edges, keep the estimate's bounds tight (±160, not ±800), and ignore
intervals far from the current estimate.

**Do not run the flywheel during acquisition.** If the true period is longer
than the estimate, the forced start always lands first, the genuine edge arrives
just after and is rejected for being too close to the previous start, and since
the period is only learned from accepted edges the estimate can never grow to
fix itself. Measured: found stuck at 30%, forced at 90%. Below a confidence
threshold, take every duration-qualified sync and force nothing.

**`VS_MIN` was 280, the same number as `QUALIFY`** — so the field detector fired
on every horizontal blanking interval and the refractory period alone set its
rate. It reported 450 fields per second against the 59.94 there are, and the
vertical servo it steers could never settle. Bound it by the line period
instead of by a guess at pulse widths: a run longer than one line (2048 > 1716)
cannot fit inside a line at all, so only the vertical interval can produce one.
That argument cannot be wrong, where "somewhere between 275 and 683" was.

**A peak detector must not snap to new extremes.** Capturing any lower sample
instantly pins the floor to the bottom on one noise spike, and the threshold —
floor plus a fraction of the span — then sits far below the real blanking level,
so the low-run qualifier never triggers. Approach one code per sample, release
one code per 64. On screen the threshold line sitting near the bottom of the
trace was the same fact, seen directly.

### Vertical position: servo, never jump

Restarting the output frame on the detected field moves it by up to a whole
field in one step. A sink shown that drops the link outright — "no signal", at
the exact moment the capture first achieved lock, which reads as a regression
and is the opposite. Trim the frame by one line instead: sample where the output
stands when the field arrives and make the next frame one line longer or
shorter. A line either way is far inside what any sink tolerates.

**The dead band sets the size of the vertical wander, directly.** The loop
cannot rest in the middle of it: the standing frame-rate error has to be given
back a line at a time forever, so it rests against whichever edge opposes the
drift. Moving `V_TARGET` only moves the picture -- the error stayed seven lines
out either way. A five-line dead band therefore means five lines of slow creep;
one line means one line of dither several times a second, which is much less
visible. Measured across 21 frames, the phase error spans a single line.

The servo also has to absorb a standing frame-rate error, which a one-shot
alignment cannot. 800x525 at 25.2 MHz is 60.000 Hz against NTSC's 59.940, so the
servo gives back half a line every frame forever and the picture dithers by a
line a couple of times a second. **`H_TOTAL` is therefore 801, not 800**:
801x525 is 59.925 Hz, four times closer, at a cost of one column of back porch.
(780x539 would be exact, but it moves the totals far enough that a picky capture
card may stop recognising the mode.)

**A 240p source needs a 524-line frame** (2026-09-27).  Most game consoles send
262 lines every field, not 262.5 -- 60.05 Hz, which wants 523.9 output lines,
1.13 a frame short of 525 and more than the servo's one line can give back.  A
console's picture therefore crept up the screen, measured at 0.15 rows a frame.
`ntsc_capture` now reports `field_clks`, the clocks between field events
(419619 every field for 240p; 419619/421221 alternately interlaced), and
`top_ntsc_hdmi` sets the frame's base length from the sum of the last two: 524
under 840039, else 525, only for a plausible pair and only once two pairs agree.
On the board the console's picture then held within 0..2 rows over 240 frames.
Count clocks, not lines: a line count read 258 and 259, because the vertical
interval's lines carry no line start.

### Replay a real capture in simulation — `make sim-capture`

`sim/ntsc_capture_tb.v` feeds recorded ADC samples into `ntsc_capture` and
reports found, forced, qualified, fields, lock and the slicing levels. A
parameter change costs a second instead of the three minutes a synthesis,
programming and video-capture round trip takes, and it needs neither the board,
the source, nor a working HDMI link — which is what made it possible to keep
going when the link died mid-session.

Two stimuli, both from `sim/ntsc_capture_19lines.hex`, resampled 27 → 25.2 MHz:

| file | sync amplitude | stands for |
|------|----------------|------------|
| `sim/ntsc_25msps.hex` | 36 codes (98 against 134) | a healthy source |
| `sim/ntsc_25msps_weaksync.hex` | 8 codes | the M5 generator |

The weak file is the first with everything below blanking compressed to about a
fifth. It reproduces the hardware's symptoms closely — 54% of lines found and
more qualifications than there are lines — which is what makes it worth
trusting. `THR_SHIFT`, `QUALIFY`, `VS_MIN` and `RELEASE` are in the module's
parameter *port list* specifically so the bench can override them; a parameter
declared in the module body cannot be overridden by name (Icarus says so
explicitly, Yosys does not care).

Note what the stimulus cannot do: it is 19 lines looped, so it contains no
vertical interval and cannot validate field detection, and its picture is a
nearly blank raster so `f_max` does not represent a real scene. Roughly one
forced line per loop seam is an artifact, not a defect.

**Make the sweep stop when a build fails.** `vvp` will happily re-run the
previous binary, and a sweep that reports identical numbers for every setting
reads as "this parameter does nothing" rather than "nothing was built". That
wasted a round here.

### Slice between sync tip and blanking — the levels, measured

A median line profile of the real capture, aligned on the sync edge, at
25.2 MHz:

| | samples | time | nominal |
|---|---|---|---|
| sync pulse | 0..115 | 4.58 us | 4.7 |
| colour burst | 134..197 | starts 5.3 us, lasts 2.5 | same |
| active video | from 237 | 9.4 us | same |

So the textbook offsets are right, and an earlier comment in `ntsc_capture.v`
claiming this source blanks for 25 us was an artifact of measuring with a
threshold above blanking, which counts the dark end of the picture as part of
it.

**The threshold must land between the sync tip and blanking**, and everything
follows from whether it does:

- Below blanking, what falls under it is the sync pulse alone -- 115 samples --
  and nothing in the picture can trigger at all, because picture content never
  goes below blanking. The run starts at the sync edge, so the trigger has a
  position that does not depend on the picture.
- Above blanking, the run is the whole blanking interval *plus any dark content
  adjoining it*. On 75% bars the last bar is blue at about 8 IRE, dark enough to
  join in, so the run start -- and the trigger, `QUALIFY` samples later --
  moves with the picture.

`QUALIFY` then has to be the sync pulse's length, not blanking's: 88 samples,
with anything from 72 to 104 measuring identically. 64 fails because equalising
pulses are 58. `VS_MIN` becomes 400, between a 115-sample line sync and a
683-sample vertical broad pulse.

Deriving the offset from the *sync* amplitude (half of `black - f_min`, what a
textbook slicer uses) was tried and does not work: `black` is the back porch
level, and the back porch window is positioned relative to a line start that
does not exist until sync is found. Before lock it reads whatever it lands on --
166 against a blanking level of 133, in simulation -- and pushes the threshold
above blanking, which is the failure it was meant to prevent.

### The floor tracker's release rate sets everything downstream

`f_min` is held down by the sync tip, which comes round once a line. Releasing
one code every 64 samples lets it climb **25 codes within a single line**, so by
mid-line the threshold has floated above blanking and the design is in the
"above blanking" regime described above for half of every line. Replayed
through the bench, that fired the field detector 21 times in 800 lines of a
stimulus containing no vertical interval whatsoever.

`RELEASE` is therefore 10 -- one code per 1024 samples, 1.5 codes per line.
Measured across both stimuli:

| RELEASE | healthy source | weak source | spurious fields |
|---------|----------------|-------------|-----------------|
| 6 | locked, 717 found | locked, 838 found | **21** |
| 8 | locked, 717 | **119/255, 451 found** | 0 |
| **10** | **locked, 717** | **locked, 717** | **0** |
| 12 | **fails to lock** | locked, 717 | 0 |

Both neighbours break something, so 10 is not a value to nudge casually.

### Read the board's own HDMI output back through the capture card

The single biggest workflow change in this project. A UGREEN HDMI capture stick
is on the Mac, so the output can be read programmatically:

```sh
ffmpeg -f avfoundation -list_devices true -i ""          # UGREEN-25854 is [0]
ffmpeg -f avfoundation -video_size 640x480 -framerate 60 \
       -i "0" -frames:v 40 -fps_mode passthrough cap%02d.png
```

**`-video_size 640x480` is required.** Without it the card defaults to 1080p and
returns a card reading "Please re-select the capture resolution", which looks
like a board fault and is not one.

Two things then become possible, and both replace a person at the bench
describing what they see:

- **Read the diagnostic bars exactly.** Scan each bar's row for the contiguous
  run of its colour from x=0. Match with a tolerance of about 60 per channel
  (the card delivers uyvy422, so colours arrive slightly off) and allow a gap of
  a few pixels — the red tick marks are drawn *over* the bars and will otherwise
  end the scan early, which silently reports the tick's position as the value.
- **Recover the captured waveform.** The scope trace is drawn at
  `y = 479 - (val*15)/8`, so inverting that per column returns the actual ADC
  samples. A real line read back this way showed blanking runs of 372 and 558
  samples broken up by dips of 9 to 45 — which is how the glitch-tolerance
  question below got settled.

Measuring picture quality directly is better still: find a strong edge on each
line and look at the spread of its position. That turns "it wobbles a bit" into
"the left edge of the white bar spans 24 pixels line to line", and a change that
halves the number is unarguable. Steady state at the time of writing is a
5-pixel median spread with 4% of lines further than 6 pixels out.

**A diagnostic can measure itself.** `run_min` -- the shortest per-line low run
-- was closed out at `line_edge`, but a detected line *starts* the instant the
run reaches `QUALIFY`, so it always reported `QUALIFY` minus a sample or two
whatever the signal did. Lowering the threshold appeared to lower the
measurement, which reads as confirmation and is circular. Close the measurement
out when the run ends, not when the line starts.

### The design target is a source with no sync step at all

Production input will be M5 quality or worse, so this is the case to be good at,
not a defect to work around. With no sync step the only handle on a line start
is how long the signal sits at the floor -- and that run is not the 275-sample
blanking interval either. With the threshold a few codes above the floor, the
**colour burst swings back above it and cuts the run short at about 135
samples**. `QUALIFY` therefore has a hard ceiling that has nothing to do with
blanking's nominal length, and finding it needs a sweep, not arithmetic:

| `QUALIFY` | found | displaced lines |
|---|---|---|
| 88 | 65% | 21% |
| 108 | 51% | 11% |
| **124** | **83%** | **5%** |
| 132 | 83% | 7% |
| 140 | 54% | **90%** |
| 150+ | qualifier stops firing almost entirely | |

Longer is better right up to the cliff, and the reason is worth keeping. False
qualifications are not harmless noise: a picture edge that dips below the
threshold at the same point on every line is a **self-consistent false lock**,
and the flywheel will sit on it happily for several frames before something
disturbs it. That is what the occasional glitch is -- bursts of five to ten
consecutive displaced frames, not isolated bad lines. Measuring a single capture
right after programming will not show it; capture, discard, capture again, and
count displaced *frames*.

Adopting 124 moved detection from 74% to 83%, confidence from about 200 to 250
of 255, and unsliceable lines from 12% to 6%.

A video stabiliser or distribution amplifier that regenerates sync would help
more than anything on this side can, because the sync amplitude is information
that is genuinely missing rather than merely hard to extract.

### Detection and position want different thresholds — and you cannot have both

The clearest result of the whole bring-up, from sweeping one number on the
board and measuring the picture each time:

| slice | unsliceable lines | false qualifications | lines >6px out of place |
|-------|------------------|----------------------|-------------------------|
| `span>>3` (above blanking) | **102/s** | many | **56%** |
| `span>>5` (inside sync) | 1587/s | none | **4%** |

A slice above blanking sees essentially every sync, because it only has to
notice that the signal went dark. But what it measures is blanking *plus
whatever dark picture adjoins it* -- on 75% bars, the blue bar at the end of the
previous line -- so the run begins where the picture says and the trigger, a
fixed count later, moves with it. A slice inside the sync pulse has a position
immune to the picture and cannot see a tenth of the lines, because sync tips
vary by a few codes and the slice sits four above the floor.

A two-threshold scheme -- high slice to detect, low slice's falling edge for the
position -- was built and removed. It delivered on detection: unsliceable lines
1894/s → 204/s, and false qualifications gone (15257/s against a line rate of
15667, where one threshold gave 18278). It did not deliver a picture: displaced
lines went 4.3% → 11%, because the duration test can *complete before the sync
edge it belongs to* when the run starts early, leaving no edge to wind back to.
Holding the qualification until the next edge arrived made it 34%. The code is
gone but the note is in `ntsc_capture.v`; do not rebuild it without a plan for
that case.

What did help, and is kept: a forced line fires `FMARGIN` samples late by
design, and a run of them is late by `FMARGIN` more each time, so the picture on
those lines walks right. Carrying that lag and applying it to the *window
positions* -- never to `ccnt` itself, which also drives the end-of-line wrap and
the bank swap, nor to `pcnt`, which is the flywheel's own reference -- puts the
picture back without touching the timing. Both of those were tried the wrong way
first: correcting `ccnt` swapped banks mid-line, and correcting `pcnt` removed
the margin's whole purpose and dropped detection from 89% to 49%.

### Three fixes that measured worse, and why

Kept because each looks obviously right and the next person will try them.

**Bridging brief excursions above threshold (`GLITCH`).** Blanking sits only a
few codes under the slicing level, so noise crosses back over it; letting a run
survive sixteen samples of that raised the qualifier's hit rate as intended. It
also tripled the jitter -- 24 pixels of line-to-line edge spread against 7 --
because bridging moves the trigger as well as saving the run. A dip in the
picture just before blanking welds on, the run starts early, and the QUALIFY-th
sample arrives early by the same amount. The run's only value is a position, and
this buys detections by spending it.

**Narrowing the acceptance window (`P_WIN`) to 96.** `in_window` is a lower
bound only, so once a line starts in the wrong place the next sync falls outside
the window and there is no way back. Edge spread went to over 400 pixels and
confidence collapsed. The width is load-bearing; leave it at half a line.

**Tightening the forced-line margin.** Eight samples makes every forced line
eight samples long-- half the lines are forced, so that is real displacement.
One and two both measured worse than eight, and four was no better: a tighter
margin lets the forced start pre-empt a genuine edge, and losing the detection
costs more than the displacement saves. Eight is a local optimum, not an
oversight.

### Diagnostics belong on screen, as bars with known targets

Every bar has a tick mark at the value it should reach, so reading it needs no
arithmetic and no serial link: found and forced lines, field events per second
(tick at 59.94), shortest and longest low run per line (ticks at `QUALIFY` and
`VS_MIN`), and the vertical phase error. Ask "is the bar left or right of the
tick" and each answer is worth more than a paragraph of description. Setting
`QUALIFY` stopped being a guess the moment the shortest measured run was drawn
next to it.

Note that this makes the person at the bench the instrument, so ask for
comparisons, not readings. "Is the white bar past the red line" works; "how long
is the low run" does not.

### This source has no sync amplitude, and it costs real robustness

Sync tip and blanking sit at the same level (see the colour-bar source section),
so the sync *pulse* cannot be sliced out by voltage at all. What reads as "below
threshold" is the whole horizontal blanking interval, whose measured length
drifts between 250 and 280 samples with the threshold — against the 248 that
picture content can reach. `QUALIFY = 280` misses about a third of lines and
`QUALIFY = 256` was worse, not better. There is no good value; the margin is
gone because the information is gone. Fixing the generator is worth more than
any further tuning here.

## Step 3 — colour: the burst-locked NCO

`src/burst_nco.v`, validated by `make sim-burst` against a synthetic burst of a
phase we chose, because a recording does not come with the right answer. It
locks to within about 10 degrees and holds through +/-100 ppm of source
frequency error.

Design notes that were not obvious:

- **No multipliers**, so the phase detector correlates against the *sign* of the
  reference. A square-wave correlator has the same zero crossing as a sine one.
- **The burst is half-wave** on this source -- blanking is the bottom of the ADC
  range, so its negative lobes are missing. Phase survives that; amplitude does
  not.
- **Derive the increment from the sample rate, not from a tuning word**:
  2^32 x 3.579545 / 25.2 MHz is 0x245D16F8, exact to under a part per billion.

Four bugs found here, all of which produced plausible, stable, wrong behaviour:

1. **`~phase[31]` is the sign of *sine*, not cosine** -- the first half turn is
   where sine is positive. Getting the quadrature backwards still leaves a
   stable lock, just a quarter turn from the intended one.
2. **The loop sign was inverted.** It settled at the unstable point, 74 degrees
   out, and reported itself locked.
3. **`inc + (err >>> KI)` evaluates unsigned**, because `inc` is unsigned, so
   the arithmetic right shift became a logical one and a negative error arrived
   as a number near 2^32. The increment ran from 610 million to 1.68 billion on
   the first line. Evaluate shifts into a signed wire *first*, then add.
4. **Sign-correcting the error by the in-phase correlation** -- `err = i<0 ? -q :
   q`, the obvious way to resolve the half-turn ambiguity -- puts a
   discontinuity at i = 0 and the loop locks to *that*: i dithered about zero
   while q sat at -180 and never moved. Use q alone; its two zeros are one
   stable and one not, so the loop finds the right one by itself, and the loop's
   sign decides which.

And two bench bugs, both of the same family as everything else in this project:

- **The testbench's progress trace replaced the main wait**, so every run was
  200 lines regardless of `LINES` -- which made the integral gain look like it
  did nothing when it was simply never given time.
- **Reading i and q once at the end** samples an arbitrary point of the loop's
  once-a-line dither. An eightfold change in loop gain looked like no change at
  all. Average |q| over the last few hundred lines instead.

The 10 degree residual is a dither, not a bias: neither loop gain (16..20) nor
burst gate length (56..70 samples, 7.95..9.94 subcarrier cycles) moves it, which
points at harmonic products between the square-wave correlator and the half-wave
burst. A three-level reference with zero segments at the crossings cancels the
third harmonic and is the way to improve it.

### On the board: it locks, and the residual is not the loop's fault

Integrated into `ntsc_capture` -- fed the raw sample, the back porch level as
its zero, and the burst gate at 240..300 -- and read off the screen:

| | simulation | board |
|---|---|---|
| plain sign reference | 10.0 deg | 22.7 |
| three-level reference | 6.6 | 17.2 |
| error averaged over 8 lines | 8.0 | 24.1 |

**Chroma lock holds on every frame captured, in every configuration.** The
three-level reference is a real improvement on both; the averaging is not
measurable on the board, and repeating the same build varies by five degrees, so
treat differences under that as noise.

The residual matters less than it looks, and the arithmetic says why the loop is
not where to look for it: the subcarrier is **7.04 samples per cycle**, so one
sample of line-start jitter is **51 degrees** of subcarrier phase. Against that,
the difference between a good and a bad loop gain is nothing. The NCO free-runs
across lines and is only nudged once a line, which is what keeps it usable at
all -- but anything that wants absolute phase per sample has to reckon with
where the line started, not just with the burst.

### First colour, and what it shows

Y/C separation, quadrature demodulation and YUV to RGB are in `ntsc_capture`,
and the picture comes out in colour. Two things are wrong with it and both are
informative.

**A seven-sample boxcar is the right filter for this design, twice over.**
25.2 MHz over 7 is 3.600 MHz, which puts the boxcar's first null essentially on
the 3.5795 MHz subcarrier -- about -45 dB, against -18 for the eight-tap version
that would divide by a shift. The same seven-sample window then integrates the
demodulated chroma over exactly one subcarrier cycle, which is what cancels the
sum-frequency product the mixer leaves. Dividing by seven is x37>>8, a 1% gain
error the luma gain absorbs.

The luma path previously averaged sample *pairs*, which is a two-tap boxcar and
only 1 dB down at 3.58 MHz -- that is why the monochrome picture always showed
the subcarrier as fine vertical stripes.

**Diagonal hue striping.** The hue slides progressively from line to line. That
is the line-start jitter again, seen through a much less forgiving instrument:
the subcarrier is 7.04 samples per cycle, so a single sample of jitter is 51
degrees of hue. The NCO free-runs across lines and is nudged once a line, so it
tracks the 227.5-cycles-per-line relationship correctly on average, but the
per-line residual lands straight in the colour.

The fix is the one every real decoder uses: take the burst phase *per line* and
demodulate that line against it, rather than against a filtered average. The
loop is then a frequency reference and the burst is the phase reference.

**A constant hue rotation** on top of that, which is expected and not yet
addressed: the burst sits at a defined angle from +U, and nothing has calibrated
that offset. The bars carry published YUV values, so this is arithmetic against
a measurement rather than a knob to turn by eye.

### The source breaks the one relationship NTSC colour is built on

Measured, and it settles what the striping is:

| | |
|---|---|
| this source's line rate | 15779.6 Hz, **+0.29%** on NTSC's 15734.3 |
| subcarrier, from the burst | 3.579545 MHz |
| **fsc / fh** | **226.847**, where NTSC *defines* 227.500 |
| line-to-line subcarrier step | **304.8 deg**, where NTSC gives exactly 180 |

That 124.8 degrees per line of extra rotation is the diagonal striping, and it
is not a decoding fault. NTSC fixes fsc at 227.5 x fh precisely so that the
subcarrier's phase at each line start alternates by half a cycle and a decoder
can run one continuous oscillator across a field. A source that misses the ratio
is internally inconsistent between its colour and its timing, and no amount of
lock quality helps: the loop is tracking a burst that does not agree with the
chroma that follows it.

Three attempts, all measured, none of which fixed it:

| attempt | hue wobble on the board | picture |
|---|---|---|
| loop as designed (KP 19) | 29 deg | diagonal striping |
| full per-line correction (KP 23) | 48 | diagonal striping |
| hard snap to a constant at burst end | -- | striping turned horizontal |

The snap is instructive: snapping to a *constant* assumes the oscillator is
already at the burst's phase, which throws the per-line measurement away rather
than using it.

**A CORDIC settles it.** `src/cordic_atan.v` gives the burst angle each line by
vectoring -- shifts, adds and a sixteen-entry table, no multiplier, which is why
it fits where the honest rotation (four variable-by-variable multiplies) does
not. Sixteen iterations take 127 ns out of a 63 us line, and `make sim-cordic`
measures better than 0.4 degrees of error at a correlation magnitude of 200,
which is what the real burst produces. `phase_ref` is then the oscillator less
that angle, and the line-to-line hue instability goes: the bars come out as
stable flat colours instead of striped ones.

It replaced a sixteen-sector approximation -- octant from the two signs and |i|
against |q|, then one comparison against tan(22.5) -- which is worth recording
because it *half* worked and that was informative: the striping stopped being
diagonal, so the progressive rotation was genuinely gone, but 22.5 degrees of
quantisation left the hue visibly stepped line to line. Resolution was the
missing thing, not the idea.

What remains is a constant hue rotation, and calibrating it is not finished.

Read off a clean capture, the picture is seven flat 80-pixel bars starting at
x=16, and their hues come out as 172, 66, 85, 274, 237 and 280 degrees against
the standard 60, 180, 120, 300, 0 and 240. **No single rotation fits that**, but
`h_measured + h_expected` clusters (232, 246, 205, 214, 237, 160) where
`h_measured - h_expected` does not -- which says the decode carries a
*reflection* as well as a rotation, so a sign is wrong somewhere between the
mixer and the RGB matrix.

Negating V is the obvious candidate and it is not the right one: saturation
collapsed from 0.72..0.92 to 0.04..0.12, which is cancellation rather than
reflection. The sign belongs somewhere the two components are still separable --
most likely in which mixer output is called U and which V, or in the sense of
the quadrature reference, rather than after the fact in the matrix.

### The calibration harness, and two more circular-average bugs

`scratchpad/calib.py` fits the eight bars to the picture and measures each one's
hue against its published value. Getting it trustworthy took fixing three
things, and the first two are the same mistake at two different levels:

- **Averaging RGB across frames** pulls every bar towards grey, because the hue
  wobbles twenty-odd degrees and hue is circular. It reported saturations of
  0.03..0.13 for bars that are 0.6..0.75 in any single row.
- **Averaging RGB down a column** does the same thing for the same reason. Fix
  both by averaging the hue as an angle, weighted by saturation, and reporting
  the coherence -- the vector length over the scalar mean -- so a meaningless
  average announces itself.
- **Fit the bars on luma**, which does not cancel, not on colour.
- Reject frames where the HDMI link has dropped; a black frame reads as fully
  saturated in HSV, so "pick the most saturated frame" picks a dead one.

### The per-line correction was inert, and finding out why took a third pass

`cordic_done` is one cycle of the 126 MHz clock and it was being consumed inside
the 25.2 MHz sample strobe. That does not merely miss it sometimes: the result
lands 17 clocks after a start that is itself on a strobe, and 17 mod 5 is 2, so
**the two never coincide at all**. `burst_off` stayed at zero and the whole
per-line correction did nothing.

This is the second time the same mistake appeared in this design -- `vs_seen`
was the first -- so it is worth stating as a rule: **anything crossing from the
126 MHz clock into the sample-rate logic has to be a level the consumer clears,
never a pulse.**

It also corrects an earlier conclusion here. The improvement attributed to
"adding the CORDIC" was really "removing the sixteen-sector approximation",
because the CORDIC's answer was never reaching the reference. With the crossing
fixed, the per-line correction genuinely works: the smooth rotation down the
picture is gone, and coherence -- the circular mean's vector length over the
scalar mean, per bar -- goes from 0.11..0.45 to **0.85..0.92**. What is left is
random per-line hue noise of about +/-40 degrees, which is what a 19-code burst
buys.

### Hue is the wrong space to measure chroma in, and that explains both puzzles

Two things looked inexplicable: applying two *constants* (a sign flip and a
rotation) dropped the per-bar coherence from 0.85 to 0.19, and the rotation's
median came out 251 degrees on one capture and 311 on another. Neither is
mysterious once the measurement moves to the right space.

**The YUV to RGB matrix is not a rotation.** R takes 1.140 V while B takes
2.032 U, so the chroma plane is anisotropically scaled on its way to RGB. A
given phase wobble therefore produces a hue wobble whose size depends on *where
in the plane* the colour sits. A constant rotation moves every bar to a
different part of that map, so it changes the measured hue coherence without
touching the phase stability, and a "median hue error" is not the plane's
rotation at all.

`scripts/calib_uvfit.py` measures in the UV plane instead. The decoder's matrix
inverts exactly -- its inverse is the standard luma sum -- so the demodulated
pair is recoverable from the RGB it produced:

    Y = 0.299R + 0.587G + 0.114B     v = (R-Y)/1.140     u = (B-Y)/2.032

With (u,v) measured and (U,V) known for each bar, one 2x2 least-squares fit
gives the whole transform, and **the sign of its determinant answers the
mirror question outright** rather than by comparing spreads. In that space
coherence reads 0.86..0.98 and the mirror is unambiguous.

### Chroma clipping is phase-dependent, and it looks exactly like phase noise

The other thing this turn established, and it changes the order of the work:
**set the chroma gain below clipping before calibrating anything about phase.**

At `CHROMA_SHIFT` 2 with the mirror applied, most bars clip, and clipping a
rotating vector distorts its angle by an amount that depends on the angle --
which shows up as line-to-line hue striping indistinguishable from a phase
problem, and drags the measured coherence to 0.16..0.63. Drop the gain two
shifts and the same build reads 0.86..0.98.

It also invalidates a gain measurement made earlier: a UV fit taken while the
phase still wobbled put the gain at 0.367, and acting on that (one shift up)
clipped nearly every bar. Wobble shrinks a vector average without shrinking the
signal, so **gain must be calibrated after phase, never alongside it.**

The rotation constant is still not pinned. Sweeping it gives residuals that do
not move smoothly with it -- 167 deg to 70.6, 106 to -61.1, 37 to -79.4 -- and
successive captures of the *same* build disagree on the fitted gain by a factor
of five, which says the decode state itself drifts between captures rather than
the fit being noisy. That is the thing to chase next, and it is a stability
question rather than a calibration one.

Two implementation notes worth keeping:

- **`small` is a Verilog keyword** (a trireg charge strength). Yosys accepts it
  as an identifier and Icarus does not -- the same trap as `expect`.
- **The unwrap has to be pipelined.** A sixteen-way case feeding a 32-bit
  subtract feeding two comparisons feeding a mux drags the capture clock from
  140 MHz to 100, under the 126 it must make. The answer is not needed for a
  whole line, so registering the sector and unwrapping it on the next sample
  costs nothing.

### The burst timeout was shorter than the vertical interval

`burst_nco`'s `burst_age` watchdog drops the lock -- and resets the learned
subcarrier frequency -- when no qualifying burst has arrived for a while. It was
15 bits: 32767 samples, or **20.5 lines**. The vertical interval carries no
burst at all and is about 20 lines.

So it timed out once per field, every field, by construction. The loop
re-acquired sixty times a second and the picture spent most of its time in the
monochrome fallback that `COLOUR && burst_locked` selects. Measured on the
board: **colour held in 17 of 50 live frames; with the counter widened to 18
bits, 50 of 50.**

The watchdog is worth keeping. It just has to be longer than the longest gap a
*valid* signal contains, and that gap is the vertical interval, not a line.

### Judge the picture by counting rows, not by a chroma-noise figure

`scratchpad/quality.py` classifies every row of the picture as correct, dropped
or torn, using the one thing known about the test pattern: eight bars of
monotonically decreasing luminance. A dropped row has no bright first bar; a
torn row has the order broken; a noisy row has neither, which is the point --
the three defects are counted separately instead of summed into one number.

This replaced a median row-to-row colour difference, and the replacement was
not cosmetic. That metric measures chroma noise only, and being a median it is
robust to outliers *by construction*, so rows that are dropped or torn cannot
move it. It preferred a tracking weight of 4 over 2 by a tenth of a code while
the picture at 4 was visibly worse -- and it was, by ten times the torn rows.
The eye was right and the number was measuring the wrong thing.

Two cautions on reading it:

- **The bottom quarter of the pattern is a grey ramp whose first step is black**,
  so a "black row" test sampling the left of the picture scores the ramp as
  dropped. Only the bar region means anything.
- **The dropped figure carries real run-to-run variance** -- 2.8% and 5.9% on
  the same build, minutes apart. The torn figure is steady, so treat a small
  change in dropped as noise and a change in torn as signal.

Pushing the frame down to move the vertical interval off the top of the picture
(`V_TARGET` 488 to 504) made everything worse -- correct rows 97.0% to 92.6%,
torn rows 0.2% to 4.4% -- so the black at the top is not simply the vertical
interval sitting a few lines inside the visible area.

### Track the burst angle; do not believe each line's measurement

**Superseded (2026-09-26):** tracking is now off by default -- with eight
working bits each line's measurement is good to a degree, and the tracker's
memory was drawing horizontal hue bands.  See *The horizontal hue bands*.

`burst_nco` now predicts this line's burst angle from the last one plus a
learned per-line step, and blends the measurement into that rather than taking
it raw. The step is real and nearly constant -- 124.8 degrees per line on this
source, 180 on one that honours fsc = 227.5 fh -- so tracking it costs nothing
in following the rotation and buys a square-root in noise.

Three things this needed, all of which had bitten before:

- **The step needs two measurements to seed.** Deriving it from one makes the
  step equal to the angle, and the loop then has to unwind a whole turn of wrong
  prediction. Hence `have_prev` before `have_step`.
- **`track_pred + (track_err >>> TRACK_P)` evaluates unsigned**, because
  `track_pred` is, so the arithmetic shift becomes logical and a negative error
  arrives as a number near 2^32. Third occurrence in this design. Compute the
  shifts into signed wires first.
- **Split it across two clocks.** Add the adjust, subtract the prediction, shift
  twice, add twice does not fit: 125.87 MHz against the 125.94 needed. It runs
  once per line, so there is a line's worth of slack.

Measured on the board, and it works: the median row-to-row colour difference
inside a flat bar goes from **3.7 codes to 1.3**. Per bar the improvement is
consistent -- 6.9 to 2.7, 9.4 to 1.5, 5.9 to 2.8 -- and `sim-video` is unchanged
at `bad_channels=0, max_error=17`.

`TRACK_P` was swept against that number: off 3.7 | 2 → 1.8 | 3 → 2.5 | 4 → 1.7
| 6 → 12.7. Two through four are one measurement's variance apart and six is
plainly too slow to follow the rotation, so the useful range has a floor and a
cliff, and 4 sits in it.

**Measure the artifact, not a physical quantity that stands in for it.** The
obvious metric here was per-line chroma phase noise in degrees, and it fought
back: high chroma gain clips, and clipping bends the angle by an amount that
depends on the angle, so it counts as phase noise; low gain drops the
correlation below any sensible magnitude floor. The window between the two is
narrow. Median row-to-row colour difference has neither problem -- it is what
the eye calls streaky, it survives clipping, and it assumes nothing about hue.

### Bits 2, 3 and 6 are the pin choice, not the converter

**A second board with a second AD9280, read with the identical bitstream on the
same source minutes apart, shows exactly the same three bits dead.**

| | distinct codes | b2 | b3 | b6 | others |
|---|---|---|---|---|---|
| original board and part | 18 of 256 | 0.00 | 0.00 | 0.00 | 0.46..0.95 |
| new board, new part | 29 of 256 | **0.00** | **0.00** | **0.00** | 0.45..0.67 |

That retires the diagnosis recorded here earlier -- "U1's D2, D3 and D6 output
stages are stuck low; the part needs replacing" -- which was wrong.  The
evidence for it was a known DC input returning the wrong code, and that evidence
was real; it simply does not distinguish a converter that cannot produce a bit
from an FPGA pin that cannot receive one.  Replacing the part was the cost of
finding that out, and it was worth paying: nothing else would have settled it.

What is left is the carrier board's pin choice.  `adc_d[2]` is FPGA pin 42,
`adc_d[3]` is 41, `adc_d[6]` is 31.  Also ruled out, each by measurement: an
open joint, a short to ground (130 kOhm, same as a working bit), the read-back
path, the source, the sampling phase, the ADC clock duty, and the IO standard
(LVCMOS18/25/12 all read identically).  Pins 41 and 42 are named as the analog
audio outputs in Tang Nano 20K reference material, but that reference describes
a dock with external conditioning, so it does not settle what is attached on the
bare module, and pin 31 is still unidentified.

**The test to run next, and it is self-contained.**  Do not try to read pin
state from outside again -- the scope path returns contradictory answers on a
board with no signal, and three attempts went that way.  Instead drive those
three pins as outputs from the FPGA with a known pattern and read them back
through the same IO, which needs no external instrument and no interpretation.
A pin that reads back what it was driven is usable and the fault is elsewhere; a
pin that does not is unavailable on this module, and the three signals need
moving to free pins -- three bodge wires, not a respin.

Until then the cost is bounded and small: 24 of 256 codes, and the picture still
measures 100% correct rows, because the luma path's seven-sample boxcar averages
the dither across the missing range.

### The respun board works: all eight bits, measured (2026-09-24)

The corrected carrier arrived and was measured with a new Tang module, using the
same scope bitstream recipe as the baseline (`SCOPE_ONLY=1 SCOPE_FULL_RANGE=1
DEFAULT_PHASE=2`, seed 3) so the two numbers are directly comparable:

| | distinct codes | min..max | b0 | b1 | b2 | b3 | b4 | b5 | b6 | b7 |
|---|---|---|---|---|---|---|---|---|---|---|
| old pins (42/41/31) | 18 of 256 | 0..179 | .50 | .95 | **.00** | **.00** | .47 | .46 | **.00** | .48 |
| respun (72/76/75) | **79 of 256** | 80..191 | .59 | .47 | **.64** | **.33** | .56 | .67 | **.48** | .52 |

Every recovered sample used to satisfy `y mod 16 in {12,13,14,15}`; the residues
are now spread across all sixteen. The diagnosis was right and the fix is real.

Two variables changed at once -- the carrier *and* the module -- so if a later
result ever disagrees, the R7-bodged old board is still the reference that
separates them. Nothing so far needs it.

### The source does emit sync, and three conclusions here were made through a broken converter

With eight working bits the waveform reads cleanly, and it contradicts things
recorded above that were measured through five bits. All eight scope frames
agree, so these are not one-off readings:

| | code | volts (7.81 mV/code) | NTSC |
|---|---|---|---|
| sync tip | 82..85 | — | — |
| blanking (front porch) | **117**, on every frame | — | — |
| **sync step** | **33 codes** | 258 mV | 286 mV |
| peak white | 191 | — | — |
| burst | 63 samples = **2.50 us** | — | 2.51 |

So **retract "this source has no sync amplitude"** and the whole family of notes
built on it. It has a sync step within 10% of the standard one. What it does
have is a burst that swings 100..166 around a blanking of 117 -- positive-going
by 49 codes and negative-going by only 17 -- which is the half-wave clipping the
M5's DAC floor produces, and that part of the old reading stands.

The line geometry, measured from the sync leading edge, and what the standard
(`LEGACY_TIMING = 0`) window constants ask for:

| | measured | constant |
|---|---|---|
| sync pulse | 0..135 | `QUALIFY` 80, accepted up to 150 |
| colour burst | 135..198 | `BURST_START` 136, `BURST_END` 192 |
| back porch | 198..261 | `BP_START` 200 |
| active video | from ~261 | `ACTIVE_START` 252 |

The standard set is right for this source to within a few samples. Measured back
to back at seed 3, on the respun board, same capture protocol, second capture:

| | correct | dropped | wrong-order | colour frames |
|---|---|---|---|---|
| `LEGACY_TIMING = 1` (M5 geometry) | 18.4% | **47.8%** | 33.8% | **0 of 120** |
| `LEGACY_TIMING = 0` (standard) | 22.1% | **0.43%** | 77.5% | **120 of 120** |

Sync and colour both go from broken to essentially perfect. `correct` barely
moves because a different defect dominates it -- see the next section. The
legacy set exists only for a source with no sync step, so with the converter
fixed it is the wrong default for this one.

**And retract the mirror.** `scripts/calib_uvfit.py` on the standard build now
prefers a **pure rotation of 1.7 degrees** (rms residual 15.0) over a mirror fit
(residual 20.5). The earlier "the decode carries a reflection as well as a
rotation" was fitted to a picture produced by 24 expressible codes. There is no
sign error to find; the demodulation axes are already right.

The same fit reports a chroma gain of 0.152, and that number is *not* usable:
per-bar coherence is 0.46..0.67, and a vector average over a wobbling phase
shrinks without the signal shrinking. Gain is calibrated after phase, as recorded
above, and phase is not settled yet.

### The back porch is 16 codes low on some lines, and it is the dominant defect now

This is what 77.5% wrong-order rows is, and it is worth following because the
first two readings of it were wrong.

Inside a bar, the decoded luma alternates between two values on consecutive
*captured* lines -- each drawn twice by the bob, so the picture shows it as a
four-row beat:

| bar | bright line | dark line | difference |
|---|---|---|---|
| white 75% | 195 | 149 | -46 |
| yellow | 167 | 124 | -43 |
| cyan | 178 | 128 | -50 |
| green | 134 | 96 | -38 |
| magenta | 132 | 85 | -47 |

It looks like chroma leaking into luma, and it is not: **the white bar
alternates by as much as the coloured ones**, and white 75% carries no chroma.
The shift is additive and the same size everywhere, which is the signature of
the black reference moving, not of a gain or a phase error. The horizontal
position is identical on bright and dark rows (left edge x=7, right edge x=561
on both), so it is not a line that started in the wrong place either.

The raw waveform says it outright. Across 40 scope frames, ten distinct line
dumps:

| | value |
|---|---|
| sync tip | 82, on all ten |
| front porch | 117, on all ten |
| **back porch** | **117 on five, 101 on five** |

16 codes, bimodal, in the ADC samples themselves, with the front porch of the
same lines rock steady. `black` is averaged over 32 samples of back porch at
`BP_START` 200, so it faithfully follows a reference that is wrong, and
`16 x 2.8125` -- the luma gain at `gain_sel` 0 -- is 45, which is the measured
alternation.

**Resolved: it is the generator, and black now comes from the front porch.**
The AC-coupling explanation first recorded here was wrong -- a 1 uF input into
the AD9280's high impedance has a time constant of milliseconds, not
microseconds.  A full-rate recording (below) shows the cause directly: the M5's
`Panel_CVBS` uses two DMA line buffers and writes their breezeway, back porch
and right-hand edge only during the vertical interval, so the two carry
different blanking.  One line in two has its breezeway at sync level (a
132-sample sync) and back porch at 117; the other has breezeway and back porch
at 101 and its black bar at 85, near sync tip.  The front porch is 117 on both,
and it is blanking by definition on any source, so `black` is now its 16-sample
average, taken as the slicer first falls and committed only when that run
qualifies as a sync.  Measured: white-bar luma changes 2.3 codes line to line in
the replay and 0.7..1.3 on the board, against 46 before.

### A full-rate recording of the source, replayed in simulation (2026-09-25)

This is what turned three days of reading a picture into an afternoon of
measuring a signal, and it is the first tool to reach for next time.

- `make ntsc-tape-program` records 32768 consecutive ADC samples (20 lines)
  once, freezes them, and shows them as grey cells: two 4-pixel cells a
  sample, sixteen levels 17 apart, a calibration staircase and an identity
  header.  One HDMI frame holds the whole recording.
- `scripts/tape_decode.py OUT.hex FRAMES...` learns the levels from the
  staircase, reads each cell at its centre, votes across frames and rejects any
  frame whose header, completion flag or level spacing is wrong.  `make
  sim-tape` checks the recorder and the decoder end to end against a known
  memory image, pixel for pixel.  On the board: 12 frames, unanimous, worst
  decision margin 9 codes where the levels are 17 apart.
- `scripts/tape_trim.py` cuts it to a whole, even number of lines, so the loop
  keeps the subcarrier continuous and any line-alternating property in step.
- `sim/replay_tb.v` feeds it through `ntsc_capture` and writes every decoded
  line; `scripts/replay_quality.py` scores that -- and, with `--frames`, board
  captures -- with the same bar geometry.  Before any fix the replay predicted
  the board's white-bar line-to-line luma change to within a code (46.3 against
  45.1), which is what makes it trustworthy.
- `scripts/tape_reference.py` decodes the recording in floating point, per-line
  burst phase and all: what *this* signal should decode to, which is the only
  fair target when the source is imperfect.

`sim/m5_tape_18lines.hex` is the recording of the M5 through the respun board.

### Bits 0, 1, 4 and 5 were packed as LVDS receivers, and most of the M5's "quirks" were that (2026-09-25)

**Not the circuit: Apicula.**  gowin_pack configures every input buffer with
its *bank's* IO_TYPE, not its own, and forces a bank holding a true LVDS output
to LVDS25 (`check_io_banks`, `process_IBUF`).  Bank 5 holds the HDMI clock lane
(pins 33/34) and ADC bits 0, 1, 4 and 5 (pins 27..30), so those four LVCMOS33
inputs were packed as LVDS receivers, each A/B pair -- 27/28 and 29/30 --
compared against the other.  Bits 2, 3, 6 and 7 are in bank 1 and were never
affected.  Everything measured through bits 0, 1, 4 and 5 before this date is
suspect.

Found with a raw-read recorder -- both IDDR outputs of all eight bits, every
126 MHz clock for 16384 clocks, shown through the TAPE path and analysed
offline (a scratch build; on-chip counters gave answers that could not be
trusted):

- bank-1 bits changed at exactly one read position of ten, with no isolated
  glitch; bank-5 bits flipped at many positions, 1400 isolated glitches in
  32768 reads;
- the errors sat where a pair's two bits were *equal*: bit 0 = bit 1 = 0 gave
  3.25 wrong reads of ten per conversion, unequal 0.07..0.27 -- a differential
  receiver's signature;
- not noise: with the ADC clock stopped the same pins read perfectly.  Not
  carrier crosstalk: the old layout puts D4/D5 further from the clock trace
  than the clean D7.  Not an IO setting: input hysteresis changed nothing, and
  adc_clk at DRIVE=4 only cut it by a fifth.

**Fix: `scripts/gowin_pack_io.py`**, which every Makefile pack step now uses.
It packs single-ended IBUFs in a true-LVDS bank as their own IO_TYPE and
leaves everything else to Apicula (the probe design packs byte-identically).
The same routed design then records no glitch in 32768 reads, every bit
changing at one position.  Worth reporting upstream.

What the misreads had been doing, from a corrected recording
(`sim/m5_tape_fixedio_18lines.hex`) and the floating-point reference:

| bar | luma IRE | chroma IRE | hue | textbook |
|---|---|---|---|---|
| yellow | 59.9 | 24.3 | +166.0 | +167.1 |
| cyan | 47.1 | 33.5 | -84.1 | -79.0 |
| green | 40.6 | 33.9 | -121.9 | -119.3 |
| magenta | 28.1 | 34.9 | +60.0 | +63.5 |
| red | 21.1 | 36.4 | +100.8 | +103.5 |
| blue | 8.7 | 26.0 | -13.6 | -12.9 |

The M5 sends nearly textbook bars.  **Superseded, below:** bars out of luma
order, pale yellow and cyan, the "101/166 square wave" burst, porches at
117/101 and a black bar at 117/85 (16 and 32 codes: bits 4 and 5), the
boot-dependent blanking, and the diagonal crawl.  Against the morning's
recording, the products at 25.2 - 6 fsc and 8 fsc - 25.2 fall by 39 and 47 dB,
to 0.0..0.1 codes.  **The LC filter is not needed.**  C13 at 680 pF now only
costs chroma: about -2.5 dB at 3.58 MHz from the 57.5 ohm source, where the
schematic's 100 pF costs 0.1.

The decoder replays the corrected recording within 5 degrees of textbook hue,
1.6..2.5 degrees line to line, luma in order on every line.  On the board it
exposed two more things:

- **The burst tracker's trap** (found on the `sample-clock` branch): with the
  corrected signal it caught every load -- hue out by 70..90 degrees, stripes
  line to line.  The escape -- a running mean of the tracking miss, relearning
  the step above 45 degrees -- is now in master, judged a clock after the
  update so 126 MHz still closes; `sim-tracking` knocks the step half and a
  third of a turn out and requires recovery within 14 lines.
- **Master's placement lottery is real.**  Seeds 3, 5 and 11 of one netlist,
  each consistent across its loads: seed 5 hue +3/+0/-6/+7 degrees, 0.8..2.5
  line to line, median row-to-row difference 1.2..2.3 (4.8 before); seed 11
  about 32 degrees line to line; seed 3 wrong colour.  `NTSC_SEED` was 5.  The
  `sample-clock` branch has no ALU cells and was measured not to depend on it;
  it is merged now (*The decoder on the pixel clock*).

### A broken input is shown, not blacked out (2026-09-26)

Wanted behaviour, from the bench: a damaged or missing signal should come out
as noise, the way a television shows it, never as a black screen.  It did not.
Lines were published only from line starts, and while acquiring there are no
forced ones (*Do not run the flywheel during acquisition*), so a signal with no
usable sync published nothing: black before the first lock, and after losing
lock, four flywheel lines and then the last good line repeated down the whole
screen.

`FREE_RUN` restarts only the write window -- `ccnt`, just before
`ACTIVE_START`, one nominal line apart -- whenever acquisition has gone a line
and more without a start.  `pcnt`, the lock count and the flywheel never see
it, so a real sync is taken the moment it arrives, and one that turns up after
a free start simply restarts that line before it is published.  `make
sim-freerun`, noise / recording / flat level / noise / recording:

| | noise | recording | flat | noise | recording | lock after |
|---|---|---|---|---|---|---|
| without | 1 of 60 | 158 of 200 | 6 of 40 | 0 of 40 | 158 of 200 | 104, 105 lines |
| `FREE_RUN` | 60 of 60 | 199 of 200 | 40 of 40 | 40 of 40 | 200 of 200 | 104, 105 lines |

So it also fills the lines that used to go missing before lock.  On the board
with the M5 it measures exactly as before (rotation 0.5 degrees, same hues,
colour on 60 of 60 frames, two loads).  Free lines skip the burst and back
porch windows, so black holds its last value and colour times out to
monochrome after the burst watchdog -- snow, not colour noise, once it settles.

### The horizontal hue bands: the tracker's memory, then the seed (2026-09-26)

With the bars right, what was left was horizontal banding: every bar of a line
turning hue together, 36 degrees rms, starting abruptly and dying away over 4
to 20 lines.  `scripts/replay_quality.py` now prints this as **hue bands**, the
whole-line rotation -- the median over the six colour bars of each bar's hue
less its mean.  The per-bar line-to-line medians cannot see it, and read 2..4
degrees throughout: a band lasts several lines, so most steps are small.

**Not the source, not C13.**  The corrected recording's burst phase against a
single fixed oscillator varies 1.0 degree rms line to line, and the bars 0.3 to
1.1.  The replay holds every active line within 2 degrees, including across a
synthesised 22-line vertical interval with no burst.  And a fixed filter treats
every line alike, so it cannot turn one line and not the next.

Two changes, both in `burst_nco`:

- **The tracker's prediction left out `correlation_adjust`**, the phase step
  the loop has just given the oscillator.  Every loop correction therefore
  reached the tracker as a measurement error, a quarter of it was taken, and
  the rest decayed as a band.  With it included, `sim-tracking` worst goes from
  4.41 to 0.31 degrees, and 5.25 to 0.82 with the step knocked out.
- **Tracking is off by default** (`BURST_TRACK = 0`).  It was chosen when one
  line's measurement came through five bits and a 19-code burst; now it is good
  to a degree, averaging buys nothing (replay 0.8 raw against 0.9 tracked), and
  memory is what lets one bad update spoil twenty lines.  `sim-reference`, which
  checks the reference itself, goes from 4.36/4.89/7.45 degrees worst to
  0.93/1.33/5.62.

On the board the seed matters more than either change -- whole-line rotation
rms, one netlist per row, each seed repeating itself across loads:

| | by seed | best |
|---|---|---|
| tracking (previous master) | 5.8, 10.3, 19, 34, 36, 39, 66; seed 3 fails timing | seed 8, but bar hues +6..+26 |
| raw (now) | **0.7**, 3.4, 12, 21, 33, 37, 38, 49 | **seed 5**: 0.6..0.8 over three loads, 0.1..0.2% of lines beyond 20 degrees, hues -9..+8 |

The previous master's seed 5 read 36; `make ntsc` reproduced the raw seed 5
byte for byte until the merge below.  Where a bad seed still bands with tracking off, the
state carrying it can only be the NCO loop's.  So the lottery was not gone
with this change; the ALU-free decoder, merged the same day, is what removed
it -- see *The decoder on the pixel clock*.

**Loop a recording on a multiple of five lines.**  The M5's line is 1601.6
samples, so 18 lines is 28828.8, and the loop drops 0.8 of a sample: a 41-degree
step in the subcarrier at every seam, which the tracker turned into a band
every eighteen lines and made the replay look worse than the board.  Ten lines
of `m5_tape_fixedio_18lines.hex` are exactly 16016 samples (`+nsamp=16016`).

### What the M5 actually transmits, measured at full rate

**Superseded (2026-09-25):** measured through bits 0, 1, 4 and 5 while they were packed as LVDS receivers -- see *Bits 0, 1, 4 and 5 were packed as LVDS receivers* above.

Several conclusions recorded above came from five usable bits or from reading
the scope trace; these supersede them.

| | measured | notes |
|---|---|---|
| line period | **1601.6 samples** | nominal.  The "+0.29%, fsc/fh = 226.847" above is wrong; the M5 clocks its DAC at 4 fsc with 910 samples a line, so fsc/fh is 227.5 by construction |
| sync | 116 samples, tip 83; 132 on alternate lines | the two DMA line buffers differ, see the back-porch note |
| blanking | 117 (front porch, every line); back porch 117 / 101 alternating | |
| burst | 101 / 166 square wave, 2.5 us | not centred on blanking |
| black bar | 117 / 85 alternating | the 85 sits at sync-tip level |
| bars' luma, IRE | 64, 50, 58, 37, 38, 15, 16, -16 | **not descending**: yellow < cyan, green < magenta, red < blue |
| bars' chroma, IRE | 6, 8.5, 7.6, 18, 30, 43, 53 | yellow and cyan carry almost none (75% bars want 44 and 62) |

Two consequences:

- **The row-order metric cannot be used on this source.**  A correct decoder
  must put the bars out of luma order, because the M5 sends them that way;
  `video_quality.py`'s "correct rows" reads about 20..35% on a picture that is
  right.  Use `replay_quality.py`'s hue error and line-to-line change against
  `tape_reference.py` instead.  The 100% measured in September was an artefact
  of the dead bits.
- **Pale yellow and cyan are the source**, not the decoder.

### The diagonal crawl is aliasing of the M5's DAC, and no decoder can remove it

**Superseded (2026-09-25):** measured through bits 0, 1, 4 and 5 while they were packed as LVDS receivers -- see *Bits 0, 1, 4 and 5 were packed as LVDS receivers* above.

What remains visible after every fix is a fine diagonal texture inside the
coloured bars.  The floating-point reference shows the same thing, so it is in
the samples.  A least-squares fit over each bar finds two components 143 kHz
either side of the subcarrier, as large as the chroma itself on some bars --
green: 16.6 codes of chroma, 11.5 at 3.437 MHz and 7.0 at 3.722:

- 3.722 MHz = 25.2 - 6 fsc, the M5 waveform's 6th harmonic folded;
- 3.437 MHz = 8 fsc - 25.2, the DAC's sample-rate image folded.

The ESP32 DAC has no reconstruction filter, and 25.2 MSPS happens to fold both
products onto the chroma band.  Nothing 143 kHz from the carrier can be
separated without a chroma bandwidth useless for real pictures.  A real source
(DVD, console, camera) filters its output and does not produce this.  The
remedies are analogue: a reconstruction low-pass on the M5's output, or a
proper anti-alias filter in front of the AD9280 (C13 alone is first order, and
820 pF with the 75-ohm source would also cut the chroma).

### Four decoder faults, found by replaying the recording

All decided in simulation first, then confirmed on the board.

1. **The slice sat on the sync tip's noise.**  `THR_SHIFT` 5 put the threshold
   3 codes above a low-passed tip wandering over 82..85, which broke half the
   syncs into fragments: 112 of 249 replayed lines coasted on the flywheel, with
   every window misplaced.  4 (about 5 codes up) qualifies all 18 syncs of the
   recording; 14 of 249 lines coast, one per loop, at a genuine glitch in the
   recording where the M5's black-bar pulse runs into the next sync.
2. **Black from the back porch** -- see the back-porch section.  Now the front
   porch.
3. **Forced lines assumed a 4.7 us sync** (`ccnt` 124).  They now inherit the
   position the last real edge was measured at.
4. **A late real edge left the burst gate integrating sync tip.**  The flywheel
   fires first, the gate opens on its timing, and the real edge moves the line
   without restarting the integration.  `gate_restart` now clears the burst
   correlator at any line start.  This is what `sim-video-late` failed on when
   the slice moved, and fixing it restored `max_error=17` rather than widening
   a tolerance.

### The sampling instant moves with every placement, and it looked like a compiler bug

**The largest single fault, and probably the explanation for the unexplained
rebuild-to-rebuild swings recorded in this file.**

The ADC is clocked from a register in the fabric and read back through the
fabric, and one of five 126 MHz reads per conversion is used.  Which read is
safe depends on the round trip -- routing out, the AD9280's output delay,
routing back -- and that changes with every placement.  With the phase fixed at
2, the same RTL decoded the recording perfectly in simulation and scrambled the
colour on the board, and a rebuild with no logical change moved the picture
vertically as well.  It fails in a way that points everywhere but at itself:
flat areas decode, because neighbouring samples agree in their upper bits and
the luma filter averages the rest, while the burst, swinging 65 codes every
sample, is corrupted on every line.  Brightness right, colour wrong.

`AUTO_PHASE` measures it instead.  Per read phase it counts how often the data
differs from the previous clock's, which locates the switching window, and
reads at the quietest point -- the minimum of `n[s-1] + 2n[s] + 2n[s+1] +
n[s+2]` -- re-evaluated every 4 ms with hysteresis.  `sim/replay_tb.v`'s
`ADC_DELAY`/`MIX` model a switching window on the fixed read: it distorts the
decode with the phase fixed, and the calibration restores it exactly.

Measured on the board, two different placements, against the replay and the
floating-point reference (hue error in degrees; wobble is the median
line-to-line change):

| | green | magenta | red | blue | wobble |
|---|---|---|---|---|---|
| fixed phase (fix4) | +77 | +61 | +115 | +68 | ~30 |
| calibrated, seed 3 | -2 | -17 | -9 | +25 | 2..3 |
| calibrated, seed 5 | -4 | -15 | -9 | +26 | 2..6 |
| replay (simulation) | -1 | -13 | -7 | +23 | 3..9 |
| reference (float) | -0 | -19 | -1 | +25 | -- |

The residual still varies between placements -- 5 read points 7.9 ns apart is
coarse -- so the shipping seed was chosen by measurement over seeds 3, 5, 7, 11
and 13: **seed 11**, wobble 4.8 degrees mean (5.7..9.6 for the rest), hues within
0..9 degrees of the reference, 143.2 MHz.  `make ntsc` rebuilds it byte for
byte.  Finer control of the read instant (IDDR, or the GW2A's IODELAY if the
open flow supports it) is the way to take the remaining spread out.

The `adc_clk_r` comment in `ntsc_capture.v` -- "a mux here cost the picture
half its rows" -- was this same effect: any change to the design moved the
read instant.

### The rest of the placement lottery is Apicula's ALU bug, not the sampling instant

The section above says the fixed read phase is "probably the explanation" for
the rebuild-to-rebuild swings.  It is one mechanism, and the next experiment
showed it is not the only one.

The ADC now runs through the pins' own IO logic -- `IDDR` on `adc_d`, `ODDR` on
`adc_clk` -- so the round trip no longer passes through the router (the report
shows 8 IOLOGICI and 4 IOLOGICO; timing rose to 150 MHz).  Two seeds of that
design, measured back to back on the board:

| | green | magenta | red | blue | wobble |
|---|---|---|---|---|---|
| seed 11 | -4 | -9 | -12 | +1 | 5..6 |
| seed 3 | -15 | -34 | -50 | -21 | 23..25 |
| replay | -4 | -1 | -4 | +10 | 3..7 |

With the interface fixed in silicon the two builds still disagree, so the
chroma arithmetic itself computes differently by placement.  That is
[YosysHQ/apicula#514](https://github.com/YosysHQ/apicula/issues/514): "design
with yosys-inferred ALU carry cells computes wrong on silicon; RTL sim,
gate-level netlist sim, and timing all pass; `synth_gowin -noalu` fixes it".
A nextpnr fix landed in July 2026 (our suite, 2026-08-25, has it) and cured the
reporters' designs up to about 800 ALU cells, but they still see failures at
3300.  This design has about 4300.

`-noalu` is the known cure and it does not fit: without carry cells the
126 MHz domain reaches 93..103 MHz.  Almost all of that logic only has to
settle once per sample, five clocks, so the way to an ALU-free build is to run
the sample-rate logic on the 25.2 MHz pixel clock and keep 126 MHz for the IO
front end only.  Until then: **choose the seed by measurement on the board,
every time the RTL changes** -- seed 11 for the current RTL, 151.7 MHz,
reproduced byte for byte by `make ntsc`.

The IO registers and the read-phase calibration stay: each removes a real
placement dependence, and they cost nothing.

### The decoder on the pixel clock, with no ALU cells (merged 2026-09-26)

Everything but the converter's clock now runs on the 25.2 MHz pixel clock, one
sample per clock, and is built with `synth_gowin -nodsp -noalu`: 0 ALU cells,
58% of LUTs, about 50 MHz against 25.2 needed.  Every bench reproduces its
126 MHz figure (sim-video `max_error=17`, capture 379/400 and weak 400/400,
reference 4.36/4.89/7.45 deg, tracking 4.41), and replaying both M5
recordings, every bar's hue matches the 126 MHz design within 0.2 degrees.

**The converter interface** (`src/adc_front.v`) had to change shape.  A
ten-read `IDES10` per bit would be ideal and cannot be had: it takes both IO
cells of a pin pair, and every data pin on this board shares its pair with
another ADC signal (nextpnr refuses it).  Instead each bit is an `IDDR` on the
pixel clock -- two reads a conversion, rising (the sample) and falling (the
witness) -- and the converter's clock comes from an `ODDR` on 126 MHz sending
`1111100000` rotated in 3.97 ns steps.  The AD9280's outputs are latched, so
two reads with no switching between them agree bit for bit whatever the
video does; counting disagreements per rotation locates the switching, and
the centre of the longer quiet run is at least a quarter conversion from every
read whatever the pixel clock's duty cycle.  `make sim-adc-front` covers a
whole period of output delay, a 14 ns switching window, drift both ways,
glitching bits, and a negative control.

**Two things one sample per clock broke, both silent:**

- `burst_nco` registered its correlator weights from the phase.  At five
  clocks per sample the lag was invisible; at one it paired every sample with
  the previous sample's phase, 51 degrees against the demodulator, which pairs
  them correctly.  sim-video: `max_error=216`, with sync, lock and black all
  perfect.  The weights now come straight from the current phase.
- The last burst product reaches `sum_r` three clocks after the gate falls,
  which at five clocks per sample had always happened by the next strobe.  The
  fall is now acted on by clock count, and a gate restart drops the pipeline.

The colour pipeline costs samples at this rate: rgb is four samples later
(`PIPE`), `y_delay` is two longer to keep luma with it, and writes start four
later so every pixel stays put.  The period arithmetic is registered one
sample ahead (`rcnt + 1`); the window compares are combinational.

**Bits 0, 1, 4 and 5 read noisily, and the calibration must not count them.**
`make ntsc-adcdiag` steps the rotation through 0..9 and shows each bit's
rising/falling disagreement (`scripts/adc_diag.py` records a few seconds of
the strip as video and tabulates it).  Bits 2, 3, 6 and 7 -- pins 72, 76, 75,
77, the top bank -- read exactly alike at four rotations of ten, as a latched
output should.  Bits 0, 1, 4 and 5 -- pins 27..30, the bottom bank beside the
HDMI pins -- disagree on 3 to 13 percent of conversions at *every* rotation.
Counted in, no rotation was ever quiet: the calibration re-swept for ever (63
sweeps within seconds) while the picture still looked fine, because a moving
read instant shifts burst and chroma alike.  `CAL_MASK` now counts the top
bank only; on the board every seed then settles once, at rotation 3, with 0
disagreements in 16384.  Why the bottom bank misreads is not known --
crosstalk from the TMDS pins and slow edges are the candidates -- and it may
be costing noise in those four bits.

**Explained, 2026-09-25:** Apicula packed those four inputs as LVDS receivers
(*Bits 0, 1, 4 and 5 were packed as LVDS receivers*), and every build now
goes through `scripts/gowin_pack_io.py`.  `CAL_MASK` is kept: the top bank
alone still locates the switching, and the choice within the quiet run already
counts all eight bits.

**The strip.**  The bottom rows of the diagnostic view -- S1, or the view
`make ntsc-scope` starts in; every frame of `ntsc-adcdiag` -- carry the
interface's state as 32-bit words, 16-pixel cells, white = 1 (`ADC_STRIP`): rotation,
calibrated, pair, sweeps so far, the last tracking window's disagreement
count, and one rotation's sweep counts per frame.  `scripts/adc_strip.py`
reads it from captures.  **Sweeps must stay at 1 and track at 0**; anything
else means the read is not clean, however good the picture looks.

**The colour failures were the burst tracker, not the toolchain.**  With the
read clean, one load in two still lost colour -- colour on half the frames, a
random-looking hue on every line -- and it looked like placement: three seeds
of one netlist gave two good and one bad.  It is not.  **The same bitstream,
loaded again, went from bad to good and back**, and the strip showed why: the
burst's measured angle was right (the CORDIC matches atan2 of its own inputs
within 0.2 degrees, every frame, good runs and bad), but the tracked angle
`burst_off` was cycling round it -- two values about 160 degrees apart, or
three about 120 apart.

`burst_nco` predicts each line's burst angle from the last plus a learned
per-line step.  A step a half or a third of a turn wrong is a stable trap: the
prediction cycles round the measurement, the corrections cancel over the
cycle, and nothing ever pulls it out.  Whether an acquisition falls in is
chance -- it depends on where the loop happens to be when the step is seeded --
so it follows the load, not the build.  `sim-tracking` reproduces it by
knocking the step half or a third of a turn out: the old tracker stays out by
94 and 112 degrees, for good.

The fix keeps a running mean of the miss (1/8 a line) and relearns the step
from the next two measurements when it passes 45 degrees; a right tracker
misses by a few.  A run of large misses was tried first and is not enough: in
the three-cycle one line in three lands close and the run never completes --
the board found that case after simulation passed the two-cycle one.

Measured with the fix, two seeds, five loads each, the same M5 boot:

| | colour frames | correct rows | dropped | line-to-line | hue G/M/R/B |
|---|---|---|---|---|---|
| seed 3, loads a..e | 60/60 every time | 99.3..99.6% | 0 | 2.1..3.8 deg | +3.2 / +2.2 / -2.3 / +12.2 |
| seed 11, loads a..e | 60/60 every time | 99.6..99.7% | 0 | 2.2..3.8 deg | +3.2 / +2.3 / -2.4 / +12.2 |

Every figure agrees across all ten loads to within 0.4 degrees, while the
calibration settled at rotations 0, 2, 5 and 6 on different loads -- it
absorbs the load-to-load phase between the 126 MHz counter and the pixel
clock divider, as designed.  Against the measured 126 MHz build (master,
seed 11) on the same boot: 89.1% correct, 4.3..4.8 degrees line to line.

**This retires the "placement lottery" as recorded above for the colour
path.**  The 126 MHz design has the same tracker, and every comparison
behind "the rest of the placement lottery is Apicula's ALU bug" was one load
per build, so the trap explains those swings at least as well; it was not
re-measured there.  The ALU bug is real upstream and `-noalu` costs nothing
now, so it stays.  The rule that follows: **load a build more than once
before crediting or blaming its placement.**

**Merged into master, 2026-09-26**, together with master's IO packing, raw
burst angle and the tracker's prediction fix.  That last paragraph was only
half right: the trap was real, but so was the 126 MHz lottery -- with the trap
escaped and tracking off, eight seeds of that design still spread 0.7..49
degrees of whole-line hue rotation (*The horizontal hue bands*).  This design
has none.  Eight seeds of one netlist, one after another on one M5 boot,
scored by `replay_quality.py --frames`:

| | whole-line rotation rms | lines beyond 20 deg | hue Y/C/G/M/R/B | line to line |
|---|---|---|---|---|
| 126 MHz master, seed 5 (its best of eight) | 2.2 | 0.3% | +7/-9/-2/-4/-5/+4 | 0.2..0.5 |
| pixel clock, seeds 1..8 | **0.5, every seed** | **0.0%** | +7/-9/-2/-4/-6/+4, every seed | 0.2..0.4 |

Every seed calibrated once -- at rotation 0, 2, 6 or 8 -- with no disagreement
in 16384, and seeds 3, 5 and 8 reloaded read the same to the digit.  Timing:
the pixel clock makes 49..52 MHz against 25.2 on every seed.

### The M5's blanking levels depend on its boot

**Superseded (2026-09-25):** measured through bits 0, 1, 4 and 5 while they were packed as LVDS receivers -- see *Bits 0, 1, 4 and 5 were packed as LVDS receivers* above.

A second recording, after the M5 had been power-cycled, showed different junk
in its two DMA line buffers: front porch 99/115 alternating (it had been 117 on
every line), back porch 114/99, black bar 101/117.  The front-porch black
reference banded again (45 codes).  In both boots, on every line, one porch
read true blanking and the other the burst's low level -- never the reverse --
so black is now the higher of the two, averaged at quarter weight across lines.
Replayed: black 116..117 and 114..115, white-bar line-to-line change 1.8 and
2.8 codes for the two boots; on the board 0.8..1.2.

Two things this also broke, now fixed: `tape_trim.py` slices at tip + 8 (a
porch at 99 sat under the old midpoint slice) and keeps only sync pulses with a
partner one line away (the M5's sync-level black bar has none).  And the
recorder can trigger during the vertical interval right after programming,
before the field is known -- about one recording in seven; record again.

**C13 is now 680 pF.**  Its effect on the alias products could not be measured:
the M5 rebooted between the two recordings, and every bar's chroma changed by a
different factor (0.13..1.67) and the burst's third harmonic by 22 dB, which no
capacitor does.  A before/after of the filter needs one M5 boot on both sides.

### Removing the crawl digitally: only a five-line comb, and only on a still pattern

**Superseded (2026-09-25):** measured through bits 0, 1, 4 and 5 while they were packed as LVDS receivers -- see *Bits 0, 1, 4 and 5 were packed as LVDS receivers* above.

Both products are exact multiples of the M5's line (6 fsc and 8 fsc are 1365
and 1820 cycles a line) while chroma alternates, so a comb along the lines
separates them -- but only over a delay that is a whole number of samples.
One line is 1601.6 samples, and a fractional delay interpolated on the samples
shifts an alias as the 3.7 MHz tone it appears to be, not as the 21.5 or
28.6 MHz tone it is, so nothing cancels.  **Five lines are 8008 samples**:
over them chroma turns 1137.5 cycles and inverts while both products turn a
whole number and repeat, so `(x[n] - x[n-8008]) / 2` keeps chroma and cancels
them.  Measured on the three M5 recordings: chroma unchanged, aliases
-14..-19 dB -- nearly what the LC filter is expected to do.

It is not a fix for real pictures.  It assumes the picture is the same five
lines (ten picture lines) apart, which is true of bars and false of anything
else, where it smears colour vertically; and it relies on the M5's clock
matching ours -- five lines are 8007.94 samples on these recordings, and a
larger crystal offset loses the cancellation.  Real sources filter their
output and never carry the products.  The analogue filter removes them for
any picture; the comb would only be worth building as an M5-only mode.  Not
built.

### An LC anti-alias filter on R3's pads (*Planned*, parts arriving)

**Superseded (2026-09-25):** measured through bits 0, 1, 4 and 5 while they were packed as LVDS receivers -- see *Bits 0, 1, 4 and 5 were packed as LVDS receivers* above.

Remove R3 (20 ohm, 0603) and bridge its pads with **1 uH in series with
47 ohm** (39..56 is fine), leaded parts, short leads; C13 stays 680 pF.  With
the 75-ohm source, the design calculation gives, across the parts' tolerance:
colour band -3.4..+0.6 dB, 21.5 MHz at least 19.9 dB down, 28.6 MHz at least
24.9 dB down, peaking no more than +0.7 dB.

Measuring it needs one M5 boot on both sides, so **keep the M5 powered through
the rework** and unplug only the Tang.  Record the before and after with one
tape bitstream (`make ntsc-tape`).  After: load it, capture 12 frames with `scripts/live_capture.sh`,
`scripts/tape_decode.py`, `scripts/tape_trim.py ... 18`, then
`python3 scripts/filter_check.py BEFORE.hex AFTER.hex`,
which fits burst and bars at the subcarrier and at both alias frequencies and
prints the chroma gain the decoder must make up.  If the M5 reboots, record a
new baseline first -- a comparison across a reboot measures the reboot.

**The recorder lands on the grey staircase about one time in four** (it
triggers on any line from 41 to 229, and the bottom quarter of the pattern
has no chroma).  Compared with a recording on the bars, that reads as 22 dB
of colour removed.  `filter_check.py` now refuses such a recording; record
again.  The floor between two recordings with nothing changed, same boot:
strong-bar chroma +0.1 dB, aliases -0.4 and -1.1 dB (individual small
components up to 4 dB).  The filter should move the aliases by about 20.

### The capture card may expand limited range

After a replug the UGREEN card began mapping 16..235 to 0..255, which collapsed
the tape's nibble levels 0/1 and 14/15 (it used grey = 17 x nibble).  The tape
now uses grey = 16 + 14 x nibble, inside limited range either way, and
`tape_decode.py` learns the levels from the staircase rows of each frame.
Hue survives the expansion; chroma magnitudes read about 16% high in picture
captures taken that way, so compare magnitudes only within one capture state.

### Apicula has an open placement-dependent miscompute bug on this exact chip

**The same RTL produces different functional results depending only on
`nextpnr --seed`, on GW2A-18C.**  Not timing, not marginality: a comparator
computes the wrong answer in one placement and the right answer in another, in
the same bitstream.  It is reported as
[YosysHQ/apicula#541](https://github.com/YosysHQ/apicula/issues/541), it is
open, and there is no known workaround.  It does not affect the GW1N-9C used by
the sibling 9K project, which is why nothing like it appears there.

The affected construct is **signed comparison** -- `$signed(a) > $signed(b)`.
This design is full of them: the flywheel's period window, the burst NCO's
tracking error, the CORDIC's sign decisions.  The reporter ruled out BSRAM
placement, memory contents and path delay, so there is nothing to tune around.

This retires the last unexplained thing in this file.  Rebuilds of logically
identical designs measured 98.4%, then 63.8%, 50%, and 1.1% correct rows within
one session, and several hours went into hunting an RTL cause -- including
removing a parameter from the ADC clock path and measuring *worse*.  There was
no RTL cause.

**Correction, 2026-09-25: this claim was false.**  Yosys found eleven signed
comparison cells when asked directly -- the grep below cannot see a comparison
between values merely *declared* signed, nor one against a signed integer such
as `P_BAND * 256`, which kept the "fixed" plausibility test signed.  All eleven
are gone now (the NCO clamp, the RGB clip, the plausibility test and five in the
TMDS encoder's disparity logic), and `make check-signed`, part of `make test`,
elaborates the design and fails on any signed `$lt/$le/$gt/$ge`.  Removing the
NCO clamp's the first time cost 30 MHz; this time the loop update was pipelined
instead, from registered values, with bit-identical bench figures.

And note what this section attributed to Apicula.  The fixed ADC sampling
phase is a demonstrated placement-dependent mechanism that produces exactly
those swings -- see *The sampling instant moves with every placement* -- so
the rebuild-to-rebuild figures above are at least as likely to have been that.
Keep the signed comparisons out anyway; the bug is real upstream.

The original text, for the record:  There were two, and
both are gone:

- the flywheel's period plausibility test, `period_error` against `+/-P_BAND`,
  which decides whether a sync edge is accepted -- a wrong answer there corrupts
  the line timing for a whole frame.  Both operands are counts and cannot be
  negative, so it is now one unsigned magnitude compare.  `period_error` itself
  stays, because the bug is in comparison and not in arithmetic, and the shift
  that trims `period_next` still needs it.
- `burst_nco`'s clamp on the NCO increment.  The bounds are positive constants,
  so the sign bit handles the negative case and the rest is unsigned.

`grep -nE '\$signed[^;]*(>=|<=|>|<)'` over `src/` returns nothing, and every
testbench figure is unchanged: reference worst 4.36/4.89/7.45 degrees, tracking
worst 4.41, video `max_error=17`.  Keep it that way -- a signed comparison
added back anywhere is a placement-dependent fault waiting for a rebuild.

What follows from it, and it is not optional:

- **Decide RTL questions in simulation.**  `make test` is deterministic; the
  board is not.  This was already the conclusion for other reasons; now there
  is a mechanism.
- **Choose the shipping seed by measurement, and record which seed it was.**  A
  seed is part of the build, not an implementation detail.
- **Never attribute a picture change to an edit without rebuilding the
  unedited version at the same seed and measuring it back to back.**  Every
  wrong conclusion in this file came from skipping that step.

### The colour banding is the burst being quantised away, and no parameter fixes it

The picture scores 100% correct rows and still looks wrong, in a specific way
worth writing down: inside a bar that should be one flat colour, the colour
alternates between two states in horizontal bands five to ten rows deep.

Measured inside one green bar:

| | standard deviation |
|---|---|
| blue | **40** (range 44..230) |
| red | 19 |
| green | 14 |

Blue is `Y + 2.032 U`, the largest coefficient in the matrix, so the error is in
**U** -- the chroma demodulation.  Row-to-row change is 8.7 against 4.5 between
neighbouring pixels in a row, so it is **per-line phase**, not pixel noise.

The cause is the dead bits again, and this is where they hurt most.  The burst
is a small signal riding on blanking, and the expressible codes there run
`0,1,2,3` then jump to `16,17,18,19` -- **a 13-code gap, and the same gap
everywhere, because bits 2 and 3 leave only four steps inside each group of
sixteen**.  A burst of +/-20 codes has almost no phase resolution left.

Three parameter sweeps found nothing, and the reason they cannot is measurable:

| | blue sd |
|---|---|
| `TRACK_P` 2 / 3 / 4 | 38.6 / 34.0 / 45.3 (and 3 drops colour lock to 18 frames of 40) |
| `BURST_TRACK` on / off | 49.6 / 46.1 |
| **one bitstream, measured three times** | **40.0 / 44.5 / 43.1** |

The repeat spread is 4.5 and the sweep spread is 11, overlapping.  **No setting
is resolvable above the measurement.**  Software tuning for this is finished;
what is missing is resolution, and averaging cannot recover information that was
never digitised.

### The top bars merge because of the dead bits, not because of clipping

Worth following the whole chain, because the first two readings of it were
wrong and the correction is the useful part.

The raw trace shows white, yellow and cyan resting at **exactly 179 for 390
consecutive samples**.  179 is `0xB3`, and that reads as saturation.  It is not.
With bits 2, 3 and 6 stuck at zero the converter maps every true value in
179..191 -- and 243..255 -- onto 179, so three bars whose real levels differ by
tens of codes come back identical.  **The merging is the dead bits.**

Two measurements settle it, and both had to be made before the conclusion held:

- **Source level does nothing.**  `M5_OUTPUT_LEVEL` swept 128, 96, 80, 64 leaves
  the trace at `min=1 max=179 blanking=2` every time.  Of course it does: with
  24 expressible codes clustered at the ends, the observed extremes are pinned
  regardless of amplitude.  **Levels cannot be measured through this converter
  at all**, which is why no analog tuning can be verified until the pins are
  fixed.
- **The picture agrees.**  Bars 0 and 1 read 246 at every level.  At 96 a third
  bar separates (186 against 246) and at 64 the order breaks and colour is lost
  entirely, so 128 remains the best setting -- 100.0% correct rows, colour on
  every frame.

`adc_otr` is now wired to the diagnostic counter (`SCOPE_TEST_RAMP == 7`) and
saturates its bar against a bit-6 count of zero on the same counter, so sync
tips are going under-range.  That is real and separate, and it cannot be
corrected either: the analog clamp needs `lock_cnt >= 16`, sync cannot lock
through a clipped signal, and forcing the clamp to pin AIN at CLAMPIN does not
move the operating point back -- C2 at 1 uF is too much for the clamp amplifier,
exactly as recorded above.

**So the order of work is fixed, not a preference.**  Until `adc_d[2]`,
`adc_d[3]` and `adc_d[6]` reach the FPGA, the converter has 24 of 256 codes, no
level measurement means anything, and the top of the picture cannot separate.
Three wires gate everything else.

**And note what the row metric says while all of this is true: 100.00% correct,
zero dropped, colour on 60 frames of 60.**  It tests for a non-increasing
sequence and equal bars are non-increasing.  Read the bar values.

### The luma and chroma gains were constants, and the source's amplitude moved

This is the largest single improvement measured in this project: **50.1% correct
rows to 100.0%**, on the same signal, in one change.

The gains were fixed for a source whose blanking-to-white span is 130 codes.
When the span grew to 177 -- which happened on its own, along with the sync step
described above -- the same constants map white to 498.  The top of the range
folds together, the bars stop being ordered, and the picture measures:

| | correct | dropped | wrong-order | saturated |
|---|---|---|---|---|
| fixed gains, 177-code span | 50.1% | 0.0% | 49.9% | 55.7% |
| luma gain halved | 85.1% | 0.0% | 14.9% | 16.8% |
| luma halved, chroma quartered | **100.0%** | **0.0%** | **0.0%** | 0.8% |

Note what the failure looked like: **no dropped rows and colour on every frame**.
Sync and burst were locking perfectly.  Only the order of the bars was wrong,
because clipping had squashed the bright end flat.  A picture can be completely
unusable with every timing measurement reading healthy.

`AUTO_GAIN` now picks the gain from `f_max - black` rather than trusting a
constant, with the threshold at a 150-code span.  That leaves the 130-code case
bit-identical -- which is what keeps `sim-video`'s published RGB values valid,
and it still passes with the same `max_error=17` -- while the board gets the
halved luma and quartered chroma.  Measured through the automatic path: 100.00%
and 99.98% correct, zero dropped, zero wrong-order, colour on 60 frames of 60.

Two shifts and a mux, not a variable shift, so it costs nothing on the timing
path.

**Do not calibrate anything about chroma phase against a clipped picture.**  The
earlier note saying so was right, and this is the same trap at a larger scale:
half the rows were out of order and the cause was entirely a gain constant.

### With real sync present, the standard geometry gives the best picture yet

Late in a session the source began emitting a sync step -- the waveform floor at
33 with a run 30-odd codes below it, where every earlier measurement here found
a flat floor and no step at all.  Nothing on this side changed to cause it; it
appeared during repeated reseating.  With it present, `LEGACY_TIMING = 0`
measures far better than anything recorded before:

| | correct | dropped | wrong-order | colour |
|---|---|---|---|---|
| standard geometry, sync present | **98.4%**, 97.2..97.8% repeated | **0.00%** | 2.2..2.8% | **60 of 60** |
| M5 geometry, same signal | 14.3% | 84.7% | -- | 0 of 60 |
| best previously recorded here | 84.5% | 12.7% | 2.8% | yes |

Zero dropped rows and colour on every frame.  So the decoder is right, and most
of the difficulty recorded in this file came from a source that emitted no sync,
not from the decode.  A source with sync wants the standard set, as the geometry
note above says.

**But the default was not flipped, because the result would not hold still.**
Rebuilding the same logic gave 63.8%, then 50%, then 1.1%, and the capture card
froze through twelve passes.  The likeliest reading is that the source's sync
comes and goes -- it arrived on its own, so it can leave the same way -- which
would explain swings that no RTL difference accounts for, including one chased
as far as removing a parameter from the ADC clock path and measuring *worse*.

Before touching this again, **read the waveform first and record whether a sync
step is present**, then interpret the picture number in that light.  A build
comparison across a source that changes state is not a comparison at all.

### `LEGACY_TIMING` -- superseded, and why it was ever 1

The window offsets come in two sets: standard NTSC geometry measured from the
sync leading edge (`QUALIFY` 80, burst 136..192, active from 252), and the ones
measured on the M5 (`QUALIFY` 124, burst 240..300, active from 313).

They differ because the source appeared to have **no sync step**, so the low run
the detector qualifies on was the whole blanking interval rather than the sync
pulse, and the trigger landed somewhere else entirely. With the standard set the
picture rolled and tore; with `LEGACY_TIMING = 1` it sat still and every live
frame carried colour, so 1 was the default.

**That reading was taken through a converter delivering 24 of 256 codes.** With
the respun board it is measurably wrong -- the source emits a 33-code sync step,
and the standard set wins by 47 points of dropped rows and 120 colour frames to
zero. `top_ntsc_hdmi`'s default is now `LEGACY_TIMING = 1'b0`, and `make
ntsc-legacy` builds the M5 set. See *The source does emit sync* above.

Keep the legacy set. A source whose sync tip and blanking are the same level is
a real case -- this project spent weeks on one -- and nothing else works on it.

### Measure against a clean tree, or diff first

Two conclusions here were drawn from a bench run that also carried an *earlier,
unrelated* edit, and both were wrong: "widening the timeout breaks sim-video"
was really "the chroma gain changed twenty minutes ago breaks sim-video", since
that bench checks decoded RGB against published values and a quarter of the
gain fails it by construction. `git diff` settled it in one command -- which is
the first thing version control paid for here.

### 2026-09-14 continuation: two reproducible holdover bugs

The M5 defaults are retained: `LEGACY_TIMING=1`, `TRACK_P=2`, the 18-bit
burst watchdog and `V_TARGET=488`. This continuation does not change chroma
gain or the generator firmware.

1. **Burst prediction must not bridge missing lines as one line.** The long
   watchdog preserved colour lock through VBI, but `track_pred` still advanced
   only one learned step when the next measurement arrived. A 24-line gap in
   a rotating-burst test gave 38.22 degrees of error on return and four bad
   lines. Invalidate only `have_prev/have_step` after 2403 sample strobes
   (1.5 nominal lines); preserve the NCO frequency and colour lock. Two fresh
   bursts re-seed the predictor. `sim-tracking` now checks the first returning
   line as well as the settled lines: 84 checks, maximum 4.41 degrees, no errors
   above the 12-degree limit. The old RTL fails this test.
2. **Accept qualified sync just after a coasted start.** A delayed sync could
   land a few samples after `force_line` reset `pcnt`, outside `in_window`.
   All following syncs then landed just after subsequent forced starts, so
   they were rejected until `FORCE_GIVEUP` dropped lock. A short late window
   when `force_run != 0` allows the real sync to correct the early start.
   `period_out` reports `rcnt` for real edges, not the short time since the
   forced start. With the recorded full-sync stimulus, final lock confidence
   improved from 38/255 (unlocked) to 255/255; accepted edges improved from
   358/400 to 379/400. Weak sync accepts 400/400 and holds 255/255. The recording
   seam is not an exact line period. `sim-video-late` adds an independent
   24-sample phase step: old capture RTL loses lock, fixed RTL passes with
   `bad_channels=0`, `bad_lines=0`, maximum RGB error 17.

The burst correlator also registers ADC-minus-blank before multiplication.
The original subtract/multiply path failed routed timing at 119.03 MHz;
separating it preserves the sample/reference alignment (five clocks per
sample) and the intermediate build reached 134.99 MHz against 125.94 required.
Always inspect the **final routed** timing results for each final bitstream,
not the pre-route estimate or that intermediate number.

`make test` now asserts the recorded-waveform results instead of only printing
them. The colour-video stimulus blanks for 24 lines, not just the nine-line
equalising/broad-pulse sequence. Capture and weak-capture tests use separate
executables, so `make -j4 test` cannot race on the same binary. `ntsc-legacy`
and `ntsc-legacy-program` provide `LEGACY_TIMING=1` with separate output files;
they do not change the default build or imply a bench test of either geometry.
(These were `ntsc-standard*` while `LEGACY_TIMING=1` was the default.)

`scripts/video_quality.py` makes the bar-row metric reproducible without the
external scratchpad or Pillow. It reports all frames, including missing
pictures, and separately reports colour-bearing frames, high-end RGB clipping
and row-to-row RGB differences. Defaults are rows 20:350, first bar at x=24,
80-pixel bar spacing; the grey ramp is outside this ROI. These definitions
differ from the old scratchpad, so do not compare the percentages directly.
The second unmodified-hardware baseline (`build/ntsc_resume_baseline2_*.png`)
has 120/120 colour-bearing frames, 93.588% correct-order rows, 3.662% dropped,
2.750% wrong-order and 27.617% saturated channel samples. Luminance order alone
does not prove hue or gain accuracy.

### Reading the ADC back off the HDMI scope: geometry yes, amplitude no

`make ntsc-scope-program` starts in the oscilloscope view with the full 256-code
vertical scale (`SCOPE_FULL_RANGE`), and `scripts/scope_trace.py` recovers the
plotted samples from a captured frame by their *position*, not their colour --
the trace is white above the slicing threshold and red below it, so red alone
finds both, and the threshold line is green and excludes itself.  No UART is
involved, which is the point: the serial link on this board has never been
dependable and the HDMI output always has been.

**Detect the mark at r > 120, not r > 180.** A mark is one column wide, and
where neighbouring columns sit at very different heights -- exactly the
modulated regions worth measuring -- the capture card's horizontal filtering
dims it below 180 and the column vanishes.  Lowering the threshold takes
recovery from 551 to 639 of 640 columns, and where both settings read a column
they differ by at most 2 codes, so it adds coverage without adding error.

**Locate the burst by shape, not by offset.** About half the lines start from
the flywheel rather than from a detected sync, so the dump can begin anywhere in
the line and every fixed offset slides with it.  `locate_burst` looks for an
oscillating stretch of 18..30 columns between two flat ones at the blanking
level, and finds it in 19 frames out of 19.  Judging flatness needs a
neighbourhood rather than a single column: a sinusoid sampled every third sample
crosses its own mean, so individual columns inside the burst sit exactly at
blanking and split the run into unrecognisable pieces.

Measured this way the line comes back correctly, and this is what the tool is
for:

| | samples | time | NTSC |
|---|---|---|---|
| front porch + sync + breezeway | 190 | 7.5 us | 6.8 |
| colour burst | 72 | 2.9 us | 2.5 |
| back porch | 48 | 1.9 us | 1.6 |

and the next line's burst lands 1593 samples after this one's, against a
1597-sample line.  The first bar after blanking is flat at 161..163 -- white,
no chroma -- and the strongly coloured bars swing by up to 145 codes.  So the
source does emit a burst; the earlier "this source appears to emit no usable
colour burst" is wrong, and so is a later attempt of mine to confirm it by
measuring 103..40 samples before the first bright bar, which lands on the
*previous* line's back porch and duly reports a flat 0.1 codes.

**Do not read an amplitude out of it.**  Across nineteen frames the recovered
samples take **27 distinct values out of 256**: bit 6 is never set at all, and
bits 2 and 3 appear in under 0.2% of samples.  Equivalently every recovered
trace position satisfies `y mod 16 in {12,13,14,15}`.  That is why the burst
comes back as three discrete levels -- 18, 34 and 130 -- where a sinusoid
sampled at 153 degrees a column has to spread around the circle, and why this
path puts the burst at 95 codes peak-to-peak where the hardware's own min/max
detector reads 19 across the same window.

Four things are established about it, so nobody need repeat them:

- **It is not the capture card.**  The diagnostic bars in the same frames land
  on rows 112, 120, 128 and so on -- exactly where the design draws them, with
  no preference for any grid.  Only the one-pixel-wide trace marks are banded.
- **It is not the sampling phase**, or not only.  `ntsc-scope` hard-codes
  `DEFAULT_PHASE 2` while the normal build searches and settles on 4.  Phase 4
  does help -- 38 distinct values instead of 27, bits 2/3/6 at 2.4/1.5/0.5%
  instead of 0.2/0.1/0.0 -- but low bits should sit near 50%, not 2%.
- **It is not the ADC bus.**  With bits 2, 3 and 6 cleared, 75% bars stop being
  monotonic in luma: magenta lands on 80 while cyan lands on 34.  The picture
  measures 86% of rows in correct luminance order, which that mapping cannot
  produce.  The video path sees a healthy bus.

- **It is not the read-back path.**  `SCOPE_TEST_RAMP` writes a constant 0xAA
  into the dump buffer instead of the ADC sample, and all 3840 recovered
  samples across six frames read exactly 170 -- through BSRAM, trace drawing,
  the HDMI link, the capture card and the recovery script, with no other value
  appearing at all.  0xAA sets bit 3, which the ADC samples never show, so
  nothing in that chain is dropping bits.

- **It is not the detector in the script.**  The original strict settings
  (r > 180, runs of 4 or more) give the same picture: 22 distinct values, bits
  2, 3 and 6 at 0.02, 0.00 and 0.00.  Relaxing them changes coverage, not this.
- **It is not the sampling phase.**  `HUNT_PHASE` defaults off, so the phase is
  fixed at `DEFAULT_PHASE`, and all five values band the same way -- 27 to 38
  distinct values, bits 2/3/6 at 0..3%.  A phase inside the AD9280's switching
  window would be bad at one setting and good at another.

So the dump buffer receives banded values while the read-back of a constant is
exact.  And yet **the video path, which reads the same `adc_r` on the same
strobe, is demonstrably fine**: the eight bars come off the capture card at
253, 250, 237, 188, 162, 131, 94, 0, monotonic seven times out of seven.  With
bits 2, 3 and 6 cleared those become 129, 51, 34, 32, 16, 2, 49, 32 -- red
below blue -- and essentially every row would count as out of order, against a
measured 2.8%.

That contradiction is the open question, and it is worth stating plainly rather
than resolving by assumption, which is how the burst was declared absent twice
in this file already.  One lead worth checking first, because it would make the
whole thing a non-problem: **the dump holds a single line**, and a colour-bar
line legitimately contains only about ten luma levels.  Twenty-odd distinct
values is what that should look like.  What that does not explain is why the
missing ones are exactly those with bits 2, 3 or 6 set, when chroma modulation
around each bar level ought to sweep through them.

`SCOPE_TEST_RAMP` is left in place as the harness for settling it: it writes a
known constant into the dump instead of the ADC sample, which is what proved
the read-back path exact, and the same switch is where a ramp or a
line-dependent pattern goes next.

## Captured reference data

`make dumpbig-program` fills a 32768-sample buffer (about 19 consecutive lines) from a sync edge
and dumps it as hex over the serial port; `sim/ntsc_capture_19lines.hex` is one such capture from
the real board. `sim/ntsc_line_capture.hex` is the earlier single-line version.

Develop the colour decoder against these in Python first, then port. Iterating on a chroma PLL by
rebuilding a bitstream and squinting at a picture is exactly the trap this project already fell
into once with HDMI; offline data makes each iteration seconds instead of minutes, and lets the
Verilog be checked against a reference implementation via `$readmemh`.

Measured from `ntsc_capture_19lines.hex`:

| Quantity | Value | Note |
|----------|-------|------|
| mean line period | **1716.06** samples | NTSC is 1716.05 — the sample clock is right |
| burst amplitude | ~21 codes (42 p-p) | stable line to line, well above noise |
| burst phase vs a free-running NCO | drifts only **~3°/line** | see below |
| blanking level | 133–134 | matches the black level the hardware measures |

The 3°/line figure is the important one and it de-risks the chroma PLL: an NCO at 3.579545 MHz
derived from our own 27 MHz advances 227.508 subcarrier cycles per line, while the source advances
exactly 227.5 (NTSC defines fsc = 227.5 × fh). The two nearly cancel, so the burst phase seen by a
free-running NCO is almost stationary and the loop only has to correct a slow drift.

A full demodulation of a line in Python (burst-locked reference, boxcar low-pass, YUV→RGB) already
produces plausible colour, so the data and the approach are sound.

### The capture side is not the limit: nothing is being clipped

Measured in hardware rather than inferred: **zero samples a second sit at the
bottom of the ADC's range.** The signal occupies codes 16..145 of 0..255, so
there is a hundred codes of headroom above and nothing pressed against the
floor. Whatever is missing from this source was never transmitted; it is not
being lost on the way in.

That settles the board question. The AD9280's clamp -- already wired, and
unusable only because C2 at 1 uF is far more than its clamp amplifier can drive
-- would move blanking up to CLAMPIN, around code 80, and buy room *below* it.
That is worth doing if sync and burst are being clipped off. They are not, so
**changing C2 would not recover them** and no board change is warranted.

A theory worth recording as dead: that the black level was being dragged down by
picture content, because AC coupling with no DC restoration puts the average at
the bias point and colour bars are bright. Tested by flashing the M5 with a
nearly black frame and measuring: 17/14/142 against 16/14/144 for the bars. The
levels do not move with content at all.

### The burst is there; the line geometry, measured

An earlier pass through this concluded the source emits no colour burst. That
was wrong, and what corrected it was one sentence from the bench: the generator
had always shown colour on a TV. A receiver cannot show colour without a burst,
so the measurement had to be at fault -- and it was.

Two measurement bugs, both of which produced steady, plausible, wrong numbers:

- **The burst min/max were latched per line and read one line at a time.** A
  read that lands on a vertical-interval line sees blanking wherever the gate is
  pointed, so every gate position reported the same 16..34 and the sweep looked
  flat. Accumulate over a field, and only over picture lines.
- **`vs_seen` was a single 126 MHz cycle consumed inside the 25.2 MHz sample
  strobe**, so the two never coincided and the accumulator was never closed out
  at all -- it read back its reset values. Anything crossing from the fast clock
  into the sample-rate logic has to be a level that the consumer clears, not a
  pulse.

With those fixed, gating a min/max detector and sweeping it gives the geometry
directly, in samples after the line start:

| gate | swing | what it is |
|---|---|---|
| 240..300 | **19 codes** | colour burst, on the blanking floor |
| 350..400 | 131 codes | picture |
| 74..102, 102..168 | 17 | artefacts of the broken measurement above |

Everything checks against everything else from there: the burst starts 5.3 us
after the sync edge, so the sync edge is at **106**; active video starts 9.4 us
after the sync edge, at **343**, which is exactly where the raw trace shows the
first white bar begin; and the burst's 60 samples are the 2.4 us NTSC asks for.

**`ACTIVE_START` was 106 and is now 343.** 106 is the sync edge, not the
picture, so the capture window opened 237 samples early and the left of the
screen was blanking and burst rather than video. The old value came from
assuming the qualifying low run begins at the sync edge. It does not -- it
begins about 230 samples earlier -- and only a measurement settles that.

The burst is half-wave: it rides on blanking, which is this signal's floor, so
the negative lobes have nowhere to go and only the positive ones survive. That
is enough for a phase reference -- the peaks are the phase -- but it is 19 codes
where a healthy source gives about 40.

### Line geometry, measured by the hardware itself

`blank_end` reports the first sample above threshold after a line start, which
is the one number the back porch and burst windows have to be built on -- and
the one the scope could not be trusted for, since its alignment has been wrong
before. It reads **102 to 104**. With `QUALIFY` at 124 the line starts 124
samples into the blanking run, so the run spans about 226 samples, or 9.0 us
against NTSC's 10.9 -- sane, and it means the run begins at the sync edge rather
than at the front porch (the front porch sits at blanking level, which is the
floor here, so it is below threshold too).

Burst amplitude, gated and measured per line:

| gate (samples after the line start) | swing |
|---|---|
| 0..102 (all of post-start blanking) | 18 codes |
| 10..74 (where the burst should be) | 3 codes |
| 48..100 | 4 codes |
| 74..102 | 17 codes |

The swing is in the last 28 samples of blanking, which is where the picture
starts -- it is the leading edge of active video, not a burst. The back porch
itself is flat. **This source appears to emit no usable colour burst**, which
would make a phase reference impossible to recover from it, and is consistent
with the burst being the same kind of below-blanking excursion that the sync is.
Worth an external check before acting on it: does a TV show colour from this
generator, or only a monochrome picture?

### The M5 generator's sync is absent, and `output_level` cannot restore it

Measured end to end, with the M5 rebuilt and reflashed from this machine
(`/dev/cu.usbserial-AD526BEB00`, `idf.py -p ... -b 115200 flash` -- the default
460800 fails on this adapter) and the result read off the Tang's own display
through the HDMI capture card:

| `output_level` | sync fraction |
|---|---|
| 64 | video collapses |
| 128 (library default) | 0% |
| 176 | 0% |
| 224 | 0% |
| 255 | 0% |

`main/CMakeLists.txt` passes `-DM5_OUTPUT_LEVEL=` through to the firmware, and
the define was verified present in `build/compile_commands.json` before any
conclusion was drawn from the sweep.

The library's intent is correct -- `Panel_CVBS` emits sync at DAC code 0,
blanking at 286 mV and white at 960 mV, which is the 29.8% NTSC asks for -- and
`output_level` scales blanking and white away from a sync pinned at code 0. The
sync *fraction* is therefore not something it can change, which the sweep
confirms. What arrives at the ADC has no measurable sync step at all: the
design's own trackers report the floor and the back porch at the same code.
That agrees with the independent reading `scripts/analyse_ntsc.py` gave from raw
dumps, so two unrelated measurements now say the same thing.

The remaining firmware-side option is to patch `Panel_CVBS.cpp` so sync is
emitted above DAC code 0 with everything shifted up to match, which would keep
the whole signal inside the part of the ESP32 DAC's range that behaves. It is a
vendored dependency, so that edit needs to survive `idf.py reconfigure`.

**Do not measure signal levels off the scope trace.** The trace is one mark per
column taken from every third sample, and 3.58 MHz chroma sampled at 25.2 MHz
puts adjacent columns on opposite phases -- so it is a scatter, not a line, and
a per-column average is not a level. Five sweeps of the generator were read that
way and produced plausible, stable, wrong numbers (a sync fraction of 12.7%
against the true 0%) before looking at the picture made it obvious. The design
now draws `f_min`, `black` and `f_max` as bars at rows 112/120/128, two pixels
per code, straight from the hardware trackers; read levels from those.

### The colour-bar source, and where it currently stands

`tools/m5-colorbars/` turns an M5Stack ATOM (ESP32-PICO-D4) into a composite colour bar generator
using LovyanGFX's `Panel_CVBS` (via `m5stack/m5gfx`, which carries the same code and *is* in the
ESP component registry — `lovyan03/lovyangfx` is not). Output is on G26, the M5Stack RCA unit's
pin. The pattern is 75% bars plus a 16-step grey staircase, so hue, saturation and luma linearity
can each be checked against published values instead of by eye.

**Use rgb332, not rgb565.** At 360x240 an rgb565 frame buffer is 173 kB and the largest free block
on an ATOM is 160 kB, so `gfx.init()` fails — *silently*, producing a signal that looks like video
but is not. That cost a wrong diagnosis (the chroma level was blamed and reduced for nothing). The
firmware now logs free heap and the init result on its own serial port; read it before trusting a
capture.

**Unresolved: the captured signal has no sync amplitude.** `scripts/analyse_ntsc.py` reports
sync-to-blanking of about 0 codes for every dump from this source, where the *previous* source
measured a correct 36 codes through the same front end. So the analogue path is fine and something
about the generated signal or its configuration is wrong. Leading suspicion is the ESP32 DAC's
poor linearity near its rails compressing the sync tip, which `output_level` would move; that is
untested. The cheap test that splits it: does a TV sync to this signal? If it does, the loss is on
our side after all.

### Analysis tooling

- `scripts/parse_dump.py` — pulls sample dumps out of a serial capture. It validates rows
  individually rather than trusting the `#DUMP`/`#END` framing, because the UART drops bytes often
  enough that a report line lands mid-dump and would otherwise discard the whole capture.
- `scripts/analyse_ntsc.py` — finds sync, burst and active video *by searching the waveform*, then
  decodes the bars and prints hue error and saturation ratio per bar against the expected values.
  It does not assume fixed offsets: a dump starts wherever the hardware slicer thought a sync edge
  was, which on a marginal source is not always a real one. Assuming fixed windows measured the
  wrong thing several times before this existed.
- `scripts/capture.sh` — programs a bitstream and captures in one shot; see the UART note below.
- `scripts/tang_port.py` — identifies the Tang by its USB vendor via `ioreg`. Taking the last
  `/dev/cu.usbserial-*` breaks the moment anything else is plugged in, and silently reads the
  wrong device.

### Do not trust the serial link, and do not build the workflow on it

The UART on this board has been unreliable for an entire bring-up session, in a
way never fully explained. It goes silent — JTAG still works, the design still
runs and drives HDMI perfectly — and comes back for one bufferful after a
physical replug or a cable change, then dies again. Things that did *not* fix
it: SRAM programming instead of flash, a libusb port reset
(`scripts/usb_reset.py`), a different USB-C cable, direct connection to the Mac
rather than a hub, startup hold-offs, smaller and rarer transfers.

Two lessons, both learned expensively:

- **Never make a physical replug part of the edit-test loop.** Flashing was
  adopted to dodge the UART problem, but flashing needs a power cycle before
  the FPGA picks up the new bitstream — so it made the replug *mandatory* for
  every single test, while not avoiding the problem at all. The replug was what
  fixed the UART, not the flash. `make ntsc-run` builds, loads to SRAM and
  reads in one step; prefer it.
- **Put diagnostics on the channel that works.** The HDMI output was rock solid
  throughout. The design now draws the captured waveform on screen as a
  line-triggered oscilloscope, with the slicing threshold and a sync-confidence
  bar over it. Watching the waveform is what produced every real insight in
  this project; doing it live and without a serial link is worth far more than
  another round of tuning constants blind.

### The UART interface dies after programming

On macOS, `openFPGALoader` claiming the FTDI device over libusb intermittently leaves the UART
interface dead — JTAG still works, the design still runs and drives HDMI, but the serial port goes
completely silent. The only fix found is unplugging and replugging the board. Budget programming
runs accordingly: `scripts/capture.sh` exists so each one is followed immediately by a capture.
Prefer small dumps; 2048 samples transfers in about a second where 32768 takes nineteen and often
does not survive.

Colour bars are vertical, so **one line contains all eight colours** — there is no need for the
long capture at all.

## Measuring the picture: take the second capture, not the first

`scripts/video_quality.py` classifies rows of a 120-frame capture as correct,
dropped or wrong-order.  It resolves an RTL change perfectly well -- but only if
the capture is taken the right way, and getting that wrong invented a whole
false conclusion here before it was caught.

**Programming drops the HDMI link, and the first capture afterwards reads
systematically low** while the sink, the capture card and the vertical servo
re-acquire:

| | correct |
|---|---|
| first capture after programming | 56.7% |
| second, third, fourth | 64.7%, 65.1%, 64.2% |

Eight points on an unchanged bitstream.  Take two captures and keep the second.

With that done the instrument is good.  Five placement seeds of one design
spread three points (64.8..67.8%), and rebuilding an old revision reproduces
its earlier figure to within two (84.5% now against 86.5/87.3% hours before).

A retracted claim, recorded because the reasoning was seductive: an earlier
pass through this concluded that build-to-build spread was *thirty* points and
that the metric could not resolve RTL at all.  Every number behind that was a
first-capture-after-programming.  A seed sweep that programs and immediately
measures compares four equally biased numbers, and the bias is large enough to
swamp exactly the effects being looked for.  **The instrument was fine; the
protocol was not.**

Do still check the reported frequency before believing a measurement:
`--freq`/`--sdc` does not stop a build being programmed, and a seed that reports
`FAIL at 125.94 MHz` still produces a `.fs`.

### ADC bit 6 is stuck low, and a known DC input proves it

The board reports only 24 of 256 codes -- 16..19, 32..35, 48..51, 128..131,
144..147, 160..163 -- and nothing at all between 64 and 127.  Four independent
measurements agree, so this is not an artefact of any one of them:

- the dumped waveform read off the HDMI scope;
- the hardware's own 16-bin histogram over the UART, `H 0000 0032 0115 0035
  0000 0000 0000 0000 007B 0091 00F6 0000 ...`, with bins 4..7 empty;
- a counter on `adc_r[6]` read straight off the register, against a positive
  control on `adc_r[5]` that saturates its bar;
- `CLAMP_FORCE`, which pins AIN to CLAMPIN = VREF x 10/32 = 0.625 V.  The right
  answer is code 80, `0101_0000`.  The board returns 17..19 and 33..35, which
  is 80 and 96 with bit 6 removed, and bit 7 goes to zero as well because
  nothing exceeds 63 any more.  No video, no sync, no display path, no source.

What it is not, each ruled out by measurement rather than argument:

- **not an open joint.**  Rewriting only the pull attributes of an
  already-routed netlist -- `scripts/scope_pull_variant.py`, so placement is
  identical -- leaves every data bit unmoved by PULL_MODE UP or DOWN.  An
  unsoldered pin follows the pull; all eight resist it.
- **not the read-back path.**  A known ramp written into the dump buffer comes
  back exactly: 241 distinct values, every column within one code.
- **not the source.**  Inserting a stabiliser changed the signal and left the
  banding untouched.
- **not the sampling phase** (all five band identically) **nor the ADC clock
  duty** (60% gives 21 distinct codes against 40%'s 27, and bit 6 stays dead).

So the D6 net is held low by something low-impedance.  A bridge to ground, a
failed AD9280 output, or a failed FPGA input, in that order of likelihood.  It
is `adc_d[6]` -- FPGA pin 31, AD9280 pin 11, DIP pad 14 -- and an ohmmeter to
ground with the power off separates the first from the other two.

**It is the AD9280, and the chain that gets there is worth keeping.**  With the
bus verified alive in all three configurations -- the five working bits sit at
0.44..0.65 in each, which is what makes the reading trustworthy -- bits 2, 3 and
6 stay at exactly 0.00 under PULL_MODE UP as well as DOWN and NONE.  A floating
pin reads 1.00 with an internal pull-up, so something low-impedance holds them.

An ohmmeter to ground, power off, then reads **130 kOhm on D2, D3 and D6 -- and
the same 130 kOhm on D5, which works.**  So the nets are not shorted and the PCB
is fine.

And the high-Z accident above settles the last leg: while the AD9280's outputs
were disabled, PULL_MODE=UP read those same three bits at 0.58, 0.37 and 0.57.
**The FPGA inputs can read a one on pins 42, 41 and 31.**  They only ever read
zero when the AD9280 is driving.

Not shorted, not the FPGA, not floating, and a known 0.625 V input whose correct
code is 80 comes back as 17..35.  **U1's D2, D3 and D6 output stages are stuck
low; the part needs replacing.**  That is worth doing: the converter is
delivering 24 of 256 codes, and several long-standing oddities recorded in this
file -- a burst at half its specified amplitude, levels that never sat right,
chroma that would not calibrate -- are consistent with five usable bits.

**A reading taken while the outputs were high-Z is not a reading.**  Rework left
the AD9280's THREE-STATE or STBY pin (16, 17) briefly off ground, which puts the
whole data bus into high impedance -- it reads all zeros with no pull, and with
PULL_MODE=UP it reads 72 "distinct codes" of pure noise, including apparent life
on bits 2, 3 and 6.  That was reported here as the rework having worked.  It had
not.  The tell was in the same line: bits 0 and 5, which are healthy, read 0.07
and 0.14, and healthy bits do not do that.  **Check the known-good bits before
believing anything about the suspect ones.**

**Why the picture looked fine, and why that misled three attempts here.**  The
luma path averages seven consecutive samples, and the samples dither across the
missing range in proportion to the true level, so the boxcar output climbs
smoothly through values the ADC itself never produces: 162, 148, 136, 132, 121,
118, 98, 97, 87, 81, 62, 54, 33 measured off a real dump.  A monotonic
eight-bar picture is therefore not evidence that the ADC is intact, and
reasoning that it was cost several rounds.  Fixing this recovers the six bits
of range now being thrown away, which is the largest single improvement
available to this project.

### The capture card freezes, and a frozen frame reads as a confident result

Worse than the first-capture bias above, and it produced a wrong conclusion
here before it was caught.  After programming, the card can return the *same
frame* for minutes.  Three different bitstreams -- built, packed and loaded
minutes apart -- produced byte-identical PNGs, and the analysis of them
produced a clean, plausible, entirely fictional finding: that the decoder's own
register held data the dump did not.  Measured live, the two agree exactly.

The tell is an MD5 that does not change, so `scripts/live_capture.sh` checks
for it and refuses to return a stale capture.  Use it instead of calling ffmpeg
directly; it needed nine passes once.  Nothing downstream can detect this,
because a frozen frame is a perfectly valid picture.

### What the stabiliser did, measured

An external video stabiliser was tried in the signal path, on the reasoning
recorded above that regenerating sync would return information the M5 simply
does not transmit.  It did not regenerate sync -- the waveform floor stayed at
33..34 with no step below it -- and the picture got much worse:

| | correct | dropped | wrong-order | colour |
|---|---|---|---|---|
| no stabiliser, M5 timing | **84.5%** | 12.7% | 2.8% | yes |
| stabiliser, M5 timing | 22.5% | 66.4% | 11.1% | **0 of 120** |
| stabiliser, standard timing | 32.2% | 49.0% | 18.8% | **0 of 120** |

Levels essentially unchanged, yet neither sync nor burst locks.  That
combination points at the vertical interval being rewritten, which is how this
class of device works.  The unit has settings that were not swept, so this
retires the specific attempt rather than the idea.

### Do not disturb the burst phase to fix the vertical interval

`burst_nco` tracks the per-line burst angle and blends each measurement into a
prediction at quarter weight, which is where its noise advantage comes from --
median row-to-row colour difference 3.7 codes against 1.3.  The vertical
interval carries no burst for about twenty lines, so the prediction free-runs
and the first line back is up to 38 degrees out.  `sim-tracking` asserts this.

Two remedies were built and both cost seventeen points of good rows on the
board, with seven times as many out-of-order rows:

| | correct | wrong-order |
|---|---|---|
| no gap handling | 84.5%, 86.0% | 2.8%, 3.2% |
| gap invalidates the learned step | 67.8% | 20.3% |
| gap snaps the phase, keeps the step | 67.3% | 20.9% |

That the *second* one is no better is the informative part.  It preserves
everything the first throws away, so the damage is not the step being
re-learned -- it is moving `burst_off` at all on a gap.  A gap long enough to
fire is not rare on this source: the burst is 19 codes against a spec 40, so
individual lines fall under `MAG_MIN` in the middle of active video, and each
misfire replaces an average over a field with one noisy line's measurement.
Widening the window to five lines does not help; it still fires.

So the mechanism stays in `burst_nco` with its test, and `ntsc_capture` passes
`BURST_GAP_SAMPLES` large enough to disable it.  Four bad lines per field is
cheaper than what fixing them costs everywhere else.  A source with a
full-amplitude burst would not misfire and should turn it back on.

## Hardware (Verified against `../tangADC.zip` → `tangADC.kicad_sch` + `production/netlist.ipc`)

Carrier board `tangADC`: AD9280ARS (U1, SSOP-28) on a DIP-40 socket for the Tang Nano 20K (U2).
Board is powered from the Tang Nano's own 3V3 (DIP pads 19 and 25) through ferrite beads
FB1 → `+3V3A` and FB2 → `+3V3D`. The `+5V` pin (pad 40) is brought out but otherwise unused.

### FPGA pin assignment

The data bus is **not** in physical pin order. This mapping is authoritative:

This is the **corrected** assignment, on the respun board. `adc_d[2]`, `adc_d[3]`
and `adc_d[6]` moved off FPGA 42/41/31, which the Tang module holds low — see
*The respun board works* below for the measurement that confirmed it.

| Signal      | Dir        | FPGA pin | Tang-side net | DIP pad | Series R |
|-------------|------------|---------:|---------------|--------:|----------|
| `adc_clk`   | FPGA → ADC |   **73** | HSPI_DIN2     |       1 | 33 Ω (R13) |
| `adc_clamp` | FPGA → ADC |   **74** | HSPI_DIN3     |       2 | —        |
| `adc_d[6]`  | ADC → FPGA |   **75** | HSPI_DIR      |   **3** | 20 Ω (R11) |
| `adc_d[7]`  | ADC → FPGA |   **77** | GCLKT_1       |       5 | 20 Ω (R12) |
| `adc_d[0]`  | ADC → FPGA |   **27** | LCD_B7        |       8 | 20 Ω (R5) |
| `adc_d[1]`  | ADC → FPGA |   **28** | LCD_B6        |       9 | 20 Ω (R6) |
| `adc_d[4]`  | ADC → FPGA |   **29** | LCD_B5        |      12 | 20 Ω (R9) |
| `adc_d[5]`  | ADC → FPGA |   **30** | LCD_B4        |      13 | 20 Ω (R10) |
| `adc_otr`   | ADC → FPGA |   **71** | HSPI_DIN0     |      23 | 20 Ω (R18) |
| `adc_d[2]`  | ADC → FPGA |   **72** | HSPI_DIN1     |  **24** | 20 Ω (R7) |
| `adc_d[3]`  | ADC → FPGA |   **76** | GCLKC_1       |  **38** | 20 Ω (R8) |

Bit order, flattened: `D0=27  D1=28  D2=72  D3=76  D4=29  D5=30  D6=75  D7=77`.
`D2`/`D3` and `D4`..`D6` are the easy ones to transpose — a swapped pair shows up as a symmetric
"folded" luma ramp, not as noise.

The superseded assignment, for reading old logs: `D2=42  D3=41  D6=31`, DIP pads
36, 35 and 14. Anything measured on those three bits before 2026-09-24 was
measured through pins that read a constant zero.

`adc_d[3]` is on 76, which is `GCLKC_1`. A global-clock pin used as an ordinary
input is fine — it simply also has a clock-capable route — and it is measured
alive. It is a *configuration* pin that must be avoided, not a clock one.

Onboard (not on the carrier): 27 MHz oscillator on **pin 4**; HDMI TMDS on pins 33–40
(clk 33/34, data0 35/36, data1 37/38, data2 39/40); LEDs on pins 15–20.

### AD9280 analog operating point (from the datasheet, *Verified*)

`MODE` tied to AVDD selects **single-ended** operation, where the datasheet states the input spans
`REFBS ≤ AIN ≤ REFTS`, with the two required to be 1–2 V apart. On this board REFTS = VREF and
REFBS = AGND, and VREF measures 2.0 V (`REFSENSE` to ground selects the internal 2 V reference), so:

    AIN range = 0 V .. 2.0 V, ground-referenced (not centred on a mid-supply common mode)

CLAMPIN = VREF x 10/32 = **0.625 V ≈ code 80**. NTSC is 1 V sync-tip-to-white, so clamping the sync
tip to 0.625 V puts blanking near code 116 and peak white near code 208 — comfortably inside the
span. **The board's analog design is sound**; do not go looking for a design error there.

A consequence worth remembering: code 0 together with OTR asserted is the AD9280's *under-range*
flag, and it is what you see whenever AIN sits below 0 V — which is exactly what an AC-coupled
input does when DC restoration is not happening.

### AD9280 pinout — independently verified against the datasheet

The KiCad symbol, the schematic and `constraints/tangnano20k_adc_probe.cst` all agree with the
AD9280 pin function table. Do not re-litigate this:

| Pin | Datasheet | On this board |
|-----|-----------|---------------|
| 3, 4 | DNC (Do Not Connect) | unconnected |
| 5 / 12 | **D0 = LSB / D7 = MSB** | `adc_d[0]`=FPGA 27, `adc_d[7]`=FPGA 77 — bit order correct |
| 15 | CLK | FPGA 73 |
| 16 | THREE-STATE: HI = high-Z, **LO = normal** | GND, outputs enabled |
| 17 | STBY: HI = power-down, **LO = normal** | GND |
| 19 | CLAMP: **HI = enable clamp**, LO = none | driven active-high (`CLAMP_ACTIVE_HIGH = 1`) |

### AD9280 strapping (fixed in copper — the FPGA cannot change these)

- `THREE-STATE` (16) → GND — outputs always enabled.
- `STBY` (17) → GND — always running.
- `REFSENSE` (18) → GND, `REFTS` (21) → `VREF`, `REFBS` (25) → GND — internal reference.
- `MODE` (23) → `+3V3A`.
- `CLAMPIN` (20) ← resistive divider from `VREF`: R2 22 kΩ / R4 10 kΩ = `VREF × 0.3125`,
  bypassed by C12 0.1 µF. The clamp *level* is hardwired; the FPGA only gates it via `adc_clamp`.
- `adc_clk` (pin 73) and `adc_clamp` (pin 74) each have a **10 kΩ pulldown** (R17, R14). If the
  FPGA leaves them floating the ADC is unclocked and unclamped — a dead bus reads as all-zero,
  which is indistinguishable from a bit-order bug. Drive `adc_clk` before debugging data.

### Analog front end

`J1` (RCA) / `J3` (RJ-2410N) → R1 75 Ω shunt termination → D1 PESD5V0U1BA ESD clamp →
C2 1 µF AC coupling → R3 20 Ω series → C13 100 pF shunt → `AIN` (U1 pin 27).
Testpoints: TP1 = `AIN`, TP2 = `VREF`, TP3 = `CLAMPIN`, TP4 = `adc_clk`.

### Expansion header J2 / Grove J4, J5

J2 carries FPGA pins **17, 18, 19, 20, 48, 49**. Pins 48 and 49 have 4.7 kΩ pull-ups to 3V3
(R15, R16) and are also on the Grove connectors J4/J5 — that is the I²C pair.
**FPGA 17–20 are also the Tang Nano 20K's onboard LEDs**, so anything driven on those J2 pins
lights LEDs, and vice versa. Pick 48/49 for expansion unless you need four signals.

Grove J4/J5 pin 1 is FPGA 48 and pin 2 is FPGA 49 (netlist), so 48 is SCL and 49
SDA in Grove's order; pin 3 is **+5V**, pin 4 GND.  48/49 are in bank 3 at 3.3 V
with the buttons (Apicula's `pin_bank`), away from the LVDS banks.  A Grove
device that pulls SDA/SCL up to 5 V would overdrive them; check its schematic.

### M5Stack Unit 8Angle on the Grove port (2026-09-26)

`src/angle8.v` polls an 8Angle -- eight potentiometers and a slide switch behind
an STM32F030 at 0x43 -- and `top_ntsc_hdmi` draws the result at the bottom of
the diagnostic view (rows 400..463: a cyan bar per knob, two pixels a count;
at x 528 a green block for the switch, at x 592 a red block while nothing
answers).  Nothing else uses the values yet.

What the unit's firmware (m5stack/M5Unit-8Angle-Internal-FW) actually does,
because the Arduino library's register list does not say it:

- **One register per transaction, no auto-increment.**  A write of the register
  number (with a STOP) arms exactly one reply -- 0x10+n is channel n in eight
  bits, 0x00+2n in twelve (two bytes, low first), 0x20 the switch -- and the
  next read returns it.  A scan is nine write/read pairs, about 5 ms at 100 kHz.
- **It stretches SCL** while it prepares a reply (HAL, `NoStretchMode`
  disabled), so the master must wait for SCL to rise every time it lets go.
- The switch register is the pin level through a 10 kOhm pull-up, not a
  "pressed" flag; SW1 is a slide switch.
- Its SDA/SCL are pulled to its own 3.3 V (4.7 kOhm, R12/R13), so it is safe on
  these pins even though the Grove cable carries 5 V.

`make sim-angle8` runs the reader against a model of that firmware, with 30 us
of stretching on every read: all eight channels and the switch arrive and a
change is picked up.  DEV 0x44 is the negative control -- nothing at 0x43,
present stays low, no value written.  One bench bug worth knowing: the model
first released SCL in the same instant it put the data bit on SDA, and its own
START detector saw SDA fall with SCL high; data first, then SCL.

On the board it answered at once: present, the switch following the slide,
knobs moving with the bench's turns.

### Glitch controls: the knobs break the decoder itself (2026-09-26)

The bench asked for glitch / datamosh control from the 8Angle, with one rule:
not image processing on the output, but things only this decoder can do --
each knob breaks one of its own stages.  Fully left is off, and must be the
clean picture exactly.  ntsc_capture takes them as `fx`, a byte each:

| knob | fx | what breaks |
|---|---|---|
| 1 | `fx_slice` | sync slicer raised from just above black to just under white, and long runs accepted: dark picture reads as sync, so the picture decides where lines start |
| 2 | `fx_hhold` | real syncs thrown away (probability fx/256), flywheel and free-running starts up to 59 samples long: horizontal hold lost |
| 3 | `fx_stretch` | a line, with probability fx/256, resampled at a random rate -- one pixel per 4 samples (squeezed into the left half) up to one per sample (its left half stretched across); the rest of the bank still holds an older line |
| 4 | `fx_col` | the colour reference collapsing: a phase ramp on the burst-locked reference, up to 23 kHz, which the per-line correction cannot see, and the burst gate slid up to 478 samples into the picture, where the CORDIC takes a bar's chroma for the burst |
| 5 | HDMI: `tmds_sparkle` | a TMDS bit error, worked out in the FPGA: a hit pixel (probability (fx/256)^2 per channel) is encoded as its data word, bits flipped, and decoded as the sink would; the real encoder then sends that byte, so every symbol on the wire is valid -- bad-cable sparkle, snow at full |
| 6 | `fx_adc` | the bus faults this board really had, worsening in order: the LVDS pair misread of bits 0/1 and 4/5, bits 6, 3, 2 stuck low, pairs transposed, the bus reversed |
| 7 | `fx_wrap` | the colour matrix overdriven (chroma up to 4.7 times, luma 2.9) and its clip removed: past 255 a value keeps its low eight bits, so saturated and bright parts fold into their complements |
| 8 | `fx_hold` | lines left unpublished (probability fx/256): the line store repeats the last one |
| switch | | green in the diagnostic view enables them all |

**Which end is left was measured, not assumed**: all eight fully left read
253..255, so `KNOB_INVERT` is 1.  A dead band (`KNOB_DEAD`, 16 counts) keeps a
knob at the stop exactly off whatever the converter's noise.  With every knob
left and the switch on, the board measures what it did without the feature:
rotation 0.5 degrees, hues +7/-9/-2/-4/-6/+4, colour 60/60, no dropped rows.

First board trial, and what it changed:

- **Knob 6 did nothing visible** when it moved the converter's clock off its
  calibrated phase.  A read in the switching window only errs where the
  sample changes, and colour bars are flat.  Replaced by the fault list above.
- **Knob 3 only scrolled.**  The vertical servo may trim one line a frame, or
  the sink drops the link, so a vertical-hold roll is a slow, clean scroll.
  Replaced by the burst gate -- which then overlapped the NCO ramp on knob 4
  (both only turn the hue), so the two became one knob, and knob 5's Y/C
  blend, too gentle to see on bars, gave way to the TMDS sparkle.  Knob 3 is
  now the line stretch.
- **The sparkle, done on the wire, took the picture away.**  Corrupted TMDS
  symbols -- control tokens untouched and none made -- still made this sink
  drop the image: it counts bad characters.  It is now computed in the pixel
  domain, as the sink would decode the error, and sent as valid symbols.
- **Knob 7, moving the black window, stayed dull** on bars (the whole picture
  steps in brightness); it is now the wrapping matrix.
- **Knob 1 went black within seconds.**  The raised slice falls below
  threshold inside the picture, the front-porch capture then reads picture
  (the grey staircase ends bright), black followed it up to white, and the
  slice, set from black, rose with it.  The recording could not show it -- it
  holds bar lines only.  Black is now held while knob 1 or 2 is off zero.

`make sim-video-glitch` applies each effect (and all together) for 50 lines of
the colour-bar stimulus: it must visibly break the picture -- over 1000 wrong
colour channels, or for the hold, lines unpublished -- and 200 lines after it
is removed the bars must decode to the published values again, `max_error`
17 as in sim-video.  The sparkle is below the capture and has its own bench,
`make sim-sparkle`: the rate following (fx/256)^2 (0.607 against 0.609 at 200,
0.063 at 64), blanking untouched, nothing at 0, and an empty error on every
pixel round-tripping exactly -- the modelled encoder and decoder are inverses.

The first slice mapping added a fixed 0..119 codes to the normal threshold:
nothing below about a quarter turn, where the slice was still under blanking,
and nothing near full, where it sat over white and no run ever ended; and
runs over 150 samples were still refused, so above blanking it only lost sync.
Scaled between black and white with long runs accepted, it breaks the bars
at every setting (4914 / 3920 / 2728 / 882 wrong channels at 0x10 / 0x50 /
0x90 / 0xE0).

## Toolchain

Open-source flow, same as the sibling project `../tang` (a Tang Nano **9K** starter that already
has working TMDS output). The suite is installed *per-project* under `.tools/oss-cad-suite` and is
invoked through a `scripts/tool` wrapper that sources the suite's `environment` file, so the
shell PATH is never modified. Copy `../tang/scripts/{tool,setup-macos.sh}` rather than reinventing.

- **Yosys** `synth_gowin` → JSON netlist
- **nextpnr-himbaechel** → place & route (chipdb `GW2A-18C` is present in the installed suite)
- **Apicula** `gowin_pack` → `.fs` bitstream
- **openFPGALoader** `-b tangnano20k` → SRAM (volatile) or `-f` → flash
- **Icarus Verilog** (`iverilog`/`vvp`) for simulation; waveforms to `build/*.vcd`

Device strings for the Tang Nano 20K (differ from the 9K project — update both):

```
DEVICE := GW2AR-LV18QN88C8/I7
FAMILY := GW2A-18C
BOARD  := tangnano20k
```

`.tools` is a symlink to `../tang/.tools` so the 1.8 GB suite is not downloaded twice;
`scripts/setup-macos.sh` still works standalone if that sibling ever goes away.

### Commands

```sh
./scripts/setup-macos.sh   # one-time: install OSS CAD Suite into .tools/
make check-tools
make sim                   # positive: synthetic NTSC in, must measure ln=1716
make sim-badphase          # negative: a bad sampling phase must NOT measure 1716
make build                 # -> build/adc_probe_top.fs
make program               # load to SRAM (fast loop, lost at power-off)
make flash                 # write to onboard flash (persistent)
make monitor               # read the report (see the serial gotcha below)
make clean
make restore-flash         # write back the known-good 2026-09-26 NTSC bitstream
```

`bitstreams/ntsc_good_2026-09-26.fs.gz` is that bitstream itself (tag
`good-2026-09-26`, sha256 of the `.fs` `07ca2c89...acc`), kept so the known-good
state survives source and toolchain changes; `make restore-program` loads it to
SRAM only.  It is the only bitstream in version control -- add another only
when the user asks for a restore point.

Diagnostic variants — same RTL, only a constraint or a parameter differs:

```sh
make pullup-program        # weak pull-ups on the ADC inputs
make clampon-program       # CLAMP held on: AIN forced to CLAMPIN, needs no video source
make clampoff-program      # CLAMP held off, for comparison
```

Run a single testbench directly instead of adding a target for it:

```sh
./scripts/tool iverilog -g2012 -s <tb> -o build/<tb> <rtl...> sim/<tb>.v && ./scripts/tool vvp build/<tb>
```

Each top-level design gets its own `{RTL, CST, netlist, pnr, bitstream}` variable group and its own
`<name>`/`<name>-program`/`<name>-flash` targets — that is how `../tang` keeps the LED, HDMI, and
ADV7180 designs buildable side by side. Follow the same pattern so the ADC bring-up bitstream stays
buildable after the decoder lands. The pull-up and clamp variants deliberately *derive* from the
one authoritative `.cst` / RTL rather than copying it, so pin numbers have a single source.

### Serial output — the macOS trap

macOS resets a `/dev/cu.*` port to its **9600 baud** default the moment the last descriptor closes.
`stty -f PORT 115200` followed by `cat PORT` therefore reads at 9600 and produces garbage that looks
exactly like a design bug. `scripts/monitor.py` sets the speed on the descriptor it then reads from,
which is the only way to make it stick. Never replace it with stty+cat.

(This cost real debugging time once: the report decoded as a repeating 8-byte pattern, and the
transmit/receive rate ratio came out as exactly 12.00 — 115200/9600.)

### Bench checks when the ADC bus looks dead

The carrier board has test points for exactly this. A 27 MHz 50% square wave reads ~1.65 V on an
ordinary multimeter, so a meter is enough for all of these:

Load `make clkhigh-program` first so `adc_clk` is a static 3.3 V and the readings are unambiguous.

| Point | Expect | If wrong |
|-------|--------|----------|
| TP4 `adc_clk` (clkhigh loaded) | 3.3 V | see the R13 split below |
| R13 pad on the module side (net `CLK`) | 3.3 V | the module is not driving pin 73 / socket contact |
| TP2 `VREF` | ~2 V, non-zero | AD9280 reference or `+3V3A` dead (check FB1) |
| FB2 both ends | 3.3 V | **see the split-supply note below** |
| FB1 both ends | 3.3 V | `+3V3A` / AVDD |
| TP3 `CLAMPIN` | ~0.31 × VREF | R2/R4 divider |
| TP1 `AIN` | ~0.6–1.7 V with video and clamp working | front end or source |
| J1 / J3 input | ~1 Vpp composite | source not actually outputting |

**The two supplies come from different module pins**, and this is easy to miss:

    DIP pad 19 -> +3V3 -> FB1 -> +3V3A -> U1 pin 28 AVDD
    DIP pad 25 ->         FB2 -> +3V3D -> U1 pin 2  DRVDD

So a healthy TP2 (`VREF`, which depends only on AVDD) does **not** prove DRVDD is present, and
without DRVDD the digital outputs never drive — which looks exactly like a dead bus.

R13 (33 Ω) splits the clock net: its module-side pad is net `CLK` (DIP pad 1 / FPGA pin 73), its
other pad is `NET-(U1-CLK)` = TP4 = the AD9280 CLK pin, with R17 10 kΩ to ground. Module side high
and TP4 low therefore isolates the fault to R13, the trace, the socket, or the ADC's CLK pin.

## Architecture

Built today (step 1):

```
clk27 (pin 4) → rPLL → clk108
                  ├── /4 → adc_clk (pin 73)      27 MHz to the AD9280
                  ├── 4-phase capture of adc_d   phase selectable at runtime
                  ├── sync slicer → line period / vsync / level stats
                  ├── clamp gating (sync-tip window, free-runs before lock)
                  ├── 2048-sample line buffer (BSRAM) for the raw hex dump
                  └── report formatter → uart_tx (pin 69)
```

Planned, downstream of the same capture block:

```
AD9280 → adc_capture → sync_detector ─┬─ hsync / vsync / field
                                      └─ burst_gate
            ↓
       ntsc_decoder   (black-level restore, Y/C separation,
                       burst-locked NCO, U/V demod, YUV→RGB)
            ↓
       deinterlacer   (bob: 480i → 480p, line buffers only, no frame buffer)
            ↓
       video_timing → tmds_encoder ×3 → OSER10 ×4 → HDMI
```

### Clocking decisions

- The PLL primitive is **rPLL**, not PLLVR, with `defparam DEVICE = "GW2AR-18C"` — confirmed
  against Sipeed's own `TangNano-20K-example/hdmi/src/gowin_rpll/TMDS_rPLL.v`. See `src/rpll_108.v`.
  rPLL maths: `CLKOUT = FCLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1)`, `VCO = CLKOUT * ODIV_SEL`, and the
  VCO must stay in 400–1200 MHz.
- Sample at **27 MHz**, not at 4×/8×fSC. This keeps ADC clock generation
  and NTSC decoding as two independent problems; the 3.579545 MHz subcarrier is tracked by an NCO
  locked to the colour burst. AD9280 is rated to 32 MSPS, so 27 MHz is in spec.
- The ADC round-trip (FPGA → 33 Ω → ADC → pipeline → 20 Ω → FPGA) means `adc_d` is *not* aligned to
  the launch edge. `adc_probe_top` handles this by running at 108 MHz and capturing the bus on all
  four phases of each ADC period (0 / 9.3 / 18.5 / 27.8 ns after the `adc_clk` edge), with the tap
  selectable at runtime from button S2. Phase 2 is the default. Keep this mechanism when the
  decoder replaces the probe — it is the cheapest way to walk the data eye without a scope.
- Output side: 27 MHz × 5 = 135 MHz serial clock, `CLKDIV DIV_MODE="5"` back down to a 27 MHz pixel
  clock, giving CTA-861 VIC 2 (720×480p60). `../tang/hdmi/top_hdmi.v` implements exactly this and
  its `tmds_encoder.v` is directly reusable.

### 9K → 20K porting notes

`../tang` targets the 9K; the primitives carry over (`rPLL`, `CLKDIV`, `OSER10`, `ELVDS_OBUF`) but
the constraints do not:

- **The HDMI pins are TRUE LVDS on the 20K and emulated LVDS on the 9K.** This is the one porting
  trap that stops the build dead. Use `TLVDS_OBUF` + `IO_TYPE=LVDS25`; the 9K's `ELVDS_OBUF` +
  `LVDS25E` is rejected by Apicula with
  `X23Y54/IOBA (tmds_clk_p_OBUF_O) cannot be placed - location is a True LVDS pin`.
  Apicula also requires P on the pair's IOBA pin and N on its IOBB pin, i.e. 33/34, 35/36, 37/38,
  39/40 in that order. Sipeed's Gowin-EDA example names one port with both pin numbers
  (`IO_LOC "O_tmds_clk_p" 33,34;`) and lets the tool infer the negative pin; the open-source flow
  does not infer it, so name both halves explicitly. See `constraints/tangnano20k_hdmi.cst`.
- **Never put `DRIVE=` or `BANK_VCCIO=` on an LVDS25 constraint.** This one cost a long debugging
  session. Sipeed's Gowin-EDA `.cst` carries `DRIVE=3.5 BANK_VCCIO=3.3` and copying that into the
  open-source flow builds cleanly, reports perfect timing, and produces a link no sink will lock
  to — a silent, total failure. Apicula's own reference (`examples/tangnano20k.cst` in the Apicula
  tree, which drives a working DVI example on this exact board) uses only
  `IO_TYPE=LVDS25 PULL_MODE=NONE`. Both attributes are individually *valid* in Apicula's tables, so
  nothing warns.
- **Constrain `--freq` to the pixel clock (27), not the serial clock.** nextpnr applies `--freq` to
  every clock it does not otherwise know, so passing 135 makes it demand 135 MHz of the pixel-clock
  domain — where the TMDS encoder's combinational path tops out around 93 MHz — and the build fails
  a timing check that does not really exist. The serial clock only feeds OSER10 primitives, which
  have no user logic between them.
- The 9K's LED/button bank is 1.8 V (`LVCMOS18`); do not copy that constraint over. All AD9280
  signals are `LVCMOS33` — the ADC's digital side is 3.3 V. Confirm the actual bank VCCIO for
  pins 27–31 / 41 / 42 / 71–77 against the Sipeed 20K schematic before trusting `LVCMOS33` on a
  new pin; a wrong bank voltage on an input bus is a silent data-corruption failure.
- Bring `adc_clk` in via a clock buffer and constrain it (`CLOCK_LOC ... BUFG;` is used for the
  ADV7180 `LLC` input in `../tang/constraints/tangnano9k_adv7180_hdmi.cst`).

### Reusable prior art in `../tang`

- `hdmi/tmds_encoder.v` — 8b/10b TMDS encoder, device-independent.
- `hdmi/top_hdmi.v` — PLL + CLKDIV + 720×480p60 timing + OSER10/ELVDS output chain.
- `hdmi/top_adv7180.v`, `hdmi/adv_line_buffer.v` — an existing **480i → bob → 480p** path with
  two line buffers and no frame memory, plus the "blue screen until a valid line is detected"
  startup behaviour and LED diagnostics. This is the closest analogue to what the NTSC decoder
  needs downstream; read it before designing the deinterlacer.

## Conventions

- Verilog-2001/2012 with `` `default_nettype none `` at the top of every file.
- **Give reset registers a power-up initialiser** (`reg [3:0] reset_pipe = 4'b0000;`). Gowin honours
  it, and without it a reset released by PLL `LOCK` can start at X in simulation and never assert,
  leaving every subsequent register X. This is a silent, whole-design failure that looks like a
  clocking bug.
- `expect` is a SystemVerilog keyword; do not name a testbench task that.
- Every measurement testbench should have a negative control. `make sim` asserting "we measured
  1716" is only worth something because `make sim-badphase` asserts that a broken setup does not.
- Comments in English; user-facing README/docs in Japanese (matching `../tang`).
- `build/`, `.tools/`, `*.vcd`, `.DS_Store` are generated — keep them out of version control.
- Onboard LEDs are **active-low** and are a legitimate first debug output: `../tang` uses LED0/1/2
  as reset-released / PLL-locked / valid-line-detected indicators. Do the same for ADC bring-up.
