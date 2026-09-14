`default_nettype none

// ---------------------------------------------------------------------------
// Step 1 bring-up: prove the AD9280 capture path on the Tang Nano 20K.
//
// The question this design answers is not "does the bus wiggle" but "are we
// sampling a real NTSC signal correctly".  The decisive measurement is the
// line period: at a 27 MHz sample rate one NTSC line (15734.264 Hz) is
//
//     27e6 / 15734.264 = 1716.05 samples
//
// so a stable "ln=1716" in the report means the ADC clock, the data bus order
// and the sampling phase are all right.  Nothing else proves that at once.
//
// Outputs, once per window (1 s by default) on the onboard USB serial at
// 115200 8N1:
//
//   ADC ph=2 tog=255 min=79 max=205 thr=94 ln=1716 lmin=1716 lmax=1717
//       ok=15720 lns=15734 vs=60 otr=0
//
//   ph    sampling phase, 0..3 = 0/9.3/18.5/27.8 ns after the adc_clk edge
//   tog   bitwise OR of every bit that changed during the window.  255 means
//         all eight data lines are alive; a missing bit names a dead trace.
//   min   lowest code seen  -> sync tip level after clamping
//   max   highest code seen -> peak white
//   thr   sync slicing threshold actually used this window
//   ln    most recent line period in samples (want 1716)
//   lmin/lmax  spread of accepted line periods (want 1716..1717)
//   ok    accepted periods within 1700..1732
//   lns   all accepted periods (want ~15734 for a 1 s window)
//   vs    vertical sync pulses (want ~60)
//   otr   samples where the AD9280 flagged over-range (want 0)
//
// Buttons: S2 (pin 87) steps the sampling phase, S1 (pin 88) dumps 2048 raw
// consecutive samples as hex starting at a sync edge -- the visual check for
// data bus bit order.
// ---------------------------------------------------------------------------
module adc_probe_top #(
    // 27 MHz sample rate -> one window is one second.
    parameter integer SAMPLES_PER_WINDOW = 27_000_000,
    // 108 MHz / 115200 baud = 937.5; 937 is 0.05% fast, well inside tolerance.
    parameter integer CLKS_PER_BIT       = 937,
    parameter integer DEBOUNCE_CYCLES    = 108_000,   // ~1 ms at 108 MHz
    parameter integer DUMP_LEN           = 2048,      // ~1.19 NTSC lines
    parameter [1:0]   DEFAULT_PHASE      = 2'd2,      // ~18.5 ns after adc_clk
    // AD9280 CLAMP is active high on this board (10k pulldown R14 holds it off
    // whenever the FPGA is not driving).
    parameter         CLAMP_ACTIVE_HIGH  = 1'b1,
    // Default is 2 (off).  On this board the analog clamp does more harm than
    // good: C2 is 1 uF, far larger than the AD9280 clamp amplifier is meant to
    // drive, so every pulse leaves a transient that outlasts the line and
    // corrupts the next sync edge.  Measured, on a live NTSC source:
    //   clamp off          -> ok = lns = 15734, vs = 60, ln = 1716   (perfect)
    //   clamp gated on lock-> ok/lns ~ 72%, lock oscillates, vs erratic
    // The input self-biases into the converter's range without it, and DC
    // restoration is better done digitally downstream: the sync tip is measured
    // every line anyway, so the decoder can subtract it as the black reference.
    // Mode 0 is kept for experimenting (`make clampgated-program`).
    //
    // 0 = pulse once per line inside the sync tip, once sync is locked
    // 1 = hold the clamp on.  AIN is then forced to CLAMPIN, so the codes must
    //     settle at whatever CLAMPIN corresponds to.  If they stay at 0 the
    //     fault is upstream of the video: no conversion, no reference, or no
    //     clamp -- and it needs no input signal to run.
    // 2 = hold the clamp off, to see the undriven input for comparison.
    parameter [1:0]   CLAMP_MODE         = 2'd2,
    // Diagnostic drive modes for adc_clk, all measurable with a plain meter:
    //   0 = 27 MHz (normal).  A 50% square reads ~1.65 V DC.
    //   1 = held high  -> TP4 must read ~3.3 V
    //   2 = held low   -> TP4 must read ~0 V
    //   3 = divided square at SLOW_HALF_PERIOD.  At the 1 Hz default TP4 ticks
    //       0 <-> 3.3 V on a meter.  Set it to 32 for ~1.7 MHz, which is fast
    //       enough to be above any pipelined-ADC minimum conversion rate while
    //       still being immune to signal-integrity doubts.
    parameter [1:0]   ADC_CLK_MODE       = 2'd0,
    parameter integer SLOW_HALF_PERIOD   = 54_000_000,
    // Arm the raw line dump automatically, instead of waiting for S1.
    parameter         AUTO_DUMP          = 1'b0,
    // Report windows between automatic dumps.  A dump is ~13.5 kB and takes
    // about 1.2 s at 115200; back-to-back dumps leave the link permanently
    // busy, which is survivable when the design is loaded into SRAM but not
    // when it boots from flash.
    parameter integer AUTO_DUMP_EVERY    = 8,
    // Cycles of silence after configuration before anything is transmitted.
    // A flash-booted design starts running the instant power is applied --
    // well before the host has enumerated the USB serial bridge -- and a
    // bridge that is flooded through enumeration comes up wedged and stays
    // that way.  Five seconds at 108 MHz gives the host time to settle.
    parameter integer UART_HOLDOFF       = 540_000_000
) (
    input  wire       clk27,          // pin 4, onboard oscillator

    input  wire [7:0] adc_d,          // AD9280 D0..D7
    input  wire       adc_otr,        // AD9280 over-range
    output wire       adc_clk,        // 27 MHz sample clock to the AD9280
    output wire       adc_clamp,      // DC restoration gate

    input  wire [1:0] btn_n,          // S1 = pin 88, S2 = pin 87, active low
    output wire [5:0] led_n,          // onboard LEDs, active low
    output wire       uart_tx_pin     // pin 69, to the onboard USB serial
);
    // -----------------------------------------------------------------------
    // Clocking and reset
    // -----------------------------------------------------------------------
    wire clk108;
    wire pll_lock;

    rpll_108 pll (.clkin(clk27), .clkout(clk108), .lock(pll_lock));

    // Power-up value matters: it guarantees rst_n starts asserted even if LOCK
    // happens to be high before the first clk108 edge.
    reg [3:0] reset_pipe = 4'b0000;
    always @(posedge clk108 or negedge pll_lock) begin
        if (!pll_lock) reset_pipe <= 4'b0000;
        else           reset_pipe <= {reset_pipe[2:0], 1'b1};
    end
    wire rst_n = reset_pipe[3];

    // -----------------------------------------------------------------------
    // ADC clock generation and four-phase capture
    //
    // A free-running 2-bit counter divides 108 MHz by four.  adc_clk is that
    // counter's MSB through an output register, so its rising edge lands on the
    // clk108 edge whose pre-edge index is 2.  The pin is registered on every
    // clk108 edge, which gives four capture points per ADC period:
    //
    //   index 2 -> 0.0 ns    index 3 -> 9.3 ns
    //   index 0 -> 18.5 ns   index 1 -> 27.8 ns   (after the adc_clk edge)
    //
    // The AD9280 needs its output delay plus the board round trip before data
    // is valid, so index 2 is always too early; phase 2 (index 0) is the
    // starting guess and S2 walks the eye if it turns out to be wrong.
    // -----------------------------------------------------------------------
    reg [1:0] phase;
    reg [1:0] phase_r;
    reg [7:0] adc_r;
    reg       otr_r;
    reg       adc_clk_r;
    reg [1:0] phase_sel;

    wire [1:0] cap_index = phase_sel + 2'd2;

    always @(posedge clk108 or negedge rst_n) begin
        if (!rst_n) begin
            phase     <= 2'd0;
            phase_r   <= 2'd0;
            adc_r     <= 8'd0;
            otr_r     <= 1'b0;
            adc_clk_r <= 1'b0;
        end else begin
            phase     <= phase + 2'd1;
            phase_r   <= phase;
            adc_r     <= adc_d;
            otr_r     <= adc_otr;
            adc_clk_r <= phase[1];
        end
    end

    // Divided adc_clk for mode 3.  108 MHz / (2 * SLOW_HALF_PERIOD).
    localparam integer SHW = $clog2(SLOW_HALF_PERIOD);

    reg           slow_clk;
    reg [SHW-1:0] slow_cnt;
    always @(posedge clk108 or negedge rst_n) begin
        if (!rst_n) begin
            slow_cnt <= {SHW{1'b0}};
            slow_clk <= 1'b0;
        end else if (slow_cnt == SLOW_HALF_PERIOD - 1) begin
            slow_cnt <= {SHW{1'b0}};
            slow_clk <= ~slow_clk;
        end else begin
            slow_cnt <= slow_cnt + {{(SHW-1){1'b0}}, 1'b1};
        end
    end

    assign adc_clk = (ADC_CLK_MODE == 2'd1) ? 1'b1     :
                     (ADC_CLK_MODE == 2'd2) ? 1'b0     :
                     (ADC_CLK_MODE == 2'd3) ? slow_clk : adc_clk_r;

    // One pulse per ADC period, in the cycle where adc_r holds the chosen phase.
    wire sample_stb = (phase_r == cap_index);

    // -----------------------------------------------------------------------
    // Buttons
    // -----------------------------------------------------------------------
    reg [1:0]  btn_meta, btn_sync, btn_stable;
    reg [31:0] btn_timer;
    reg [1:0]  btn_press;             // one-cycle pulse per press
    // The pins take a moment to settle after configuration; without this the
    // design comes up having "seen" a press and reports the wrong phase.
    reg [19:0] btn_inhibit;

    always @(posedge clk108 or negedge rst_n) begin
        if (!rst_n) begin
            btn_meta   <= 2'b11;
            btn_sync   <= 2'b11;
            btn_stable <= 2'b11;
            btn_timer  <= 32'd0;
            btn_press  <= 2'b00;
            btn_inhibit <= 20'd0;
        end else begin
            if (btn_inhibit != 20'hFFFFF) btn_inhibit <= btn_inhibit + 20'd1;
            btn_meta  <= btn_n;
            btn_sync  <= btn_meta;
            btn_press <= 2'b00;
            if (btn_sync != btn_stable) begin
                if (btn_timer == DEBOUNCE_CYCLES - 1) begin
                    btn_timer  <= 32'd0;
                    // Active low, so a 1->0 transition is a press.
                    if (btn_inhibit == 20'hFFFFF)
                        btn_press <= btn_stable & ~btn_sync;
                    btn_stable <= btn_sync;
                end else begin
                    btn_timer <= btn_timer + 32'd1;
                end
            end else begin
                btn_timer <= 32'd0;
            end
        end
    end

    wire dump_key  = btn_press[0];    // S1
    wire phase_key = btn_press[1];    // S2

    always @(posedge clk108 or negedge rst_n) begin
        if (!rst_n)          phase_sel <= DEFAULT_PHASE;
        else if (phase_key)  phase_sel <= phase_sel + 2'd1;
    end

    // -----------------------------------------------------------------------
    // Sync slicing
    //
    // The threshold comes from the previous window's min/max.  Sync tip to
    // blanking is 28.6% of the sync-tip-to-white range, so one eighth of the
    // observed span sits comfortably between the two.
    // -----------------------------------------------------------------------
    localparam integer REJECT_MIN = 1200;   // merge half-line pulses into lines
    localparam integer GOOD_LO    = 1700;
    localparam integer GOOD_HI    = 1732;
    localparam integer VS_MIN     = 300;    // > 4.7us hsync, < 27.1us broad pulse
    localparam integer VS_REFRACT = 20000;  // one vsync event per field

    // The slicing threshold tracks over a single line, not over many.
    //
    // A source whose coupling into the 75 ohm termination is marginal droops
    // *within* a line: measured on one, the level fell 13 codes in the 2.4 us
    // between the colour burst and the back porch, which is enough to flatten
    // the 4.7 us sync pulse into blanking.  A threshold averaged over 19 lines
    // cannot follow that and the slicer finds no sync at all -- while a
    // television, whose sync separator is built for exactly this, displays the
    // same signal happily.  2048 samples is just over one line, so the window
    // always contains a sync pulse to find the floor from.
    localparam integer FAST_WIN = 2048;

    reg [7:0]  thr;
    reg [10:0] fast_cnt;
    reg [7:0]  f_min, f_max;
    reg        below_d;

    // Sync is sliced off a chroma-filtered copy of the samples; min/max, the
    // histogram, the raw dump and the line data all stay on adc_r.  See
    // sync_lpf for why: a saturated picture's subcarrier swings below any
    // sensible threshold and the slicer locks onto it instead of sync.
    wire [7:0] adc_lp;
    sync_lpf u_lpf (.clk(clk108), .rst_n(rst_n), .en(sample_stb),
                    .din(adc_r), .dout(adc_lp));

    wire below     = (adc_lp < thr);
    wire raw_fall  = below & ~below_d;

    // Confidence that we are locked to the line rate.  The clamp depends on it:
    // see the note at the clamp gating below.
    reg [7:0]  lock_cnt;
    wire       sync_locked = (lock_cnt >= 8'd64);

    reg [15:0] pcnt;                  // samples since the last accepted edge
    reg [15:0] lowrun;                // consecutive samples below threshold
    reg [15:0] vs_hold;

    wire line_edge = raw_fall && (pcnt >= REJECT_MIN);

    // -----------------------------------------------------------------------
    // Per-window accumulators
    // -----------------------------------------------------------------------
    localparam integer WCW = $clog2(SAMPLES_PER_WINDOW);

    reg [WCW-1:0] win_cnt;
    wire          win_end = sample_stb && (win_cnt == SAMPLES_PER_WINDOW - 1);

    reg  [7:0] a_or, a_and;
    reg  [7:0] a_min, a_max;
    reg [15:0] a_plast, a_pmin, a_pmax;
    reg [23:0] a_good, a_lines, a_vs, a_otr;

    // Latched report values, indexed by the output formatter.
    reg [23:0] val [0:13];
    reg        report_req;

    // Startup silence, and the automatic-dump interval.
    localparam integer HOW = $clog2(UART_HOLDOFF);
    reg [HOW-1:0] holdoff;
    reg [7:0]     dump_div;
    wire          uart_ready = (holdoff == UART_HOLDOFF - 1);

    always @(posedge clk108 or negedge rst_n) begin
        if (!rst_n)              holdoff <= {HOW{1'b0}};
        else if (!uart_ready)    holdoff <= holdoff + {{(HOW-1){1'b0}}, 1'b1};
    end

    // Sync tip to blanking is 28.6% of the sync-tip-to-white range, so one
    // eighth of the observed span sits comfortably between the two.
    wire [7:0]  span    = f_max - f_min;
    wire [7:0]  raw_off = span >> 3;
    wire [7:0]  thr_off = (raw_off < 8'd2) ? 8'd2 : raw_off;

    integer i;

    always @(posedge clk108 or negedge rst_n) begin
        if (!rst_n) begin
            thr      <= 8'd64;        // arbitrary start; replaced within ~1.2 ms
            fast_cnt <= 11'd0;
            f_min    <= 8'hFF;
            f_max    <= 8'h00;
            below_d  <= 1'b0;
            pcnt     <= 16'd0;
            lock_cnt <= 8'd0;
            lowrun   <= 16'd0;
            vs_hold  <= 16'd0;
            win_cnt  <= {WCW{1'b0}};
            a_or     <= 8'h00;
            a_and    <= 8'hFF;
            a_min    <= 8'hFF;
            a_max    <= 8'h00;
            a_plast  <= 16'd0;
            a_pmin   <= 16'hFFFF;
            a_pmax   <= 16'd0;
            a_good   <= 24'd0;
            a_lines  <= 24'd0;
            a_vs     <= 24'd0;
            a_otr    <= 24'd0;
            report_req <= 1'b0;
            for (i = 0; i < 14; i = i + 1) val[i] <= 24'd0;
        end else begin
            report_req <= 1'b0;

            if (sample_stb) begin
                below_d <= below;

                // --- line period ---------------------------------------------
                if (line_edge) begin
                    pcnt    <= 16'd1;
                    a_plast <= pcnt;
                    if (pcnt < a_pmin) a_pmin <= pcnt;
                    if (pcnt > a_pmax) a_pmax <= pcnt;
                    if (a_lines != 24'hFFFFFF) a_lines <= a_lines + 24'd1;
                    if (pcnt >= GOOD_LO && pcnt <= GOOD_HI) begin
                        if (a_good != 24'hFFFFFF) a_good <= a_good + 24'd1;
                        if (lock_cnt != 8'hFF)    lock_cnt <= lock_cnt + 8'd1;
                    end else begin
                        // Fall four times faster than we rise, so lock is quick
                        // to give up and the clamp releases before it can wedge.
                        lock_cnt <= (lock_cnt < 8'd16) ? 8'd0 : lock_cnt - 8'd16;
                    end
                end else if (pcnt != 16'hFFFF) begin
                    pcnt <= pcnt + 16'd1;
                end

                // --- vertical sync -------------------------------------------
                if (below) begin
                    if (lowrun != 16'hFFFF) lowrun <= lowrun + 16'd1;
                end else begin
                    lowrun <= 16'd0;
                end

                if (vs_hold != 16'd0) begin
                    vs_hold <= vs_hold - 16'd1;
                end else if (below && (lowrun == VS_MIN)) begin
                    vs_hold <= VS_REFRACT;
                    if (a_vs != 24'hFFFFFF) a_vs <= a_vs + 24'd1;
                end

                // --- level and liveness statistics ---------------------------
                a_or  <= a_or  | adc_r;
                a_and <= a_and & adc_r;
                if (adc_r < a_min) a_min <= adc_r;
                if (adc_r > a_max) a_max <= adc_r;

                // --- fast threshold tracking ---------------------------------
                if (adc_lp < f_min) f_min <= adc_lp;
                if (adc_lp > f_max) f_max <= adc_lp;
                if (fast_cnt == FAST_WIN - 1) begin
                    fast_cnt <= 11'd0;
                    thr      <= f_min + thr_off;
                    f_min    <= 8'hFF;
                    f_max    <= 8'h00;
                end else begin
                    fast_cnt <= fast_cnt + 11'd1;
                end
                if (otr_r && a_otr != 24'hFFFFFF) a_otr <= a_otr + 24'd1;

                // --- window boundary -----------------------------------------
                if (win_end) begin
                    val[0]  <= {22'd0, phase_sel};
                    val[1]  <= {16'd0, a_or & ~a_and};
                    val[2]  <= {16'd0, a_min};
                    val[3]  <= {16'd0, a_max};
                    val[4]  <= {16'd0, thr};
                    val[5]  <= {8'd0,  a_plast};
                    val[6]  <= {8'd0,  (a_pmin == 16'hFFFF) ? 16'd0 : a_pmin};
                    val[7]  <= {8'd0,  a_pmax};
                    val[8]  <= a_good;
                    val[9]  <= a_lines;
                    val[10] <= a_vs;
                    val[11] <= a_otr;
                    val[12] <= {22'd0, ADC_CLK_MODE};
                    val[13] <= {23'd0, sync_locked};
                    report_req <= uart_ready;

                    win_cnt <= {WCW{1'b0}};
                    a_or    <= 8'h00;
                    a_and   <= 8'hFF;
                    a_min   <= 8'hFF;
                    a_max   <= 8'h00;
                    a_pmin  <= 16'hFFFF;
                    a_pmax  <= 16'd0;
                    a_good  <= 24'd0;
                    a_lines <= 24'd0;
                    a_vs    <= 24'd0;
                    a_otr   <= 24'd0;
                end else begin
                    win_cnt <= win_cnt + {{(WCW-1){1'b0}}, 1'b1};
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // Clamp gating
    //
    // ccnt tracks position within the line.  It restarts on every accepted sync
    // edge and otherwise free-runs at the nominal line length, so the clamp
    // keeps pulsing at roughly 15.7 kHz even before sync is found -- without
    // it the AC-coupled input has no DC path and drifts out of range.
    // The window sits inside the 4.7 us sync tip, clear of the colour burst.
    // -----------------------------------------------------------------------
    localparam integer CLAMP_START = 14;    // ~0.52 us after the sync edge
    localparam integer CLAMP_STOP  = 108;   // ~4.00 us
    localparam integer CLAMP_WRAP  = 1715;

    reg [11:0] ccnt;
    reg        clamp_win;

    always @(posedge clk108 or negedge rst_n) begin
        if (!rst_n) begin
            ccnt      <= 12'd0;
            clamp_win <= 1'b0;
        end else if (sample_stb) begin
            if (line_edge || ccnt == CLAMP_WRAP) ccnt <= 12'd0;
            else                                 ccnt <= ccnt + 12'd1;
            clamp_win <= (ccnt >= CLAMP_START) && (ccnt < CLAMP_STOP);
        end
    end

    // The clamp must not run before sync is locked.  ccnt free-runs until the
    // first accepted line edge, so an unlocked clamp pulse lands on arbitrary
    // video, drags the signal out of the converter's range, and prevents the
    // sync detection that would have placed the pulse correctly -- the design
    // wedges at full scale and never recovers.  Measured on hardware: clamp
    // gated-but-unlocked sticks at code 253 forever, clamp off locks instantly.
    // So: acquire with the clamp off, then clamp inside the sync tip once
    // locked.  If the clamp ever breaks lock, lock_cnt falls and it releases.
    wire clamp_active = (CLAMP_MODE == 2'd1) ? 1'b1 :
                        (CLAMP_MODE == 2'd2) ? 1'b0 :
                        (CLAMP_MODE == 2'd3) ? clamp_win :
                        (clamp_win && sync_locked);

    assign adc_clamp = CLAMP_ACTIVE_HIGH ? clamp_active : ~clamp_active;

    // -----------------------------------------------------------------------
    // Raw line capture buffer
    // -----------------------------------------------------------------------
    localparam integer DPW = $clog2(DUMP_LEN);

    reg [7:0]     dmem [0:DUMP_LEN-1];
    reg [DPW-1:0] dwr;
    reg           dump_arm, dump_cap, dump_rdy;
    reg           dump_done;   // one-cycle pulse from the output formatter

    always @(posedge clk108 or negedge rst_n) begin
        if (!rst_n) begin
            dwr      <= {DPW{1'b0}};
            dump_div <= 8'd0;
            dump_arm <= 1'b0;
            dump_cap <= 1'b0;
            dump_rdy <= 1'b0;
        end else begin
            // Deliberately not gated on sync_locked: a dump is most useful
            // exactly when the slicer cannot lock and you need to see why.
            if (report_req)
                dump_div <= (dump_div == AUTO_DUMP_EVERY - 1) ? 8'd0
                                                              : dump_div + 8'd1;
            if ((dump_key ||
                 (AUTO_DUMP && report_req && dump_div == AUTO_DUMP_EVERY - 1))
                && !dump_arm && !dump_cap && !dump_rdy)
                dump_arm <= 1'b1;

            if (sample_stb) begin
                if (dump_cap) begin
                    dwr <= dwr + {{(DPW-1){1'b0}}, 1'b1};
                    if (dwr == DUMP_LEN - 1) begin
                        dump_cap <= 1'b0;
                        dump_rdy <= 1'b1;
                    end
                end else if (dump_arm && line_edge) begin
                    dump_arm <= 1'b0;
                    dump_cap <= 1'b1;
                    dwr      <= {DPW{1'b0}};
                end
            end

            if (dump_done) dump_rdy <= 1'b0;
        end
    end

    always @(posedge clk108) begin
        if (sample_stb && dump_cap) dmem[dwr] <= adc_r;
    end

    reg [DPW-1:0] dptr;
    reg [7:0]     drd;
    always @(posedge clk108) drd <= dmem[dptr];

    // -----------------------------------------------------------------------
    // Serial output: one formatter drives both the periodic report and the dump
    // -----------------------------------------------------------------------
    reg  [7:0] tx_data;
    reg        tx_stb;
    wire       tx_busy;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk108), .rst_n(rst_n),
        .data(tx_data), .stb(tx_stb), .tx(uart_tx_pin), .busy(tx_busy)
    );

    wire [7:0] rom_c;
    reg  [9:0] rom_ptr;
    report_rom u_rom (.addr(rom_ptr), .c(rom_c));

    localparam [3:0] O_IDLE   = 4'd0,  O_LIT     = 4'd1,  O_VAL   = 4'd2,
                     O_DECSUB = 4'd3,  O_DECOUT  = 4'd4,  O_HEXHI = 4'd5,
                     O_HEXLO  = 4'd6,  O_DHDR    = 4'd7,  O_DADDR = 4'd8,
                     O_DBHI   = 4'd9,  O_DBLO    = 4'd10, O_DSEP  = 4'd11,
                     O_DFTR   = 4'd12, O_DWAIT   = 4'd13;

    reg [3:0]  ostate;
    reg [3:0]  fld;
    reg [23:0] dec_rem;
    reg [2:0]  dec_pos;
    reg [3:0]  dec_dig;
    reg        dec_lead;
    reg [3:0]  lit_idx;               // index within a header/footer literal
    reg [1:0]  addr_nib;              // which nibble of the dump row address

    wire can_emit = !tx_busy && !tx_stb;
    wire fld_hex  = (fld == 4'd1);

    function [7:0] hexchar(input [3:0] n);
        hexchar = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
    endfunction

    function [23:0] pow10(input [2:0] i);
        case (i)
            3'd0: pow10 = 24'd10000000;
            3'd1: pow10 = 24'd1000000;
            3'd2: pow10 = 24'd100000;
            3'd3: pow10 = 24'd10000;
            3'd4: pow10 = 24'd1000;
            3'd5: pow10 = 24'd100;
            3'd6: pow10 = 24'd10;
            default: pow10 = 24'd1;
        endcase
    endfunction

    // "\r\n#DUMP\r\n"
    function [7:0] dhdr(input [3:0] i);
        case (i)
            4'd0: dhdr = 8'h0D; 4'd1: dhdr = 8'h0A; 4'd2: dhdr = "#";
            4'd3: dhdr = "D";   4'd4: dhdr = "U";   4'd5: dhdr = "M";
            4'd6: dhdr = "P";   4'd7: dhdr = 8'h0D; default: dhdr = 8'h0A;
        endcase
    endfunction

    // "\r\n#END\r\n"
    function [7:0] dftr(input [3:0] i);
        case (i)
            4'd0: dftr = 8'h0D; 4'd1: dftr = 8'h0A; 4'd2: dftr = "#";
            4'd3: dftr = "E";   4'd4: dftr = "N";   4'd5: dftr = "D";
            4'd6: dftr = 8'h0D; default: dftr = 8'h0A;
        endcase
    endfunction

    always @(posedge clk108 or negedge rst_n) begin
        if (!rst_n) begin
            ostate    <= O_IDLE;
            tx_stb    <= 1'b0;
            tx_data   <= 8'd0;
            rom_ptr   <= 10'd0;
            fld       <= 4'd0;
            dec_rem   <= 24'd0;
            dec_pos   <= 3'd0;
            dec_dig   <= 4'd0;
            dec_lead  <= 1'b0;
            lit_idx   <= 4'd0;
            addr_nib  <= 2'd0;
            dptr      <= {DPW{1'b0}};
            dump_done <= 1'b0;
        end else begin
            tx_stb    <= 1'b0;
            dump_done <= 1'b0;

            case (ostate)
                // The dump wins: it is explicitly requested, the report is not.
                O_IDLE: begin
                    if (dump_rdy) begin
                        ostate  <= O_DHDR;
                        lit_idx <= 4'd0;
                        dptr    <= {DPW{1'b0}};
                    end else if (report_req) begin
                        ostate  <= O_LIT;
                        rom_ptr <= 10'd0;
                        fld     <= 4'd0;
                    end
                end

                O_LIT: begin
                    if (rom_c == 8'h00) begin
                        rom_ptr <= rom_ptr + 10'd1;
                        ostate  <= (fld < 4'd14) ? O_VAL : O_IDLE;
                    end else if (can_emit) begin
                        tx_data <= rom_c;
                        tx_stb  <= 1'b1;
                        rom_ptr <= rom_ptr + 10'd1;
                    end
                end

                O_VAL: begin
                    if (fld_hex) begin
                        ostate <= O_HEXHI;
                    end else begin
                        dec_rem  <= val[fld];
                        dec_pos  <= 3'd0;
                        dec_dig  <= 4'd0;
                        dec_lead <= 1'b0;
                        ostate   <= O_DECSUB;
                    end
                end

                // Ungated so a full conversion costs cycles, not byte times.
                O_DECSUB: begin
                    if (dec_rem >= pow10(dec_pos)) begin
                        dec_rem <= dec_rem - pow10(dec_pos);
                        dec_dig <= dec_dig + 4'd1;
                    end else begin
                        ostate <= O_DECOUT;
                    end
                end

                O_DECOUT: begin
                    if (dec_dig != 4'd0 || dec_lead || dec_pos == 3'd7) begin
                        if (can_emit) begin
                            tx_data  <= 8'h30 + {4'd0, dec_dig};
                            tx_stb   <= 1'b1;
                            dec_lead <= 1'b1;
                            dec_dig  <= 4'd0;
                            dec_pos  <= dec_pos + 3'd1;
                            if (dec_pos == 3'd7) begin
                                fld    <= fld + 4'd1;
                                ostate <= O_LIT;
                            end else begin
                                ostate <= O_DECSUB;
                            end
                        end
                    end else begin
                        dec_dig <= 4'd0;
                        dec_pos <= dec_pos + 3'd1;
                        ostate  <= O_DECSUB;
                    end
                end

                O_HEXHI: if (can_emit) begin
                    tx_data <= hexchar(val[fld][7:4]);
                    tx_stb  <= 1'b1;
                    ostate  <= O_HEXLO;
                end

                O_HEXLO: if (can_emit) begin
                    tx_data <= hexchar(val[fld][3:0]);
                    tx_stb  <= 1'b1;
                    fld     <= fld + 4'd1;
                    ostate  <= O_LIT;
                end

                O_DHDR: if (can_emit) begin
                    tx_data <= dhdr(lit_idx);
                    tx_stb  <= 1'b1;
                    lit_idx <= lit_idx + 4'd1;
                    if (lit_idx == 4'd8) begin
                        ostate   <= O_DADDR;
                        addr_nib <= 2'd0;
                    end
                end

                // Four hex digits of the row address, then 16 bytes.
                O_DADDR: if (can_emit) begin
                    case (addr_nib)
                        2'd0: tx_data <= hexchar({{(16-DPW){1'b0}}, dptr} >> 12);
                        2'd1: tx_data <= hexchar(({{(16-DPW){1'b0}}, dptr} >> 8)  & 16'hF);
                        2'd2: tx_data <= hexchar(({{(16-DPW){1'b0}}, dptr} >> 4)  & 16'hF);
                        2'd3: tx_data <= hexchar( {{(16-DPW){1'b0}}, dptr}        & 16'hF);
                    endcase
                    tx_stb   <= 1'b1;
                    addr_nib <= addr_nib + 2'd1;
                    if (addr_nib == 2'd3) ostate <= O_DSEP;
                end

                O_DSEP: if (can_emit) begin
                    tx_data <= " ";
                    tx_stb  <= 1'b1;
                    ostate  <= O_DBHI;
                end

                O_DBHI: if (can_emit) begin
                    tx_data <= hexchar(drd[7:4]);
                    tx_stb  <= 1'b1;
                    ostate  <= O_DBLO;
                end

                O_DBLO: if (can_emit) begin
                    tx_data <= hexchar(drd[3:0]);
                    tx_stb  <= 1'b1;
                    dptr    <= dptr + {{(DPW-1){1'b0}}, 1'b1};
                    if (dptr == DUMP_LEN - 1) begin
                        ostate  <= O_DFTR;
                        lit_idx <= 4'd0;
                    end else if (dptr[3:0] == 4'hF) begin
                        // End of a 16-byte row: CR LF then the next address.
                        ostate  <= O_DHDR;
                        lit_idx <= 4'd7;
                    end else begin
                        ostate <= O_DSEP;
                    end
                end

                O_DFTR: if (can_emit) begin
                    tx_data <= dftr(lit_idx);
                    tx_stb  <= 1'b1;
                    lit_idx <= lit_idx + 4'd1;
                    if (lit_idx == 4'd7) begin
                        dump_done <= 1'b1;
                        ostate    <= O_DWAIT;
                    end
                end

                // dump_rdy is cleared by dump_done a cycle later; returning to
                // O_IDLE before then would immediately retrigger the dump.
                O_DWAIT: if (!dump_rdy) ostate <= O_IDLE;

                default: ostate <= O_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Diagnostic LEDs (active low)
    // -----------------------------------------------------------------------
    reg [26:0] hb;
    always @(posedge clk108 or negedge rst_n) begin
        if (!rst_n) hb <= 27'd0;
        else        hb <= hb + 27'd1;
    end

    wire [23:0] lines_rep = val[9];
    wire [23:0] good_rep  = val[8];

    wire sync_ok  = sync_locked;
    wire vsync_ok = (val[10] != 24'd0);
    wire otr_seen = (val[11] != 24'd0);
    wire bus_bad  = (val[1][7:0] != 8'hFF);

    assign led_n = ~{ bus_bad, otr_seen, vsync_ok, sync_ok, pll_lock, hb[25] };
endmodule

`default_nettype wire
