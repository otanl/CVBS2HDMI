`default_nettype none

// AD9280 interface in the pins' IO logic, with the converter's clock phase
// chosen by measurement, and every data register on the pixel clock.
//
// Data: an IDDR per bit, clocked by the 25.2 MHz pixel clock, reads each pin
// twice a conversion -- at the rising edge (Q0, the sample) and at the falling
// edge (Q1, the witness).  The sample never crosses a clock domain in the
// fabric.  (A ten-read IDES10 would be finer, but it takes both IO cells of a
// pin pair, and every data pin here shares its pair with another ADC signal.)
//
// Clock: an ODDR on the 126 MHz serial clock sends 1111100000 rotated by
// `rot` half-cycles, so the converter's clock -- and with it the instant its
// outputs switch -- can be moved in 3.97 ns steps against the fixed reads.
// The rotation's relationship to the pixel clock is whatever the two counters
// start at; the measurement absorbs it.
//
// Measurement: the AD9280's outputs are latched, so two reads with no output
// switching between them are identical, bit for bit, whatever the video does.
// Two pairs are counted: the witness against the sample after it (`y`) and
// the sample against the witness after it (`x`).  Each pair spans one of the
// two gaps between reads, and its count is (essentially) zero exactly when the
// switching lies in the *other* gap.  Sweeping the rotation through a whole
// conversion gives a quiet run for each; the longer run belongs to the longer
// gap, and at its centre the switching is at least a quarter conversion,
// 9.9 ns, from every read -- whatever the pixel clock's duty cycle, which
// decides how long each gap is, and whichever falling edge the IDDR pairs with
// which rising edge.  Neither is documented, so neither is assumed.
//
// Then it keeps counting that pair at the chosen rotation; if the count rises,
// the switching has drifted onto a read and the sweep runs again.  A sweep
// disturbs the sample stream for 7 ms.  With no signal (every count tiny) the
// rotation is left alone.
module adc_front #(
    parameter AUTO   = 1'b1,
    parameter SETTLE = 512,       // samples discarded after a rotation change
    parameter WIN_W  = 14,        // counting window, 2^WIN_W samples
    // Which of the ODDR's two inputs leaves first.  Not documented; an odd
    // rotation needs a transition inside a 126 MHz cycle, and the wrong order
    // turns it into a 3.97 ns glitch -- two clock edges a conversion.
    parameter CLK_D1_FIRST = 1'b0,
    // Per-bit difference counts, for finding which bit reads when.
    parameter DIAG = 1'b0,
    // The bits the calibration looks at.  Measured per bit on the respun
    // board (DIAG): bits 2, 3, 6 and 7 -- pins 72, 76, 75, 77, the top bank --
    // read exactly alike on both edges at four rotations of ten, as a latched
    // output should.  Bits 0, 1, 4 and 5 -- pins 27..30, the bottom bank beside
    // the HDMI pins -- disagree between the two reads on 3 to 13 percent of
    // conversions at every rotation, so counted in, no rotation is ever quiet
    // and the calibration re-sweeps for ever (it saturated its sweep counter
    // within seconds on the board).  The top bank alone locates the switching.
    parameter [7:0] CAL_MASK = 8'b1100_1100
) (
    input  wire       pclk,           // 25.2 MHz, the pixel clock
    input  wire       fclk,           // 126 MHz, five times pclk, same source
    input  wire       rst_n,          // pclk domain
    input  wire [7:0] adc_d,
    output wire       adc_clk,
    input  wire [3:0] manual_rot,     // with AUTO off
    output reg  [7:0] sample,         // one conversion per pclk
    output wire [3:0] rot_in_use,
    output reg        cal_done,
    // Diagnostics: sweeps run so far (saturating), and the difference count
    // of the last tracking window at the chosen rotation.
    output reg  [5:0]     sweeps,
    output wire           pair_x,     // the chosen rotation is quiet on pair x
    output reg  [WIN_W:0] track_count,
    input  wire [3:0]     dbg_rot,    // which rotation's sweep counts to show
    output wire [WIN_W:0] dbg_cx,
    output wire [WIN_W:0] dbg_cy,
    input  wire [2:0]     dbg_bit,    // DIAG: which bit's counts to show
    output wire [WIN_W:0] dbg_bx,     // DIAG: sample against the next fall
    output wire [WIN_W:0] dbg_by      // DIAG: fall against the next rise
);
    // ---- converter clock, 126 MHz domain ---------------------------------
    reg  [3:0] rot = 4'd0;            // pclk domain, below
    reg  [3:0] rot_f1 = 4'd0, rot_f2 = 4'd0;
    reg  [2:0] ph = 3'd0;             // which pair of half-cycles, 0..4
    reg  [9:0] pat = 10'b1111100000;  // bit 0 is sent first
    reg        ck0 = 1'b0, ck1 = 1'b0;
    always @(posedge fclk) begin
        rot_f1 <= rot;                // changes rarely; two stages are plenty
        rot_f2 <= rot_f1;
        ph     <= (ph == 3'd4) ? 3'd0 : ph + 3'd1;
        case (rot_f2)                 // 1111100000 rotated right by rot_f2
            4'd0:    pat <= 10'b1111100000;
            4'd1:    pat <= 10'b0111110000;
            4'd2:    pat <= 10'b0011111000;
            4'd3:    pat <= 10'b0001111100;
            4'd4:    pat <= 10'b0000111110;
            4'd5:    pat <= 10'b0000011111;
            4'd6:    pat <= 10'b1000001111;
            4'd7:    pat <= 10'b1100000111;
            4'd8:    pat <= 10'b1110000011;
            default: pat <= 10'b1111000001;
        endcase
        ck0 <= CLK_D1_FIRST ? pat[{ph, 1'b1}] : pat[{ph, 1'b0}];
        ck1 <= CLK_D1_FIRST ? pat[{ph, 1'b0}] : pat[{ph, 1'b1}];
    end

    ODDR u_clk (
        .D0(ck0), .D1(ck1), .TX(1'b0), .CLK(fclk), .Q0(adc_clk), .Q1()
    );

    // ---- data, pixel clock -----------------------------------------------
    wire [7:0] rise, fall;
    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : g_bit
            IDDR u_in (.D(adc_d[b]), .CLK(pclk), .Q0(rise[b]), .Q1(fall[b]));
        end
    endgenerate

    always @(posedge pclk) sample <= rise;

    // Per bit, the same two pairs as differ_x/differ_y, counted over
    // 2^WIN_W samples and held.
    generate
        if (DIAG) begin : g_diag
            reg [WIN_W:0] bx [0:7], by [0:7], bx_h [0:7], by_h [0:7];
            reg [WIN_W:0] dn = 0;
            integer j;
            always @(posedge pclk) begin
                dn <= dn + 1'b1;
                for (j = 0; j < 8; j = j + 1) begin
                    if (dn[WIN_W]) begin
                        bx_h[j] <= bx[j]; by_h[j] <= by[j];
                        bx[j] <= 0; by[j] <= 0;
                    end else begin
                        if (sample[j] != fall[j]) bx[j] <= bx[j] + 1'b1;
                        if (rise[j]   != fall[j]) by[j] <= by[j] + 1'b1;
                    end
                end
                if (dn[WIN_W]) dn <= 0;
            end
            assign dbg_bx = bx_h[dbg_bit];
            assign dbg_by = by_h[dbg_bit];
        end else begin : g_nodiag
            assign dbg_bx = 0;
            assign dbg_by = 0;
        end
    endgenerate

    reg differ_x, differ_y, differ_xa, differ_ya;
    always @(posedge pclk) begin
        differ_x  <= ((sample & CAL_MASK) != (fall & CAL_MASK));   // sample, next witness
        differ_y  <= ((rise & CAL_MASK)   != (fall & CAL_MASK));   // witness, next sample
        differ_xa <= (sample != fall);                            // the same, every bit
        differ_ya <= (rise != fall);
    end

    // ---- calibration -------------------------------------------------------
    localparam [2:0] S_SETTLE = 3'd0, S_COUNT = 3'd1, S_DECIDE = 3'd2,
                     S_MOVE = 3'd3, S_TRACK = 3'd4, S_PICK = 3'd5;
    localparam [WIN_W:0] WIN = {1'b1, {WIN_W{1'b0}}};
    // Too few differences anywhere to locate the switching: no signal.
    localparam [WIN_W:0] MIN_PEAK = WIN >> 6;

    reg  [2:0]     st;
    reg  [WIN_W:0] n;                 // samples into this window
    reg  [WIN_W:0] cnt_x, cnt_y, cnt_xa, cnt_ya;
    reg  [WIN_W:0] cx [0:9];
    reg  [WIN_W:0] cy [0:9];
    reg  [WIN_W:0] cxa [0:9];         // all eight bits, for the choice within a run
    reg  [WIN_W:0] cya [0:9];
    // Choosing within the quiet run.
    reg            pk_x;
    reg  [3:0]     pk_end, pk_len, pk_k, pk_best;
    reg  [WIN_W:0] pk_min;
    reg  [WIN_W:0] peak;
    reg  [3:0]     sweep;             // rotation under test
    reg  [4:0]     scan;              // 1..20 walk twice round the circle
    reg  [9:0]     low_x, low_y;
    reg  [3:0]     run_x, len_x, end_x, run_y, len_y, end_y;
    reg            use_x;             // which pair the chosen rotation is quiet on
    reg  [3:0]     keep;              // rotation to fall back on

    assign rot_in_use = rot;
    assign dbg_cx     = cx[dbg_rot];
    assign dbg_cy     = cy[dbg_rot];
    assign pair_x     = use_x;

    wire [4:0] scan_m1  = scan - 5'd1;
    wire [4:0] scan_w   = (scan_m1 >= 5'd10) ? scan_m1 - 5'd10 : scan_m1;
    wire [3:0] scan_idx = scan_w[3:0];

    // Centre of a quiet run: its last member less half its length.
    function [3:0] centre;
        input [3:0] last, len;
        reg   [3:0] half;
        begin
            half   = (len - 4'd1) >> 1;
            centre = (last >= half) ? last - half : last + 4'd10 - half;
        end
    endfunction
    wire ok_x = (len_x != 4'd0) && (len_x != 4'd10);
    wire ok_y = (len_y != 4'd0) && (len_y != 4'd10);
    wire pick_x = ok_x && (!ok_y || len_x >= len_y);

    wire [WIN_W:0] quiet_max = peak >> 3;
    wire [WIN_W:0] cnt_max   = (cnt_x > cnt_y) ? cnt_x : cnt_y;
    wire           track_differ = use_x ? differ_x : differ_y;

    // The run member under consideration, walking down from its last.
    wire [3:0]     pk_r     = (pk_end >= pk_k) ? pk_end - pk_k : pk_end + 4'd10 - pk_k;
    wire [WIN_W:0] pk_val   = pk_x ? cxa[pk_r] : cya[pk_r];
    // A run of three or more loses its ends: they sit next to a switching.
    wire           pk_cand  = (pk_len < 4'd3) || (pk_k != 4'd0 && pk_k != pk_len - 4'd1);
    // Walking down, a y-run reaches its low end last and an x-run its high
    // end first; those are the ends away from the sample, so ties go to them.
    wire           pk_takes = pk_cand && (pk_x ? (pk_val < pk_min) : (pk_val <= pk_min));

    integer i;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_SETTLE; n <= 0; cnt_x <= 0; cnt_y <= 0; peak <= 0;
            sweep <= 4'd0; scan <= 5'd0; low_x <= 10'd0; low_y <= 10'd0;
            run_x <= 4'd0; len_x <= 4'd0; end_x <= 4'd0;
            run_y <= 4'd0; len_y <= 4'd0; end_y <= 4'd0;
            use_x <= 1'b0; keep <= 4'd0; sweeps <= 6'd0; track_count <= 0;
            rot <= 4'd0; cal_done <= 1'b0;   // a constant: async reset
            cnt_xa <= 0; cnt_ya <= 0;
            pk_x <= 1'b0; pk_end <= 4'd0; pk_len <= 4'd0; pk_k <= 4'd0; pk_best <= 4'd0;
            pk_min <= 0;
            for (i = 0; i < 10; i = i + 1) begin
                cx[i] <= 0; cy[i] <= 0; cxa[i] <= 0; cya[i] <= 0;
            end
        end else if (!AUTO) begin
            rot <= manual_rot;
        end else begin
            case (st)
            S_SETTLE: begin
                n <= n + 1'b1;
                if (n == SETTLE - 1) begin
                    n <= 0; cnt_x <= 0; cnt_y <= 0; cnt_xa <= 0; cnt_ya <= 0;
                    st <= S_COUNT;
                end
            end
            S_COUNT: begin
                n <= n + 1'b1;
                if (differ_x && !cnt_x[WIN_W]) cnt_x <= cnt_x + 1'b1;
                if (differ_y && !cnt_y[WIN_W]) cnt_y <= cnt_y + 1'b1;
                if (differ_xa && !cnt_xa[WIN_W]) cnt_xa <= cnt_xa + 1'b1;
                if (differ_ya && !cnt_ya[WIN_W]) cnt_ya <= cnt_ya + 1'b1;
                if (n == WIN - 1) begin
                    n <= 0;
                    cx[sweep]  <= cnt_x;
                    cy[sweep]  <= cnt_y;
                    cxa[sweep] <= cnt_xa;
                    cya[sweep] <= cnt_ya;
                    if (cnt_max > peak) peak <= cnt_max;
                    if (sweep == 4'd9) begin
                        st <= S_DECIDE; scan <= 5'd0;
                        run_x <= 4'd0; len_x <= 4'd0; run_y <= 4'd0; len_y <= 4'd0;
                    end else begin
                        sweep <= sweep + 4'd1; rot <= sweep + 4'd1; st <= S_SETTLE;
                    end
                end
            end
            S_DECIDE: begin
                // Quiet: under an eighth of the busiest count of the sweep.
                if (scan == 5'd0) begin
                    for (i = 0; i < 10; i = i + 1) begin
                        low_x[i] <= (cx[i] < quiet_max);
                        low_y[i] <= (cy[i] < quiet_max);
                    end
                end else begin
                    if (low_x[scan_idx]) begin
                        if (run_x != 4'd10) run_x <= run_x + 4'd1;
                        if (run_x != 4'd10 && run_x + 4'd1 > len_x) begin
                            len_x <= run_x + 4'd1; end_x <= scan_idx;
                        end
                    end else
                        run_x <= 4'd0;
                    if (low_y[scan_idx]) begin
                        if (run_y != 4'd10) run_y <= run_y + 4'd1;
                        if (run_y != 4'd10 && run_y + 4'd1 > len_y) begin
                            len_y <= run_y + 4'd1; end_y <= scan_idx;
                        end
                    end else
                        run_y <= 4'd0;
                end
                scan <= scan + 5'd1;
                if (scan == 5'd20) st <= S_MOVE;
            end
            S_MOVE: begin
                if (sweeps != 6'h3F) sweeps <= sweeps + 6'd1;
                if (peak >= MIN_PEAK && (ok_x || ok_y)) begin
                    // The run is quiet on the clean bits; within it, take the
                    // rotation where all eight bits disagree least.  On this
                    // board the bottom bank misreads far more at some rotations
                    // inside the run than others -- 12..16% against 3 for bits
                    // 4 and 5 -- and the run's centre can be the worst of them.
                    pk_x    <= pick_x;
                    pk_end  <= pick_x ? end_x : end_y;
                    pk_len  <= pick_x ? len_x : len_y;
                    pk_best <= pick_x ? centre(end_x, len_x) : centre(end_y, len_y);
                    pk_k    <= 4'd0;
                    pk_min  <= {(WIN_W+1){1'b1}};
                    st      <= S_PICK;
                end else begin
                    rot <= keep;          // no signal, or nothing quiet
                    n <= 0; cnt_x <= 0; st <= S_TRACK;
                end
            end
            S_PICK: begin
                if (pk_takes) begin
                    pk_min  <= pk_val;
                    pk_best <= pk_r;
                end
                pk_k <= pk_k + 4'd1;
                if (pk_k == pk_len - 4'd1) begin
                    rot      <= pk_takes ? pk_r : pk_best;
                    keep     <= pk_takes ? pk_r : pk_best;
                    use_x    <= pk_x;
                    cal_done <= 1'b1;
                    n <= 0; cnt_x <= 0; st <= S_TRACK;
                end
            end
            S_TRACK: begin
                n <= n + 1'b1;
                if (track_differ && !cnt_x[WIN_W]) cnt_x <= cnt_x + 1'b1;
                if (n == WIN - 1) begin
                    n <= 0; cnt_x <= 0;
                    track_count <= cnt_x;
                    // The switching has reached a read, or nothing was found:
                    // measure again from the start.
                    if (!cal_done || cnt_x >= quiet_max) begin
                        st <= S_SETTLE; sweep <= 4'd0; rot <= 4'd0; peak <= 0;
                    end
                end
            end
            default: st <= S_SETTLE;
            endcase
        end
    end
endmodule

`default_nettype wire
