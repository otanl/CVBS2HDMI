SHELL := /bin/bash

# nextpnr can write its JSON before failing the final timing check. Without
# this, a second make can pack that failed result as if routing had succeeded.
.DELETE_ON_ERROR:

# Tang Nano 20K: GW2AR-18C core, 27 MHz onboard oscillator.
DEVICE    := GW2AR-LV18QN88C8/I7
FAMILY    := GW2A-18C
BOARD     := tangnano20k
FREQ_MHZ  := 108

BUILD_DIR   := build
BUILD_STAMP := $(BUILD_DIR)/.dir
TOOL        := ./scripts/tool
# gowin_pack, with single-ended inputs in a true-LVDS bank packed as their own
# IO_TYPE.  Plain gowin_pack gives them the bank's LVDS25, which turned ADC bits
# 0, 1, 4 and 5 (bank 5, beside the HDMI clock lane) into LVDS receivers; see
# scripts/gowin_pack_io.py and CLAUDE.md.  A no-op for any other design.
GOWIN_PACK  := $(TOOL) python3 scripts/gowin_pack_io.py

# --- Step 1: AD9280 capture bring-up ---------------------------------------
PROBE_TOP         := adc_probe_top
PROBE_RTL         := src/adc_probe_top.v src/uart_tx.v src/rpll_108.v \
                     src/report_rom.v src/sync_lpf.v
PROBE_CONSTRAINTS := constraints/tangnano20k_adc_probe.cst
PROBE_NETLIST     := $(BUILD_DIR)/$(PROBE_TOP).json
PROBE_PNR         := $(BUILD_DIR)/$(PROBE_TOP)_pnr.json
PROBE_BITSTREAM   := $(BUILD_DIR)/$(PROBE_TOP).fs

SIM_SRC := $(PROBE_RTL) sim/gowin_prim_sim.v sim/adc_probe_tb.v

# --- Step 2a: HDMI output bring-up, independent of NTSC -------------------
HDMI_TOP         := top_hdmi_test
HDMI_RTL         := src/top_hdmi_test.v src/rpll_135.v src/rpll_371.v \
                    src/rpll_126.v \
                    src/video_timing.v src/hdmi_out.v src/tmds_encoder.v \
                    src/hdmi_status.v src/uart_tx.v
HDMI_CONSTRAINTS := constraints/tangnano20k_hdmi.cst
HDMI_NETLIST     := $(BUILD_DIR)/$(HDMI_TOP).json
HDMI_PNR         := $(BUILD_DIR)/$(HDMI_TOP)_pnr.json
HDMI_BITSTREAM   := $(BUILD_DIR)/$(HDMI_TOP).fs

.PHONY: sim-cordic sim-burst sim-capture sim-capture-weak all probe build ntsc ntsc-program ntsc-flash \
	hdmitest hdmitest-program hdmi720 hdmi720-program hdmi640 hdmi640-program sim sim-badphase program flash monitor pullup pullup-program pulldown pulldown-program \
	clampon clampon-program clampoff clampoff-program clampgated clampgated-program \
	autodump autodump-program dumpbig dumpbig-program barcap barcap-program barcap2 barcap2-program barcap3 barcap3-program barcap4 barcap4-program \
	clkhigh clkhigh-program clklow clklow-program clkslow clkslow-program \
	clkmid clkmid-program clkmid-clampon clkmid-clampon-program \
	check-tools clean

all: build

build: probe
probe: $(PROBE_BITSTREAM)

$(BUILD_STAMP):
	mkdir -p $(BUILD_DIR)
	@touch $@

$(PROBE_NETLIST): $(PROBE_RTL) | $(BUILD_STAMP)
	$(TOOL) yosys -p "read_verilog $(PROBE_RTL); synth_gowin -top $(PROBE_TOP) -json $@"

$(PROBE_PNR): $(PROBE_NETLIST) $(PROBE_CONSTRAINTS)
	$(TOOL) nextpnr-himbaechel \
		--json $(PROBE_NETLIST) \
		--write $@ \
		--device $(DEVICE) \
		--freq $(FREQ_MHZ) \
		--vopt family=$(FAMILY) \
		--vopt cst=$(PROBE_CONSTRAINTS)

$(PROBE_BITSTREAM): $(PROBE_PNR) scripts/gowin_pack_io.py
	$(GOWIN_PACK) -d $(FAMILY) -o $@ $<

# Diagnostic variant: identical RTL, but the ADC inputs get weak pull-ups.
# If the report then shows tog=00 min=255 max=255, the AD9280 is not driving
# the bus at all (unpowered or absent).  If it still shows 0, the ADC is
# actively driving zeros -- an analog/range problem, not a connection problem.
# Pull-down twin of the pull-up probe.  With the bus reading mostly ones, this
# is the test that matters: if the ones survive a pull-down they are really
# being driven by the AD9280; if they collapse to 0 the outputs are floating.
PULLDOWN_CST       := $(BUILD_DIR)/adc_probe_pulldown.cst
PULLDOWN_PNR       := $(BUILD_DIR)/$(PROBE_TOP)_pulldown_pnr.json
PULLDOWN_BITSTREAM := $(BUILD_DIR)/$(PROBE_TOP)_pulldown.fs

pulldown: $(PULLDOWN_BITSTREAM)

