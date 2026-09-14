`default_nettype none
// 64 phase bins, evaluated at each bin centre; signed amplitude is 64.
// Sinusoidal weights avoid the phase-dependent gain of a sign/ternary mixer
// with only seven ADC samples per carrier cycle.
module chroma_sincos (
    input wire [5:0] phase,
    output wire signed [7:0] cosine,
    output wire signed [7:0] sine
);
    function signed [7:0] sin64;
        input [5:0] p;
        reg [3:0] index;
        reg signed [7:0] amplitude;
        begin
            index = p[4] ? ~p[3:0] : p[3:0];
            case (index)
                4'd0: amplitude = 8'sd3;
                4'd1: amplitude = 8'sd9;
                4'd2: amplitude = 8'sd16;
                4'd3: amplitude = 8'sd22;
                4'd4: amplitude = 8'sd27;
                4'd5: amplitude = 8'sd33;
                4'd6: amplitude = 8'sd38;
                4'd7: amplitude = 8'sd43;
                4'd8: amplitude = 8'sd47;
                4'd9: amplitude = 8'sd51;
                4'd10: amplitude = 8'sd55;
                4'd11: amplitude = 8'sd58;
                4'd12: amplitude = 8'sd60;
                4'd13: amplitude = 8'sd62;
                4'd14: amplitude = 8'sd63;
                4'd15: amplitude = 8'sd64;
            endcase
            sin64 = p[5] ? -amplitude : amplitude;
        end
    endfunction
    assign sine = sin64(phase);
    assign cosine = sin64(phase + 6'd16);
endmodule
`default_nettype wire
