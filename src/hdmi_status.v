`default_nettype none

// Reports the HDMI output chain's vital signs over the onboard USB serial, so
// a "no signal" complaint can be split into "the FPGA is not producing a valid
// stream" and "the sink will not accept it" -- without a scope.
//
// Everything is counted in the 27 MHz crystal domain, which is independent of
// the PLL under test.  Values are hex to keep the formatter to a nibble
// lookup.  For 720x480p59.94 the expected line is
//
//     HDMI lk=1 fps=3B lps=07AEC
//
//     lk  = PLL locked
//     fps = frames per second, 0x3B = 59   (59.94)
//     lps = lines per second,  0x7AEC = 31468 (27e6 / 858)
//
// For 1280x720p60 it is  HDMI lk=1 fps=3C lps=0AFC8  (74.25e6 / 1650 = 45000).
//
// lps wrong  -> pixel clock or horizontal timing is wrong.
// lps right, fps wrong -> vertical timing is wrong.
// both right -> the FPGA side is doing its job; look downstream.
module hdmi_status #(
    parameter integer CLK_HZ       = 27_000_000,
    parameter integer CLKS_PER_BIT = 234          // 27 MHz / 115200
) (
    input  wire clk27,
    input  wire rst_n,
    input  wire pll_lock,
    input  wire vsync_pix,        // active low, from the pixel-clock domain
    input  wire hsync_pix,        // active low, from the pixel-clock domain
    output wire uart_tx_pin
);
    reg [2:0] vs_sync, hs_sync;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            vs_sync <= 3'b111;
            hs_sync <= 3'b111;
        end else begin
            vs_sync <= {vs_sync[1:0], vsync_pix};
            hs_sync <= {hs_sync[1:0], hsync_pix};
        end
    end
    wire vs_fall = vs_sync[2] & ~vs_sync[1];
    wire hs_fall = hs_sync[2] & ~hs_sync[1];

    reg [24:0] win;
    reg [7:0]  f_acc, f_rep;
    reg [19:0] l_acc, l_rep;
    reg        lk_rep;
    reg        start;

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            win <= 25'd0; f_acc <= 8'd0; l_acc <= 20'd0;
            f_rep <= 8'd0; l_rep <= 20'd0; lk_rep <= 1'b0; start <= 1'b0;
        end else begin
            start <= 1'b0;
            if (vs_fall && f_acc != 8'hFF)     f_acc <= f_acc + 8'd1;
            if (hs_fall && l_acc != 20'hFFFFF) l_acc <= l_acc + 20'd1;
            if (win == CLK_HZ - 1) begin
                win    <= 25'd0;
                f_rep  <= f_acc;  f_acc <= 8'd0;
                l_rep  <= l_acc;  l_acc <= 20'd0;
                lk_rep <= pll_lock;
                start  <= 1'b1;
            end else begin
                win <= win + 25'd1;
            end
        end
    end

    reg  [7:0] tx_data;
    reg        tx_stb;
    wire       tx_busy;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk27), .rst_n(rst_n),
        .data(tx_data), .stb(tx_stb), .tx(uart_tx_pin), .busy(tx_busy)
    );

    // "HDMI lk=X fps=XX lps=XXXXX\r\n"
    localparam integer LEN = 28;

    function [7:0] hexchar(input [3:0] n);
        hexchar = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
    endfunction

    function [7:0] lit(input [4:0] i);
        case (i)
            5'd0:  lit = "H";   5'd1:  lit = "D";   5'd2:  lit = "M";
            5'd3:  lit = "I";   5'd4:  lit = " ";   5'd5:  lit = "l";
            5'd6:  lit = "k";   5'd7:  lit = "=";   5'd9:  lit = " ";
            5'd10: lit = "f";   5'd11: lit = "p";   5'd12: lit = "s";
            5'd13: lit = "=";   5'd16: lit = " ";   5'd17: lit = "l";
            5'd18: lit = "p";   5'd19: lit = "s";   5'd20: lit = "=";
            5'd26: lit = 8'h0D; default: lit = 8'h0A;
        endcase
    endfunction

    reg [4:0] idx;
    reg       busy_r;

    wire can_emit = !tx_busy && !tx_stb;

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            idx <= 5'd0; busy_r <= 1'b0; tx_stb <= 1'b0; tx_data <= 8'd0;
        end else begin
            tx_stb <= 1'b0;
            if (!busy_r) begin
                if (start) begin busy_r <= 1'b1; idx <= 5'd0; end
            end else if (can_emit) begin
                case (idx)
                    5'd8:  tx_data <= lk_rep ? "1" : "0";
                    5'd14: tx_data <= hexchar(f_rep[7:4]);
                    5'd15: tx_data <= hexchar(f_rep[3:0]);
                    5'd21: tx_data <= hexchar(l_rep[19:16]);
                    5'd22: tx_data <= hexchar(l_rep[15:12]);
                    5'd23: tx_data <= hexchar(l_rep[11:8]);
                    5'd24: tx_data <= hexchar(l_rep[7:4]);
                    5'd25: tx_data <= hexchar(l_rep[3:0]);
                    default: tx_data <= lit(idx);
                endcase
                tx_stb <= 1'b1;
                if (idx == LEN - 1) busy_r <= 1'b0;
                else                idx <= idx + 5'd1;
            end
        end
    end
endmodule

`default_nettype wire
