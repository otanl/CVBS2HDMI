`default_nettype none
`timescale 1ns/1ps

// Replay a real capture through ntsc_capture and count what it finds.
//
// The point is iteration speed.  On hardware a parameter change costs a
// synthesis run, a programming run and a video capture -- three minutes -- and
// needs the board, the source and the HDMI link all working at once.  Here it
// costs a second and needs none of them, so a sweep of QUALIFY or THR_SHIFT is
// a loop rather than an afternoon.
//
// Two stimulus files, both derived from sim/ntsc_capture_19lines.hex, which is
// 19 consecutive lines captured off this board:
//
//   sim/ntsc_25msps.hex           resampled 27 -> 25.2 MHz, sync tip at code
//                                 98 against blanking at 134, so 36 codes of
//                                 sync amplitude -- a healthy source.
//   sim/ntsc_25msps_weaksync.hex  the same, with everything below blanking
//                                 compressed to about a fifth, leaving 8
//                                 codes.  This stands in for the M5 colour bar
//                                 generator, whose sync is nearly flattened
//                                 and which is what the design actually has to
//                                 cope with today.
//
// A detector that only works on the first is not much use.
module ntsc_capture_tb;

    parameter         WEAK  = 1'b0;    // 1 = use the flattened-sync stimulus
    parameter integer LINES = 400;     // how many lines to replay
    parameter TRACE = 0;
    // Forwarded to the DUT so a sweep is a shell loop over -P.
    parameter integer Q_QUALIFY   = 88;
    parameter integer Q_THR_SHIFT = 5;
    parameter integer Q_VS_MIN    = 400;
    parameter integer Q_RELEASE   = 10;

    localparam integer NSAMP = 30453;  // samples in the stimulus files

    reg [7:0] stim [0:NSAMP-1];

    // 126 MHz and the pixel clock divided from it, as on the board.
    reg fclk = 1'b0;
    always #3.968 fclk = ~fclk;
    wire clk;
    CLKDIV #(.DIV_MODE("5")) u_div (.CLKOUT(clk), .HCLKIN(fclk), .RESETN(1'b1), .CALIB(1'b0));

    reg        rst_n = 1'b0;
    reg [7:0]  adc_d = 8'd0;
    wire       adc_clk;
    integer    idx = 0;

    // One recorded sample per conversion, 10 ns after the converter's clock
    // rises; the decoder's calibration finds where that lands.
    always @(posedge adc_clk) begin
        adc_d <= #10 stim[idx];
        idx   <= (idx == NSAMP-1) ? 0 : idx + 1;
    end

    wire [15:0] real_count, force_count, qual_count, run_min, run_max;
    wire [7:0]  lock_level, slice_min, slice_max, slice_thr;
    wire        sync_locked;
    wire        vsync_pulse;
    reg [31:0]  vs_count = 0, vs_settle = 0;
    wire [15:0] period_out;

    ntsc_capture #(
        .QUALIFY(Q_QUALIFY), .THR_SHIFT(Q_THR_SHIFT), .VS_MIN(Q_VS_MIN),
        .RELEASE(Q_RELEASE), .ADC_WIN_W(10)
    ) dut (
        .clk(clk), .fclk(fclk), .rst_n(rst_n),
        .adc_d(adc_d), .adc_otr(1'b0),
        .adc_clk(adc_clk), .adc_clamp(),
        .rot_sel(4'd0), .fx(64'd0), .gain_sel(2'd0),
        .wr_en(), .wr_addr(), .wr_data(), .wr_bank(),
        .line_done(), .vsync_pulse(vsync_pulse),
        .sync_locked(sync_locked), .lock_level(lock_level),
        .real_count(real_count), .force_count(force_count),
        .qual_count(qual_count), .run_min(run_min), .run_max(run_max),
        .dmp_we(), .dmp_addr(), .dmp_data(), .dmp_rdy(), .dmp_ack(1'b0),
        .period_out(period_out),
        .slice_min(slice_min), .slice_max(slice_max), .slice_thr(slice_thr),
        .black_out(), .hist_flat()
    );

    // Count line starts independently of the design's own counters, so the
    // bench can say "one start per line" rather than take the design's word.
    reg [31:0] settle_real, settle_force, settle_qual;

    always @(posedge clk) if (vsync_pulse) vs_count <= vs_count + 1;
    always @(posedge clk) if (TRACE && dut.sample_stb && dut.line_edge &&
        ((!dut.line_real && dut.force_run >= 4) ||
         (dut.line_real && (dut.pcnt < 1442 || dut.pcnt > 1762))))
        $display("sync trace idx=%0d real=%0d pcnt=%0d rcnt=%0d avg=%0d run=%0d lock=%0d",
                 idx, dut.line_real, dut.pcnt, dut.rcnt, dut.period_avg, dut.force_run, lock_level);

    integer i;
    initial begin
        if (WEAK) $readmemh("sim/ntsc_25msps_weaksync.hex", stim);
        else      $readmemh("sim/ntsc_25msps.hex", stim);

        repeat (100) @(posedge fclk);
        rst_n = 1'b1;

        // Let acquisition finish before measuring: the counters include every
        // line since reset, and a hundred lines of hunting would otherwise be
        // charged against the steady state.
        repeat (100 * 1603) @(posedge clk);
        settle_real  = real_count;
        settle_force = force_count;
        settle_qual  = qual_count;
        vs_settle    = vs_count;

        repeat (LINES * 1603) @(posedge clk);

        $display("stimulus=%s QUALIFY=%0d THR_SHIFT=%0d VS_MIN=%0d",
                 WEAK ? "weak" : "full", Q_QUALIFY, Q_THR_SHIFT, Q_VS_MIN);
        $display("slice         : min=%0d max=%0d thr=%0d (thr is %0d above min)",
                 slice_min, slice_max, slice_thr, slice_thr - slice_min);
        $display("period        : %0d", period_out);
        $display("lock_level    : %0d/255%s", lock_level,
                 sync_locked ? "  LOCKED" : "  not locked");
        $display("lines replayed: %0d", LINES);
        $display("found         : %0d", real_count  - settle_real[15:0]);
        $display("forced        : %0d", force_count - settle_force[15:0]);
        $display("qualified     : %0d", qual_count  - settle_qual[15:0]);
        // This recording loops picture lines only; it contains no VBI.
        $display("fields        : %0d  (expect 0: picture-only recording)",
                 vs_count - vs_settle);
        $display("run_min/max   : %0d / %0d", run_min, run_max);
        // A coasted start can be corrected by a late real edge. Those two
        // events represent one line, so real/(real+forced) is not a yield.
        $display("RESULT accepted=%0d%% of %0d expected lines",
                 (100 * (real_count - settle_real[15:0])) / LINES, LINES);
        if (!sync_locked || period_out < 1442 || period_out > 1762 ||
            real_count - settle_real[15:0] < LINES*90/100 ||
            real_count - settle_real[15:0] > LINES*110/100 || vs_count != vs_settle)
            $fatal(1, "recorded NTSC sync acquisition failed");
        $display("RESULT PASS");
        $finish;
    end
endmodule

`default_nettype wire
