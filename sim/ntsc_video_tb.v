`default_nettype none
`timescale 1ns/1ps

// Independent NTSC-J encoder: 227.5 carrier cycles/line, 262.5 lines/field,
// 4.7 us sync, nine-cycle -U burst, 75% RGB bars. Values are not derived
// from the DUT's timing windows or colour coefficients.
module ntsc_video_tb;
    parameter integer SYNC_DEPTH = 36;
    parameter integer MONO = 0;
    parameter integer FIELDS = 3;
    parameter integer VBI_LINES = 24;
    parameter integer HSHIFT = 0;
    parameter integer TOD_NS = 10;      // converter output delay after adc_clk
    // Glitch effects (ntsc_capture's fx) applied from sample FX_FROM to FX_TO.
    // Nothing is checked from FX_FROM until RECOVER samples after FX_TO, and
    // then the picture must be exactly as good as without them.  Meanwhile the
    // effect must show: FX_MIN_BAD wrong colour channels at least, or at most
    // FX_MAX_LINES lines published.
    parameter [63:0]  FX = 64'd0;
    parameter integer FX_FROM = 0;
    parameter integer FX_TO = 0;
    parameter integer RECOVER = 1602*200;
    parameter integer FX_MIN_BAD = 0;
    parameter integer FX_MAX_LINES = 1000000;
    // 126 MHz and the pixel clock divided from it, as on the board; the
    // decoder runs on the pixel clock, one sample per clock.
    reg fclk = 0;
    always #3.968 fclk = ~fclk;
    wire clk;
    CLKDIV #(.DIV_MODE("5")) u_div (.CLKOUT(clk), .HCLKIN(fclk), .RESETN(1'b1), .CALIB(1'b0));
    reg rst_n = 0;
    reg [7:0] adc = 100;
    wire adc_clk, wr_en, line_done, vsync_pulse, locked;
    wire [10:0] wr_addr;
    wire [23:0] rgb;
    wire [7:0] black;
    integer n = 0;
    wire glitching  = (FX != 64'd0) && (n >= FX_FROM) && (n < FX_TO);
    wire recovering = (FX != 64'd0) && (n >= FX_FROM) && (n < FX_TO + RECOVER);
    integer glitch_bad = 0, glitch_lines = 0;
    ntsc_capture #(.ADC_WIN_W(10)) dut (
        .clk(clk), .fclk(fclk), .rst_n(rst_n), .adc_d(adc), .adc_otr(1'b0),
        .adc_clk(adc_clk), .adc_clamp(), .rot_sel(4'd0), .fx(glitching ? FX : 64'd0), .gain_sel(2'd0),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(rgb), .wr_bank(),
        .line_done(line_done), .vsync_pulse(vsync_pulse), .sync_locked(locked),
        .black_out(black), .dmp_ack(1'b0)
    );
    integer stim_n, pos, fsamp, half_no, half_pos, bar, r, g, b;
    integer lines = 0, pixels = 0, fields = 0, checks = 0, bad_lines = 0;
    integer bad_colours = 0, er, eg, eb, err, max_error = 0;
    real phase, value, yy, uu, vv;
    localparam real PI = 3.141592653589793;
    task bar_rgb(input integer idx, output integer rr, gg, bb);
        begin
            rr = (idx == 0 || idx == 1 || idx == 4 || idx == 5) ? 191 : 0;
            gg = (idx == 0 || idx == 1 || idx == 2 || idx == 3) ? 191 : 0;
            bb = (idx == 0 || idx == 2 || idx == 4 || idx == 6) ? 191 : 0;
        end
    endtask
    // A new code TOD_NS after each rising edge of the converter's clock; the
    // decoder's calibration has to find where that lands.
    always @(posedge adc_clk) if (rst_n) begin
        // Shift one line late and retain that phase, as at a recording seam
        // or source timing jump. Subsequent lines must not be rejected just
        // because the decoder coasted before the delayed sync arrived.
        stim_n = n - ((n >= 1602*110) ? HSHIFT : 0);
        fsamp = stim_n % 420420;
        pos = ((fsamp * 5) % 8008) / 5;
        half_no = (fsamp * 5) / 4004;
        half_pos = ((fsamp * 5) % 4004) / 5;
        phase = 2.0*PI*n*(315000000.0/88.0)/25200000.0 + 0.73;
        value = 100;
        if (half_no < 18) begin
            if (half_pos < ((half_no >= 6 && half_no < 12) ? 683 : 59))
                value = 100-SYNC_DEPTH;
        end else if (pos < 118) value = 100-SYNC_DEPTH;
        // Continue blanking beyond the equalising/broad-pulse sequence.
        // A nine-line-only VBI cannot catch a 20.5-line burst watchdog bug.
        else if (fsamp < VBI_LINES*8008/5) value = 100;
        else if (pos >= 134 && pos < 197 && !MONO)
            value = 100 - 18*$sin(phase);
        else if (pos >= 237 && pos < 1557) begin
            bar = (pos-237)/165;
            bar_rgb(bar, r, g, b);
            yy = 0.299*r + 0.587*g + 0.114*b;
            uu = 0.493*(b-yy);
            vv = 0.877*(r-yy);
            value = 100 + 90.0/255.0*(yy + (MONO ? 0.0 :
                                                 uu*$sin(phase)+vv*$cos(phase)));
        end
        adc <= #(TOD_NS) $rtoi(value+0.5);
        n = n + 1;
    end
    always @(negedge clk) if (rst_n) begin
        if (vsync_pulse && !recovering) fields = fields + 1;
        if (HSHIFT && n > 1602*111 && n < 1602*125 && !locked)
            $fatal(1, "late sync caused repeated coasting and lost line lock");
        if (!MONO && !recovering && n > 420420 && fsamp < VBI_LINES*8008/5 && !dut.burst_locked)
            $fatal(1, "vertical blanking dropped colour lock");
        if (wr_en) begin
            if (wr_addr[9:0] == 0) pixels = 0; // a partial line may be discarded
            pixels = pixels + 1;
            if (n > 1602*120 && n < 1602*121 && wr_addr[9:0]%80 == 40)
                $display("bar=%0d rgb=%h u=%0d v=%0d ref=%h black=%0d pos=%0d cpos=%0d",
                         wr_addr[9:0]/80,rgb,dut.u_s,dut.v_s,dut.nco_ref,
                         black,pos,dut.cpos);
            if (glitching && fsamp > 1602*30 &&
                (wr_addr[9:0] % 80) >= 32 && (wr_addr[9:0] % 80) < 48) begin
                bar_rgb(wr_addr[9:0]/80, er, eg, eb);
                if ((rgb[23:16] > er ? rgb[23:16] - er : er - rgb[23:16]) > 24 ||
                    (rgb[15:8]  > eg ? rgb[15:8]  - eg : eg - rgb[15:8])  > 24 ||
                    (rgb[7:0]   > eb ? rgb[7:0]   - eb : eb - rgb[7:0])   > 24)
                    glitch_bad = glitch_bad + 1;
            end
            if (!recovering && n > 1602*100 && fsamp > 1602*30 &&
                (wr_addr[9:0] % 80) >= 32 && (wr_addr[9:0] % 80) < 48) begin
                bar_rgb(wr_addr[9:0]/80, er, eg, eb);
                if (MONO) begin
                    er = $rtoi(0.299*er + 0.587*eg + 0.114*eb);
                    eg = er; eb = er;
                end
                if (^rgb === 1'bx) $fatal(1, "unknown RGB");
                err = rgb[23:16]-er; if (err<0) err=-err;
                if (err>max_error) max_error=err;
                if (err>24) bad_colours=bad_colours+1;
                err = rgb[15:8]-eg; if (err<0) err=-err;
                if (err>max_error) max_error=err;
                if (err>24) bad_colours=bad_colours+1;
                err = rgb[7:0]-eb; if (err<0) err=-err;
                if (err>max_error) max_error=err;
                if (err>24) bad_colours=bad_colours+1;
                checks=checks+1;
            end
        end
        if (line_done) begin
            if (glitching) glitch_lines = glitch_lines + 1;
            if (!recovering && n > 1602*100 && pixels != 640) begin
                bad_lines=bad_lines+1;
                $display("partial line n=%0d pixels=%0d cpos=%0d",n,pixels,dut.cpos);
            end
            pixels=0;
            lines=lines+1;
        end
    end
    initial begin
        repeat (10) @(negedge clk);
        rst_n=1;
        wait (n >= 420420*FIELDS);
        @(negedge clk);
        $display("video: sync=%0d mono=%0d lock=%0d black=%0d fields=%0d lines=%0d bad_lines=%0d pixels_checked=%0d bad_channels=%0d max_error=%0d",
                 SYNC_DEPTH, MONO, locked, black, fields, lines, bad_lines,
                 checks, bad_colours, max_error);
        if (FX != 64'd0)
            $display("glitch: fx=%h from line %0d to %0d: %0d wrong channels, %0d lines published; clean again after %0d lines",
                     FX, FX_FROM/1602, FX_TO/1602, glitch_bad, glitch_lines, RECOVER/1602);
        if (!locked || (FX == 64'd0 && fields != FIELDS) || bad_lines || bad_colours || checks < 10000)
            $fatal(1, "NTSC video decode failed");
        if (glitch_bad < FX_MIN_BAD || glitch_lines > FX_MAX_LINES)
            $fatal(1, "the glitch effect did not show");
        if (black < 99 || black > 101) $fatal(1, "back porch DC restoration failed");
        $display("RESULT PASS");
        $finish;
    end
endmodule
`default_nettype wire
