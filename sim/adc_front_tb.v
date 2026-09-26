`default_nettype none
`timescale 1ps/1ps

// adc_front against a modelled AD9280 whose outputs switch TOD ps after each
// rising edge of adc_clk, with a SWITCH ps window of random bits around the
// switch.  Once calibration has settled, the recovered sample stream must
// equal the source sequence at a constant latency -- for every TOD across the
// whole 39.7 ns period.  With DRIFT, the delay then moves by that much, as a
// warming converter's would, and the stream must come back clean.  With AUTO
// off and the rotation chosen to put the read inside the window, it must not
// (the negative control).
module adc_front_tb;
    parameter integer TOD        = 20000;  // output delay, ps
    parameter integer SWITCH     = 5000;   // width of the switching window, ps
    parameter         AUTO       = 1'b1;
    parameter integer MANUAL     = 0;      // rotation, with AUTO off
    parameter         EXPECT_BAD = 1'b0;   // with AUTO off: MANUAL reads inside the window
    parameter integer DRIFT      = 0;      // ps added to TOD after the first check
    parameter integer WIN_W      = 12;
    // Glitch bits 0, 1, 4 and 5 at random instants, as the board's bottom-bank
    // pins read: the calibration must still settle on one sweep, and the
    // check is then made on the other four bits.
    parameter         NOISY      = 1'b0;

    reg fclk = 1'b0;
    always #3968 fclk = ~fclk;            // 126 MHz
    wire pclk;
    CLKDIV #(.DIV_MODE("5")) u_div (.CLKOUT(pclk), .HCLKIN(fclk), .RESETN(1'b1), .CALIB(1'b0));
    reg rst_n = 1'b0;

    wire       adc_clk;
    reg  [7:0] adc_d = 8'd0;
    wire [7:0] sample;
    wire [3:0] rot;
    wire       cal_done;
    adc_front #(.AUTO(AUTO), .WIN_W(WIN_W)) dut (
        .pclk(pclk), .fclk(fclk), .rst_n(rst_n), .adc_d(adc_d), .adc_clk(adc_clk),
        .manual_rot(MANUAL[3:0]), .rot_skew(4'd0), .sample(sample), .rot_in_use(rot), .cal_done(cal_done)
    );

    // The converter: a new code every clock, from a known sequence.  A window
    // that would open before the edge that starts it is the same as one a
    // period later; the latency search absorbs the extra conversion.
    localparam integer PERIOD = 39680;
    integer tod_now = TOD;
    reg [15:0] lfsr = 16'hBEEF;
    reg [7:0]  hist [0:4095];
    integer    conv = 0;
    // The code is passed in, not looked up at the end of the window: a window
    // that straddles the next edge would otherwise output that edge's code.
    task automatic convert(input [7:0] code, input integer lead);
        begin
            #(lead);
            repeat (SWITCH/500) begin adc_d = $random; #500; end
            adc_d = code;
        end
    endtask
    task automatic glitch(input integer at);
        begin
            #(at);
            adc_d = adc_d ^ ({$random} & 8'b0011_0011);
            #2000;
            adc_d = adc_d & 8'b1100_1100 | hist[(conv - 1) % 4096] & 8'b0011_0011;
        end
    endtask
    always @(posedge adc_clk) begin
        if (NOISY && ({$random} % 8 == 0))
            fork glitch({$random} % 36000); join_none
        lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        hist[conv % 4096] = lfsr[7:0];
        conv = conv + 1;
        fork
            convert(lfsr[7:0], ((tod_now - SWITCH/2) % PERIOD + PERIOD) % PERIOD);
        join_none
    end

    // Latency by counting matches over a thousand samples -- one match at a
    // random code is a 1-in-256 accident per candidate -- then every later
    // sample must match it.
    integer cand, best, lat, bad, checked;
    wire [7:0] mask = NOISY ? 8'b1100_1100 : 8'hFF;
    integer hits [1:8];
    task measure;
        begin
            for (cand = 1; cand <= 8; cand = cand + 1) hits[cand] = 0;
            repeat (1000) begin
                @(posedge pclk);
                for (cand = 1; cand <= 8; cand = cand + 1)
                    if ((sample & mask) === (hist[(conv - cand) % 4096] & mask)) hits[cand] = hits[cand] + 1;
            end
            best = 0; lat = -1;
            for (cand = 1; cand <= 8; cand = cand + 1)
                if (hits[cand] > best) begin best = hits[cand]; lat = cand; end
            if (best < 900) lat = -1;
            bad = 0; checked = 0;
            if (lat > 0)
                repeat (20000) begin
                    @(posedge pclk);
                    if ((sample & mask) !== (hist[(conv - lat) % 4096] & mask)) bad = bad + 1;
                    checked = checked + 1;
                end
        end
    endtask

    // One sweep is ten windows plus settling; allow three for a re-sweep.
    localparam integer SWEEP = 10 * ((1 << WIN_W) + 512);

    initial begin
        repeat (20) @(posedge fclk);
        rst_n = 1'b1;
        if (AUTO) begin
            fork : wait_cal
                wait (cal_done);
                begin
                    repeat (4 * SWEEP) @(posedge pclk);
                    $display("adc_front: x %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d  y %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d  peak %0d",
                        dut.cx[0], dut.cx[1], dut.cx[2], dut.cx[3], dut.cx[4],
                        dut.cx[5], dut.cx[6], dut.cx[7], dut.cx[8], dut.cx[9],
                        dut.cy[0], dut.cy[1], dut.cy[2], dut.cy[3], dut.cy[4],
                        dut.cy[5], dut.cy[6], dut.cy[7], dut.cy[8], dut.cy[9], dut.peak);
                    $fatal(1, "calibration never completed");
                end
            join_any
            disable wait_cal;
            repeat (1000) @(posedge pclk);
        end else
            repeat (5000) @(posedge pclk);
        measure;
        $display("adc_front: TOD=%0d ps SWITCH=%0d AUTO=%0d rotation %0d pair %s latency %0d checked %0d mismatches %0d",
                 tod_now, SWITCH, AUTO, rot, dut.use_x ? "x" : "y", lat, checked, bad);
        if (AUTO && (lat < 0 || bad != 0)) $fatal(1, "calibrated read is not clean");
        if (AUTO && dut.sweeps > 2) $fatal(1, "calibration keeps re-sweeping: %0d", dut.sweeps);
        if (!AUTO && EXPECT_BAD && lat > 0 && bad == 0)
            $fatal(1, "negative control: a read inside the switching window came back clean");
        if (DRIFT != 0) begin
            tod_now = tod_now + DRIFT;
            repeat (3 * SWEEP) @(posedge pclk);
            measure;
            $display("adc_front: drifted to TOD=%0d ps: rotation %0d latency %0d checked %0d mismatches %0d",
                     tod_now, rot, lat, checked, bad);
            if (AUTO && (lat < 0 || bad != 0)) $fatal(1, "did not recover from drift");
        end
        $finish;
    end
endmodule
`default_nettype wire