$(PULLDOWN_CST): $(PROBE_CONSTRAINTS) | $(BUILD_STAMP)
	sed -E '/^IO_PORT "adc_(d\[[0-7]\]|otr)"/ s/PULL_MODE=NONE/PULL_MODE=DOWN/' $< > $@

$(PULLDOWN_PNR): $(PROBE_NETLIST) $(PULLDOWN_CST)
	$(TOOL) nextpnr-himbaechel --json $(PROBE_NETLIST) --write $@ --device $(DEVICE) \
		--freq $(FREQ_MHZ) --vopt family=$(FAMILY) --vopt cst=$(PULLDOWN_CST)

$(PULLDOWN_BITSTREAM): $(PULLDOWN_PNR) scripts/gowin_pack_io.py
	$(GOWIN_PACK) -d $(FAMILY) -o $@ $<

pulldown-program: $(PULLDOWN_BITSTREAM)
	$(TOOL) openFPGALoader -b $(BOARD) $<

PULLUP_CST       := $(BUILD_DIR)/adc_probe_pullup.cst
PULLUP_PNR       := $(BUILD_DIR)/$(PROBE_TOP)_pullup_pnr.json
PULLUP_BITSTREAM := $(BUILD_DIR)/$(PROBE_TOP)_pullup.fs

pullup: $(PULLUP_BITSTREAM)

$(PULLUP_CST): $(PROBE_CONSTRAINTS) | $(BUILD_STAMP)
	sed -E '/^IO_PORT "adc_(d\[[0-7]\]|otr)"/ s/PULL_MODE=NONE/PULL_MODE=UP/' $< > $@

$(PULLUP_PNR): $(PROBE_NETLIST) $(PULLUP_CST)
	$(TOOL) nextpnr-himbaechel \
		--json $(PROBE_NETLIST) \
		--write $@ \
		--device $(DEVICE) \
		--freq $(FREQ_MHZ) \
		--vopt family=$(FAMILY) \
		--vopt cst=$(PULLUP_CST)

$(PULLUP_BITSTREAM): $(PULLUP_PNR) scripts/gowin_pack_io.py
	$(GOWIN_PACK) -d $(FAMILY) -o $@ $<

pullup-program: $(PULLUP_BITSTREAM)
	$(TOOL) openFPGALoader -b $(BOARD) $<

# Diagnostic variants of the same design: identical RTL, one parameter changed.
# clampon forces AIN to CLAMPIN and needs no video source; the clk* variants
# make adc_clk measurable with a plain multimeter.
define param_variant
$(BUILD_DIR)/$(PROBE_TOP)_$(1).json: $(PROBE_RTL) | $(BUILD_STAMP)
	$(TOOL) yosys -p "read_verilog $(PROBE_RTL); chparam -set $(2) $(3) $(4) $(PROBE_TOP); synth_gowin -top $(PROBE_TOP) -json $$@"

$(BUILD_DIR)/$(PROBE_TOP)_$(1)_pnr.json: $(BUILD_DIR)/$(PROBE_TOP)_$(1).json $(PROBE_CONSTRAINTS)
	$(TOOL) nextpnr-himbaechel --json $$< --write $$@ --device $(DEVICE) \
		--freq $(FREQ_MHZ) --vopt family=$(FAMILY) --vopt cst=$(PROBE_CONSTRAINTS)

$(BUILD_DIR)/$(PROBE_TOP)_$(1).fs: $(BUILD_DIR)/$(PROBE_TOP)_$(1)_pnr.json scripts/gowin_pack_io.py
	$(GOWIN_PACK) -d $(FAMILY) -o $$@ $$<

$(1): $(BUILD_DIR)/$(PROBE_TOP)_$(1).fs
$(1)-program: $(BUILD_DIR)/$(PROBE_TOP)_$(1).fs
	$(TOOL) openFPGALoader -b $(BOARD) $$<

# Writing to flash instead of SRAM is the way to work around the UART dying
# after openFPGALoader runs: flash once, then every replug power-cycles the
# board, loads the design automatically, and hands back a fresh serial port
# without libusb ever touching the device again.
$(1)-flash: $(BUILD_DIR)/$(PROBE_TOP)_$(1).fs
	$(TOOL) openFPGALoader -b $(BOARD) -f $$<
endef

