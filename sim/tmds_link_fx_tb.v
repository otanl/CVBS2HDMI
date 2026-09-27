`default_nettype none
`timescale 1ns/1ps

// tmds_link_fx, line by line against what it is allowed to do.  Random pixels
// in, 640 a line with 161 of blanking; for every line the bench finds the
// skew that explains the green lane and then requires:
//
//   - red untouched, green `s` pixels late and blue 2s, black where the delay
//     reaches back into blanking;
//   - s = amount / 8 plus a shiver made of amount / 32's bits, capped at 31;
//   - anything else wrong on the line is one span of one lane, every pixel of
//     it one lane error -- lost, v ^ 0xFE, or inverted;
//   - blocks only past half way, and on a fair share of lines near full;
//   - blanking untouched.
//
// AMOUNT 0 is the negative control: nothing may change at all.
module tmds_link_fx_tb;
    parameter integer AMOUNT = 64;
    localparam integer LINES = 600;

    reg clk = 1'b0;
    always #19.841 clk = ~clk;
    reg rst_n = 1'b0;
    reg        data = 1'b0;
    reg [23:0] pix_in = 24'd0;
    wire [23:0] pix_out;
    tmds_link_fx dut (
        .clk(clk), .rst_n(rst_n), .amount(AMOUNT[7:0]), .data(data),
        .pix_in(pix_in), .pix_out(pix_out)
    );

    reg [7:0] ir [0:639], ig [0:639], ib [0:639];
    reg [7:0] orr [0:639], og [0:639], ob [0:639];
    integer line, x, s, best, best_s, hits, errors = 0, block_lines = 0, skew_min = 99, skew_max = -1;
    integer lane, first, last, bad_lanes, kind, blank_changed = 0;

    function [7:0] exp_lane;          // what lane l of pixel xx should be, skew ss
        input integer l, xx, ss;
        begin
            case (l)
                2: exp_lane = ir[xx];
                1: exp_lane = (xx >= ss) ? ig[xx - ss] : 8'd0;
                default: exp_lane = (xx >= 2 * ss) ? ib[xx - 2 * ss] : 8'd0;
            endcase
        end
    endfunction
    function [7:0] out_lane;
        input integer l, xx;
        out_lane = (l == 2) ? orr[xx] : (l == 1) ? og[xx] : ob[xx];
    endfunction
    function [7:0] err_of;
        input [7:0] v;
        input integer k;
        err_of = (k == 1) ? v ^ 8'hFE : (k == 2) ? ~v : 8'd0;
    endfunction

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        for (line = 0; line < LINES; line = line + 1) begin
            for (x = 0; x < 640; x = x + 1) begin
                @(negedge clk);
                data = 1'b1;
                pix_in = $random;
                ir[x] = pix_in[23:16]; ig[x] = pix_in[15:8]; ib[x] = pix_in[7:0];
                #1;
                orr[x] = pix_out[23:16]; og[x] = pix_out[15:8]; ob[x] = pix_out[7:0];
            end
            for (x = 0; x < 161; x = x + 1) begin
                @(negedge clk);
                data = 1'b0;
                pix_in = $random;
                #1;
                if (pix_out !== pix_in) blank_changed = blank_changed + 1;
            end
            // The skew that explains most of green.
            best = -1; best_s = 0;
            for (s = 0; s < 32; s = s + 1) begin
                hits = 0;
                for (x = 0; x < 640; x = x + 1) if (og[x] == exp_lane(1, x, s)) hits = hits + 1;
                if (hits > best) begin best = hits; best_s = s; end
            end
            if (line > 0) begin
                if (best_s < skew_min) skew_min = best_s;
                if (best_s > skew_max) skew_max = best_s;
                if (best_s < AMOUNT / 8 || ((best_s - AMOUNT / 8) & ~((AMOUNT / 32) & 7)) != 0) begin
                    if (best_s != 31) begin
                        $display("line %0d: skew %0d at amount %0d", line, best_s, AMOUNT);
                        errors = errors + 1;
                    end
                end
            end
            // Whatever that leaves: one span of one lane, one kind of error.
            bad_lanes = 0; lane = -1;
            for (s = 0; s < 3; s = s + 1) begin
                hits = 0;
                for (x = 0; x < 640; x = x + 1)
                    if (out_lane(s, x) != exp_lane(s, x, best_s)) hits = hits + 1;
                if (hits != 0) begin bad_lanes = bad_lanes + 1; lane = s; end
            end
            if (bad_lanes > 1) begin
                $display("line %0d: %0d lanes wrong", line, bad_lanes);
                errors = errors + 1;
            end else if (bad_lanes == 1) begin
                block_lines = block_lines + 1;
                first = -1; last = -1;
                for (x = 0; x < 640; x = x + 1)
                    if (out_lane(lane, x) != exp_lane(lane, x, best_s)) begin
                        if (first < 0) first = x;
                        last = x;
                    end
                // The one kind of error that explains every pixel of the span
                // (a single pixel can fit two: 0xFF inverted reads as lost).
                kind = 3;
                for (s = 2; s >= 0; s = s - 1) begin
                    hits = 0;
                    for (x = first; x <= last; x = x + 1)
                        if (out_lane(lane, x) != err_of(exp_lane(lane, x, best_s), s)) hits = hits + 1;
                    if (hits == 0) kind = s;
                end
                if (kind == 3) begin
                    if (errors < 10)
                        $display("line %0d lane %0d x %0d..%0d: not one span of one lane error",
                                 line, lane, first, last);
                    errors = errors + 1;
                end
            end
        end
        $display("link: amount=%0d lines %0d, skew %0d..%0d, lines with a lane error %0d, blanking changed %0d, errors %0d",
                 AMOUNT, LINES, skew_min, skew_max, block_lines, blank_changed, errors);
        if (errors != 0 || blank_changed != 0) $fatal(1, "the link did something it may not");
        if (AMOUNT == 0 && (skew_max != 0 || block_lines != 0)) $fatal(1, "amount 0 changed the picture");
        if (AMOUNT <= 128 && block_lines != 0) $fatal(1, "lane errors before half way");
        if (AMOUNT > 192 && block_lines < LINES / 4) $fatal(1, "too few lane errors near full");
        if (AMOUNT >= 8 && skew_max == 0) $fatal(1, "no skew");
        $display("RESULT PASS");
        $finish;
    end
endmodule

`default_nettype wire
