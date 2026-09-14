`default_nettype none

// Chroma-rejecting low-pass for the sync slicer.
//
// Slicing sync off the raw ADC samples only works while the source has little
// colour.  With a properly saturated picture the 3.58 MHz subcarrier swings
// far below any sensible threshold during active video, the slicer fires on
// subcarrier zero crossings instead of sync edges, and lock is impossible.
// Measured on 75% colour bars: 143 codes of subcarrier peak to peak against
// 36 codes of sync amplitude.
//
// Two cascaded 8-sample boxcars.  At 27 MHz an 8-tap boxcar puts a deep null
// at 3.375 MHz, close enough to the 3.579545 MHz subcarrier for about -25 dB;
// cascading two gives roughly -49 dB, which leaves well under one code of
// residual chroma.  Group delay is 7 samples (0.26 us) -- small against a
// 4.7 us sync pulse, and a constant offset that the line-position constants
// account for.
//
// Only the sync path uses this.  Luma and chroma must be taken from the raw
// samples, which still carry the subcarrier the colour decoder needs.
module sync_lpf (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       en,             // one pulse per ADC sample
    input  wire [7:0] din,
    output wire [7:0] dout
);
    reg  [7:0]  d1 [0:7];
    reg  [7:0]  d2 [0:7];
    reg  [10:0] acc1, acc2;
    integer     j;

    wire [7:0] lp1 = acc1[10:3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc1 <= 11'd0;
            acc2 <= 11'd0;
            for (j = 0; j < 8; j = j + 1) begin
                d1[j] <= 8'd0;
                d2[j] <= 8'd0;
            end
        end else if (en) begin
            acc1  <= acc1 + {3'd0, din} - {3'd0, d1[7]};
            for (j = 7; j > 0; j = j - 1) d1[j] <= d1[j-1];
            d1[0] <= din;

            acc2  <= acc2 + {3'd0, lp1} - {3'd0, d2[7]};
            for (j = 7; j > 0; j = j - 1) d2[j] <= d2[j-1];
            d2[0] <= lp1;
        end
    end

    assign dout = acc2[10:3];
endmodule

`default_nettype wire
