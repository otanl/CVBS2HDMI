`default_nettype none

// Composite NTSC-J -> AD9280 -> 640x480p DVI-compatible HDMI.
// One 126 MHz PLL supplies the capture/serializer clock and, divided by
// five, the 25.2 MHz pixel clock. Completed input lines are bob displayed
// through an ownership-protected four-bank line store. S1 toggles diagnostics;
// S2 steps the ADC sampling phase. Default output is the decoded image.

module top_ntsc_hdmi #(
    parameter [2:0] DEFAULT_PHASE = 3'd2,
    parameter       HUNT_PHASE    = 1'b0,
    parameter       SCOPE_ONLY    = 1'b0,
    parameter       FRAME_ALIGN   = 1'b1,
    parameter       LEGACY_TIMING = 1'b1,
    parameter integer SCOPE_DIV   = 3
) (
    input  wire       clk27,

    input  wire [7:0] adc_d,
    input  wire       adc_otr,
    output wire       adc_clk,
    output wire       adc_clamp,

    input  wire [1:0] btn_n,
    output wire [5:0] led_n,
    output wire       uart_tx_pin,

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

    reg [3:0] cap_reset_pipe = 4'b0000;
    always @(posedge serial_clk) begin
        if (!vid_lock_stable) cap_reset_pipe <= 4'b0000;
        else                  cap_reset_pipe <= {cap_reset_pipe[2:0], 1'b1};
    end
    wire cap_rst_n = cap_reset_pipe[3];

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
    wire [10:0]  dmp_addr, dmp_raddr;
    wire [7:0]   dmp_data, dmp_rdata;
    wire [7:0]   black_level;
    wire [255:0] hist_flat;

    reg [1:0]  btn_meta, btn_sync, btn_stable;
    reg [19:0] btn_timer;
    reg [21:0] btn_inhibit;
    reg [2:0]  phase_sel;
    reg [1:0]  gain_sel;
    reg        scope_only;
    reg [26:0] hunt_cnt;
    always @(posedge serial_clk or negedge cap_rst_n) begin
        if (!cap_rst_n) begin
            btn_meta <= 2'b11; btn_sync <= 2'b11; btn_stable <= 2'b11;
            btn_timer <= 20'd0; phase_sel <= DEFAULT_PHASE; gain_sel <= 2'd0;
            scope_only <= SCOPE_ONLY;
            btn_inhibit <= 22'd0; hunt_cnt <= 27'd0;
        end else begin
            if (sync_locked) begin
                hunt_cnt <= 27'd0;
            end else if (!HUNT_PHASE || lock_level >= 8'd16) begin
                hunt_cnt <= 27'd0;
            end else if (hunt_cnt == 27'd125_999_999) begin   // 1 s per phase
                hunt_cnt  <= 27'd0;
                phase_sel <= (phase_sel == 3'd4) ? 3'd0 : phase_sel + 3'd1;
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
                            phase_sel <= (phase_sel == 3'd4) ? 3'd0 : phase_sel + 3'd1;
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

    ntsc_capture #(.LEGACY_TIMING(LEGACY_TIMING)) capture (
        .clk_cap(serial_clk), .rst_n(cap_rst_n),
        .adc_d(adc_d), .adc_otr(adc_otr),
        .adc_clk(adc_clk), .adc_clamp(adc_clamp),
        .phase_sel(phase_sel), .gain_sel(gain_sel),
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
        .dmp_rdy(dmp_rdy), .dmp_ack(dmp_ack),
        .black_out(black_level),
        .hist_flat(hist_flat)
    );

    reg vs_toggle;
    always @(posedge serial_clk or negedge cap_rst_n) begin
        if (!cap_rst_n)        vs_toggle <= 1'b0;
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
    wire [10:0] y_rel = (y >= V_TARGET) ? (y - V_TARGET)
                                        : (y + 11'd525 - V_TARGET);
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
        .wr_clk(serial_clk), .wr_reset_n(cap_rst_n), .wr_en(wr_en),
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

    line_buffer #(.ADDR_WIDTH(11), .DATA_WIDTH(8)) dumpbuf (
        .wr_clk(serial_clk), .wr_en(dmp_we), .wr_addr(dmp_addr),
        .wr_data(dmp_data),
        .rd_clk(pixel_clk), .rd_addr(scope_addr), .rd_data(dmp_rdata)
    );

    wire [11:0] trace_mul = ({4'd0, dmp_rdata} << 4) - {4'd0, dmp_rdata}; // x15
    wire [10:0] trace_y   = 11'd479 - trace_mul[11:3];
    wire [10:0] thr_mul   = ({3'd0, s_thr} << 4) - {3'd0, s_thr};
    wire [10:0] thr_y     = 11'd479 - thr_mul[10:3];

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
                           (x < 11'd120) && (x % 11'd24 < 11'd20);
    wire        ph_here  = (ph_slot == {8'd0, phase_sel});
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
        .gain_sel(gain_sel), .phase_sel(phase_sel),
        .hist_flat(hist_flat),
        .dmp_rdy(dmp_rdy), .dmp_rdata(dmp_rdata),
        .dmp_raddr(dmp_raddr), .dmp_ack(dmp_ack),
        .uart_tx_pin(uart_tx_pin)
    );

    reg [25:0] hb;
    always @(posedge clk27) hb <= hb + 26'd1;

    reg field_seen;
    always @(posedge serial_clk or negedge cap_rst_n) begin
        if (!cap_rst_n)       field_seen <= 1'b0;
        else if (vsync_pulse) field_seen <= 1'b1;
    end

    assign led_n = ~{gain_sel, field_seen, sync_locked, vid_lock, hb[24]};
    wire [7:0] bg_r = (scope_sync || !pixel_valid) ? 8'h00 : pixel_rgb[23:16];
    wire [7:0] bg_g = (scope_sync || !pixel_valid) ? 8'h00 : pixel_rgb[15:8];
    wire [7:0] bg_b = (scope_sync || !pixel_valid) ? 8'h00 : pixel_rgb[7:0];

    wire on_grid = scope_sync && (y_d[5:0] == 6'd0);

    wire [7:0] diagnostic_r = on_ci    ? 8'h00 :
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
    wire [7:0] diagnostic_g = on_ci    ? 8'hFF :
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
    wire [7:0] diagnostic_b = on_ci    ? 8'h40 :
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

    wire [7:0] out_r = scope_sync ? diagnostic_r : bg_r;
    wire [7:0] out_g = scope_sync ? diagnostic_g : bg_g;
    wire [7:0] out_b = scope_sync ? diagnostic_b : bg_b;

    hdmi_out out (
        .pixel_clk(pixel_clk), .serial_clk(serial_clk), .reset_n(vid_rst_n),
        .active(active_d), .hsync(hsync_d), .vsync(vsync_d),
        .red(out_r), .green(out_g), .blue(out_b),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

endmodule

`default_nettype wire
