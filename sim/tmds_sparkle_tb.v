`default_nettype none
`timescale 1ns/1ps

// tmds_sparkle: a hit pixel is encoded as a TMDS data word, corrupted, and
// decoded as the sink would.  Three checks:
//   DENSITY 0            nothing changes (the negative control);
//   DENSITY d            the fraction of pixels changed follows (d/256)^2, and
//                        nothing changes outside active video;
//   MASK_ZERO, DENSITY 255  every pixel is hit with an empty error and must
//                        come back exactly: the encoder and decoder modelled
//                        inside are each other's inverse, both inversions.
module tmds_sparkle_tb;
    parameter integer DENSITY = 200;
    parameter         MASK_ZERO = 1'b0;
    localparam integer N = 200000;

    reg clk = 1'b0;
    always #19.841 clk = ~clk;
    reg rst_n = 1'b0;
    reg        data = 1'b0;
    reg [23:0] pix_in = 24'd0;
    wire [23:0] pix_out;
    tmds_sparkle #(.MASK_ZERO(MASK_ZERO)) dut (
        .clk(clk), .rst_n(rst_n), .density(DENSITY[7:0]), .data(data),
        .pix_in(pix_in), .pix_out(pix_out)
    );

    integer i, c, pixels = 0, changed = 0, blank_changed = 0;
    real want, got;
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        for (i = 0; i < N; i = i + 1) begin
            @(negedge clk);
            data   = ($random & 7) != 0;            // blanking one pixel in eight
            pix_in = $random;
            #1;
            for (c = 0; c < 3; c = c + 1) begin
                if (^pix_out === 1'bx) $fatal(1, "unknown output");
                if (!data && pix_out[8*c +: 8] !== pix_in[8*c +: 8])
                    blank_changed = blank_changed + 1;
                if (data) begin
                    pixels = pixels + 1;
                    if (pix_out[8*c +: 8] !== pix_in[8*c +: 8]) changed = changed + 1;
                end
            end
        end
        want = MASK_ZERO ? 0.0 : (DENSITY * DENSITY / 256) / 256.0;
        got = changed * 1.0 / pixels;
        $display("sparkle: density=%0d mask_zero=%0d channel values %0d, changed %0.3f (expected about %0.3f), changed in blanking %0d",
                 DENSITY, MASK_ZERO, pixels, got, want, blank_changed);
        if (blank_changed != 0) $fatal(1, "blanking touched");
        if ((DENSITY == 0 || MASK_ZERO) ? (changed != 0) : (got < want - 0.03 || got > want + 0.01))
            $fatal(1, "wrong corruption rate, or the TMDS model does not round-trip");
        $display("RESULT PASS");
        $finish;
    end
endmodule

`default_nettype wire
