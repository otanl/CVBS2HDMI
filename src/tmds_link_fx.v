`default_nettype none

// Glitch at the HDMI layer: the link failing, as the sink would show it.
//
// Worked out in the pixel domain and then encoded properly, so every symbol
// sent is a valid one -- corrupting the symbols themselves makes this sink
// drop the picture altogether.  Two failures, one after the other as the knob
// turns:
//
//   - Lane skew.  The sink pairs each red character with a green one that
//     left `s` pixels earlier and a blue one 2s earlier, as when a lane's
//     deskew fails: the three primaries come apart along the line, trailing
//     to the right, and the skew is drawn afresh for each line, so it shivers
//     more the further the knob goes.  s runs to 31.
//   - Lane errors.  Past half way, blocks of a few lines where one lane is
//     lost (black) or its control bits are misread: bit 8 wrong decodes XOR
//     as XNOR and flips bits 1..7 (v ^ 0xFE); bits 8 and 9 wrong invert the
//     byte.  Flat areas stay flat in a wrong colour, edges stay where they
//     were -- what a bad cable does in streaks, not snow.
//
// amount 0 passes the picture through untouched.
module tmds_link_fx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  amount,      // 0 = off
    input  wire        data,        // pix_in is active video
    input  wire [23:0] pix_in,      // {red, green, blue}
    output wire [23:0] pix_out
);
    // xorshift32: a fresh 32 bits every clock, XORs and shifts only.
    reg  [31:0] rn = 32'h6D2B_79F5;
    wire [31:0] rn1 = rn ^ (rn << 13);
    wire [31:0] rn2 = rn1 ^ (rn1 >> 17);
    always @(posedge clk or negedge rst_n)
        if (!rst_n) rn <= 32'h6D2B_79F5;
        else        rn <= rn2 ^ (rn2 << 5);

    reg        data_q;
    reg  [9:0] xp;                    // pixel within the active line
    reg  [4:0] skew;                  // this line's s
    reg  [3:0] b_lines;               // lines of the current block still to go
    reg        b_on;
    reg  [1:0] b_lane, b_kind;        // lane 2 red, 1 green, 0 blue
    reg  [9:0] b_x0;
    reg  [10:0] b_x1;
    wire       line_end = data_q && !data;

    // The next line's skew: amount / 8, plus a shiver drawn from the bits of
    // amount / 32.
    wire [5:0] skew_raw = {1'b0, amount[7:3]} + {3'd0, rn[2:0] & amount[7:5]};
    // A block starts on a line with probability p (p / 2), p = (amount - 128)
    // / 128: two draws, no multiplier.  Rare just past half way, a block every
    // few lines at full, each lasting 1..16 lines.
    wire [7:0] b_prob = amount[7] ? {amount[6:0], 1'b0} : 8'd0;
    reg  [31:0] rq;                   // last clock's draw, for the block's span
    always @(posedge clk) rq <= rn;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_q <= 1'b0; xp <= 10'd0; skew <= 5'd0;
            b_lines <= 4'd0; b_on <= 1'b0; b_lane <= 2'd0; b_kind <= 2'd0;
            b_x0 <= 10'd0; b_x1 <= 11'd0;
        end else begin
            data_q <= data;
            xp     <= data ? xp + 10'd1 : 10'd0;
            if (line_end) begin
                skew <= skew_raw[5] ? 5'd31 : skew_raw[4:0];
                if (b_lines != 4'd0) begin
                    b_lines <= b_lines - 4'd1;
                end else if (rn[10:3] < b_prob && rn[18:11] < {1'b0, b_prob[7:1]}) begin
                    b_on    <= 1'b1;
                    b_lines <= rn[22:19];
                    b_lane  <= (rn[24:23] == 2'd3) ? 2'd1 : rn[24:23];
                    b_kind  <= rn[26:25];
                    b_x0    <= {1'b0, rq[8:0]};                  // 0..511
                    b_x1    <= {2'b0, rq[8:0]} + {2'b0, rq[17:9]} + 11'd32;
                end else begin
                    b_on    <= 1'b0;
                end
            end
        end
    end

    // Skew: the green and blue lanes through 64-deep delay lines, blanking
    // entering as black.
    (* ram_style = "distributed" *) reg [7:0] g_mem [0:63];
    (* ram_style = "distributed" *) reg [7:0] b_mem [0:63];
    reg  [5:0] wp = 6'd0;
    wire [7:0] g_in = data ? pix_in[15:8] : 8'd0;
    wire [7:0] b_in = data ? pix_in[7:0]  : 8'd0;
    always @(posedge clk) begin
        g_mem[wp] <= g_in;
        b_mem[wp] <= b_in;
        wp <= wp + 6'd1;
    end
    wire [5:0] g_at = wp - {1'b0, skew};
    wire [5:0] b_at = wp - {skew, 1'b0};
    wire [7:0] g_sk = (skew == 5'd0) ? g_in : g_mem[g_at];
    wire [7:0] b_sk = (skew == 5'd0) ? b_in : b_mem[b_at];

    // Lane errors, inside the block's span.
    wire in_block = b_on && (xp >= b_x0) && ({1'b0, xp} < b_x1);
    function [7:0] lane_err;
        input [7:0] v;
        input [1:0] kind;
        case (kind)
            2'd1:    lane_err = v ^ 8'hFE;     // bit 8 misread
            2'd2:    lane_err = ~v;            // bits 8 and 9 misread
            default: lane_err = 8'd0;          // lane lost
        endcase
    endfunction
    wire [7:0] r_o = (in_block && b_lane == 2'd2) ? lane_err(pix_in[23:16], b_kind) : pix_in[23:16];
    wire [7:0] g_o = (in_block && b_lane == 2'd1) ? lane_err(g_sk, b_kind) : g_sk;
    wire [7:0] b_o = (in_block && b_lane == 2'd0) ? lane_err(b_sk, b_kind) : b_sk;

    assign pix_out = data ? {r_o, g_o, b_o} : pix_in;
endmodule

`default_nettype wire
