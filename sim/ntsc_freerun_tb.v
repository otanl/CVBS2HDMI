`default_nettype none
`timescale 1ns/1ps

// A broken input must be shown, not blacked out.
//
// Five stretches in a row: noise, a real recording, a flat level (a cable
// pulled out), noise again, and the recording again.  The bench counts the
// lines ntsc_capture publishes in each and when sync locks on the recording.
//
// With FREE_RUN the decoder keeps publishing a line every nominal period
// whatever arrives, so noise is shown as noise, and a real signal still locks
// as soon as it returns.  FREE_RUN=0 is the negative control: the same bench
// must then see the first noise go (almost) unpublished -- the black screen
// before the first lock -- and so show that it can tell the two apart.
// Measured without it: 1 line of 60 on the first noise, 6 of 40 flat, 0 of 40
// on the second noise, and 158 of 200 on the recording, which is dropped
// until lock; the lock itself comes after 104 and 105 lines either way.
module ntsc_freerun_tb;
    parameter FREE_RUN = 1'b1;

    localparam integer NSAMP = 30453;   // samples in sim/ntsc_25msps.hex
    localparam integer LINE  = 1602;
    localparam integer NOISE_LINES = 60, REC_LINES = 200, FLAT_LINES = 40;

    reg [7:0] stim [0:NSAMP-1];

    reg fclk = 1'b0;
    always #3.968 fclk = ~fclk;
    wire clk;
    CLKDIV #(.DIV_MODE("5")) u_div (.CLKOUT(clk), .HCLKIN(fclk), .RESETN(1'b1), .CALIB(1'b0));

    reg        rst_n = 1'b0;
    reg [7:0]  adc_d = 8'd0;
    wire       adc_clk;
    integer    idx = 0;
    reg  [1:0] source = 2'd0;          // 0 noise, 1 recording, 2 flat
    reg [31:0] lfsr = 32'hACE1_2468;

    always @(posedge adc_clk) begin
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        adc_d <= #10 (source == 2'd1) ? stim[idx] : (source == 2'd2) ? 8'd100 : lfsr[7:0];
        idx   <= (idx == NSAMP-1) ? 0 : idx + 1;
    end

    wire line_done, sync_locked;
    ntsc_capture #(.FREE_RUN(FREE_RUN), .ADC_WIN_W(10)) dut (
        .clk(clk), .fclk(fclk), .rst_n(rst_n),
        .adc_d(adc_d), .adc_otr(1'b0),
        .adc_clk(adc_clk), .adc_clamp(),
        .rot_sel(4'd0), .fx(64'd0), .gain_sel(2'd0),
        .wr_en(), .wr_addr(), .wr_data(), .wr_bank(),
        .line_done(line_done), .vsync_pulse(),
        .sync_locked(sync_locked), .lock_level(),
        .real_count(), .force_count(), .qual_count(), .run_min(), .run_max(),
        .dmp_we(), .dmp_addr(), .dmp_data(), .dmp_rdy(), .dmp_ack(1'b0),
        .period_out(), .slice_min(), .slice_max(), .slice_thr(),
        .black_out(), .hist_flat()
    );

    integer published = 0, lock_at, failures = 0;
    always @(posedge clk) if (line_done) published <= published + 1;

    // Run LINES nominal lines of a source; report lines published and, for
    // the recording, how many lines it took to lock.
    task stretch;
        input [1:0]   src;
        input integer lines;
        input [8*8-1:0] name;
        output integer shown;
        integer start, l;
        begin
            source  = src;
            start   = published;
            lock_at = -1;
            for (l = 0; l < lines; l = l + 1) begin
                repeat (LINE) @(posedge clk);
                if (lock_at < 0 && sync_locked) lock_at = l;
            end
            shown = published - start;
            if (src == 2'd1)
                $display("%0s: %0d lines, %0d published, locked after %0d lines",
                         name, lines, shown, lock_at);
            else
                $display("%0s: %0d lines, %0d published", name, lines, shown);
        end
    endtask

    integer n_noise1, n_rec1, n_flat, n_noise2, n_rec2, lock1, lock2;
    initial begin
        $readmemh("sim/ntsc_25msps.hex", stim);
        repeat (100) @(posedge fclk);
        rst_n = 1'b1;
        stretch(2'd0, NOISE_LINES, "noise",  n_noise1);
        stretch(2'd1, REC_LINES,   "record", n_rec1);   lock1 = lock_at;
        stretch(2'd2, FLAT_LINES,  "flat",   n_flat);
        stretch(2'd0, FLAT_LINES,  "noise",  n_noise2);
        stretch(2'd1, REC_LINES,   "record", n_rec2);   lock2 = lock_at;

        // A real signal must lock, and promptly, either way.
        if (lock1 < 0 || lock1 > 120 || lock2 < 0 || lock2 > 120) begin
            $display("FAIL: the recording did not lock within 120 lines");
            failures = failures + 1;
        end
        if (FREE_RUN) begin
            if (n_noise1 < NOISE_LINES * 9 / 10 || n_flat < FLAT_LINES * 9 / 10 ||
                n_noise2 < FLAT_LINES * 9 / 10) begin
                $display("FAIL: a broken input was not shown line by line");
                failures = failures + 1;
            end
            if (n_rec1 < REC_LINES * 9 / 10 || n_rec2 < REC_LINES * 9 / 10) begin
                $display("FAIL: lines missing on the recording");
                failures = failures + 1;
            end
        end else if (n_noise1 > NOISE_LINES / 10) begin
            $display("FAIL: negative control -- the bench cannot see the black screen");
            failures = failures + 1;
        end
        $display("freerun: FREE_RUN=%0d noise %0d/%0d, flat %0d/%0d, noise %0d/%0d, lock %0d and %0d lines",
                 FREE_RUN, n_noise1, NOISE_LINES, n_flat, FLAT_LINES, n_noise2, FLAT_LINES, lock1, lock2);
        if (failures != 0) $fatal(1, "free-running line starts failed");
        $display("RESULT PASS");
        $finish;
    end
endmodule

`default_nettype wire
