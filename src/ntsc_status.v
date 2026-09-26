`default_nettype none

// Serial report for the NTSC -> HDMI design: HDMI vitals plus the luma
// levels, because a monochrome picture cannot be judged by eye.  Once per
// second, at 115200 8N1:
//
//   NTSC lk=1 sl=1 per=06B4 fps=3C lps=07AEC blk=86 H 0000 ... (16 bins)
//
//   lk   PLL locked
//   sl   sync lock confidence, hex; 0x40 and above means locked
//   per  last accepted line period in samples.  0x642 = 1602 at the 25.2 MHz
//        sample rate (25.2e6 / 15734.264 = 1601.6); this is the number that
//        proves the capture path.  See CLAUDE.md.
//   fps  frames per second, 0x3C = 60
//   lps  lines per second,  0x7AEC = 31468
//   blk  measured black level (back porch), hex.  0x86 = 134.
//   sl?  the sync slicer's own per-line floor, ceiling and threshold.  When
//        lock fails these say why: a floor equal to the threshold means the
//        sync pulse has no amplitude left for the slicer to find.
//   g    luma gain setting from S1: 0 = x2.8125, 1 = x4, 2 = x6, 3 = x8.
//   ph   sampling phase, found automatically; 0..4 = 0/7.4/14.8/22.2/29.6 ns
//   H    16 bins of the raw active-video sample distribution, bin n covering
//        codes n*16 .. n*16+15, each count scaled down by 16.
//
// Read the histogram to set the luma gain: the highest non-trivial bin is
// peak white, and a large count in bin 15 means the input is clipping.
module ntsc_status #(
    parameter integer CLK_HZ       = 27_000_000,
    parameter integer CLKS_PER_BIT = 234,
    // Cycles of silence after configuration before anything is transmitted.
    // A flash-booted design starts the instant power is applied, well before
    // the host has enumerated the USB serial bridge, and a bridge flooded
    // through enumeration comes up wedged and stays that way.
    parameter integer UART_HOLDOFF  = 135_000_000
) (
    input  wire         clk27,
    input  wire         rst_n,
    input  wire         pll_lock,
    input  wire         sync_locked,
    input  wire [7:0]   lock_level,
    input  wire [15:0]  real_count,
    input  wire [15:0]  period,
    input  wire         vsync_pix,
    input  wire         hsync_pix,
    input  wire [7:0]   black,
    input  wire [7:0]   s_min,
    input  wire [7:0]   s_max,
    input  wire [7:0]   s_thr,
    input  wire [1:0]   gain_sel,
    input  wire [3:0]   phase_sel,
    input  wire [255:0] hist_flat,
    // Raw dump, emitted after the status line whenever one is ready.
    input  wire         dmp_rdy,
    input  wire [7:0]   dmp_rdata,
    output reg  [10:0]  dmp_raddr,
    output reg          dmp_ack,
    output wire         uart_tx_pin
);
    reg [2:0] vs_sync, hs_sync;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            vs_sync <= 3'b111; hs_sync <= 3'b111;
        end else begin
            vs_sync <= {vs_sync[1:0], vsync_pix};
            hs_sync <= {hs_sync[1:0], hsync_pix};
        end
    end
    wire vs_fall = vs_sync[2] & ~vs_sync[1];
    wire hs_fall = hs_sync[2] & ~hs_sync[1];

    localparam integer HOW = $clog2(UART_HOLDOFF);
    reg [HOW-1:0] holdoff;
    wire          uart_ready = (holdoff == UART_HOLDOFF - 1);
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n)           holdoff <= {HOW{1'b0}};
        else if (!uart_ready) holdoff <= holdoff + {{(HOW-1){1'b0}}, 1'b1};
    end

    reg [24:0]  win;
    reg [7:0]   f_acc, f_rep;
    reg [19:0]  l_acc, l_rep;
    reg         lk_rep, sl_rep;
    reg [1:0]   g_rep;
    reg [7:0]   ll_rep;
    reg [15:0]  rc_rep;
    reg [3:0]   ph_rep;
    reg [15:0]  per_rep;
    reg [7:0]   blk_rep, smin_rep, smax_rep, sthr_rep;
    reg [255:0] hist_lat;
    reg         start;

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            win <= 25'd0; f_acc <= 8'd0; l_acc <= 20'd0;
            f_rep <= 8'd0; l_rep <= 20'd0; lk_rep <= 1'b0; sl_rep <= 1'b0;
            per_rep <= 16'd0; blk_rep <= 8'd0; g_rep <= 2'd0; ph_rep <= 4'd0;
            smin_rep <= 8'd0; smax_rep <= 8'd0; sthr_rep <= 8'd0; hist_lat <= 256'd0; start <= 1'b0;
        end else begin
            start <= 1'b0;
            if (vs_fall && f_acc != 8'hFF)     f_acc <= f_acc + 8'd1;
            if (hs_fall && l_acc != 20'hFFFFF) l_acc <= l_acc + 20'd1;
            if (win == CLK_HZ - 1) begin
                win     <= 25'd0;
                f_rep   <= f_acc;  f_acc <= 8'd0;
                l_rep   <= l_acc;  l_acc <= 20'd0;
                lk_rep  <= pll_lock;
                sl_rep  <= sync_locked;
                ll_rep  <= lock_level;
                rc_rep  <= real_count;
                g_rep   <= gain_sel;
                ph_rep  <= phase_sel;
                per_rep <= period;
                blk_rep  <= black;
                smin_rep <= s_min;
                smax_rep <= s_max;
                sthr_rep <= s_thr;
                // Sampled asynchronously from the capture domain.  It only
                // changes once per field and this is a diagnostic, so a torn
                // read once in a while is acceptable.
                hist_lat <= hist_flat;
                start    <= uart_ready;
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

    function [7:0] hexchar(input [3:0] n);
        hexchar = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
    endfunction

    localparam integer HDR_LEN = 77;

    function [7:0] lit(input [6:0] i);
        case (i)
            6'd0:  lit = "N";  6'd1:  lit = "T";  6'd2:  lit = "S";
            6'd3:  lit = "C";  6'd4:  lit = " ";  6'd5:  lit = "l";
            6'd6:  lit = "k";  6'd7:  lit = "=";
            6'd9:  lit = " ";  7'd10: lit = "s";  7'd11: lit = "l";
            7'd12: lit = "=";
            7'd15: lit = "p";  7'd16: lit = "e";
            7'd17: lit = "r";  7'd18: lit = "=";
            7'd23: lit = " ";  7'd24: lit = "f";  7'd25: lit = "p";
            7'd26: lit = "s";  7'd27: lit = "=";
            7'd30: lit = " ";  7'd31: lit = "l";  7'd32: lit = "p";
            7'd33: lit = "s";  7'd34: lit = "=";
            7'd40: lit = " ";  7'd41: lit = "b";  7'd42: lit = "l";
            7'd43: lit = "k";  7'd44: lit = "=";
            7'd47: lit = " ";  7'd48: lit = "g";  7'd49: lit = "=";
            7'd51: lit = " ";  7'd52: lit = "p";  7'd53: lit = "h";
            7'd54: lit = "=";
            7'd56: lit = " ";  7'd57: lit = "s";  7'd58: lit = "=";
            7'd61: lit = "/";  7'd64: lit = "/";
            7'd67: lit = " ";  7'd68: lit = "r";  7'd69: lit = "e";
            7'd70: lit = "=";  7'd75: lit = " ";  7'd76: lit = "H";
            default: lit = " ";
        endcase
    endfunction

    localparam [2:0] ST_IDLE = 3'd0, ST_HDR  = 3'd1, ST_HIST = 3'd2,
                     ST_EOL  = 3'd3, ST_DHDR = 3'd4, ST_DROW = 3'd5,
                     ST_DFTR = 3'd6;

    // "\r\n#DUMP\r\n" and "\r\n#END\r\n"
    function [7:0] dhdr(input [3:0] i);
        case (i)
            4'd0: dhdr = 8'h0D; 4'd1: dhdr = 8'h0A; 4'd2: dhdr = "#";
            4'd3: dhdr = "D";   4'd4: dhdr = "U";   4'd5: dhdr = "M";
            4'd6: dhdr = "P";   4'd7: dhdr = 8'h0D; default: dhdr = 8'h0A;
        endcase
    endfunction

    function [7:0] dftr(input [3:0] i);
        case (i)
            4'd0: dftr = 8'h0D; 4'd1: dftr = 8'h0A; 4'd2: dftr = "#";
            4'd3: dftr = "E";   4'd4: dftr = "N";   4'd5: dftr = "D";
            4'd6: dftr = 8'h0D; default: dftr = 8'h0A;
        endcase
    endfunction

    reg [3:0] dlit;
    reg [2:0] dcol;          // 0 = space, 1..2 = the two hex digits
    reg [2:0] dnib;          // which nibble of the row address

    reg [2:0] state;
    reg [6:0] idx;
    reg [3:0] bin;
    reg [2:0] pos;

    wire can_emit = !tx_busy && !tx_stb;
    wire [15:0] bin_val = hist_lat[bin*16 +: 16];

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE; idx <= 7'd0; bin <= 4'd0; pos <= 3'd0;
            tx_stb <= 1'b0; tx_data <= 8'd0;
            dlit <= 4'd0; dcol <= 3'd0; dnib <= 3'd0;
            dmp_raddr <= 11'd0; dmp_ack <= 1'b0;
        end else begin
            tx_stb  <= 1'b0;
            dmp_ack <= 1'b0;
            case (state)
                ST_IDLE: if (start) begin
                    state <= ST_HDR; idx <= 7'd0;
                end

                ST_HDR: if (can_emit) begin
                    case (idx)
                        6'd8:  tx_data <= lk_rep ? "1" : "0";
                        7'd13: tx_data <= hexchar(ll_rep[7:4]);
                        7'd14: tx_data <= hexchar(ll_rep[3:0]);
                        7'd19: tx_data <= hexchar(per_rep[15:12]);
                        7'd20: tx_data <= hexchar(per_rep[11:8]);
                        7'd21: tx_data <= hexchar(per_rep[7:4]);
                        7'd22: tx_data <= hexchar(per_rep[3:0]);
                        7'd28: tx_data <= hexchar(f_rep[7:4]);
                        7'd29: tx_data <= hexchar(f_rep[3:0]);
                        7'd35: tx_data <= hexchar(l_rep[19:16]);
                        7'd36: tx_data <= hexchar(l_rep[15:12]);
                        7'd37: tx_data <= hexchar(l_rep[11:8]);
                        7'd38: tx_data <= hexchar(l_rep[7:4]);
                        7'd39: tx_data <= hexchar(l_rep[3:0]);
                        7'd45: tx_data <= hexchar(blk_rep[7:4]);
                        7'd46: tx_data <= hexchar(blk_rep[3:0]);
                        7'd50: tx_data <= hexchar({2'd0, g_rep});
                        7'd55: tx_data <= hexchar(ph_rep);
                        7'd59: tx_data <= hexchar(smin_rep[7:4]);
                        7'd60: tx_data <= hexchar(smin_rep[3:0]);
                        7'd62: tx_data <= hexchar(smax_rep[7:4]);
                        7'd63: tx_data <= hexchar(smax_rep[3:0]);
                        7'd65: tx_data <= hexchar(sthr_rep[7:4]);
                        7'd66: tx_data <= hexchar(sthr_rep[3:0]);
                        7'd71: tx_data <= hexchar(rc_rep[15:12]);
                        7'd72: tx_data <= hexchar(rc_rep[11:8]);
                        7'd73: tx_data <= hexchar(rc_rep[7:4]);
                        7'd74: tx_data <= hexchar(rc_rep[3:0]);
                        default: tx_data <= lit(idx);
                    endcase
                    tx_stb <= 1'b1;
                    if (idx == HDR_LEN - 1) begin
                        state <= ST_HIST; bin <= 4'd0; pos <= 3'd0;
                    end else begin
                        idx <= idx + 7'd1;
                    end
                end

                ST_HIST: if (can_emit) begin
                    case (pos)
                        3'd0: tx_data <= " ";
                        3'd1: tx_data <= hexchar(bin_val[15:12]);
                        3'd2: tx_data <= hexchar(bin_val[11:8]);
                        3'd3: tx_data <= hexchar(bin_val[7:4]);
                        default: tx_data <= hexchar(bin_val[3:0]);
                    endcase
                    tx_stb <= 1'b1;
                    if (pos == 3'd4) begin
                        pos <= 3'd0;
                        if (bin == 4'd15) state <= ST_EOL;
                        else              bin <= bin + 4'd1;
                    end else begin
                        pos <= pos + 3'd1;
                    end
                end

                ST_EOL: if (can_emit) begin
                    tx_data <= (pos == 3'd0) ? 8'h0D : 8'h0A;
                    tx_stb  <= 1'b1;
                    if (pos == 3'd0) begin
                        pos <= 3'd1;
                    end else begin
                        pos <= 3'd0;
                        if (dmp_rdy) begin
                            state     <= ST_DHDR;
                            dlit      <= 4'd0;
                            dmp_raddr <= 11'd0;
                        end else begin
                            state <= ST_IDLE;
                        end
                    end
                end

                ST_DHDR: if (can_emit) begin
                    tx_data <= dhdr(dlit);
                    tx_stb  <= 1'b1;
                    dlit    <= dlit + 4'd1;
                    if (dlit == 4'd8) begin
                        state <= ST_DROW;
                        dnib  <= 3'd0;
                        dcol  <= 3'd7;      // 7 = emitting the address
                    end
                end

                // One row: four hex digits of address, then sixteen bytes.
                ST_DROW: if (can_emit) begin
                    if (dcol == 3'd7) begin
                        case (dnib)
                            3'd0: tx_data <= hexchar({1'b0, dmp_raddr[10:8]});
                            3'd1: tx_data <= hexchar(dmp_raddr[7:4]);
                            default: tx_data <= hexchar(dmp_raddr[3:0]);
                        endcase
                        tx_stb <= 1'b1;
                        if (dnib == 3'd2) dcol <= 3'd0;
                        else              dnib <= dnib + 3'd1;
                    end else if (dcol == 3'd0) begin
                        tx_data <= " ";
                        tx_stb  <= 1'b1;
                        dcol    <= 3'd1;
                    end else if (dcol == 3'd1) begin
                        tx_data <= hexchar(dmp_rdata[7:4]);
                        tx_stb  <= 1'b1;
                        dcol    <= 3'd2;
                    end else begin
                        tx_data   <= hexchar(dmp_rdata[3:0]);
                        tx_stb    <= 1'b1;
                        dmp_raddr <= dmp_raddr + 11'd1;
                        if (dmp_raddr[3:0] == 4'hF) begin
                            // End of a sixteen-byte row.
                            if (dmp_raddr == 11'd2047) begin
                                state <= ST_DFTR;
                                dlit  <= 4'd0;
                            end else begin
                                state <= ST_DHDR;
                                dlit  <= 4'd7;   // just the CR LF
                            end
                        end else begin
                            dcol <= 3'd0;
                        end
                    end
                end

                ST_DFTR: if (can_emit) begin
                    tx_data <= dftr(dlit);
                    tx_stb  <= 1'b1;
                    dlit    <= dlit + 4'd1;
                    if (dlit == 4'd7) begin
                        dmp_ack <= 1'b1;
                        state   <= ST_IDLE;
                    end
                end
            endcase
        end
    end
endmodule

`default_nettype wire
