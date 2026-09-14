`default_nettype none

// Angle of a vector, by CORDIC vectoring, in 32-bit turn units.
//
// This exists because the obvious ways to get an angle are both closed off
// here.  `atan2` needs a divide; rotating the demodulated pair by the burst
// vector instead needs four variable-by-variable multiplies, and the project
// synthesises with `-nodsp` because Apicula cannot pack a MULT9X9 on this part.
// CORDIC needs neither: each iteration is a shift, two adds and a table lookup.
//
// It is also far cheaper than it looks in time.  One angle is wanted per line --
// the burst's -- and sixteen iterations at 126 MHz take 127 ns against a line
// of 63 us.  The sector approximation it replaces resolved 22.5 degrees; this
// resolves better than a hundredth of one.
//
// Only the angle is taken, so the CORDIC gain of 1.6468 is irrelevant: it
// scales x and y, which are discarded.
module cordic_atan #(
    parameter integer ITER = 16
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               start,        // one cycle; x,y sampled here
    input  wire signed [17:0] x_in,
    input  wire signed [17:0] y_in,
    output reg         [31:0] angle,        // 0 = +x axis, counts anticlockwise
    output reg                done          // one cycle when angle is valid
);
    reg signed [19:0] x, y;
    reg        [31:0] z;
    reg        [4:0]  k;
    reg               busy;

    // atan(2^-k), in turn units.
    reg [31:0] atan_k;
    always @(*) begin
        case (k)
             0: atan_k = 32'h20000000;  //  45.0000 deg
             1: atan_k = 32'h12E4051E;  //  26.5651 deg
             2: atan_k = 32'h09FB385B;  //  14.0362 deg
             3: atan_k = 32'h051111D4;  //   7.1250 deg
             4: atan_k = 32'h028B0D43;  //   3.5763 deg
             5: atan_k = 32'h0145D7E1;  //   1.7899 deg
             6: atan_k = 32'h00A2F61E;  //   0.8952 deg
             7: atan_k = 32'h00517C55;  //   0.4476 deg
             8: atan_k = 32'h0028BE53;  //   0.2238 deg
             9: atan_k = 32'h00145F2F;  //   0.1119 deg
            10: atan_k = 32'h000A2F98;  //   0.0560 deg
            11: atan_k = 32'h000517CC;  //   0.0280 deg
            12: atan_k = 32'h00028BE6;  //   0.0140 deg
            13: atan_k = 32'h000145F3;  //   0.0070 deg
            14: atan_k = 32'h0000A2FA;  //   0.0035 deg
            default: atan_k = 32'h0000517D;
        endcase
    end

    wire signed [19:0] x_sh = x >>> k;
    wire signed [19:0] y_sh = y >>> k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x     <= 20'sd0;
            y     <= 20'sd0;
            z     <= 32'd0;
            k     <= 5'd0;
            busy  <= 1'b0;
            angle <= 32'd0;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                // Fold the left half plane onto the right before iterating:
                // vectoring only converges for |angle| < 90 degrees, so a
                // vector pointing left has to be turned round first and the
                // half turn added back at the end.
                if (x_in[17]) begin
                    x <= -{{2{x_in[17]}}, x_in};
                    y <= -{{2{y_in[17]}}, y_in};
                    z <= 32'h8000_0000;          // 180 degrees
                end else begin
                    x <= {{2{x_in[17]}}, x_in};
                    y <= {{2{y_in[17]}}, y_in};
                    z <= 32'd0;
                end
                k    <= 5'd0;
                busy <= 1'b1;
            end else if (busy) begin
                // Drive y to zero; the angle turned out of it is the answer.
                if (y[19]) begin                 // y < 0, rotate anticlockwise
                    x <= x - y_sh;
                    y <= y + x_sh;
                    z <= z - atan_k;
                end else begin
                    x <= x + y_sh;
                    y <= y - x_sh;
                    z <= z + atan_k;
                end

                if (k == ITER[4:0] - 5'd1) begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    angle <= (y[19] ? (z - atan_k) : (z + atan_k));
                end else begin
                    k <= k + 5'd1;
                end
            end
        end
    end
endmodule

`default_nettype wire
