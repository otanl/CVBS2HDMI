`default_nettype none

// AD9280 NTSC-J decoder on the 25.2 MHz pixel clock, one sample per clock.
// 126 MHz reaches only the converter's clock (adc_front); nothing else runs
// there, so the whole decoder builds without ALU cells (Apicula #514).
// Pulse-width-qualified H/V sync, digital back-porch restoration, seven-tap
// Y/C separation, burst-referenced quadrature demodulation and RGB output.
// Windows use samples from the sync leading edge; LEGACY_TIMING retains
// the old blanking-relative windows for diagnosing the M5 generator.
// line_done publishes a complete 640-pixel line, never a sync/reset event.

module ntsc_capture #(
    parameter integer LPF_DELAY     = 12,
    // Compatibility with the old, measured blanking-relative M5 windows.
    // Normal operation counts from the sync leading edge at 25.2 MSPS.
    parameter         LEGACY_TIMING = 1'b0,
    // Forwarded to burst_nco, large enough to disable its gap handling.
    //
    // That handling is correct -- it takes the first line back from vertical
    // blanking from 38 degrees of phase error to 4, which sim-tracking asserts
    // -- and on this source it costs 17 points of good rows and seven times the
    // out-of-order rows, because a 19-code burst drops under MAG_MIN in the
    // middle of active video and each misfire throws away a field's averaging.
    // See CLAUDE.md.  A source with a full-amplitude burst should enable it.
    parameter integer BURST_GAP_SAMPLES = 262142,
    parameter         CLAMP_ENABLE  = 1'b0,
    // Standard timing reads 16 samples of back porch, well clear of the burst's
    // end (~197) and of the picture's start (~237); legacy keeps its 32.
    parameter integer BP_START      = LEGACY_TIMING ? 305 : 210,
    parameter integer BP_END        = BP_START + (LEGACY_TIMING ? 32 : 16),
    parameter integer BURST_START   = LEGACY_TIMING ? 240 : 136,
    parameter integer BURST_END     = LEGACY_TIMING ? 300 : 192,
    parameter integer ACTIVE_START  = LEGACY_TIMING ? 313 : 252,
    parameter integer ACTIVE_PIXELS = 640,
    parameter         SYNC_ON_SLOPE = 1'b0,
    parameter integer LUMA_SHIFT    = 4,
    // The slice sits span >> THR_SHIFT above the floor.  With a real sync step
    // 5 is too close: on the M5 recording the low-passed sync tip wanders over
    // 82..85 and a slice at 85 broke half the sync pulses into fragments, so
    // 112 lines of 249 were coasted by the flywheel and every window on them
    // landed in the wrong place.  4 puts it about 5 codes up, where all 18
    // syncs of the recording qualify as one clean run.  The legacy path is
    // for a source with no sync step and keeps the slice at the floor.
    parameter integer THR_SHIFT     = LEGACY_TIMING ? 5 : 4,
    parameter integer QUALIFY       = LEGACY_TIMING ? 124 : 80,
    parameter integer VS_MIN        = 400,
    parameter integer RELEASE       = 10,
    parameter integer FORCE_GIVEUP  = 4,
    parameter integer FMARGIN       = 8,
    parameter integer THR_SHIFT_LO  = 5,
    parameter integer ACC_WIN       = LEGACY_TIMING ? 800 : 128,
    parameter         SCOPE_LIVE    = 1'b1,
    // Dump depth, as an address width.  11 is the one-line scope; 15 records
    // 32768 consecutive samples -- twenty lines -- for replay in simulation.
    parameter integer DUMP_AW       = 11,
    // Fill the scope dump with a known constant instead of the ADC, so the
    // whole read-back path -- BSRAM, trace drawing, HDMI, capture card and
    // scripts/scope_trace.py -- can be checked against an answer known in
    // advance.  0xAA exercises alternating bits, including the ones the ADC
    // samples never show.  Measured: 3840 of 3840 recovered samples read 170.
    // Modes 4/5 count ADC bit 6/5; mode 6 selects the M5's bottom grey ramp.
    parameter integer SCOPE_TEST_RAMP = 0,   // 0 decoder tap, 1 const, 2 ramp, 3 raw adc_r
    parameter integer CLAMP_FORCE = 0,       // 1 = hold the clamp on, AIN -> ~code 80
    parameter integer SCOPE_FREERUN = 0,     // 1 = dump without needing a detected line
    parameter integer CHROMA_SHIFT = 0,
    // Halve the luma gain and quarter the chroma gain when the input is large.
    //
    // The gains were constants chosen for a source whose blanking-to-white span
    // is 130 codes.  When the span grew to 177 the same constants map white to
    // 498, the top of the range folds together, and the bars stop being ordered:
    // 50.1% correct rows, 55.7% of channel samples saturated.  Choosing by the
    // measured span instead gives 100.0% correct, 0.0% wrong-order and 0.8%
    // saturated on the same signal, and leaves the 130-code case exactly as it
    // was -- which is what keeps sim-video's published RGB values valid.
    parameter integer AUTO_GAIN = 1,
    // Choose the sampling instant by measurement; see the calibration below.
    // 0 keeps phase_sel, which is what the ADC probe and the benches that
    // predate this used.
    parameter         AUTO_PHASE   = 1'b1,
    // adc_front's counting window, 2^ADC_WIN_W samples.  Benches shorten it.
    parameter integer ADC_WIN_W    = 14,
    parameter         ADC_CLK_SWAP = 1'b0,   // adc_front's CLK_D1_FIRST
    parameter         ADC_DIAG     = 1'b0,   // adc_front's DIAG
    parameter         COLOUR       = 1'b1
) (
    input  wire        clk,            // pixel clock, 25.2 MHz, one sample each
    input  wire        fclk,           // 126 MHz, the converter's clock only
    input  wire        rst_n,

    input  wire [7:0]  adc_d,
    input  wire        adc_otr,
    output wire        adc_clk,
    output wire        adc_clamp,

    input  wire [3:0]  rot_sel,       // converter clock rotation, AUTO_PHASE off
    output wire [3:0]  rot_in_use,
    output wire        adc_cal_done,
    output wire [5:0]  adc_sweeps,
    output wire        adc_pair_x,
    output wire [15:0] adc_track,
    input  wire [3:0]  adc_dbg_rot,
    output wire [15:0] adc_dbg_cx,
    output wire [15:0] adc_dbg_cy,
    input  wire [2:0]  adc_dbg_bit,
    output wire [15:0] adc_dbg_bx,
    output wire [15:0] adc_dbg_by,
    input  wire [1:0]  gain_sel,

    output reg         wr_en,
    output reg  [10:0] wr_addr,
    output reg  [23:0] wr_data,
    output reg         wr_bank,

    output reg         line_done,     // one clk pulse at end of each line
    output reg         vsync_pulse,   // one clk pulse per field
    output wire        sync_locked,
    output wire [7:0]  lock_level,    // how close to lock, 0..255; 64 locks
    output reg  [15:0] real_count,
    output reg  [15:0] force_count,
    output reg  [15:0] qual_count,
    output reg  [15:0] miss_count,
    output reg  [11:0] blank_end,
    output reg  [15:0] clip_count,
    output reg  [7:0]  burst_min,
    output reg  [7:0]  burst_max,
    output wire [31:0] nco_phase,
    output wire        burst_locked,
    output wire signed [15:0] burst_corr_i,
    output wire signed [15:0] burst_corr_q,
    output reg  [15:0] run_min,
    output reg  [15:0] run_max,
    output reg         dmp_we,
    output reg  [DUMP_AW-1:0] dmp_addr,
    output reg  [7:0]  dmp_data,
    output reg         dmp_rdy,
    input  wire        dmp_ack,
    output reg  [15:0] period_out,    // last accepted line period, want 1602
    output wire [7:0]  slice_min,
    output wire [7:0]  slice_max,
    output wire [7:0]  slice_thr,
    output wire [7:0]  black_out,
    output wire [255:0] hist_flat
);
    // The converter's interface and its read timing: see adc_front.
    wire [7:0] adc_r;
    reg        otr_r;
    wire [ADC_WIN_W:0] adc_track_w;
    assign adc_track = adc_track_w;   // WIN_W <= 15
    wire [ADC_WIN_W:0] adc_dbg_cx_w, adc_dbg_cy_w, adc_dbg_bx_w, adc_dbg_by_w;
    assign adc_dbg_bx = adc_dbg_bx_w;
    assign adc_dbg_by = adc_dbg_by_w;
    assign adc_dbg_cx = adc_dbg_cx_w;
    assign adc_dbg_cy = adc_dbg_cy_w;
    adc_front #(.AUTO(AUTO_PHASE), .WIN_W(ADC_WIN_W), .CLK_D1_FIRST(ADC_CLK_SWAP),
                .DIAG(ADC_DIAG)) u_adc (
        .pclk(clk), .fclk(fclk), .rst_n(rst_n), .adc_d(adc_d), .adc_clk(adc_clk),
        .manual_rot(rot_sel), .sample(adc_r), .rot_in_use(rot_in_use),
        .cal_done(adc_cal_done), .sweeps(adc_sweeps), .pair_x(adc_pair_x),
        .track_count(adc_track_w),
        .dbg_rot(adc_dbg_rot), .dbg_cx(adc_dbg_cx_w), .dbg_cy(adc_dbg_cy_w),
        .dbg_bit(adc_dbg_bit), .dbg_bx(adc_dbg_bx_w), .dbg_by(adc_dbg_by_w)
    );
    always @(posedge clk) otr_r <= adc_otr;   // a diagnostic only

    // One sample every clock.  The name stays so the code still says which
    // logic runs per sample; it used to be one clock in five at 126 MHz.
    wire sample_stb = 1'b1;

    localparam integer CLAMP_START = 13  + LPF_DELAY;   // ~0.5 us after sync
    localparam integer CLAMP_STOP  = 101 + LPF_DELAY;   // ~4.0 us, inside the tip

    reg clamp_win;

    reg  [7:0]  lock_cnt;
    // CLAMP_FORCE holds the analog clamp on continuously, which pins AIN to
    // CLAMPIN = VREF * 10/32 = 0.625 V, about code 80.  That is 0x50 -- bit 6
    // set -- so it is a known DC input whose correct answer requires the bit
    // this board never reports.  No video source is involved, and there is no
    // room to interpret the result.
    assign adc_clamp = (CLAMP_FORCE != 0) ? 1'b1
                     : (CLAMP_ENABLE && clamp_win && (lock_cnt >= 8'd16));

    localparam integer P_NOM     = 1602;
    localparam integer P_WIN_NAR = 128;
    localparam integer P_WIN_WIDE= ACC_WIN;
    localparam integer P_WIN     = P_WIN_WIDE;   // for P_MIN/P_MAX below
    localparam integer P_MIN     = P_NOM - 160;
    localparam integer P_MAX     = P_NOM + 160;
    localparam integer P_BAND    = 128;
    localparam integer VS_REFRACT = 60000;
    localparam integer FAST_WIN   = 2048;
    localparam integer LINE_WRAP  = 1601;

    reg  [7:0]  thr;
    reg  [10:0] fast_cnt;
    reg  [7:0]  f_min, f_max;
    reg         below_d;
    reg  [15:0] pcnt, lowrun, vs_hold;
    reg  [7:0]  thr_lo;
    reg         below_lo_d;
    reg  [15:0] lo_fall_pcnt;   // pcnt when the sync edge went by
    reg         lo_fall_seen;
    reg  [4:0]  hi_run;   // samples above threshold within a tolerated glitch
    reg  [11:0] ccnt;
    reg  [11:0] ccnt_real;   // ccnt as the last real edge set it

    wire [7:0] adc_lp;
    sync_lpf u_lpf (.clk(clk), .rst_n(rst_n), .en(sample_stb),
                    .din(adc_r), .dout(adc_lp));

    wire       below     = (adc_lp < thr);
    wire       below_lo  = (adc_lp < thr_lo);
    wire       lo_fall   = below_lo && !below_lo_d;
    wire       level_fall = below & ~below_d;

    localparam integer GLITCH  = 0;
    // Qualify the complete pulse. Equalising pulses are too short; vertical
    // broad pulses are too long. This prevents half-line false H syncs.
    wire sync_qual = LEGACY_TIMING ? (below && (lowrun == QUALIFY))
                    : (!below && below_d && lowrun >= QUALIFY && lowrun <= 150);

    reg  [7:0] sl_d [0:3];
    reg  [7:0] drop_track, drop_ref;
    integer    sj;

    wire [7:0] drop      = (sl_d[3] > adc_lp) ? (sl_d[3] - adc_lp) : 8'd0;
    wire [7:0] drop_gate = {1'd0, drop_ref[7:1]};
    reg        slope_armed;
    wire       slope_fall = SYNC_ON_SLOPE && slope_armed &&
                            (drop >= drop_gate) && (drop_ref >= 8'd2);

    wire       raw_fall  = SYNC_ON_SLOPE ? slope_fall : level_fall;
    reg [15:0] period_avg;
    reg [15:0] rcnt;
    reg [7:0]  force_run;
    reg [8:0]  line_in_field;
    reg        be_armed;
    reg [7:0]  bmin_acc, bmax_acc;
    reg        vs_seen;
    reg [11:0] lag;
    reg [7:0]  pfrac;
    reg [7:0]  facc;
    reg        extra;   // this line gets one more sample
    reg [15:0] run_peak;      // longest low run within the current line
    reg [15:0] run_min_acc;   // shortest such peak within the current window
    reg [15:0] run_max_acc;   // longest low run within the current window
    reg [7:0]  run_lines;
    reg        peak_pend;

    reg        dmp_cap;
    reg [20:0] dmp_arm;   // 2^21 clocks, 83 ms between scope refreshes
    // Allow the first missing edge a margin, then coast at the learned
    // period. Adding the margin on every forced line causes cumulative drift.
    reg [15:0] free_period;
    wire [15:0] win_w     = P_WIN_WIDE[15:0];
    wire [15:0] edge_age  = pcnt - lo_fall_pcnt;
    wire        edge_ok   = lo_fall_seen && (pcnt >= lo_fall_pcnt) &&
                            (edge_age <= 16'd400);
    wire [11:0] lag_next  = FMARGIN[11:0];
    reg signed [24:0] period_error;
    wire signed [24:0] period_adjust = period_error >>> 6;
    reg [23:0] period_next;
    reg [15:0] window_start;
    reg in_window, force_line, period_plausible;
    // Unsigned distance between the measured and estimated period.
    //
    // The plausibility test used to be a pair of signed comparisons against
    // +/-P_BAND.  Apicula miscompiles signed comparison on this part depending
    // only on the placement seed (YosysHQ/apicula#541, open, no workaround), and
    // this particular comparison decides whether a sync edge is accepted -- a
    // wrong answer here corrupts the line timing for the whole frame.  Both
    // operands are counts and cannot be negative, so the same test is available
    // as one unsigned magnitude compare, which the bug does not touch.
    // period_error stays for the shift that trims period_next; the bug is in
    // comparison, not arithmetic.
    // Two unsigned compares against constants, the same shape as the two
    // signed ones they replace, so the cost is the same.  Taking a magnitude
    // first instead -- a negate and a mux ahead of the compare -- dropped the
    // capture clock from 141 MHz to 100.  A negative period_error is simply a
    // large unsigned one, so the sign bit picks which constant to test.
    localparam [24:0] PE_NEG_LIMIT = 25'd0 - (P_BAND * 256);
    localparam [23:0] PE_POS_LIMIT = P_BAND * 256;
    reg in_late_window;
    // At 126 MHz these were registered in the idle clocks between samples.
    // At one sample per clock a register would lag a sample, so the compares
    // against pcnt are combinational -- 39.7 ns is plenty -- and the period
    // arithmetic is registered one sample *ahead*: rcnt counts up by one a
    // sample, so the error for rcnt + 1 is exactly what the next clock's
    // line_real needs (after a line_real the next is at least QUALIFY away).
    // window_start and free_period move only at a line edge and are used
    // hundreds of samples later, so a register costs nothing there.
    wire [15:0] rcnt_ahead = (rcnt == 16'hFFFF) ? rcnt : rcnt + 16'd1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            period_error <= 0;
            free_period <= P_NOM + FMARGIN;
            window_start <= P_NOM - ACC_WIN;
        end else begin
            period_error <= $signed({1'b0, rcnt_ahead, 8'd0}) -
                            $signed({1'b0, period_avg, pfrac});
            free_period <= period_avg + {15'd0, extra} +
                           ((lag == 0) ? FMARGIN[15:0] : 16'd0);
            window_start <= period_avg - win_w;
        end
    end
    always @(*) begin
        period_next = {period_avg, pfrac} + period_adjust[23:0];
        in_window = pcnt >= window_start;
        // Gated on the standard-timing path so the M5 build synthesises
        // to exactly what it did before this existed.
        in_late_window = !LEGACY_TIMING && (pcnt < P_WIN_NAR[15:0]);
        force_line = pcnt >= free_period;
        // Both halves unsigned.  The positive one used to compare against
        // the integer P_BAND * 256, which is signed, so the comparison
        // was still a signed one and still exposed to apicula#541.
        period_plausible = period_error[24]
                         ? (period_error >= PE_NEG_LIMIT)
                         : (period_error[23:0] <= PE_POS_LIMIT);
    end
    reg        locked_st;
    reg        vertical_reacquire;
    wire       acquiring   = !locked_st;

    // A real edge arriving just after the flywheel already coasted a line is
    // still that line's edge -- the flywheel was early, not the source late.
    // Rejecting it left the standard-timing path coasting indefinitely: sync
    // never locked and only 89% of lines were accepted.  Accepting it resyncs.
    wire       late_real   = !LEGACY_TIMING && (force_run != 8'd0) && in_late_window;
    wire       line_real   = sync_qual && (in_window || acquiring || vertical_reacquire || late_real);
    wire       line_edge   = line_real || (force_line && !acquiring);

    wire [7:0] span      = f_max - f_min;
    wire [7:0] raw_off   = span >> THR_SHIFT;
    wire [7:0] span_off  = (raw_off < 8'd2) ? 8'd2 : raw_off;

    reg  [7:0]  black;
    wire [7:0] thr_off   = span_off;                 // high: detection
    wire [7:0] lo_raw    = span >> THR_SHIFT_LO;
    wire [7:0] thr_lo_off= (lo_raw < 8'd2) ? 8'd2 : lo_raw;

    assign sync_locked = (lock_cnt >= 8'd64);
    assign lock_level  = lock_cnt;
    assign slice_min   = f_min;
    assign slice_max   = f_max;
    assign slice_thr   = thr;

    // Black reference (standard timing): the higher of the two porches, lightly
    // smoothed across lines.
    //
    // Neither porch is blanking on every line of the M5.  Its two DMA line
    // buffers are written only during the vertical interval, so the blanking
    // they carry depends on the boot: one boot gave front porch 117 on every
    // line and back porch 117/101 alternating, the next front porch 99/115 and
    // back porch 114/99.  Clamping to either porch moves black 16 codes every
    // other line -- 45 codes of luma banding after the gain.  What held in both
    // boots, on every line, is that one porch reads true blanking and the other
    // the burst's low level, never the reverse.  So take the higher of the two:
    // on a standard source both are blanking and the maximum of two averages is
    // biased by a fraction of a code.  A quarter-weight IIR across lines takes
    // out what alternation is left (113 against 115 on the second boot).
    //
    // Front porch: a 16-sample running sum of the raw samples, delayed so that when the
    // low-passed slicer first drops below threshold -- the leading edge as the
    // slicer sees it, a dozen samples after the true one -- the window sits on
    // the front porch, clear of both the end of the picture and the edge's own
    // fall.  It is committed to black only when that low run then qualifies as
    // a line sync, so equalising pulses, broad pulses and dips in the picture
    // never reach it.
    localparam integer FP_LAG = 18;   // age of the newest sample in the window
    localparam integer FP_N   = 16;
    reg  [7:0]  fp_dl [0:FP_LAG+FP_N-1];
    reg  [11:0] fp_sum;
    reg  [7:0]  fp_cand;
    integer     fj;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fp_sum <= 12'd0; fp_cand <= 8'd134;
            for (fj = 0; fj < FP_LAG+FP_N; fj = fj + 1) fp_dl[fj] <= 8'd0;
        end else if (sample_stb) begin
            fp_dl[0] <= adc_r;
            for (fj = 1; fj < FP_LAG+FP_N; fj = fj + 1) fp_dl[fj] <= fp_dl[fj-1];
            fp_sum <= fp_sum + {4'd0, fp_dl[FP_LAG-1]} - {4'd0, fp_dl[FP_LAG+FP_N-1]};
            if (level_fall) fp_cand <= fp_sum[11:4];
        end
    end

    reg [12:0] bp_acc;
    reg  [7:0] fp_line;         // front porch of the current line
    reg  [9:0] black_q;         // black * 4, the smoothed reference
    wire [7:0] bp_val    = bp_acc[11:4];                 // 16-sample average
    wire [7:0] porch_max = (fp_line > bp_val) ? fp_line : bp_val;
    reg [7:0]  s_even;

    reg [19:0] hist [0:15];
    reg [19:0] hist_rep [0:15];
    integer    hi;

    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : g_hist
            assign hist_flat[gi*16 +: 16] = hist_rep[gi][19:4];
        end
    endgenerate

    assign black_out = black;

    wire [11:0] cpos      = ccnt + lag;
    wire        in_burst  = (cpos >= BURST_START) && (cpos < BURST_END);
    wire        in_bp     = (cpos >= BP_START) && (cpos < BP_END);
    wire        in_active = (cpos >= ACTIVE_START) &&
                            (cpos <  ACTIVE_START + 2 * ACTIVE_PIXELS);
    // The colour pipeline -- mixer, moving sum, gain and matrix -- delivers
    // rgb four samples later than it did with five clocks per sample, and
    // y_delay is two longer to keep luma with it.  Writing four samples later
    // puts every pixel back where it was.
    localparam integer PIPE = 4;
    wire [11:0] wpos      = cpos - PIPE[11:0];
    wire        in_write  = (wpos >= ACTIVE_START) &&
                            (wpos <  ACTIVE_START + 2 * ACTIVE_PIXELS);
    wire [11:0] a_idx     = wpos - ACTIVE_START[11:0];

    wire [31:0] nco_ref;
    reg  [7:0] dl [0:6];
    reg [10:0] sum7;
    integer     di;

    // 73/512 approximates 1/7 within 0.2%. Unlike x37>>8 this
    // neither biases the back porch upward nor wraps at ADC code 255.
    wire [16:0] s7x73 = ({6'd0, sum7} << 6) + ({6'd0, sum7} << 3) +
                        {6'd0, sum7} + 17'd256;
    wire [7:0] luma_lp = s7x73[16:9];
    reg [31:0] ref_delay [0:3];
    reg [7:0] y_delay [0:5];
    reg signed [20:0] u_delay [0:6], v_delay [0:6];

    wire signed [9:0] chroma = {2'b00, dl[3]} - {2'b00, luma_lp};

    reg signed [20:0] u_acc, v_acc;
    reg signed [20:0] u_lat, v_lat;
    reg  [2:0]         mix_cnt;

    wire signed [15:0] ch_ext = {{6{chroma[9]}}, chroma};
    // dl[3] is four sample strobes old. Delay the phase by the same
    // amount; a current phase rotates colour by about 204.5 degrees.
    // NTSC C = U*sin(t) + V*cos(t), burst = -A*sin(t).
    // phase_ref is a cosine reference for that burst: U uses -cos(ref),
    // and V uses +sin(ref). See AD723 datasheet, chrominance signal path.
    wire [7:0] mpc = ref_delay[3][31:24];
    wire [31:0] mix_sine_phase = ref_delay[3] - 32'h4000_0000;
    wire [7:0] mps = mix_sine_phase[31:24];
    wire mi_neg = (mpc < 8'd43) || (mpc >= 8'd213);
    wire mi_pos = (mpc >= 8'd85) && (mpc < 8'd171);
    wire mq_pos = (mps < 8'd43) || (mps >= 8'd213);
    wire mq_neg = (mps >= 8'd85) && (mps < 8'd171);

    wire signed [7:0] ref_cosine, ref_sine;
    reg signed [7:0] cos_weight, sin_weight;
    reg signed [9:0] chroma_r;
    reg signed [20:0] u_mix, v_mix;
    chroma_sincos mixer_ref (.phase(ref_delay[3][31:26]),
                            .cosine(ref_cosine), .sine(ref_sine));
    // Two registers: the LUT and operands, then the products.  u_mix is two
    // samples behind chroma; see PIPE.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cos_weight <= 0; sin_weight <= 0; chroma_r <= 0;
            u_mix <= 0; v_mix <= 0;
        end else begin
            cos_weight <= ref_cosine; sin_weight <= ref_sine;
            chroma_r <= chroma;
            u_mix <= -chroma_r * cos_weight;
            v_mix <= chroma_r * sin_weight;
        end
    end
    wire signed [20:0] u_next = u_acc + u_mix - u_delay[6];
    wire signed [20:0] v_next = v_acc + v_mix - v_delay[6];

    wire [8:0]  pair_sum  = {1'b0, s_even} + {1'b0, adc_r};
    wire [7:0]  pair_avg  = pair_sum[8:1];
    wire [7:0] diff = (y_delay[5] > black) ? (y_delay[5] - black) : 8'd0;
    wire [15:0] d16  = {8'd0, diff};
    wire [15:0] m45  = (d16 << 5) + (d16 << 3) + (d16 << 2) + d16;  // x2.8125
    wire [15:0] m64  =  d16 << 6;                                    // x4
    wire [15:0] m96  = (d16 << 6) + (d16 << 5);                      // x6
    wire [15:0] m128 =  d16 << 7;                                    // x8
    wire [15:0] prod = (gain_sel == 2'd0) ? m45  :
                       (gain_sel == 2'd1) ? m64  :
                       (gain_sel == 2'd2) ? m96  : m128;
    wire [7:0]  white_span = (f_max > black) ? (f_max - black) : 8'd1;
    wire        wide_input = (AUTO_GAIN != 0) && (white_span > 8'd150);
    // Two constant shifts and a mux, not a variable shift.
    wire [15:0] scaled    = wide_input ? (prod >> (LUMA_SHIFT + 1))
                                       : (prod >> LUMA_SHIFT);
    wire [7:0]  luma      = (scaled > 16'd255) ? 8'd255 : scaled[7:0];

    // Seven samples times the three-level mixer's fundamental gain
    // (sqrt(3)/pi) is 3.86. These constants undo it and apply the same
    // ADC-to-RGB gain as the luma path (45/16, 4, 6 or 8).
    wire signed [29:0] ug = (gain_sel == 0) ? u_lat * 9'sd51 :
                            (gain_sel == 1) ? u_lat * 9'sd73 :
                            (gain_sel == 2) ? u_lat * 9'sd110 : u_lat * 9'sd146;
    wire signed [29:0] vg = (gain_sel == 0) ? v_lat * 9'sd51 :
                            (gain_sel == 1) ? v_lat * 9'sd73 :
                            (gain_sel == 2) ? v_lat * 9'sd110 : v_lat * 9'sd146;
    reg signed [15:0] u_s, v_s;
    reg [7:0] luma_r, luma_matrix;

    wire signed [23:0] v73  = (v_s <<< 6) + (v_s <<< 3) + v_s;
    wire signed [23:0] u101 = (u_s <<< 6) + (u_s <<< 5) + (u_s <<< 2) + u_s;
    wire signed [23:0] v149 = (v_s <<< 7) + (v_s <<< 4) + (v_s <<< 2) + v_s;
    wire signed [23:0] u130 = (u_s <<< 7) + (u_s <<< 1);

    reg signed [23:0] v73_r, u101_r, v149_r, u130_r;
    // Gain, then matrix products, each registered: two more samples of PIPE.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            u_s <= 0; v_s <= 0; luma_r <= 0; luma_matrix <= 0;
            v73_r <= 0; u101_r <= 0; v149_r <= 0; u130_r <= 0;
        end else begin
            u_s <= wide_input ? (ug >>> (12 + CHROMA_SHIFT + 2))
                             : (ug >>> (12 + CHROMA_SHIFT));
            v_s <= wide_input ? (vg >>> (12 + CHROMA_SHIFT + 2))
                             : (vg >>> (12 + CHROMA_SHIFT));
            luma_r <= luma;
            v73_r <= v73; u101_r <= u101; v149_r <= v149; u130_r <= u130;
            luma_matrix <= luma_r;
        end
    end
    wire signed [23:0] y_ext = {16'd0, luma_matrix};
    wire signed [23:0] r_raw = y_ext + (v73_r  >>> 6);
    wire signed [23:0] g_raw = y_ext - (u101_r >>> 8) - (v149_r >>> 8);
    wire signed [23:0] b_raw = y_ext + (u130_r >>> 6);

    wire [7:0] r_clip = r_raw[23] ? 8'd0 : (|r_raw[22:8] ? 8'd255 : r_raw[7:0]);
    wire [7:0] g_clip = g_raw[23] ? 8'd0 : (|g_raw[22:8] ? 8'd255 : g_raw[7:0]);
    wire [7:0] b_clip = b_raw[23] ? 8'd0 : (|b_raw[22:8] ? 8'd255 : b_raw[7:0]);
    // Clip by bits, not by a signed compare against 255 (apicula#541): once the
    // sign bit is clear, anything above bit 7 means more than 255.
    wire [23:0] rgb = (COLOUR && burst_locked) ? {r_clip, g_clip, b_clip}
                                              : {luma_matrix, luma_matrix, luma_matrix};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            thr <= 8'd64; fast_cnt <= 11'd0; f_min <= 8'hFF; f_max <= 8'h00;
            drop_track <= 8'd0; drop_ref <= 8'd0; slope_armed <= 1'b1;
            for (sj = 0; sj < 4; sj = sj + 1) sl_d[sj] <= 8'd0;
            below_d <= 1'b0; pcnt <= 16'd0; lowrun <= 16'd0; vs_hold <= 16'd0;
            sum7 <= 11'd0; mix_cnt <= 3'd0;
            u_acc <= 16'sd0; v_acc <= 16'sd0; u_lat <= 16'sd0; v_lat <= 16'sd0;
            for (di = 0; di < 7; di = di + 1) dl[di] <= 8'd0;
            for (di = 0; di < 7; di = di + 1) begin
                u_delay[di] <= 16'sd0; v_delay[di] <= 16'sd0;
            end
            for (di = 0; di < 4; di = di + 1) ref_delay[di] <= 32'd0;
            for (di = 0; di < 6; di = di + 1) y_delay[di] <= 8'd0;
            thr_lo <= 8'd60; below_lo_d <= 1'b0;
            lo_fall_pcnt <= 16'd0; lo_fall_seen <= 1'b0;
            hi_run <= 5'd0;
            lock_cnt <= 8'd0; ccnt <= 12'd0; period_out <= 16'd0; lag <= 12'd0;
            ccnt_real <= 12'd124;
            real_count <= 16'd0; force_count <= 16'd0; qual_count <= 16'd0;
            dmp_we <= 1'b0; dmp_addr <= {DUMP_AW{1'b0}}; dmp_data <= 8'd0;
            dmp_rdy <= 1'b0; dmp_cap <= 1'b0; dmp_arm <= 21'd0;
            period_avg <= P_NOM[15:0]; rcnt <= 16'd0; force_run <= 8'd0;
            line_in_field <= 9'd0; be_armed <= 1'b0;
            blank_end <= 12'd0; clip_count <= 16'd0;
            burst_min <= 8'hFF; burst_max <= 8'd0; vs_seen <= 1'b0;
            bmin_acc <= 8'hFF; bmax_acc <= 8'd0;
            line_in_field <= 9'd0; locked_st <= 1'b0;
            vertical_reacquire <= 1'b0;
            pfrac <= 8'd0; facc <= 8'd0; extra <= 1'b0;
            run_min <= 16'd0; run_min_acc <= 16'hFFFF; miss_count <= 16'd0;
            run_max <= 16'd0; run_max_acc <= 16'd0;
            run_peak <= 16'd0; run_lines <= 8'd0; peak_pend <= 1'b0;
            bp_acc <= 13'd0; black <= 8'd134; s_even <= 8'd0; clamp_win <= 1'b0;
            fp_line <= 8'd134; black_q <= 10'd536;
            for (hi = 0; hi < 16; hi = hi + 1) begin
                hist[hi]     <= 20'd0;
                hist_rep[hi] <= 20'd0;
            end
            wr_en <= 1'b0; wr_addr <= 11'd0; wr_data <= 24'd0; wr_bank <= 1'b0;
            line_done <= 1'b0; vsync_pulse <= 1'b0;
        end else begin
            wr_en       <= 1'b0;
            line_done   <= 1'b0;
            vsync_pulse <= 1'b0;

            dmp_we <= 1'b0;
            if (dmp_arm != 21'h1FFFFF) dmp_arm <= dmp_arm + 21'd1;
            if (dmp_ack) dmp_rdy <= 1'b0;
            if (sample_stb) begin
                if (dmp_cap) begin
                    dmp_we   <= 1'b1;
                    dmp_addr <= dmp_addr + 1'b1;
                    // dl[0] is the decoder's previous ADC sample. The raw tap
                    // in mode 3 is one sample newer. An earlier apparent bit
                    // difference between these taps was a stale capture-card
                    // frame, not proof of an input timing fault (CLAUDE.md).
                    dmp_data <= (SCOPE_TEST_RAMP == 1) ? 8'hAA
                              : (SCOPE_TEST_RAMP == 2) ? dmp_addr[10:3]
                              : (SCOPE_TEST_RAMP == 3) ? adc_r
                              : dl[0];
                    if (&dmp_addr) begin
                        dmp_cap <= 1'b0;
                        dmp_rdy <= 1'b1;
                    end
                // SCOPE_FREERUN arms on the timer alone.  Without it the dump
                // waits for a detected line, so with no source connected the
                // buffer is never written and the scope shows its power-up
                // zeros -- which reads as "every ADC pin is low" and is not a
                // measurement of the pins at all.  That wasted a test.
                end else if ((SCOPE_LIVE || !dmp_rdy) &&
                             dmp_arm == 21'h1FFFFF &&
                             (SCOPE_FREERUN != 0 ||
                              (line_edge &&
                               line_in_field > ((SCOPE_TEST_RAMP == 6) ? 9'd200 : 9'd40) &&
                               line_in_field < 9'd230))) begin
                    dmp_cap  <= 1'b1;
                    dmp_addr <= {DUMP_AW{1'b0}};
                    dmp_arm  <= 21'd0;
                end
            end

            // One clock for the read-modify-write; at 126 MHz it took two.
            if (in_active) hist[adc_r[7:4]] <= hist[adc_r[7:4]] + 20'd1;

            if (sample_stb) begin
                below_d <= below;

                below_lo_d <= below_lo;

                dl[0] <= adc_r;
                for (di = 1; di < 7; di = di + 1) dl[di] <= dl[di-1];
                sum7 <= sum7 + {3'd0, adc_r} - {3'd0, dl[6]};

                ref_delay[0] <= nco_ref;
                y_delay[0] <= luma_lp;
                for (di = 1; di < 4; di = di + 1) ref_delay[di] <= ref_delay[di-1];
                for (di = 1; di < 6; di = di + 1) y_delay[di] <= y_delay[di-1];
                u_delay[0] <= u_mix; v_delay[0] <= v_mix;
                for (di = 1; di < 7; di = di + 1) begin
                    u_delay[di] <= u_delay[di-1];
                    v_delay[di] <= v_delay[di-1];
                end
                u_acc <= u_next; v_acc <= v_next;
                u_lat <= u_next; v_lat <= v_next;
                if (lo_fall) begin
                    lo_fall_pcnt <= pcnt;
                    lo_fall_seen <= 1'b1;
                end

                // Mode 4 repurposes this counter, and its existing on-screen
                // bar, to answer one question without touching the dump path:
                // does adc_r ever have bit 6 set?  The dump says never, which
                // would mean no sample lands between 64 and 127 -- while the
                // picture plainly shows bars there.  This counter is read by
                // the hardware straight off adc_r, so it settles which of the
                // two is lying, inside a single bitstream.
                // Mode 5 is the positive control mode 4 needs: bit 5 is set in
                // about two thirds of the dumped samples, so if its bar is also
                // empty the counter is broken and mode 4 proves nothing.
                // Mode 7 counts the AD9280's own out-of-range flag, which this
                // design otherwise declares and ignores.  The top three bars sit
                // at exactly 179 -- 0xB3, the largest value expressible with
                // bits 2, 3 and 6 stuck at zero -- and three different bars
                // reading the same maximum is what saturation looks like.  OTR
                // says whether that saturation is the analog input leaving the
                // converter's range, or something after it.
                if ((SCOPE_TEST_RAMP == 4) ? adc_r[6] :
                    (SCOPE_TEST_RAMP == 5) ? adc_r[5] :
                    (SCOPE_TEST_RAMP == 7) ? otr_r : (adc_r <= 8'd2))
                    clip_count <= clip_count + 16'd1;

                if (in_burst && line_in_field > 9'd40 && line_in_field < 9'd230)
                begin
                    if (adc_r < bmin_acc) bmin_acc <= adc_r;
                    if (adc_r > bmax_acc) bmax_acc <= adc_r;
                end
                if (vs_seen) begin
                    vs_seen   <= 1'b0;
                    burst_min <= bmin_acc; burst_max <= bmax_acc;
                    bmin_acc  <= 8'hFF;    bmax_acc  <= 8'd0;
                end

                if (line_edge)            be_armed  <= 1'b1;
                else if (be_armed && !below) begin
                    be_armed  <= 1'b0;
                    blank_end <= ccnt;
                end

                if (line_edge && line_in_field != 9'd511)
                    line_in_field <= line_in_field + 9'd1;

                if (line_real)              rcnt <= 16'd1;
                else if (rcnt != 16'hFFFF)  rcnt <= rcnt + 16'd1;

                if (below && lowrun > run_max_acc) run_max_acc <= lowrun;
                if (sync_qual) qual_count <= qual_count + 16'd1;
                if (line_edge) peak_pend <= 1'b1;
                if (peak_pend && !below) begin
                    peak_pend <= 1'b0;
                    run_peak  <= 16'd0;
                    if (run_peak < QUALIFY[15:0]) miss_count <= miss_count + 16'd1;
                    if (run_peak < run_min_acc) run_min_acc <= run_peak;
                    run_lines <= run_lines + 8'd1;
                    if (run_lines == 8'hFF) begin
                        run_min     <= (run_peak < run_min_acc) ? run_peak
                                                                : run_min_acc;
                        run_min_acc <= 16'hFFFF;
                        run_max     <= run_max_acc;
                        run_max_acc <= 16'd0;
                    end
                end else if (below && lowrun > run_peak) begin
                    run_peak <= lowrun;
                end

                if (lock_cnt >= 8'd48)     locked_st <= 1'b1;
                else if (lock_cnt <= 8'd8) locked_st <= 1'b0;

                if (line_edge) begin
                    pcnt       <= 16'd1;   // may be overridden just below
                    // pcnt is reset by a forced start too, so on a late
                    // correction it holds a fragment of a line.  rcnt counts
                    // real edge to real edge and is the period that matters.
                    period_out <= line_real ? rcnt : pcnt;
                    {extra, facc} <= {1'b0, facc} + {1'b0, pfrac};
                    if (line_real) begin
                        vertical_reacquire <= 1'b0;
                        real_count <= real_count + 16'd1;
                        force_run  <= 8'd0;
                        lag        <= 12'd0;
                        if (lock_cnt != 8'hFF) lock_cnt <= lock_cnt + 8'd1;
                        if (acquiring) begin
                            if (rcnt >= P_MIN[15:0] && rcnt <= P_MAX[15:0])
                                period_avg <= rcnt;
                        end else if (period_plausible) begin
                            {period_avg, pfrac} <= period_next;
                        end
                    end else begin
                        force_count <= force_count + 16'd1;
                        if (force_run != 8'hFF) force_run <= force_run + 8'd1;
                        lag <= lag_next;
                        lock_cnt <= (lock_cnt == 8'd0) ? 8'd0 : lock_cnt - 8'd1;
                        if (force_run >= FORCE_GIVEUP) begin
                            lock_cnt <= 8'd0;
                            locked_st <= 1'b0;
                        end
                    end
                end else if (pcnt != 16'hFFFF) begin
                    pcnt <= pcnt + 16'd1;
                end

                if (below) begin
                    hi_run <= 5'd0;
                    if (lowrun != 16'hFFFF) lowrun <= lowrun + 16'd1;
                end else if (hi_run >= GLITCH[4:0]) begin
                    lowrun <= 16'd0;
                end else begin
                    hi_run <= hi_run + 5'd1;
                end
                if (vs_hold != 16'd0) begin
                    vs_hold <= vs_hold - 16'd1;
                end else if (below && (lowrun == VS_MIN)) begin
                    vs_hold     <= VS_REFRACT;
                    vsync_pulse <= 1'b1;
                    vertical_reacquire <= 1'b1;
                    vs_seen     <= 1'b1;
                    line_in_field <= 9'd0;
                    for (hi = 0; hi < 16; hi = hi + 1) begin
                        hist_rep[hi] <= hist[hi];
                        hist[hi]     <= 20'd0;
                    end
                end

                sl_d[0] <= adc_lp;
                sl_d[1] <= sl_d[0];
                sl_d[2] <= sl_d[1];
                sl_d[3] <= sl_d[2];
                if (drop > drop_track) drop_track <= drop;
                if (slope_fall)        slope_armed <= 1'b0;
                else if (drop == 8'd0) slope_armed <= 1'b1;

                if (adc_lp < f_min)       f_min <= f_min - 8'd1;
                else if (fast_cnt[RELEASE-1:0] == {RELEASE{1'b1}} && f_min != 8'hFF)
                    f_min <= f_min + 8'd1;
                if (adc_lp > f_max)       f_max <= f_max + 8'd1;
                else if (fast_cnt[RELEASE-1:0] == {RELEASE{1'b1}} && f_max != 8'h00)
                    f_max <= f_max - 8'd1;

                thr      <= f_min + thr_off;
                thr_lo   <= f_min + thr_lo_off;
                fast_cnt <= fast_cnt + 11'd1;

                if (fast_cnt == FAST_WIN - 1) begin
                    drop_ref   <= drop_track;
                    drop_track <= 8'd0;
                end

                clamp_win <= (ccnt >= CLAMP_START) && (ccnt < CLAMP_STOP);

                // A forced start fires FMARGIN samples after where the last
                // real edge would have been, so it inherits that edge's
                // position -- lag supplies the margin.  It used to assume a
                // 4.7 us sync (124), which put every forced line up to 17
                // samples early on a source whose sync measures longer, and
                // opened the burst gate on the sync tip.
                if (line_edge) begin
                    ccnt <= LEGACY_TIMING ? 12'd0 :
                            (line_real ? lowrun + LPF_DELAY + 1 : ccnt_real);
                    if (line_real) ccnt_real <= lowrun + LPF_DELAY + 1;
                end else if (ccnt != 12'hFFF) begin
                    ccnt <= ccnt + 12'd1;
                end

                if (cpos == BP_START - 1) begin
                    bp_acc <= 13'd0;
                end else if (in_bp) begin
                    bp_acc <= bp_acc + {5'd0, adc_r};
                end else if (cpos == BP_END) begin
                    if (LEGACY_TIMING) begin
                        black <= bp_acc[12:5];        // 32-sample average
                    end else begin
                        // max(front porch, back porch), then black_q is black
                        // times four and moves a quarter of the way each line.
                        black_q <= black_q + {2'd0, porch_max} - {2'd0, black_q[9:2]};
                        black   <= black_q[9:2];
                    end
                end
                if (line_real) fp_line <= fp_cand;   // this line's front porch

                if (in_write) begin
                    if (!a_idx[0]) begin
                        s_even <= adc_r;
                    end else begin
                        wr_en   <= 1'b1;
                        wr_addr <= {wr_bank, a_idx[10:1]};
                        wr_data <= rgb;
                        if (a_idx == 2 * ACTIVE_PIXELS - 1) begin
                            // Publish only after every pixel was written.
                            // Sync detection and free-running position wrap
                            // must never announce a partially filled bank.
                            wr_bank <= ~wr_bank;
                            line_done <= 1'b1;
                        end
                    end
                end
            end
        end
    end
    burst_nco #(.TRACK_GAP_SAMPLES(BURST_GAP_SAMPLES)) u_nco (
        .clk(clk), .rst_n(rst_n), .sample_en(sample_stb),
        .sample(adc_r), .blank_ref(black), .burst_gate(in_burst),
        // A line start inside the gate -- a real edge arriving just after a
        // forced one -- restarts the integration, so samples taken on the
        // forced timing (sync tip, on a late line) never reach the angle.
        .gate_restart(line_edge),
        .phase(nco_phase), .inc(),
        .burst_i(burst_corr_i), .burst_q(burst_corr_q),
        .locked(burst_locked), .good_lines(), .phase_ref(nco_ref)
    );

endmodule

`default_nettype wire
