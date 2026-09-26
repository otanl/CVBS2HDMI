`timescale 1ns/1ps

// Behavioural stand-in for the Gowin rPLL, good enough for functional
// simulation: it measures the input period and emits CLKIN*(FBDIV_SEL+1)
// /(IDIV_SEL+1), asserting LOCK after a short delay.  Not a timing model.
module rPLL (
    output wire       CLKOUT,
    output wire       LOCK,
    output wire       CLKOUTP,
    output wire       CLKOUTD,
    output wire       CLKOUTD3,
    input  wire       RESET,
    input  wire       RESET_P,
    input  wire       CLKIN,
    input  wire       CLKFB,
    input  wire [5:0] FBDSEL,
    input  wire [5:0] IDSEL,
    input  wire [5:0] ODSEL,
    input  wire [3:0] PSDA,
    input  wire [3:0] DUTYDA,
    input  wire [3:0] FDLY
);
    parameter FCLKIN           = "100.0";
    parameter DYN_IDIV_SEL     = "false";
    parameter IDIV_SEL         = 0;
    parameter DYN_FBDIV_SEL    = "false";
    parameter FBDIV_SEL        = 0;
    parameter DYN_ODIV_SEL     = "false";
    parameter ODIV_SEL         = 8;
    parameter PSDA_SEL         = "0000";
    parameter DYN_DA_EN        = "false";
    parameter DUTYDA_SEL       = "1000";
    parameter CLKOUT_FT_DIR    = 1'b1;
    parameter CLKOUTP_FT_DIR   = 1'b1;
    parameter CLKOUT_DLY_STEP  = 0;
    parameter CLKOUTP_DLY_STEP = 0;
    parameter CLKFB_SEL        = "internal";
    parameter CLKOUT_BYPASS    = "false";
    parameter CLKOUTP_BYPASS   = "false";
    parameter CLKOUTD_BYPASS   = "false";
    parameter DYN_SDIV_SEL     = 2;
    parameter CLKOUTD_SRC      = "CLKOUT";
    parameter CLKOUTD3_SRC     = "CLKOUT";
    parameter DEVICE           = "GW2A-18";

    real period_in  = 0.0;
    real last_edge  = -1.0;
    real period_out;

    reg clk_r  = 1'b0;
    reg lock_r = 1'b0;

    assign CLKOUT   = clk_r;
    assign CLKOUTP  = clk_r;
    assign CLKOUTD  = clk_r;
    assign CLKOUTD3 = clk_r;
    assign LOCK     = lock_r;

    always @(posedge CLKIN) begin
        if (last_edge >= 0.0) period_in = $realtime - last_edge;
        last_edge = $realtime;
    end

    initial begin
        wait (period_in > 0.0);
        period_out = period_in * (IDIV_SEL + 1) / (FBDIV_SEL + 1);
        fork
            forever #(period_out / 2.0) clk_r = ~clk_r;
            // LOCK must not lead the clock, or a design whose reset is released
            // by LOCK would never see an edge while reset is asserted.
            begin #(period_out * 20.0) lock_r = 1'b1; end
        join
    end
endmodule

// Functional HDMI primitive models. Physical TMDS timing is checked on the
// board, not by these idealised clock/serializer/output-buffer models.
module CLKDIV (output wire CLKOUT, input wire HCLKIN, RESETN, CALIB);
    parameter DIV_MODE = "5";
    parameter GSREN = "false";
    reg [2:0] count = 0;
    always @(posedge HCLKIN or negedge RESETN)
        if (!RESETN) count <= 0;
        else count <= count == 4 ? 0 : count + 1;
    assign CLKOUT = RESETN && count < 2;
endmodule

module OSER10 (
    output reg Q,
    input wire D0,D1,D2,D3,D4,D5,D6,D7,D8,D9,
    input wire PCLK,FCLK,RESET
);
    reg [9:0] word;
    reg [3:0] index=0;
    always @(posedge PCLK) word <= {D9,D8,D7,D6,D5,D4,D3,D2,D1,D0};
    always @(posedge FCLK or negedge FCLK or posedge RESET)
        if (RESET) begin index<=0; Q<=0; end
        else begin Q<=word[index]; index<=index==9 ? 0 : index+1; end
endmodule

module TLVDS_OBUF(input wire I, output wire O, OB);
    assign O=I;
    assign OB=~I;
endmodule

// IO-logic registers, behaviourally.  Yosys's own models for these are empty.
// IDDR: Q0 is the rising-edge capture and Q1 the falling-edge one, both
// presented at the rising edge; the capture uses Q0 only.
module IDDR (input wire D, input wire CLK, output reg Q0 = 1'b0, output reg Q1 = 1'b0);
    parameter Q0_INIT = 1'b0;
    parameter Q1_INIT = 1'b0;
    reg fall = 1'b0;
    always @(negedge CLK) fall <= D;
    always @(posedge CLK) begin
        Q0 <= D;
        Q1 <= fall;
    end
endmodule

// ODDR: D0 in the first half of the clock, D1 in the second; Q1 carries TX
// for a tristate buffer.  Q0 is a register on both edges, so a word whose
// halves differ does not produce a zero-width glitch at the rising edge (a
// combinational CLK ? r0 : r1 briefly shows the old r0 there).
module ODDR (input wire D0, input wire D1, input wire TX, input wire CLK,
             output wire Q0, output wire Q1);
    parameter TXCLK_POL = 0;
    parameter INIT = 0;
    reg q = 1'b0, d1_hold = 1'b0;
    always @(posedge CLK) begin
        q       <= D0;
        d1_hold <= D1;
    end
    always @(negedge CLK) q <= d1_hold;
    assign Q0 = q;
    assign Q1 = TX;
endmodule

`default_nettype wire