$(eval $(call param_variant,clampon,CLAMP_MODE,1,))
$(eval $(call param_variant,clampgated,CLAMP_MODE,0,))
$(eval $(call param_variant,autodump,AUTO_DUMP,1,))
# ~19 consecutive lines (32768 samples, 15 BSRAM blocks), dumped automatically.
# Enough real video to develop the colour decoder against offline instead of
# guessing at it on hardware.
$(eval $(call param_variant,dumpbig,AUTO_DUMP,1,-set DUMP_LEN 32768))
# Auto-dumping with the sync-locked clamp engaged.  A bright source needs the
# clamp: the AIN node has no DC path of its own, so without it the level
# floats with average picture level and the sync tip collapses.
$(eval $(call param_variant,barcap,AUTO_DUMP,1,-set CLAMP_MODE 0))
# Free-running clamp: the one that can actually acquire a bright source.
$(eval $(call param_variant,barcap2,AUTO_DUMP,1,-set CLAMP_MODE 3))
# 4096 samples is 2.4 lines, so a whole line fits wherever the sync edge that
# triggered the dump actually lands.  At 2048 (1.19 lines) a late sync leaves
# no room for the active video and the capture is wasted.
$(eval $(call param_variant,barcap3,AUTO_DUMP,1,-set CLAMP_MODE 3 -set DUMP_LEN 4096))
# Clamp off, matching what the video path does while acquiring.  For measuring
# what the sync detector is actually up against rather than guessing at it.
# Clamp off, matching what the video path does while acquiring.  2048 samples
# every 32 s: the bridge survives a 13 kB burst where it wedges on a 27 kB one,
# and 1.2 lines is plenty when the bars are vertical.
$(eval $(call param_variant,barcap4,AUTO_DUMP,1,-set CLAMP_MODE 2 -set DUMP_LEN 2048 -set AUTO_DUMP_EVERY 32))
$(eval $(call param_variant,clampoff,CLAMP_MODE,2,))
$(eval $(call param_variant,clkhigh,ADC_CLK_MODE,1,))
$(eval $(call param_variant,clklow,ADC_CLK_MODE,2,))
$(eval $(call param_variant,clkslow,ADC_CLK_MODE,3,))
# ~1.7 MHz: above any pipelined-ADC minimum rate, below any SI concern.
$(eval $(call param_variant,clkmid,ADC_CLK_MODE,3,-set SLOW_HALF_PERIOD 32))
# Definitive combination: AIN pinned at CLAMPIN (a known-good in-range level)
# AND a 1.7 MHz clock that is above any minimum conversion rate and below any
# signal-integrity doubt.  If the bus is still frozen here, nothing outside the
# AD9280 explains it.
$(eval $(call param_variant,clkmid-clampon,ADC_CLK_MODE,3,-set SLOW_HALF_PERIOD 32 -set CLAMP_MODE 1))

# Feeds a synthetic NTSC composite signal through a behavioural AD9280 and
# checks that the design measures a 1716-sample line period.
sim: | $(BUILD_STAMP)
	$(TOOL) iverilog -g2012 -s adc_probe_tb -o $(BUILD_DIR)/adc_probe_tb $(SIM_SRC)
	$(TOOL) vvp $(BUILD_DIR)/adc_probe_tb

# Negative control: sampling phase 1 lands in the AD9280 output switching
# window, and the bench asserts that the design does NOT report a valid line.
# Replay a real capture through ntsc_capture.  WEAK=1 uses the flattened-sync
# stimulus that stands in for the M5 generator; the parameters can be swept
# from the command line, e.g.
#   make sim-capture SIMARGS="-Pntsc_capture_tb.Q_QUALIFY=110"
SIMARGS ?=
CAPTURE_SIM_RTL := src/ntsc_capture.v src/adc_front.v src/sync_lpf.v src/burst_nco.v src/cordic_atan.v src/chroma_sincos.v sim/gowin_prim_sim.v
sim-capture: | $(BUILD_STAMP)
	$(TOOL) iverilog -g2012 -s ntsc_capture_tb -o build/ntsc_capture_tb $(SIMARGS) \
		$(CAPTURE_SIM_RTL) sim/ntsc_capture_tb.v
	$(TOOL) vvp build/ntsc_capture_tb

# Burst-locked NCO against a synthetic burst of known phase.  Synthetic on
# purpose: the point is to prove the loop converges to an angle we chose, and a
# recording does not come with the answer.
sim-cordic: | $(BUILD_STAMP)
	$(TOOL) iverilog -g2012 -s cordic_atan_tb -o build/cordic_atan_tb \
		src/cordic_atan.v sim/cordic_atan_tb.v
	$(TOOL) vvp build/cordic_atan_tb

sim-burst: | $(BUILD_STAMP)
	$(TOOL) iverilog -g2012 -s burst_nco_tb -o build/burst_nco_tb $(SIMARGS) \
		-Pburst_nco_tb.LINES=2000 src/burst_nco.v src/cordic_atan.v src/chroma_sincos.v sim/burst_nco_tb.v
	$(TOOL) vvp build/burst_nco_tb

sim-capture-weak: | $(BUILD_STAMP)
	$(TOOL) iverilog -g2012 -s ntsc_capture_tb -Pntsc_capture_tb.WEAK=1 $(SIMARGS) \
		-o $(BUILD_DIR)/ntsc_capture_weak_tb $(CAPTURE_SIM_RTL) sim/ntsc_capture_tb.v
	$(TOOL) vvp $(BUILD_DIR)/ntsc_capture_weak_tb

sim-badphase: | $(BUILD_STAMP)
	$(TOOL) iverilog -g2012 -s adc_probe_tb -Padc_probe_tb.PHASE=1 \
		-o $(BUILD_DIR)/adc_probe_tb_p1 $(SIM_SRC)
	$(TOOL) vvp $(BUILD_DIR)/adc_probe_tb_p1

# Volatile: fastest development loop; the design disappears at power-off.
program: $(PROBE_BITSTREAM)
	$(TOOL) openFPGALoader -b $(BOARD) $<

# Persistent: write the design to the board's flash memory.
flash: $(PROBE_BITSTREAM)
	$(TOOL) openFPGALoader -b $(BOARD) -f $<

# The board exposes two serial interfaces; the UART is the higher-numbered one.
# Override with: make monitor PORT=/dev/cu.usbserial-XXXX
# Do not replace this with stty+cat: on macOS the port reverts to 9600 baud as
# soon as stty closes it, and the report comes out as garbage.
PORT ?=

