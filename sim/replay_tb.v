`default_nettype none
`timescale 1ns/1ps

// Replay a TAPE recording through ntsc_capture and write every decoded line.
//
//   vvp build/replay_tb +stim=sim/m5_tape.hex +nsamp=32032 +lines=300 \
//       +out=build/replay.txt
//
// The recording loops, so trim it to a whole, even number of lines first
// (scripts/tape_trim.py): even keeps the subcarrier continuous across the seam
// and keeps any line-alternating property of the source in step.
//
// Each output record is one decoded line:
//   L <index> <black> <real> <burst_locked> <burst_off hex> <640 RGB hex>
// scripts/replay_quality.py scores it with the same bar geometry as the
// board's HDMI captures, so a change can be judged here before it is built.
module replay_tb;
    parameter integer THR_SHIFT = 4;    // the module default for standard timing
    parameter         AUTO = 1'b1;      // AUTO_PHASE
    // A converter's output switching window.  0 keeps the old model: the new
    // sample appears on the edge that sees adc_clk rise, settled.  1..4: it
    // appears that many clocks later, and with MIX the clock before that
    // carries half its bits switched -- what a read inside the window gets.
    parameter integer ADC_DELAY = 0;
    parameter integer MIX = 0;
    reg [7:0] stim [0:65535];
    integer nsamp, lines_to_run, fd, idx = 0, lines = 0, i;
    reg [1023:0] stim_path, out_path;

    reg clk = 1'b0;
    always #3.968 clk = ~clk;          // 126 MHz
    reg        rst_n = 1'b0;
    reg [7:0]  adc_d = 8'd0;
    wire       adc_clk;

    reg adc_clk_d = 1'b0;
    reg [2:0] since = 3'd7;            // clocks since adc_clk rose; 7 idle
    reg [7:0] newv = 8'd0;
    always @(posedge clk) begin
        adc_clk_d <= adc_clk;
        if (adc_clk && !adc_clk_d) begin
            newv  <= stim[idx];
            idx   <= (idx == nsamp-1) ? 0 : idx + 1;
            since <= 3'd1;
            if (ADC_DELAY == 0) adc_d <= stim[idx];
            else if (MIX && ADC_DELAY == 1)
                adc_d <= (adc_d & 8'hAA) | (stim[idx] & 8'h55);
        end else if (since != 3'd7) begin
            since <= (since == 3'd4) ? 3'd7 : since + 3'd1;
            if (ADC_DELAY != 0 && since == ADC_DELAY) adc_d <= newv;
            else if (MIX && since == ADC_DELAY - 1)
                adc_d <= (adc_d & 8'hAA) | (newv & 8'h55);
        end
    end

    wire        wr_en, line_done;
    wire [10:0] wr_addr;
    wire [23:0] wr_data;
    wire [7:0]  black;
    ntsc_capture #(.THR_SHIFT(THR_SHIFT), .AUTO_PHASE(AUTO)) dut (
        .clk_cap(clk), .rst_n(rst_n), .adc_d(adc_d), .adc_otr(1'b0),
        .adc_clk(adc_clk), .adc_clamp(), .phase_sel(3'd2), .gain_sel(2'd0),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .wr_bank(),
        .line_done(line_done), .vsync_pulse(), .sync_locked(),
        .black_out(black), .dmp_ack(1'b0)
    );

    reg [23:0] pix [0:639];
    reg        was_real;
    always @(posedge clk) if (rst_n && dut.line_edge) was_real <= dut.line_real;

    always @(posedge clk) if (rst_n) begin
        if (wr_en) pix[wr_addr[9:0]] <= wr_data;
        if (line_done) begin
            $fwrite(fd, "L %0d %0d %0d %0d %h ", lines, black, was_real,
                    dut.burst_locked, dut.u_nco.burst_off);
            for (i = 0; i < 640; i = i + 1) $fwrite(fd, "%h", pix[i]);
            $fwrite(fd, "\n");
            lines = lines + 1;
        end
    end

    initial begin
        if (!$value$plusargs("stim=%s", stim_path)) stim_path = "sim/m5_tape.hex";
        if (!$value$plusargs("out=%s", out_path)) out_path = "build/replay.txt";
        if (!$value$plusargs("nsamp=%d", nsamp)) nsamp = 32768;
        if (!$value$plusargs("lines=%d", lines_to_run)) lines_to_run = 300;
        $readmemh(stim_path, stim, 0, nsamp-1);
        fd = $fopen(out_path, "w");
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        wait (lines >= lines_to_run);
        $fclose(fd);
        $display("replay: %0d lines decoded from %0s", lines, stim_path);
        $finish;
    end
endmodule

`default_nettype wire
