`default_nettype none
`timescale 1ns/1ps

// Render one TAPE frame from a known memory image and check every pixel.
// Also writes the frame as a PPM and the memory as hex, so that
// scripts/tape_decode.py can be checked against the same answer end to end.
module tape_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg [10:0] fx = 0, fy = 0;
    integer i, xx, yy, bad = 0, checked = 0, fd;
    reg [15:0] lfsr = 16'hACE1;
    reg [7:0] frame [0:640*480-1];

    top_ntsc_hdmi #(.TAPE(1)) dut (
        .clk27(clk), .adc_d(8'd0), .adc_otr(1'b0), .btn_n(2'b11)
    );

    function [7:0] expected(input integer x, input integer y);
        integer nib, word;
        reg [31:0] id;
        begin
            id = {16'hA55A, 7'd0, 1'b1, 8'h5C};
            if (y < 8)
                nib = (x < 512 && id[31 - x/16]) ? 15 : 0;
            else if (y < 16)
                nib = (x/4) % 16;
            else if (y < 426) begin
                word = dut.dumpbuf.mem[((y-16)*80 + x/8) % 32768];
                nib = ((x/4) % 2) ? (word & 15) : (word >> 4);
            end else
                nib = 0;
            expected = nib * 17;
        end
    endfunction

    initial begin
        for (i = 0; i < 32768; i = i + 1) begin
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            dut.dumpbuf.mem[i] = lfsr[7:0];
        end
        force dut.pixel_clk = clk;
        force dut.vid_rst_n = 1'b1;
        force dut.dmp_rdy = 1'b1;
        force dut.scope_frame = 8'h5C;
        force dut.x = fx;
        force dut.y = fy;
        // Walk the raster one pixel a clock, as video_timing would.  x and y
        // are what the logic sees during a cycle; after the next edge the
        // output is that position's pixel, as it is for active_d.
        for (yy = 0; yy < 480; yy = yy + 1) begin
            for (xx = 0; xx < 640; xx = xx + 1) begin
                fx = xx; fy = yy;
                @(posedge clk); #1;
                frame[yy*640 + xx] = dut.out_r;
                if (dut.out_r !== expected(xx, yy) ||
                    dut.out_g !== dut.out_r || dut.out_b !== dut.out_r)
                    bad = bad + 1;
                checked = checked + 1;
            end
        end
        fd = $fopen("build/tape_tb.ppm", "w");
        $fwrite(fd, "P2\n640 480\n255\n");
        for (i = 0; i < 640*480; i = i + 1)
            $fwrite(fd, "%0d\n", frame[i]);
        $fclose(fd);
        fd = $fopen("build/tape_tb_mem.hex", "w");
        for (i = 0; i < 32768; i = i + 1)
            $fwrite(fd, "%02x\n", dut.dumpbuf.mem[i]);
        $fclose(fd);
        $display("tape: pixels=%0d mismatches=%0d", checked, bad);
        if (bad != 0 || checked != 640*480) $fatal(1, "tape frame does not encode the memory");
        $display("RESULT PASS");
        $finish;
    end
endmodule

`default_nettype wire