monitor:
	python3 scripts/monitor.py $(PORT)

hdmitest: $(HDMI_BITSTREAM)

$(HDMI_NETLIST): $(HDMI_RTL) | $(BUILD_STAMP)
	$(TOOL) yosys -p "read_verilog $(HDMI_RTL); synth_gowin -top $(HDMI_TOP) -json $@"

$(HDMI_PNR): $(HDMI_NETLIST) $(HDMI_CONSTRAINTS)
	$(TOOL) nextpnr-himbaechel --json $(HDMI_NETLIST) --write $@ --device $(DEVICE) \
		--freq 27 --vopt family=$(FAMILY) --vopt cst=$(HDMI_CONSTRAINTS)

$(HDMI_BITSTREAM): $(HDMI_PNR) scripts/gowin_pack_io.py
	$(GOWIN_PACK) -d $(FAMILY) -o $@ $<

hdmitest-program: $(HDMI_BITSTREAM)
	$(TOOL) openFPGALoader -b $(BOARD) $<

# Same design at 1280x720p60, which every sink accepts.  If this displays and
# hdmitest does not, the FPGA is fine and the sink is refusing 480p.
HDMI720_NETLIST   := $(BUILD_DIR)/$(HDMI_TOP)_720.json
HDMI720_PNR       := $(BUILD_DIR)/$(HDMI_TOP)_720_pnr.json
HDMI720_BITSTREAM := $(BUILD_DIR)/$(HDMI_TOP)_720.fs

hdmi720: $(HDMI720_BITSTREAM)

$(HDMI720_NETLIST): $(HDMI_RTL) | $(BUILD_STAMP)
	$(TOOL) yosys -p "read_verilog $(HDMI_RTL); chparam -set MODE 1 $(HDMI_TOP); synth_gowin -top $(HDMI_TOP) -json $@"

$(HDMI720_PNR): $(HDMI720_NETLIST) $(HDMI_CONSTRAINTS)
	$(TOOL) nextpnr-himbaechel --json $< --write $@ --device $(DEVICE) \
		--freq 75 --vopt family=$(FAMILY) --vopt cst=$(HDMI_CONSTRAINTS)

$(HDMI720_BITSTREAM): $(HDMI720_PNR) scripts/gowin_pack_io.py
	$(GOWIN_PACK) -d $(FAMILY) -o $@ $<

hdmi720-program: $(HDMI720_BITSTREAM)
	$(TOOL) openFPGALoader -b $(BOARD) $<

# 640x480p60 test pattern.  Capture devices that refuse 720x480 usually take
# this, and it keeps the 525-line 60 Hz structure the NTSC path relies on.
HDMI640_NETLIST   := $(BUILD_DIR)/$(HDMI_TOP)_640.json
HDMI640_PNR       := $(BUILD_DIR)/$(HDMI_TOP)_640_pnr.json
HDMI640_BITSTREAM := $(BUILD_DIR)/$(HDMI_TOP)_640.fs

hdmi640: $(HDMI640_BITSTREAM)

$(HDMI640_NETLIST): $(HDMI_RTL) | $(BUILD_STAMP)
	$(TOOL) yosys -p "read_verilog $(HDMI_RTL); chparam -set MODE 2 $(HDMI_TOP); synth_gowin -top $(HDMI_TOP) -json $@"

$(HDMI640_PNR): $(HDMI640_NETLIST) $(HDMI_CONSTRAINTS)
	$(TOOL) nextpnr-himbaechel --json $< --write $@ --device $(DEVICE) \
		--freq 27 --vopt family=$(FAMILY) --vopt cst=$(HDMI_CONSTRAINTS)

$(HDMI640_BITSTREAM): $(HDMI640_PNR) scripts/gowin_pack_io.py
	$(GOWIN_PACK) -d $(FAMILY) -o $@ $<

hdmi640-program: $(HDMI640_BITSTREAM)
	$(TOOL) openFPGALoader -b $(BOARD) $<

# --- NTSC-J in, colour 640x480p HDMI out ---------------------------------
NTSC_TOP       := top_ntsc_hdmi
NTSC_RTL       := src/top_ntsc_hdmi.v src/ntsc_capture.v src/adc_front.v src/line_buffer.v \
                  src/video_line_store.v src/chroma_sincos.v \
                  src/sync_lpf.v src/burst_nco.v src/cordic_atan.v \
                  src/video_timing.v src/hdmi_out.v src/tmds_encoder.v \
                  src/ntsc_status.v src/uart_tx.v src/rpll_126.v
# Built by concatenation so the pin numbers keep a single source: the ADC,
# clock, LED, button and UART pins come from the probe constraints and the
# TMDS pins from the HDMI ones.
NTSC_CST       := $(BUILD_DIR)/tangnano20k_ntsc_hdmi.cst
NTSC_NETLIST   := $(BUILD_DIR)/$(NTSC_TOP).json
NTSC_PNR       := $(BUILD_DIR)/$(NTSC_TOP)_pnr.json
NTSC_BITSTREAM := $(BUILD_DIR)/$(NTSC_TOP).fs

ntsc: $(NTSC_BITSTREAM)

$(NTSC_CST): $(PROBE_CONSTRAINTS) $(HDMI_CONSTRAINTS) | $(BUILD_STAMP)
	cat $(PROBE_CONSTRAINTS) > $@
	grep -E '"tmds_' $(HDMI_CONSTRAINTS) >> $@

