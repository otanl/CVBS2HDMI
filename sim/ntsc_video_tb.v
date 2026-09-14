`default_nettype none
`timescale 1ns/1ps

// Independent NTSC-J encoder: 227.5 carrier cycles/line, 262.5 lines/field,
// 4.7 us sync, nine-cycle -U burst, 75% RGB bars. Values are not derived
// from the DUT's timing windows or colour coefficients.
module ntsc_video_tb;
    parameter integer SYNC_DEPTH = 36;
    parameter integer MONO = 0;
    parameter integer FIELDS = 3;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst_n = 0;
    reg [7:0] adc = 100;
    wire adc_clk, wr_en, line_done, vsync_pulse, locked;
    wire [10:0] wr_addr;
    wire [23:0] rgb;
    wire [7:0] black;
    ntsc_capture dut (
        .clk_cap(clk), .rst_n(rst_n), .adc_d(adc), .adc_otr(1'b0),
        .adc_clk(adc_clk), .adc_clamp(), .phase_sel(3'd2), .gain_sel(2'd0),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(rgb), .wr_bank(),
        .line_done(line_done), .vsync_pulse(vsync_pulse), .sync_locked(locked),
        .black_out(black), .dmp_ack(1'b0)
    );
    integer n = 0, pos, fsamp, half_no, half_pos, bar, r, g, b;
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
    // Set ADC data at its rising clock edge. Phase 2 samples settled data.
    always @(posedge adc_clk) if (rst_n) begin
        fsamp = n % 420420;
        pos = ((fsamp * 5) % 8008) / 5;
        half_no = (fsamp * 5) / 4004;
        half_pos = ((fsamp * 5) % 4004) / 5;
        phase = 2.0*PI*n*(315000000.0/88.0)/25200000.0 + 0.73;
        value = 100;
        if (half_no < 18) begin
            if (half_pos < ((half_no >= 6 && half_no < 12) ? 683 : 59))
                value = 100-SYNC_DEPTH;
        end else if (pos < 118) value = 100-SYNC_DEPTH;
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
        adc <= $rtoi(value+0.5);
        n = n + 1;
    end
    always @(negedge clk) if (rst_n) begin
        if (vsync_pulse) fields = fields + 1;
        if (wr_en) begin
            if (wr_addr[9:0] == 0) pixels = 0; // a partial line may be discarded
            pixels = pixels + 1;
            if (n > 1602*120 && n < 1602*121 && wr_addr[9:0]%80 == 40)
                $display("bar=%0d rgb=%h u=%0d v=%0d ref=%h black=%0d pos=%0d cpos=%0d",
                         wr_addr[9:0]/80,rgb,dut.u_s,dut.v_s,dut.nco_ref,
                         black,pos,dut.cpos);
            if (n > 1602*100 && fsamp > 1602*30 &&
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
            if (n > 1602*100 && pixels != 640) begin
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
        if (!locked || fields != FIELDS || bad_lines || bad_colours || checks < 10000)
            $fatal(1, "NTSC video decode failed");
        if (black < 99 || black > 101) $fatal(1, "back porch DC restoration failed");
        $display("RESULT PASS");
        $finish;
    end
endmodule
`default_nettype wire
