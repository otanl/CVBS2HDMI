`default_nettype none

// Glitch at the HDMI layer: what a TMDS bit error does to a pixel, as the sink
// would decode it.
//
// Corrupting the symbols on the wire is the obvious way and it does not work:
// the sink here counts bad characters and drops the picture altogether.  So
// the error is worked out in the FPGA instead -- each hit pixel is encoded as
// its TMDS data word (transition-minimised, and inverted or not at random, as
// the running disparity would have it), bits of the word are flipped, and the
// result is decoded exactly as the sink's decoder does it.  That byte goes to
// the real encoder, so every symbol sent is a valid one and the link never
// notices.  A flipped bit 9 or 8 changes how the whole byte decodes, a flipped
// data bit smears into its neighbour through the XOR/XNOR chain: the unrelated
// colours of a bad cable, per channel, and snow at full density.
module tmds_sparkle #(
    parameter MASK_ZERO = 1'b0     // test only: hit with an all-zero error
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  density,     // 0 = off; hits a channel with (density^2)/2^16
    input  wire        data,        // pix_in is active video
    input  wire [23:0] pix_in,      // {red, green, blue}
    output wire [23:0] pix_out
);
    // Two xorshift32 generators, a fresh 64 bits every clock, XORs and shifts
    // only.
    reg [31:0] ra = 32'h6D2B_79F5, rb = 32'hC0FF_EE17;
    wire [31:0] ra1 = ra ^ (ra << 13);
    wire [31:0] ra2 = ra1 ^ (ra1 >> 17);
    wire [31:0] rb1 = rb ^ (rb << 13);
    wire [31:0] rb2 = rb1 ^ (rb1 >> 17);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ra <= 32'h6D2B_79F5; rb <= 32'hC0FF_EE17;
        end else begin
            ra <= ra2 ^ (ra2 << 5);
            rb <= rb2 ^ (rb2 << 5);
        end
    end

    wire [15:0] p16 = density * density;
    wire [7:0]  p   = p16[15:8];

    // Encode as a data word, flip the mask's bits, decode as the sink does.
    function [7:0] via_tmds;
        input [7:0] px;
        input       inv;
        input [9:0] mask;
        integer i;
        reg [3:0] ones;
        reg       xnor_mode;
        reg [8:0] q;
        reg [9:0] w;
        reg [7:0] d;
        begin
            ones = 4'd0;
            for (i = 0; i < 8; i = i + 1) ones = ones + {3'd0, px[i]};
            xnor_mode = (ones > 4'd4) || (ones == 4'd4 && !px[0]);
            q[0] = px[0];
            for (i = 1; i < 8; i = i + 1)
                q[i] = xnor_mode ? ~(q[i-1] ^ px[i]) : (q[i-1] ^ px[i]);
            q[8] = !xnor_mode;
            w = {inv, q[8], inv ? ~q[7:0] : q[7:0]} ^ mask;
            d = w[9] ? ~w[7:0] : w[7:0];
            via_tmds[0] = d[0];
            for (i = 1; i < 8; i = i + 1)
                via_tmds[i] = w[8] ? (d[i] ^ d[i-1]) : ~(d[i] ^ d[i-1]);
        end
    endfunction

    genvar c;
    generate
        for (c = 0; c < 3; c = c + 1) begin : g_ch
            wire [7:0] px   = pix_in[8*c +: 8];
            wire [9:0] mask = MASK_ZERO ? 10'd0 : rb[10*c +: 10];
            wire       hit  = data && (density != 8'd0) && (ra[8*c +: 8] < p);
            assign pix_out[8*c +: 8] = hit ? via_tmds(px, ra[24 + c], mask) : px;
        end
    endgenerate
endmodule

`default_nettype wire