# -nodsp: the luma gain multiply otherwise lands in a MULT9X9 that Apicula
# cannot pack (KeyError 'IRBY_IREG0BL_0').  It is a multiply by a constant, so
# LUT logic is the right implementation anyway.
# -noalu: no ALU carry cells at all.  Designs with a few thousand of them
# compute wrongly on this part depending on placement (Apicula #514, open), and
# this one had about 4300.  LUT adders are slower, which is why the decoder
# moved from 126 MHz to the 25.2 MHz pixel clock: at one sample per clock it
# has five times the time per operation.
NTSC_SYNTH := synth_gowin -nodsp -noalu
$(NTSC_NETLIST): $(NTSC_RTL) | $(BUILD_STAMP)
	$(TOOL) yosys -p "read_verilog $(NTSC_RTL); $(NTSC_SYNTH) -top $(NTSC_TOP) -json $@"

# The SDC constrains the 126 MHz capture domain and 25.2 MHz pixel domain.
# Placement affects margin; always require the final routed timing check.
# A different seed requires rebuilding the PNR target (make -B ntsc).
# Any seed works: the decoder has no ALU cells and its converter read is
# calibrated.  Seeds 1..8 measured 2026-09-26 on one M5 boot: every one read
# whole-line hue rotation 0.5 deg rms and identical bar hues, calibration
# settled once; seeds 3, 5 and 8 reloaded read the same.  The 126 MHz design
# spread 0.7..49 deg over eight seeds (CLAUDE.md).  Seed 3 is the one make
# ntsc reproduces byte for byte.  Load a build more than once before crediting
# or blaming a seed.
NTSC_SEED ?= 3
$(NTSC_PNR): $(NTSC_NETLIST) $(NTSC_CST) constraints/tangnano20k_ntsc.sdc
	$(TOOL) nextpnr-himbaechel --json $(NTSC_NETLIST) --write $@ --device $(DEVICE) \
		--freq 27 --sdc constraints/tangnano20k_ntsc.sdc --seed $(NTSC_SEED) \
		--vopt family=$(FAMILY) --vopt cst=$(NTSC_CST)

$(NTSC_BITSTREAM): $(NTSC_PNR) scripts/gowin_pack_io.py
	$(GOWIN_PACK) -d $(FAMILY) -o $@ $<

ntsc-program: $(NTSC_BITSTREAM)
	$(TOOL) openFPGALoader -b $(BOARD) $<

# Build, load to SRAM, and read the report in one go.
#
# Prefer this over the flash targets.  Flashing needs a power cycle before the
# FPGA picks up the new bitstream, so it makes a physical replug mandatory for
# every single test; SRAM takes effect immediately.  The flash route was
# adopted to dodge the UART wedging after openFPGALoader runs, which it does
# not actually avoid -- the replug was doing that, not the flash.
ntsc-run: $(NTSC_BITSTREAM)
	$(TOOL) openFPGALoader -b $(BOARD) $<
	@python3 scripts/read_raw.py "$$(python3 scripts/tang_port.py)" 12 | grep -a '^NTSC' | tail -4

ntsc-flash: $(NTSC_BITSTREAM)
	$(TOOL) openFPGALoader -b $(BOARD) -f $<

# The M5 compatibility geometry, for a source with no sync step.  It was the
# default until the respun board showed this source does emit sync; measured
# back to back at seed 3 it drops 47.8% of rows and carries colour on 0 frames
# of 120, against 0.43% and 120 of 120 for the standard set.  Keep it: it is
# the only thing that works on a source whose sync tip and blanking are the
# same level, and this project has seen one.
# Separate filenames so switching modes never reuses a stale file.
NTSC_LEGACY_NETLIST := $(BUILD_DIR)/$(NTSC_TOP)_legacy.json
NTSC_LEGACY_PNR := $(BUILD_DIR)/$(NTSC_TOP)_legacy_pnr.json
NTSC_LEGACY_BITSTREAM := $(BUILD_DIR)/$(NTSC_TOP)_legacy.fs
.PHONY: ntsc-legacy ntsc-legacy-program
ntsc-legacy: $(NTSC_LEGACY_BITSTREAM)

$(NTSC_LEGACY_NETLIST): $(NTSC_RTL) | $(BUILD_STAMP)
	$(TOOL) yosys -p "read_verilog $(NTSC_RTL); chparam -set LEGACY_TIMING 1 $(NTSC_TOP); $(NTSC_SYNTH) -top $(NTSC_TOP) -json $@"

$(NTSC_LEGACY_PNR): $(NTSC_LEGACY_NETLIST) $(NTSC_CST) constraints/tangnano20k_ntsc.sdc
	$(TOOL) nextpnr-himbaechel --json $< --write $@ --device $(DEVICE) \
		--freq 27 --sdc constraints/tangnano20k_ntsc.sdc --seed $(NTSC_SEED) \
		--vopt family=$(FAMILY) --vopt cst=$(NTSC_CST)

$(NTSC_LEGACY_BITSTREAM): $(NTSC_LEGACY_PNR) scripts/gowin_pack_io.py
	$(GOWIN_PACK) -d $(FAMILY) -o $@ $<

ntsc-legacy-program: $(NTSC_LEGACY_BITSTREAM)
	$(TOOL) openFPGALoader -b $(BOARD) $<

