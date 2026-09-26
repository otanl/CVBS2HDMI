`default_nettype none

// Composite NTSC-J -> AD9280 -> 640x480p DVI-compatible HDMI.
// One 126 MHz PLL supplies the serializer clock and, divided by five, the
// 25.2 MHz pixel clock, on which the whole decoder runs at one sample per
// clock; 126 MHz otherwise reaches only the converter's clock.  Completed
// input lines are bob displayed through an ownership-protected four-bank line
// store. S1 toggles diagnostics; S2 steps the converter clock's rotation (used
// only with the calibration off). Default output is the decoded image.

module top_ntsc_hdmi #(
    parameter [3:0] DEFAULT_PHASE = 4'd0,   // rotation, with calibration off
    parameter       HUNT_PHASE    = 1'b0,
    parameter       SCOPE_ONLY    = 1'b0,
    parameter       FRAME_ALIGN   = 1'b1,
    parameter       LEGACY_TIMING = 1'b0,
    parameter       SCOPE_FULL_RANGE = 1'b0,
    parameter integer SCOPE_TEST_RAMP = 0,
    parameter integer CLAMP_FORCE    = 0,
    parameter integer SCOPE_FREERUN  = 0,
    parameter integer SCOPE_DIV   = 3,
    // Record 32768 consecutive ADC samples once, freeze them, and show them as
    // grey nibble cells instead of a picture: scripts/tape_decode.py turns a
    // captured frame back into the samples, for replay through the decoder in
    // simulation.  The serial link on this board has never been dependable;
    // the HDMI output always has.
    parameter         TAPE        = 1'b0,
    // adc_front's counting window, 2^ADC_WIN_W samples.  Benches shorten it.
    parameter integer ADC_WIN_W   = 14,
    // Show adc_front's state in the bottom four rows of the picture.
    parameter         ADC_STRIP   = 1'b1,
    parameter         ADC_CLK_SWAP = 1'b0,
    // Diagnostic: the calibration off, the rotation stepping 0..9 every
    // 0.67 s, and each bit's two difference counts in the strip.
    parameter         ADC_DIAG    = 1'b0,
    // Which end of an 8Angle knob is "off".  Measured on the unit here: all
    // eight turned fully left read 253..255, so the value is inverted and a
    // knob turned left is zero.
    parameter         KNOB_INVERT = 1'b1,
    parameter [7:0]   KNOB_DEAD   = 8'd16
) (
    input  wire       clk27,

    input  wire [7:0] adc_d,
    input  wire       adc_otr,
    output wire       adc_clk,
    output wire       adc_clamp,

    input  wire [1:0] btn_n,
    output wire [5:0] led_n,
    output wire       uart_tx_pin,

    // M5Stack Unit 8Angle on Grove J4/J5 (src/angle8.v).  Open drain: only
    // ever pulled low from here.
    inout  wire       i2c_scl,
    inout  wire       i2c_sda,

    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);
    localparam [10:0] H_TOTAL  = 11'd801;
    localparam [10:0] V_ACTIVE = 11'd480;
    localparam [10:0] V_FRONT  = 11'd10;

    wire serial_clk, vid_lock, pixel_clk;
    reg vid_lock_stable = 1'b0;
    rpll_126 pll_vid (.clkin(clk27), .clkout(serial_clk), .lock(vid_lock));

    CLKDIV pixel_clock_divider (
        .CLKOUT(pixel_clk), .HCLKIN(serial_clk),
        .RESETN(vid_lock_stable), .CALIB(1'b0)
    );
    defparam pixel_clock_divider.DIV_MODE = "5";
    defparam pixel_clock_divider.GSREN    = "false";

    reg [11:0] lock_filter = 12'd0;
    always @(posedge serial_clk) begin
        if (vid_lock) begin
            if (lock_filter != 12'hFFF) lock_filter <= lock_filter + 12'd1;
        end else begin
            lock_filter <= (lock_filter > 12'd0) ? lock_filter - 12'd1 : 12'd0;
        end
        if (lock_filter == 12'hFFF) vid_lock_stable <= 1'b1;
        else if (lock_filter == 12'd0) vid_lock_stable <= 1'b0;
    end

    reg [3:0] vid_reset_pipe = 4'b0000;
    always @(posedge pixel_clk) begin
        if (!vid_lock_stable) vid_reset_pipe <= 4'b0000;
        else           vid_reset_pipe <= {vid_reset_pipe[2:0], 1'b1};
    end
    wire vid_rst_n = vid_reset_pipe[3];

    wire        wr_en;
    wire [10:0] wr_addr;
    wire [23:0] wr_data;
    wire        wr_bank;
    wire         line_done, vsync_pulse, sync_locked;
    wire [15:0]  line_period;
    wire [7:0]   s_min, s_max, s_thr, lock_level;
    wire [15:0]  force_count, run_min, run_max, qual_count, miss_count, clip_count;
    wire [11:0]  blank_end;
    wire [7:0]   burst_min, burst_max;
    wire [31:0]  nco_phase;
    wire         burst_locked;
    wire signed [15:0] burst_corr_i, burst_corr_q;
    wire [15:0]  real_count;
    wire         dmp_we, dmp_rdy, dmp_ack;
    localparam integer DUMP_AW = TAPE ? 15 : 11;
    wire [DUMP_AW-1:0] dmp_addr;
    wire [10:0]  dmp_raddr;
    wire [7:0]   dmp_data, dmp_rdata;
    wire [7:0]   black_level;
    wire [255:0] hist_flat;

    reg [1:0]  btn_meta, btn_sync, btn_stable;
    reg [19:0] btn_timer;
    reg [21:0] btn_inhibit;
    reg [3:0]  phase_sel;    // converter clock rotation, 0..9
    wire [3:0] phase_used;   // the rotation in use
    wire       adc_cal_done;
    wire [5:0] adc_sweeps;
    reg  [3:0] adc_dbg_rot = 4'd0;
    wire [15:0] adc_dbg_cx, adc_dbg_cy, adc_dbg_bx, adc_dbg_by;
    wire [15:0] dbg_line_i, dbg_line_q;
    wire [31:0] dbg_line_angle, dbg_line_off;
    wire        dbg_line_fresh;
    reg  [23:0] diag_timer = 24'd0;
    reg  [3:0]  diag_rot = 4'd0;
    always @(posedge pixel_clk) begin
        diag_timer <= diag_timer + 24'd1;
        if (&diag_timer) diag_rot <= (diag_rot == 4'd9) ? 4'd0 : diag_rot + 4'd1;
    end
    wire       adc_pair_x;
    wire [15:0] adc_track;
    reg [1:0]  gain_sel;
    reg        scope_only;
    reg [26:0] hunt_cnt;
    always @(posedge pixel_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            btn_meta <= 2'b11; btn_sync <= 2'b11; btn_stable <= 2'b11;
            btn_timer <= 20'd0; phase_sel <= DEFAULT_PHASE; gain_sel <= 2'd0;
            scope_only <= SCOPE_ONLY;
            btn_inhibit <= 22'd0; hunt_cnt <= 27'd0;
        end else begin
            if (sync_locked) begin
                hunt_cnt <= 27'd0;
            end else if (!HUNT_PHASE || lock_level >= 8'd16) begin
                hunt_cnt <= 27'd0;
            end else if (hunt_cnt == 27'd25_199_999) begin    // 1 s per rotation
                hunt_cnt  <= 27'd0;
                phase_sel <= (phase_sel == 4'd9) ? 4'd0 : phase_sel + 4'd1;
            end else begin
                hunt_cnt <= hunt_cnt + 27'd1;
            end
            if (btn_inhibit != 22'h3FFFFF) btn_inhibit <= btn_inhibit + 22'd1;
            btn_meta <= btn_n;
            btn_sync <= btn_meta;
            if (btn_sync != btn_stable) begin
                if (btn_timer == 20'hFFFFF) begin
                    btn_timer <= 20'd0;
                    if (btn_inhibit == 22'h3FFFFF) begin
                        if (btn_stable[1] && !btn_sync[1])
                            phase_sel <= (phase_sel == 4'd9) ? 4'd0 : phase_sel + 4'd1;
                        if (btn_stable[0] && !btn_sync[0])
                            scope_only <= ~scope_only;
                    end
                    btn_stable <= btn_sync;
                end else begin
                    btn_timer <= btn_timer + 20'd1;
                end
            end else begin
                btn_timer <= 20'd0;
            end
        end
    end

    // ---- the Unit 8Angle: glitch controls ------------------------------------
    // Eight knobs, each breaking one stage of the decoder (ntsc_capture's fx_*,
    // and the vertical roll below).  A knob turned fully left is off: a dead
    // band of KNOB_DEAD counts keeps the picture exactly clean there whatever
    // the converter's noise.  The switch in the green position (as the
    // diagnostic view shows it) enables them, and nothing acts while the unit
    // is not answering.
    wire i2c_scl_low, i2c_sda_low;
    assign i2c_scl = i2c_scl_low ? 1'b0 : 1'bz;
    assign i2c_sda = i2c_sda_low ? 1'b0 : 1'bz;
    wire [63:0] knobs;
    wire        knob_sw, knob_present;
    angle8 knob_unit (
        .clk(pixel_clk), .rst_n(vid_rst_n),
        .scl_in(i2c_scl), .sda_in(i2c_sda),
        .scl_low(i2c_scl_low), .sda_low(i2c_sda_low),
        .knobs(knobs), .sw(knob_sw), .present(knob_present), .scans()
    );
    wire        fx_on = knob_present && knob_sw;
    wire [63:0] fx;
    genvar ki;
    generate
        for (ki = 0; ki < 8; ki = ki + 1) begin : g_fx
            wire [7:0] kraw = KNOB_INVERT ? ~knobs[8*ki +: 8] : knobs[8*ki +: 8];
            assign fx[8*ki +: 8] = (fx_on && kraw > KNOB_DEAD) ? kraw - KNOB_DEAD : 8'd0;
        end
    endgenerate

    ntsc_capture #(.LEGACY_TIMING(LEGACY_TIMING),
                   .SCOPE_TEST_RAMP(SCOPE_TEST_RAMP),
                                      .CLAMP_FORCE(CLAMP_FORCE),
                   .SCOPE_FREERUN(SCOPE_FREERUN),
                   // A tape is recorded once and held: re-recording while it
                   // is on screen would mix two recordings in one frame.
                   .DUMP_AW(DUMP_AW), .SCOPE_LIVE(!TAPE),
                   .ADC_WIN_W(ADC_WIN_W), .ADC_CLK_SWAP(ADC_CLK_SWAP),
                   .ADC_DIAG(ADC_DIAG), .AUTO_PHASE(!ADC_DIAG)) capture (
        .clk(pixel_clk), .fclk(serial_clk), .rst_n(vid_rst_n),
        .adc_d(adc_d), .adc_otr(adc_otr),
        .adc_clk(adc_clk), .adc_clamp(adc_clamp),
        .rot_sel(ADC_DIAG ? diag_rot : phase_sel), .fx(fx), .rot_in_use(phase_used),
        .adc_cal_done(adc_cal_done),
        .adc_sweeps(adc_sweeps), .adc_pair_x(adc_pair_x), .adc_track(adc_track),
        .adc_dbg_rot(adc_dbg_rot), .adc_dbg_cx(adc_dbg_cx), .adc_dbg_cy(adc_dbg_cy),
        .adc_dbg_bit(adc_dbg_rot[2:0]), .adc_dbg_bx(adc_dbg_bx), .adc_dbg_by(adc_dbg_by),
        .dbg_line_i(dbg_line_i), .dbg_line_q(dbg_line_q), .dbg_line_angle(dbg_line_angle),
        .dbg_line_off(dbg_line_off), .dbg_line_fresh(dbg_line_fresh),
        .gain_sel(gain_sel),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .wr_bank(wr_bank),
        .line_done(line_done), .vsync_pulse(vsync_pulse),
        .sync_locked(sync_locked), .period_out(line_period),
        .slice_min(s_min), .slice_max(s_max), .slice_thr(s_thr),
        .lock_level(lock_level), .real_count(real_count),
        .force_count(force_count), .run_min(run_min), .run_max(run_max),
        .qual_count(qual_count), .miss_count(miss_count),
        .blank_end(blank_end), .clip_count(clip_count),
        .burst_min(burst_min), .burst_max(burst_max),
        .nco_phase(nco_phase), .burst_locked(burst_locked),
        .burst_corr_i(burst_corr_i), .burst_corr_q(burst_corr_q),
        .dmp_we(dmp_we), .dmp_addr(dmp_addr), .dmp_data(dmp_data),
        .dmp_rdy(dmp_rdy), .dmp_ack(TAPE ? 1'b0 : dmp_ack),
        .black_out(black_level),
        .hist_flat(hist_flat)
    );

    reg vs_toggle;
    always @(posedge pixel_clk or negedge vid_rst_n) begin
        if (!vid_rst_n)        vs_toggle <= 1'b0;
        else if (vsync_pulse)  vs_toggle <= ~vs_toggle;
    end

    reg [2:0] vs_tog_sync;
    reg [2:0] bank_sync;
    always @(posedge pixel_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            vs_tog_sync <= 3'b000;
            bank_sync   <= 3'b000;
        end else begin
            vs_tog_sync <= {vs_tog_sync[1:0], vs_toggle};
            bank_sync   <= {bank_sync[1:0], wr_bank};
        end
    end
    wire vs_event = vs_tog_sync[2] ^ vs_tog_sync[1];

    wire [10:0] x, y;
    wire        active, hsync, vsync;

    wire line_end = (x == H_TOTAL - 11'd1);

    reg [2:0] lock_sync;
    always @(posedge pixel_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) lock_sync <= 3'b000;
        else            lock_sync <= {lock_sync[1:0], sync_locked};
    end

    reg [10:0] y_at_field;
    reg        v_longer, v_shorter;

    localparam [10:0] V_TARGET = 11'd488;
    // fx[23:16], vertical hold: the servo's target walks on by fx/256 of a line
    // every frame, and the servo, which only ever trims one line a frame so the
    // sink keeps its lock, follows it -- the picture rolls.  Knob off, the
    // target comes home and the servo walks the picture back, a line a frame.
    wire [7:0]  fx_vroll = fx[23:16];
    reg  [9:0]  v_off = 10'd0;
    reg  [7:0]  v_frac = 8'd0;
    wire [8:0]  v_frac_next = {1'b0, v_frac} + {1'b0, fx_vroll};
    always @(posedge pixel_clk) begin
        if (fx_vroll == 8'd0) begin
            v_off <= 10'd0; v_frac <= 8'd0;
        end else if (x == 11'd0 && y == 11'd0) begin
            v_frac <= v_frac_next[7:0];
            if (v_frac_next[8]) v_off <= (v_off == 10'd524) ? 10'd0 : v_off + 10'd1;
        end
    end
    wire [10:0] v_tsum   = V_TARGET + {1'b0, v_off};
    wire [10:0] v_target = (v_tsum >= 11'd525) ? v_tsum - 11'd525 : v_tsum;
    wire [10:0] y_rel = (y >= v_target) ? (y - v_target)
                                        : (y + 11'd525 - v_target);
    always @(posedge pixel_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            y_at_field <= 11'd0; v_longer <= 1'b0; v_shorter <= 1'b0;
        end else if (vs_event && lock_sync[2]) begin
            y_at_field <= y_rel;
            v_longer  <= FRAME_ALIGN && (y_rel > 11'd1)   && (y_rel < 11'd263);
            v_shorter <= FRAME_ALIGN && (y_rel >= 11'd263) && (y_rel < 11'd524);
        end
    end

    reg align_pending;
    always @(posedge pixel_clk or negedge vid_rst_n) begin
        if (!vid_rst_n)                    align_pending <= 1'b0;
        else if (FRAME_ALIGN && vs_event && lock_sync[2]) align_pending <= 1'b1;
        else if (line_end)                 align_pending <= 1'b0;
    end

    video_timing #(
        .H_ACTIVE(11'd640), .H_FRONT(11'd16), .H_SYNC(11'd96), .H_TOTAL(H_TOTAL),
        .V_ACTIVE(11'd480), .V_FRONT(11'd10), .V_SYNC(11'd2),  .V_TOTAL(11'd525),
        .SYNC_POS(1'b0)
    ) timing (
        .pixel_clk(pixel_clk), .reset_n(vid_rst_n),
        .vsync_align(1'b0),
        .v_longer(v_longer), .v_shorter(v_shorter),
        .x(x), .y(y), .active(active), .hsync(hsync), .vsync(vsync)
    );

    wire [23:0] pixel_rgb;
    wire pixel_valid;

    video_line_store linebuf (
        .wr_clk(pixel_clk), .wr_reset_n(vid_rst_n), .wr_en(wr_en),
        .wr_x(wr_addr[9:0]), .wr_data(wr_data), .wr_done(line_done),
        .rd_clk(pixel_clk), .rd_reset_n(vid_rst_n), .rd_line_end(line_end),
        .rd_x(x[9:0]), .rd_data(pixel_rgb), .rd_valid(pixel_valid)
    );

    reg active_d, hsync_d, vsync_d;
    always @(posedge pixel_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            active_d <= 1'b0; hsync_d <= 1'b1; vsync_d <= 1'b1;
        end else begin
            active_d <= active; hsync_d <= hsync; vsync_d <= vsync;
        end
    end

    reg [3:0] sys_reset_pipe = 4'b0000;
    always @(posedge clk27) sys_reset_pipe <= {sys_reset_pipe[2:0], 1'b1};

    wire [10:0] scope_addr = (SCOPE_DIV == 3)
                           ? ({x[9:0], 1'b0} + {1'b0, x[9:0]})
                           : {1'b0, x[9:0]};

    // Tape layout, 640 x 480: rows 0-7 identity bits, rows 8-15 a calibration
    // staircase of the sixteen grey levels, rows 16-425 the samples.  Each
    // sample is two 4-pixel cells, high nibble first, grey = 16 + 14 * nibble,
    // so 80 samples a row.  Sixteen levels 14 apart survive the capture card's
    // RGB -> YUV422 -> RGB trip and its horizontal filtering, which dims a
    // one-pixel mark by a third; four-pixel cells are read at their centre.
    localparam [10:0] TAPE_ROW0 = 11'd16;
    wire [10:0] tape_row  = y - TAPE_ROW0;
    wire [14:0] tape_addr = {tape_row[8:0], 6'd0} + {2'd0, tape_row[8:0], 4'd0}
                          + {8'd0, x[9:3]};

    wire [DUMP_AW-1:0] scope_addr_w = scope_addr;   // zero-extended

    line_buffer #(.ADDR_WIDTH(DUMP_AW), .DATA_WIDTH(8)) dumpbuf (
        .wr_clk(pixel_clk), .wr_en(dmp_we), .wr_addr(dmp_addr),
        .wr_data(dmp_data),
        .rd_clk(pixel_clk),
        .rd_addr(TAPE ? tape_addr[DUMP_AW-1:0] : scope_addr_w),
        .rd_data(dmp_rdata)
    );

    wire [11:0] trace_mul = ({4'd0, dmp_rdata} << 4) - {4'd0, dmp_rdata}; // x15
    // Full range keeps all 256 ADC codes below the diagnostic bars.
    wire [10:0] trace_y   = SCOPE_FULL_RANGE ? (11'd479 - {3'd0, dmp_rdata})
                                           : (11'd479 - trace_mul[11:3]);
    wire [10:0] thr_mul   = ({3'd0, s_thr} << 4) - {3'd0, s_thr};
    wire [10:0] thr_y     = SCOPE_FULL_RANGE ? (11'd479 - {3'd0, s_thr})
                                           : (11'd479 - thr_mul[10:3]);

    reg [10:0] y_d;
    reg        scope_sync;
    always @(posedge pixel_clk) begin
        y_d        <= y;
        scope_sync <= scope_only;
    end

    wire below_thr = (dmp_rdata < s_thr);

    wire on_trace = scope_sync && (y_d + 11'd3 >= trace_y) && (trace_y + 11'd3 >= y_d);
    wire on_thr   = scope_sync && (y_d == thr_y);
    reg [15:0] vs_cnt, vs_rate, qc_prev, qc_rate, mc_prev, mc_rate, cl_prev, cl_rate;
    reg [15:0] rc_prev, rc_rate, fc_prev, fc_rate;
    reg [22:0] rate_win;
    always @(posedge pixel_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            rate_win <= 23'd0;
            vs_cnt <= 16'd0; vs_rate <= 16'd0;
            rc_prev <= 16'd0; rc_rate <= 16'd0;
            fc_prev <= 16'd0; fc_rate <= 16'd0;
            qc_prev <= 16'd0; qc_rate <= 16'd0;
            mc_prev <= 16'd0; mc_rate <= 16'd0;
            cl_prev <= 16'd0; cl_rate <= 16'd0;
        end else if (rate_win == 23'd6_299_999) begin // a quarter second
            rate_win <= 23'd0;
            rc_rate  <= real_count  - rc_prev;
            fc_rate  <= force_count - fc_prev;
            qc_rate  <= qual_count - qc_prev;
            mc_rate  <= miss_count - mc_prev;
            cl_rate  <= clip_count - cl_prev;
            cl_prev  <= clip_count;
            mc_prev  <= miss_count;
            qc_prev  <= qual_count;
            rc_prev  <= real_count;
            fc_prev  <= force_count;
            vs_rate  <= vs_cnt;
            vs_cnt   <= 16'd0;
        end else if (vs_event) begin
            vs_cnt   <= vs_cnt + 16'd1;
            rate_win <= rate_win + 23'd1;
        end else begin
            rate_win <= rate_win + 23'd1;
        end
    end

    wire on_lock = (y_d < 11'd8) && (x < {2'd0, lock_level, 1'b0});
    wire [20:0] rate_scaled = (({5'd0, rc_rate} << 2) + {5'd0, rc_rate}) >> 5;
    wire [20:0] frc_scaled  = (({5'd0, fc_rate} << 2) + {5'd0, fc_rate}) >> 5;
    wire on_frc = (y_d >= 11'd24) && (y_d < 11'd32) &&
                  (x < (frc_scaled > 21'd640 ? 11'd640 : frc_scaled[10:0]));
    wire [20:0] mc_scaled = (({5'd0, mc_rate} << 2) + {5'd0, mc_rate}) >> 5;
    wire on_run  = (y_d >= 11'd36) && (y_d < 11'd44) &&
                   (x < (mc_scaled > 21'd640 ? 11'd640 : mc_scaled[10:0]));
    wire on_qtick = (y_d >= 11'd34) && (y_d < 11'd46) &&
                    (x >= 11'd263) && (x < 11'd266);
    wire on_yaf = (y_d >= 11'd48) && (y_d < 11'd56) && (x < y_at_field);
    wire [20:0] vs_scaled = {5'd0, vs_rate} << 2;
    wire on_vsr = (y_d >= 11'd60) && (y_d < 11'd68) &&
                  (x < (vs_scaled > 21'd640 ? 11'd640 : vs_scaled[10:0]));
    wire on_vtick = (y_d >= 11'd58) && (y_d < 11'd70) &&
                    (x >= 11'd59) && (x < 11'd62);
    wire [20:0] rmax_scaled = {5'd0, run_max} >> 2;
    wire on_rmax = (y_d >= 11'd72) && (y_d < 11'd80) &&
                   (x < (rmax_scaled > 21'd640 ? 11'd640 : rmax_scaled[10:0]));
    wire on_mtick = (y_d >= 11'd70) && (y_d < 11'd82) &&
                    (x >= 11'd511) && (x < 11'd514);
    wire [10:0] ph_slot  = x / 11'd24;
    wire        on_phase = (y_d >= 11'd84) && (y_d < 11'd96) &&
                           (x < 11'd240) && (x % 11'd24 < 11'd20);
    wire        ph_here  = (ph_slot == {7'd0, phase_used});
    wire [20:0] qc_scaled = (({5'd0, qc_rate} << 2) + {5'd0, qc_rate}) >> 6;
    wire on_qual = (y_d >= 11'd100) && (y_d < 11'd108) &&
                   (x < (qc_scaled > 21'd640 ? 11'd640 : qc_scaled[10:0]));

    wire on_lmin = (y_d >= 11'd112) && (y_d < 11'd118) && (x < {2'd0, s_min, 1'b0});
    wire on_lblk = (y_d >= 11'd120) && (y_d < 11'd126) && (x < {2'd0, black_level, 1'b0});
    wire on_lmax = (y_d >= 11'd128) && (y_d < 11'd134) && (x < {2'd0, s_max, 1'b0});
    wire on_bend = (y_d >= 11'd136) && (y_d < 11'd142) && (x < {1'b0, blank_end[11:2], 1'b0});
    wire [20:0] cl_scaled = (({5'd0, cl_rate} << 2) + {5'd0, cl_rate}) >> 5;
    wire on_clip = (y_d >= 11'd144) && (y_d < 11'd150) &&
                   (x < (cl_scaled > 21'd640 ? 11'd640 : cl_scaled[10:0]));
    wire on_bmin = (y_d >= 11'd152) && (y_d < 11'd158) && (x < {2'd0, burst_min, 1'b0});
    wire on_bmax = (y_d >= 11'd160) && (y_d < 11'd166) && (x < {2'd0, burst_max, 1'b0});

    wire signed [15:0] ci = burst_corr_i[15] ? -burst_corr_i : burst_corr_i;
    wire signed [15:0] cq = burst_corr_q[15] ? -burst_corr_q : burst_corr_q;
    wire on_ci   = (y_d >= 11'd168) && (y_d < 11'd174) && (x < ci[10:0]);
    wire on_cq   = (y_d >= 11'd176) && (y_d < 11'd182) && (x < cq[10:0]);
    wire on_clk_ = (y_d >= 11'd184) && (y_d < 11'd192) && (x < 11'd64) && burst_locked;
    wire on_qtick2 = (y_d >= 11'd98) && (y_d < 11'd110) &&
                     (x >= 11'd306) && (x < 11'd309);
    wire on_rate = (y_d >= 11'd12) && (y_d < 11'd20) &&
                   (x < (rate_scaled > 21'd640 ? 11'd640 : rate_scaled[10:0]));

    ntsc_status status (
        .clk27(clk27), .rst_n(sys_reset_pipe[3]),
        .pll_lock(vid_lock),
        .sync_locked(sync_locked), .lock_level(lock_level),
        .real_count(real_count),
        .period(line_period),
        .vsync_pix(vsync_d), .hsync_pix(hsync_d),
        .black(black_level), .s_min(s_min), .s_max(s_max), .s_thr(s_thr),
        .gain_sel(gain_sel), .phase_sel(phase_used),
        .hist_flat(hist_flat),
        .dmp_rdy(dmp_rdy), .dmp_rdata(dmp_rdata),
        .dmp_raddr(dmp_raddr), .dmp_ack(dmp_ack),
        .uart_tx_pin(uart_tx_pin)
    );

    reg [25:0] hb;
    always @(posedge clk27) hb <= hb + 26'd1;

    reg field_seen;
    always @(posedge pixel_clk or negedge vid_rst_n) begin
        if (!vid_rst_n)       field_seen <= 1'b0;
        else if (vsync_pulse) field_seen <= 1'b1;
    end

    assign led_n = ~{gain_sel, field_seen, sync_locked, vid_lock, hb[24]};
    wire [7:0] bg_r = (scope_sync || !pixel_valid) ? 8'h00 : pixel_rgb[23:16];
    wire [7:0] bg_g = (scope_sync || !pixel_valid) ? 8'h00 : pixel_rgb[15:8];
    wire [7:0] bg_b = (scope_sync || !pixel_valid) ? 8'h00 : pixel_rgb[7:0];

    wire on_grid = scope_sync && (y_d[5:0] == 6'd0);

    // Machine-readable scope identity and liveness. A capture card may replay
    // an older image after programming; changing PNG hashes alone cannot tell
    // whether that image belongs to the requested diagnostic mode.
    // 32 cells, 16 pixels each, MSB first: A5, mode/rotation, frame, 02.
    // Version 2: the rotation is four bits where version 1 had a three-bit
    // phase and a reserved zero; scripts/scope_trace.py reads both.
    // Kept above the full-range trace (y >= 224), below the existing bars.
    reg [7:0] scope_frame = 8'd0;
    always @(posedge pixel_clk) begin
        if (!vid_rst_n) scope_frame <= 8'd0;
        else if (x == 0 && y == 0) scope_frame <= scope_frame + 8'd1;
    end
    wire [31:0] scope_identity = {8'hA5, SCOPE_TEST_RAMP[3:0], phase_used,
                                  scope_frame, 8'h02};
    wire on_scope_id = SCOPE_FULL_RANGE && y_d >= 11'd200 && y_d < 11'd208 && x < 11'd512;
    wire scope_id_bit = scope_identity[31-x[8:4]];
    wire [7:0] scope_id_rgb = scope_id_bit ? 8'hFF : 8'h00;

    // The Unit 8Angle's eight knobs, near the bottom of the diagnostic view,
    // eight rows apart and two pixels per count like the other bars.  The scope
    // trace only comes this low for codes under the sync tip.  To the right,
    // the switch as a green block and a red block while the unit is not
    // answering.
    wire [10:0] k_rel    = y_d - 11'd400;
    wire        in_krows = (y_d >= 11'd400) && (y_d < 11'd464);
    wire [7:0]  k_val    = knobs[{k_rel[5:3], 3'd0} +: 8];
    wire        k_row    = in_krows && (k_rel[2:0] < 3'd6);
    wire on_knob  = k_row && (x < {2'd0, k_val, 1'b0});
    wire on_ktrk  = k_row && (x < 11'd512);
    wire on_ksw   = in_krows && knob_sw && (x >= 11'd528) && (x < 11'd576);
    wire on_kgone = in_krows && !knob_present && (x >= 11'd592) && (x < 11'd640);

    wire [7:0] diagnostic_r = on_scope_id ? scope_id_rgb : on_knob ? 8'h00 :
                       on_ksw   ? 8'h00 : on_kgone ? 8'hFF : on_ktrk ? 8'h30 :
                       on_ci    ? 8'h00 :
                       on_cq    ? 8'hFF :
                       on_clk_  ? 8'h00 :
                       on_bmin  ? 8'h00 :
                       on_bmax  ? 8'h00 :
                       on_bend  ? 8'hFF :
                       on_clip  ? 8'hFF :
                       on_lmin  ? 8'h00 :
                       on_lblk  ? 8'hFF :
                       on_lmax  ? 8'hFF :
                       on_qual  ? 8'h00 :
                       on_phase ? (ph_here ? 8'hFF : 8'h30) :
                       on_mtick ? 8'hFF :
                       on_rmax  ? 8'hFF :
                       on_vtick ? 8'hFF :
                       on_vsr   ? 8'h00 :
                       on_yaf   ? 8'hFF :
                       on_qtick ? 8'hFF :
                       on_run   ? 8'hFF :
                       on_frc   ? 8'h00 :
                       on_rate  ? 8'hFF :
                       on_lock  ? 8'h00 :
                       on_trace ? 8'hFF :
                       on_thr   ? 8'h00 :
                       on_grid  ? 8'h20 : bg_r;
    wire [7:0] diagnostic_g = on_scope_id ? scope_id_rgb : on_knob ? 8'hFF :
                       on_ksw   ? 8'hFF : on_kgone ? 8'h00 : on_ktrk ? 8'h30 :
                       on_ci    ? 8'hFF :
                       on_cq    ? 8'h40 :
                       on_clk_  ? 8'hFF :
                       on_bmin  ? 8'hC0 :
                       on_bmax  ? 8'hFF :
                       on_bend  ? 8'h80 :
                       on_clip  ? 8'h00 :
                       on_lmin  ? 8'hFF :
                       on_lblk  ? 8'hFF :
                       on_lmax  ? 8'hFF :
                       on_qual  ? 8'hFF :
                       on_phase ? (ph_here ? 8'hFF : 8'h30) :
                       on_mtick ? 8'h00 :
                       on_rmax  ? 8'hC0 :
                       on_vtick ? 8'h00 :
                       on_vsr   ? 8'hFF :
                       on_yaf   ? 8'h00 :
                       on_qtick ? 8'h00 :
                       on_run   ? 8'hFF :
                       on_frc   ? 8'h60 :
                       on_rate  ? 8'hC0 :
                       on_lock  ? 8'hFF :
                       on_trace ? (below_thr ? 8'h00 : 8'hFF) :
                       on_thr   ? 8'hC0 :
                       on_grid  ? 8'h20 : bg_g;
    wire [7:0] diagnostic_b = on_scope_id ? scope_id_rgb : on_knob ? 8'hFF :
                       on_ksw   ? 8'h00 : on_kgone ? 8'h00 : on_ktrk ? 8'h30 :
                       on_ci    ? 8'h40 :
                       on_cq    ? 8'hFF :
                       on_clk_  ? 8'hFF :
                       on_bmin  ? 8'hFF :
                       on_bmax  ? 8'h80 :
                       on_bend  ? 8'h00 :
                       on_clip  ? 8'h00 :
                       on_lmin  ? 8'hFF :
                       on_lblk  ? 8'h00 :
                       on_lmax  ? 8'hFF :
                       on_qual  ? 8'h60 :
                       on_phase ? (ph_here ? 8'h00 : 8'h30) :
                       on_mtick ? 8'h00 :
                       on_rmax  ? 8'h00 :
                       on_vtick ? 8'h00 :
                       on_vsr   ? 8'hFF :
                       on_yaf   ? 8'hFF :
                       on_qtick ? 8'h00 :
                       on_run   ? 8'hFF :
                       on_frc   ? 8'hFF :
                       on_rate  ? 8'h00 :
                       on_lock  ? 8'h00 :
                       on_trace ? (below_thr ? 8'h00 : 8'hFF) :
                       on_thr   ? 8'h00 :
                       on_grid  ? 8'h20 : bg_b;



    // The read port has a clock of latency, so the cell geometry uses the
    // registered x -- the same alignment active_d gives the output.
    reg [10:0] x_d;
    always @(posedge pixel_clk) x_d <= x;
    wire [31:0] tape_id  = {16'hA55A, 7'd0, dmp_rdy, scope_frame};
    wire        tape_bit = tape_id[31 - x_d[8:4]];
    wire [3:0]  tape_nib = (y_d < 11'd8)  ? {4{tape_bit && x_d < 11'd512}}
                         : (y_d < TAPE_ROW0) ? x_d[5:2]
                         : (y_d < 11'd426) ? (x_d[2] ? dmp_rdata[3:0] : dmp_rdata[7:4])
                         : 4'd0;
    wire [7:0]  tape_grey;   // 16 + 14 * nibble; see g_tape_grey at the end

    // The converter interface's state, in the bottom four rows of the
    // diagnostic view (S1; the view ntsc-scope starts in) and of every
    // ADC_DIAG frame, kept off the picture itself: 32 cells of 16 pixels, MSB
    // first, white = 1, the same encoding as the scope identity.  A, rotation,
    // calibrated, pair (x = 1), sweeps so far, and the last tracking window's
    // difference count -- near zero when the read is clean.
    wire [31:0] adc_word = {4'hA, phase_used, adc_cal_done, adc_pair_x,
                            adc_sweeps, adc_track};
    // Above it, the last sweep's two counts for one rotation, a different
    // rotation each frame: 5, rotation, then each count / 8 in twelve bits.
    always @(posedge pixel_clk)
        if (x == 0 && y == 0) adc_dbg_rot <= (adc_dbg_rot == 4'd9) ? 4'd0 : adc_dbg_rot + 4'd1;
    wire [31:0] adc_word2 = ADC_DIAG
        ? {3'b101, adc_dbg_rot[2:0], phase_used, adc_dbg_bx[14:4], adc_dbg_by[14:4]}
        : {4'h5, adc_dbg_rot, adc_dbg_cx[14:3], adc_dbg_cy[14:3]};
    // And above those, line 100's burst: i and q, then the CORDIC's angle
    // (15 bits), whether it was fresh, and the tracked angle (16 bits).
    wire [31:0] adc_word3 = {dbg_line_i, dbg_line_q};
    wire [31:0] adc_word4 = {dbg_line_angle[31:17], dbg_line_fresh, dbg_line_off[31:16]};
    wire on_adc_word = ADC_STRIP && !TAPE && (scope_sync || ADC_DIAG) &&
                       y_d >= 11'd464 && y_d < 11'd480 && x < 11'd512;
    wire [31:0] adc_show = (y_d >= 11'd476) ? adc_word
                         : (y_d >= 11'd472) ? adc_word2
                         : (y_d >= 11'd468) ? adc_word4 : adc_word3;
    wire [7:0] adc_rgb = adc_show[31 - x[8:4]] ? 8'hFF : 8'h00;

    wire [7:0] out_r = TAPE ? tape_grey : on_adc_word ? adc_rgb : scope_sync ? diagnostic_r : bg_r;
    wire [7:0] out_g = TAPE ? tape_grey : on_adc_word ? adc_rgb : scope_sync ? diagnostic_g : bg_g;
    wire [7:0] out_b = TAPE ? tape_grey : on_adc_word ? adc_rgb : scope_sync ? diagnostic_b : bg_b;

    hdmi_out out (
        .pixel_clk(pixel_clk), .serial_clk(serial_clk), .reset_n(vid_rst_n),
        .active(active_d), .hsync(hsync_d), .vsync(vsync_d),
        .red(out_r), .green(out_g), .blue(out_b),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    // 16 + 14 * nibble, 16..226: inside video's limited range, so a capture
    // card that expands 16..235 to 0..255 still gives sixteen distinct levels.
    // Plain nibble * 17 collapsed 0 with 1 and 14 with 15 when the card
    // switched to doing that after a replug.
    //
    // At the end of the file, and elaborated only for the tape, on purpose:
    // Yosys names cells after their source line, so an edit that moves lines
    // renames every cell below it, which moves the placement -- and with
    // Apicula's ALU bug a placement is part of whether the decoder computes
    // correctly.  Kept here, the normal build's netlist is unchanged and
    // `make ntsc` still reproduces the measured seed-11 bitstream byte for byte.
    generate
        if (TAPE) begin : g_tape_grey
            assign tape_grey = 8'd16 + {1'b0, tape_nib, 3'b000}
                             + {2'b00, tape_nib, 2'b00} + {3'b000, tape_nib, 1'b0};
        end else begin : g_tape_unused
            assign tape_grey = {tape_nib, tape_nib};
        end
    endgenerate

endmodule

`default_nettype wire
