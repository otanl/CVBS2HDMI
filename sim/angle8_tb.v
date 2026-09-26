`default_nettype none
`timescale 1ns/1ps

// src/angle8.v against a model of the Unit 8Angle's firmware
// (m5stack/M5Unit-8Angle-Internal-FW): address 0x43, one register per
// transaction -- a write of the register number, then a read of that one
// value -- and SCL stretched while each reply is prepared.
//
// Checks that all eight channels and the switch arrive, that a change is
// picked up on a later scan, and that present is set.  DEV other than 0x43 is
// the negative control: nothing answers, so present must stay low and no value
// may be written.
module angle8_tb;
    parameter [6:0]  DEV        = 7'h43;
    parameter integer STRETCH_NS = 30000;

    reg clk = 1'b0;
    always #19.841 clk = ~clk;              // 25.2 MHz
    reg rst_n = 1'b0;

    wire m_scl_low, m_sda_low;
    reg  s_scl_low = 1'b0, s_sda_low = 1'b0;
    wire scl = !(m_scl_low || s_scl_low);    // open drain, pulled up
    wire sda = !(m_sda_low || s_sda_low);

    wire [63:0] knobs;
    wire        sw, present;
    wire [7:0]  scans;
    angle8 dut (
        .clk(clk), .rst_n(rst_n), .scl_in(scl), .sda_in(sda),
        .scl_low(m_scl_low), .sda_low(m_sda_low),
        .knobs(knobs), .sw(sw), .present(present), .scans(scans)
    );

    // ---- the unit -----------------------------------------------------------
    reg [7:0] val [0:7];
    reg       sw_val;
    localparam integer IDLE = 0, ADDRS = 1, WR = 2, RD = 3;
    integer st = IDLE, nbit = 0, wr_len = 0, stops = 0;
    reg [7:0] shift = 8'd0, regp = 8'd0, prepared = 8'hEE;

    always @(negedge sda) if (scl) begin           // START
        st = ADDRS; nbit = 0; wr_len = 0;
    end
    always @(posedge sda) if (scl) begin           // STOP
        if (st == WR && wr_len == 1) begin
            if (regp >= 8'h10 && regp <= 8'h17) prepared = val[regp - 8'h10];
            else if (regp == 8'h20)             prepared = {7'd0, sw_val};
            else                                prepared = 8'hEE;
        end
        st = IDLE; stops = stops + 1;
    end
    always @(posedge scl) if (st != IDLE) begin
        nbit = nbit + 1;
        if (nbit <= 8 && st != RD) shift = {shift[6:0], sda};
    end
    always @(negedge scl) if (st != IDLE) begin
        if (nbit == 8) begin                        // the ACK slot begins
            if (st == ADDRS) begin
                if (shift[7:1] == DEV) s_sda_low = 1'b1;
                else st = IDLE;                     // not us
            end else if (st == WR) begin
                s_sda_low = 1'b1;
                if (wr_len == 0) regp = shift;
                wr_len = wr_len + 1;
            end else begin
                s_sda_low = 1'b0;                   // the master's ACK/NACK
            end
        end else if (nbit == 9) begin               // the ACK slot ends
            s_sda_low = 1'b0;
            nbit = 0;
            if (st == ADDRS) begin
                if (shift[0]) begin
                    st = RD;
                    s_scl_low = 1'b1;               // preparing the reply
                    #(STRETCH_NS);
                    s_sda_low = !prepared[7];
                    shift = {prepared[6:0], 1'b1};
                    // Data first, then SCL: released in the same instant, the
                    // model's own START detector would see SDA fall with SCL
                    // already high.
                    #100 s_scl_low = 1'b0;
                end else begin
                    st = WR;
                end
            end
        end else if (st == RD) begin
            s_sda_low = !shift[7];
            shift = {shift[6:0], 1'b1};
        end
    end

    // ---- the test -----------------------------------------------------------
    integer k, failures = 0;
    task expect_values;
        begin
            for (k = 0; k < 8; k = k + 1)
                if (knobs[8*k +: 8] !== (DEV == 7'h43 ? val[k] : 8'd0)) begin
                    $display("FAIL: channel %0d read %0d, expected %0d", k, knobs[8*k +: 8],
                             DEV == 7'h43 ? val[k] : 0);
                    failures = failures + 1;
                end
            if (DEV == 7'h43 && sw !== sw_val) begin
                $display("FAIL: switch read %0d, expected %0d", sw, sw_val);
                failures = failures + 1;
            end
            if (present !== (DEV == 7'h43)) begin
                $display("FAIL: present=%0d", present);
                failures = failures + 1;
            end
        end
    endtask

    task wait_scans;
        input integer n;
        integer start;
        begin
            start = scans;
            fork : w
                begin
                    wait (scans == ((start + n) & 255));
                    disable w;
                end
                begin
                    #(n * 12_000_000);              // a scan is about 5 ms
                    $display("FAIL: no scan completed");
                    failures = failures + 1;
                    disable w;
                end
            join
        end
    endtask

    initial begin
        for (k = 0; k < 8; k = k + 1) val[k] = 17 * k + 5;
        sw_val = 1'b1;
        #200 rst_n = 1'b1;
        wait_scans(2);
        expect_values;
        val[3] = 8'd200; val[7] = 8'd0; sw_val = 1'b0;
        wait_scans(2);
        expect_values;
        $display("angle8: DEV=0x%02h present=%0d switch=%0d knobs=%0d %0d %0d %0d %0d %0d %0d %0d scans=%0d stops=%0d",
                 DEV, present, sw, knobs[7:0], knobs[15:8], knobs[23:16], knobs[31:24],
                 knobs[39:32], knobs[47:40], knobs[55:48], knobs[63:56], scans, stops);
        if (failures != 0) $fatal(1, "angle8 reader failed");
        $display("RESULT PASS");
        $finish;
    end
endmodule

`default_nettype wire