# The converter interface's per-bit diagnostic: calibration off, rotation
# stepping 0..9 every 0.67 s, and each bit's rising/falling-read disagreement
# in the strip.  Read with scripts/adc_diag.py, which records a few seconds of
# the strip as video.  This is how the bottom-bank bits were found.
NTSC_ADCDIAG_NETLIST := $(BUILD_DIR)/$(NTSC_TOP)_adcdiag.json
NTSC_ADCDIAG_PNR := $(BUILD_DIR)/$(NTSC_TOP)_adcdiag_pnr.json
NTSC_ADCDIAG_BITSTREAM := $(BUILD_DIR)/$(NTSC_TOP)_adcdiag.fs
.PHONY: ntsc-adcdiag ntsc-adcdiag-program
ntsc-adcdiag: $(NTSC_ADCDIAG_BITSTREAM)

$(NTSC_ADCDIAG_NETLIST): $(NTSC_RTL) | $(BUILD_STAMP)
	$(TOOL) yosys -p "read_verilog $(NTSC_RTL); chparam -set ADC_DIAG 1 $(NTSC_TOP); $(NTSC_SYNTH) -top $(NTSC_TOP) -json $@"

$(NTSC_ADCDIAG_PNR): $(NTSC_ADCDIAG_NETLIST) $(NTSC_CST) constraints/tangnano20k_ntsc.sdc
	$(TOOL) nextpnr-himbaechel --json $< --write $@ --device $(DEVICE) \
		--freq 27 --sdc constraints/tangnano20k_ntsc.sdc --seed $(NTSC_SEED) \
		--vopt family=$(FAMILY) --vopt cst=$(NTSC_CST)

$(NTSC_ADCDIAG_BITSTREAM): $(NTSC_ADCDIAG_PNR) scripts/gowin_pack_io.py
	$(GOWIN_PACK) -d $(FAMILY) -o $@ $<

ntsc-adcdiag-program: $(NTSC_ADCDIAG_BITSTREAM)
	$(TOOL) openFPGALoader -b $(BOARD) $<

# Start in the existing HDMI oscilloscope view, without relying on UART.
NTSC_SCOPE_PHASE ?= 2
NTSC_SCOPE_RAMP ?= 0
# Free-running acquisition must not depend on the sync path under diagnosis.
# Include the switch in filenames so a changed option cannot reuse old logic.
NTSC_SCOPE_FREERUN ?= 0
NTSC_SCOPE_NETLIST := $(BUILD_DIR)/$(NTSC_TOP)_scope_p$(NTSC_SCOPE_PHASE)r$(NTSC_SCOPE_RAMP)f$(NTSC_SCOPE_FREERUN).json
NTSC_SCOPE_PNR := $(BUILD_DIR)/$(NTSC_TOP)_scope_p$(NTSC_SCOPE_PHASE)r$(NTSC_SCOPE_RAMP)f$(NTSC_SCOPE_FREERUN)_pnr.json
NTSC_SCOPE_BITSTREAM := $(BUILD_DIR)/$(NTSC_TOP)_scope_p$(NTSC_SCOPE_PHASE)r$(NTSC_SCOPE_RAMP)f$(NTSC_SCOPE_FREERUN).fs
.PHONY: ntsc-scope ntsc-scope-program
ntsc-scope: $(NTSC_SCOPE_BITSTREAM)

$(NTSC_SCOPE_NETLIST): $(NTSC_RTL) | $(BUILD_STAMP)
	$(TOOL) yosys -p "read_verilog $(NTSC_RTL); chparam -set SCOPE_ONLY 1 -set SCOPE_FULL_RANGE 1 -set DEFAULT_PHASE $(NTSC_SCOPE_PHASE) -set SCOPE_TEST_RAMP $(NTSC_SCOPE_RAMP) -set SCOPE_FREERUN $(NTSC_SCOPE_FREERUN) $(NTSC_TOP); $(NTSC_SYNTH) -top $(NTSC_TOP) -json $@"

$(NTSC_SCOPE_PNR): $(NTSC_SCOPE_NETLIST) $(NTSC_CST) constraints/tangnano20k_ntsc.sdc
	$(TOOL) nextpnr-himbaechel --json $< --write $@ --device $(DEVICE) \
		--freq 27 --sdc constraints/tangnano20k_ntsc.sdc --seed $(NTSC_SEED) \
		--vopt family=$(FAMILY) --vopt cst=$(NTSC_CST)

$(NTSC_SCOPE_BITSTREAM): $(NTSC_SCOPE_PNR) scripts/gowin_pack_io.py
	$(GOWIN_PACK) -d $(FAMILY) -o $@ $<

ntsc-scope-program: $(NTSC_SCOPE_BITSTREAM)
	$(TOOL) openFPGALoader -b $(BOARD) $<

# Record 32768 consecutive ADC samples once and show them as grey cells for
# scripts/tape_decode.py -- a full-rate recording of the real source, for
# replay through the decoder in simulation, with no serial link involved.
NTSC_TAPE_NETLIST := $(BUILD_DIR)/$(NTSC_TOP)_tape.json
NTSC_TAPE_PNR := $(BUILD_DIR)/$(NTSC_TOP)_tape_pnr.json
NTSC_TAPE_BITSTREAM := $(BUILD_DIR)/$(NTSC_TOP)_tape.fs
.PHONY: ntsc-tape ntsc-tape-program
ntsc-tape: $(NTSC_TAPE_BITSTREAM)

