`default_nettype none

// Literal text of the once-per-window report, stored as one flat, NUL-separated
// string.  The formatter walks it linearly: every NUL ends a segment and means
// "now print the next value", so no per-segment offset table is needed.
//
//   "ADC ph=<n> tog=<hex> min=<n> max=<n> thr=<n> ln=<n> lmin=<n> lmax=<n>
//    ok=<n> lns=<n> vs=<n> otr=<n> clk=<n> lk=<n>\r\n"
module report_rom (
    input  wire [9:0] addr,
    output reg  [7:0] c
);
    localparam integer LENGTH = 87;

    always @* begin
        case (addr)
            10'd0  : c = 8'h41;   // 'A'
            10'd1  : c = 8'h44;   // 'D'
            10'd2  : c = 8'h43;   // 'C'
            10'd3  : c = 8'h20;   // ' '
            10'd4  : c = 8'h70;   // 'p'
            10'd5  : c = 8'h68;   // 'h'
            10'd6  : c = 8'h3D;   // '='
            10'd7  : c = 8'h00;   // 0
            10'd8  : c = 8'h20;   // ' '
            10'd9  : c = 8'h74;   // 't'
            10'd10 : c = 8'h6F;   // 'o'
            10'd11 : c = 8'h67;   // 'g'
            10'd12 : c = 8'h3D;   // '='
            10'd13 : c = 8'h00;   // 0
            10'd14 : c = 8'h20;   // ' '
            10'd15 : c = 8'h6D;   // 'm'
            10'd16 : c = 8'h69;   // 'i'
            10'd17 : c = 8'h6E;   // 'n'
            10'd18 : c = 8'h3D;   // '='
            10'd19 : c = 8'h00;   // 0
            10'd20 : c = 8'h20;   // ' '
            10'd21 : c = 8'h6D;   // 'm'
            10'd22 : c = 8'h61;   // 'a'
            10'd23 : c = 8'h78;   // 'x'
            10'd24 : c = 8'h3D;   // '='
            10'd25 : c = 8'h00;   // 0
            10'd26 : c = 8'h20;   // ' '
            10'd27 : c = 8'h74;   // 't'
            10'd28 : c = 8'h68;   // 'h'
            10'd29 : c = 8'h72;   // 'r'
            10'd30 : c = 8'h3D;   // '='
            10'd31 : c = 8'h00;   // 0
            10'd32 : c = 8'h20;   // ' '
            10'd33 : c = 8'h6C;   // 'l'
            10'd34 : c = 8'h6E;   // 'n'
            10'd35 : c = 8'h3D;   // '='
            10'd36 : c = 8'h00;   // 0
            10'd37 : c = 8'h20;   // ' '
            10'd38 : c = 8'h6C;   // 'l'
            10'd39 : c = 8'h6D;   // 'm'
            10'd40 : c = 8'h69;   // 'i'
            10'd41 : c = 8'h6E;   // 'n'
            10'd42 : c = 8'h3D;   // '='
            10'd43 : c = 8'h00;   // 0
            10'd44 : c = 8'h20;   // ' '
            10'd45 : c = 8'h6C;   // 'l'
            10'd46 : c = 8'h6D;   // 'm'
            10'd47 : c = 8'h61;   // 'a'
            10'd48 : c = 8'h78;   // 'x'
            10'd49 : c = 8'h3D;   // '='
            10'd50 : c = 8'h00;   // 0
            10'd51 : c = 8'h20;   // ' '
            10'd52 : c = 8'h6F;   // 'o'
            10'd53 : c = 8'h6B;   // 'k'
            10'd54 : c = 8'h3D;   // '='
            10'd55 : c = 8'h00;   // 0
            10'd56 : c = 8'h20;   // ' '
            10'd57 : c = 8'h6C;   // 'l'
            10'd58 : c = 8'h6E;   // 'n'
            10'd59 : c = 8'h73;   // 's'
            10'd60 : c = 8'h3D;   // '='
            10'd61 : c = 8'h00;   // 0
            10'd62 : c = 8'h20;   // ' '
            10'd63 : c = 8'h76;   // 'v'
            10'd64 : c = 8'h73;   // 's'
            10'd65 : c = 8'h3D;   // '='
            10'd66 : c = 8'h00;   // 0
            10'd67 : c = 8'h20;   // ' '
            10'd68 : c = 8'h6F;   // 'o'
            10'd69 : c = 8'h74;   // 't'
            10'd70 : c = 8'h72;   // 'r'
            10'd71 : c = 8'h3D;   // '='
            10'd72 : c = 8'h00;   // 0
            10'd73 : c = 8'h20;   // ' '
            10'd74 : c = 8'h63;   // 'c'
            10'd75 : c = 8'h6C;   // 'l'
            10'd76 : c = 8'h6B;   // 'k'
            10'd77 : c = 8'h3D;   // '='
            10'd78 : c = 8'h00;   // 0
            10'd79 : c = 8'h20;   // ' '
            10'd80 : c = 8'h6C;   // 'l'
            10'd81 : c = 8'h6B;   // 'k'
            10'd82 : c = 8'h3D;   // '='
            10'd83 : c = 8'h00;   // 0
            10'd84 : c = 8'h0D;   // CR
            10'd85 : c = 8'h0A;   // LF
            10'd86 : c = 8'h00;   // 0
            default: c = 8'h00;
        endcase
    end
endmodule

`default_nettype wire