$(NTSC_TAPE_NETLIST): $(NTSC_RTL) | $(BUILD_STAMP)
	$(TOOL) yosys -p "read_verilog $(NTSC_RTL); chparam -set TAPE 1 $(NTSC_TOP); $(NTSC_SYNTH) -top $(NTSC_TOP) -json $@"

$(NTSC_TAPE_PNR): $(NTSC_TAPE_NETLIST) $(NTSC_CST) constraints/tangnano20k_ntsc.sdc
	$(TOOL) nextpnr-himbaechel --json $< --write $@ --device $(DEVICE) \
		--freq 27 --sdc constraints/tangnano20k_ntsc.sdc --seed $(NTSC_SEED) \
		--vopt family=$(FAMILY) --vopt cst=$(NTSC_CST)

$(NTSC_TAPE_BITSTREAM): $(NTSC_TAPE_PNR) scripts/gowin_pack_io.py
	$(GOWIN_PACK) -d $(FAMILY) -o $@ $<

ntsc-tape-program: $(NTSC_TAPE_BITSTREAM)
	$(TOOL) openFPGALoader -b $(BOARD) $<

check-tools:
	@$(TOOL) yosys -V >/dev/null
	@$(TOOL) nextpnr-himbaechel --version >/dev/null
	@$(TOOL) gowin_pack -h >/dev/null
	@$(TOOL) iverilog -V >/dev/null 2>&1
	@$(TOOL) openFPGALoader --version >/dev/null
	@echo "All required tools are available."

.PHONY: test sim-reference sim-tracking sim-video sim-video-weak sim-video-mono sim-video-late sim-hdmi test-quality
test: sim sim-badphase sim-cordic sim-burst sim-burst-products sim-reference sim-tracking sim-capture sim-capture-weak sim-video sim-video-weak sim-video-mono sim-video-late sim-hdmi sim-scope-header sim-scope-freerun sim-tape sim-adc-front check-signed test-quality

.PHONY: sim-burst-products
sim-burst-products: | $(BUILD_STAMP)
	@for sine in 0 1; do \
		$(TOOL) iverilog -g2012 -s burst_products_tb -Pburst_products_tb.SINE_REF=$$sine \
			-o $(BUILD_DIR)/burst_products_tb src/burst_nco.v src/cordic_atan.v \
			src/chroma_sincos.v sim/burst_products_tb.v && \
		$(TOOL) vvp $(BUILD_DIR)/burst_products_tb || exit $$?; \
	done

.PHONY: check-signed
check-signed:
	python3 scripts/check_signed_compare.py

.PHONY: sim-tape
sim-tape: | $(BUILD_STAMP)
	$(TOOL) iverilog -g2012 -s tape_tb -o $(BUILD_DIR)/tape_tb \
		$(NTSC_RTL) sim/gowin_prim_sim.v sim/tape_tb.v
	$(TOOL) vvp $(BUILD_DIR)/tape_tb
	python3 scripts/tape_decode.py $(BUILD_DIR)/tape_tb_decoded.hex $(BUILD_DIR)/tape_tb.ppm
	cmp $(BUILD_DIR)/tape_tb_decoded.hex $(BUILD_DIR)/tape_tb_mem.hex

.PHONY: sim-adc-front
# Calibration across a whole conversion period of output delay, a switching
# window a third of a period wide, drift in both directions (small enough to
# ride out, and large enough to force a re-sweep), the production window
# length, the negative control -- at 20 ns, rotation 4 puts the read inside
# the switching window and must not come back clean -- and bits 0, 1, 4, 5
# glitching as on the board, where the calibration must settle on one sweep.
# Fields: TOD SWITCH AUTO rotation EXPECT_BAD DRIFT WIN_W [NOISY]
sim-adc-front: | $(BUILD_STAMP)
	@for cfg in "0 5000 1 0 0 0 12" "8000 5000 1 0 0 0 12" "16000 5000 1 0 0 0 12" \
	            "24000 5000 1 0 0 0 12" "32000 5000 1 0 0 0 12" "38000 5000 1 0 0 0 12" \
	            "20000 14000 1 0 0 0 12" "20000 5000 1 0 0 6000 12" "20000 5000 1 0 0 -14000 12" \
	            "28000 5000 1 0 0 0 14" "20000 5000 0 4 1 0 12" \
	            "12000 5000 1 0 0 0 12 1" "30000 5000 1 0 0 0 12 1"; do \
		set -- $$cfg; \
		$(TOOL) iverilog -g2012 -s adc_front_tb -Padc_front_tb.TOD=$$1 -Padc_front_tb.SWITCH=$$2 \
			-Padc_front_tb.AUTO=$$3 -Padc_front_tb.MANUAL=$$4 -Padc_front_tb.EXPECT_BAD=$$5 \
			-Padc_front_tb.DRIFT=$$6 -Padc_front_tb.WIN_W=$$7 -Padc_front_tb.NOISY=$${8:-0} \
			-o $(BUILD_DIR)/adc_front_tb src/adc_front.v sim/gowin_prim_sim.v sim/adc_front_tb.v || exit $$?; \
		$(TOOL) vvp -n $(BUILD_DIR)/adc_front_tb > $(BUILD_DIR)/adc_front_tb.log; rc=$$?; \
		grep -E '^adc_front|FATAL' $(BUILD_DIR)/adc_front_tb.log; test $$rc -eq 0 || exit 1; \
	done

.PHONY: sim-scope-freerun
sim-scope-freerun: | $(BUILD_STAMP)
	$(TOOL) iverilog -g2012 -s scope_freerun_tb -o $(BUILD_DIR)/scope_freerun_tb \
		$(CAPTURE_SIM_RTL) sim/scope_freerun_tb.v
	$(TOOL) vvp $(BUILD_DIR)/scope_freerun_tb

.PHONY: sim-scope-header
sim-scope-header: | $(BUILD_STAMP)
	$(TOOL) iverilog -g2012 -s scope_identity_tb -o $(BUILD_DIR)/scope_identity_tb \
		$(NTSC_RTL) sim/gowin_prim_sim.v sim/scope_identity_tb.v
	$(TOOL) vvp $(BUILD_DIR)/scope_identity_tb

test-quality:
	python3 scripts/test_video_quality.py
	python3 scripts/test_scope_trace.py
	python3 scripts/test_build_safety.py
	python3 scripts/test_live_capture.py
	python3 scripts/test_scope_pull_variant.py

# TRAP=1 knocks the learned step half a turn, or a third, out mid-run -- the
# states some acquisitions on the board fell into; the tracker must be back
# within 14 lines.
sim-tracking: | $(BUILD_STAMP)
	@for trap in "0 32'h80000000" "1 32'h80000000" "1 32'h55555555" "1 32'hAAAAAAAB"; do \
		set -- $$trap; \
		$(TOOL) iverilog -g2012 -s burst_tracking_tb -Pburst_tracking_tb.TRAP=$$1 \
			-Pburst_tracking_tb.TRAP_ADD=$$2 \
			-o $(BUILD_DIR)/burst_tracking_tb \
			src/burst_nco.v src/cordic_atan.v src/chroma_sincos.v sim/burst_tracking_tb.v || exit $$?; \
		$(TOOL) vvp $(BUILD_DIR)/burst_tracking_tb || exit $$?; \
	done

sim-reference: | $(BUILD_STAMP)
	@for args in "0 0" "0 -100" "1 100"; do \
		set -- $$args; \
		$(TOOL) iverilog -g2012 -s burst_reference_tb \
			-Pburst_reference_tb.HALFWAVE=$$1 -Pburst_reference_tb.PPM=$$2 \
			-o $(BUILD_DIR)/burst_reference_tb src/burst_nco.v src/cordic_atan.v \
			src/chroma_sincos.v sim/burst_reference_tb.v && \
		$(TOOL) vvp $(BUILD_DIR)/burst_reference_tb || exit $$?; \
	done

sim-video: | $(BUILD_STAMP)
	$(TOOL) iverilog -g2012 -s ntsc_video_tb -o $(BUILD_DIR)/ntsc_video_tb $(CAPTURE_SIM_RTL) sim/ntsc_video_tb.v
	$(TOOL) vvp $(BUILD_DIR)/ntsc_video_tb

sim-video-weak: | $(BUILD_STAMP)
	$(TOOL) iverilog -g2012 -s ntsc_video_tb -Pntsc_video_tb.SYNC_DEPTH=8 -Pntsc_video_tb.FIELDS=1 \
		-o $(BUILD_DIR)/ntsc_video_weak_tb $(CAPTURE_SIM_RTL) sim/ntsc_video_tb.v
	$(TOOL) vvp $(BUILD_DIR)/ntsc_video_weak_tb

sim-video-mono: | $(BUILD_STAMP)
	$(TOOL) iverilog -g2012 -s ntsc_video_tb -Pntsc_video_tb.MONO=1 -Pntsc_video_tb.FIELDS=1 \
		-o $(BUILD_DIR)/ntsc_video_mono_tb $(CAPTURE_SIM_RTL) sim/ntsc_video_tb.v
	$(TOOL) vvp $(BUILD_DIR)/ntsc_video_mono_tb

sim-video-late: | $(BUILD_STAMP)
	$(TOOL) iverilog -g2012 -s ntsc_video_tb -Pntsc_video_tb.HSHIFT=24 -Pntsc_video_tb.FIELDS=1 \
		-o $(BUILD_DIR)/ntsc_video_late_tb $(CAPTURE_SIM_RTL) sim/ntsc_video_tb.v
	$(TOOL) vvp $(BUILD_DIR)/ntsc_video_late_tb

sim-hdmi: | $(BUILD_STAMP)
	$(TOOL) iverilog -g2012 -s tmds_encoder_tb -o $(BUILD_DIR)/tmds_encoder_tb src/tmds_encoder.v sim/tmds_encoder_tb.v
	$(TOOL) vvp $(BUILD_DIR)/tmds_encoder_tb
	$(TOOL) iverilog -g2012 -s video_line_store_tb -o $(BUILD_DIR)/video_line_store_tb src/video_line_store.v sim/video_line_store_tb.v
	$(TOOL) vvp $(BUILD_DIR)/video_line_store_tb
	$(TOOL) iverilog -g2012 -s hdmi_pipeline_tb -o $(BUILD_DIR)/hdmi_pipeline_tb $(NTSC_RTL) sim/gowin_prim_sim.v sim/hdmi_pipeline_tb.v
	$(TOOL) vvp $(BUILD_DIR)/hdmi_pipeline_tb

clean:
	rm -rf $(BUILD_DIR)
