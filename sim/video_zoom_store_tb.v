`default_nettype none
`timescale 1ns/1ps

// video_zoom_store against a model, with the output frame servoed onto the
// input fields exactly as top_ntsc_hdmi does it.
//
// Lines arrive every 1601.6 clocks on average and are written a pixel every
// two clocks, as the capture does; four lines after each field event go
// unpublished, like the vertical interval's.  Each line's red is its number,
// green and blue a hash of line and pixel, all multiples of four so the
// store's dither leaves them exact.  Every displayed pixel is then checked:
//
//   - the whole row is one line (no tearing), and it is the line that was
//     the latest at the row's time, t_field + OFF + STEP * row;
//   - green and blue are the model's interpolation of that line at 2x/3;
//   - the picture holds still: row r shows the same line relative to the
//     field in every frame (every other frame, interlaced), across the servo's
//     trims -- at least one of which must happen while it is checked;
//   - with the field events stopped, rows still show whole lines in order,
//     160 lines down the frame, from the frame's own start.
//
// NS = 60 is the negative control: too short a ring for the lag, which the
// bench must see as failures.
module video_zoom_store_tb;
    parameter integer V_TOT = 524;          // 524 with 240p, 525 interlaced
    parameter         INTERLACED = 1'b0;
    parameter integer NS = 88;
    parameter         EXPECT_FAIL = 1'b0;

    localparam integer H_TOTAL = 801;
    localparam [10:0]  V_TARGET = 11'd400;
    localparam integer OFF = 96921, STEP = 534;
    localparam integer W = 427, X0 = 106;
    localparam integer FRAMES = 24, CHECK_FROM = 6, SILENT_FROM = 16, SILENT_TO = 20;

    reg clk = 1'b0;
    always #19.841 clk = ~clk;
    reg rst_n = 1'b0;
    integer t = 0;
    always @(posedge clk) if (rst_n) t <= t + 1;

    // ---- the output frame and its servo ------------------------------------
    wire [10:0] x, y;
    reg v_longer = 1'b0, v_shorter = 1'b0;
    video_timing #(
        .H_ACTIVE(11'd640), .H_FRONT(11'd16), .H_SYNC(11'd96), .H_TOTAL(H_TOTAL[10:0]),
        .V_ACTIVE(11'd480), .V_FRONT(11'd10), .V_SYNC(11'd2), .V_TOTAL(V_TOT[10:0])
    ) timing (
        .pixel_clk(clk), .reset_n(rst_n), .vsync_align(1'b0), .v_total(V_TOT[10:0]),
        .v_longer(v_longer), .v_shorter(v_shorter),
        .x(x), .y(y), .active(), .hsync(), .vsync()
    );

    // ---- the input ---------------------------------------------------------
    reg        wr_en = 1'b0, wr_done = 1'b0, field = 1'b0;
    reg [9:0]  wr_x = 10'd0;
    reg [23:0] wr_data = 24'd0;
    wire [23:0] rd_data;
    wire        rd_valid;
    video_zoom_store #(.NS(NS)) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_x(wr_x), .wr_data(wr_data), .wr_done(wr_done),
        .field(field), .x(x), .y(y), .rd_data(rd_data), .rd_valid(rd_valid)
    );

    function [5:0] hash;
        input integer n, j, k;
        reg [31:0] h;
        begin
            h = n * 32'h9E37_79B1 ^ j * 32'h85EB_CA77 ^ k * 32'hC2B2_AE3D;
            h = h ^ (h >> 15);
            hash = h[5:0];
        end
    endfunction

    // Publications: line number and time, by publication count.
    integer pub_n [0:8191];
    integer pub_t [0:8191];
    integer npub = 0;

    integer line_n = 0, line_start = 100, pat = 0, j;
    reg [5:0] ln6;
    integer field_k = 0, field_t = 0, next_field;
    integer field_line [0:127];             // the line in progress at each event
    integer fields_on = 1;
    integer frame = 0;
    always @(posedge clk) if (rst_n) begin
        wr_en <= 1'b0; wr_done <= 1'b0; field <= 1'b0;
        j = t - line_start - 252;
        if (j >= 0 && j < 1280 && j % 2 == 1) begin
            wr_en   <= 1'b1;
            wr_x    <= j / 2;
            ln6      = line_n % 64;
            wr_data <= {ln6, 2'b00, hash(line_n, j / 2, 1), 2'b00,
                        hash(line_n, j / 2, 2), 2'b00};
            if (j == 1279 && !(t - field_t < 4 * 1602 && field_k > 0)) begin
                wr_done <= 1'b1;
                pub_n[npub % 8192] = line_n;
                pub_t[npub % 8192] = t + 1;       // the store sees it next clock
                npub = npub + 1;
            end
        end
        if (t == line_start + 1601 + ((pat % 5) % 2 == 0)) begin
            line_start = t;
            line_n = line_n + 1;
            pat = pat + 1;
        end
        if (t == next_field) begin
            if (fields_on) begin
                field <= 1'b1;
                field_t = t + 1;
                field_line[field_k % 128] = line_n;
                field_k = field_k + 1;
            end
            next_field = next_field + (INTERLACED ? 420420 : 419619);
        end
    end

    // The servo, as top_ntsc_hdmi: rest the field event at V_TARGET.
    wire [10:0] y_rel = (y >= V_TARGET) ? (y - V_TARGET) : (y + V_TOT[10:0] - V_TARGET);
    integer trims = 0, trims_checked = 0;
    always @(posedge clk) if (field) begin
        v_longer  <= (y_rel > 11'd1) && (y_rel < 11'd263);
        v_shorter <= (y_rel >= 11'd263) && (y_rel < V_TOT[10:0] - 11'd1);
        if (((y_rel > 11'd1) && (y_rel < 11'd263)) || (y_rel >= 11'd263 && y_rel < V_TOT - 1)) begin
            trims = trims + 1;
            if (frame >= CHECK_FROM && frame < SILENT_FROM) trims_checked = trims_checked + 1;
        end
    end

    // ---- the checks --------------------------------------------------------
    integer errors = 0, rows_checked = 0, px_checked = 0, future_rows = 0;
    integer row_line, row_tau, row_field, lag, max_lag = 0, k, want_n;
    integer rel [0:1][0:479];               // row -> line - field line, by parity
    integer have_rel [0:1];
    integer first_row_n, last_row_n, first_row_y = -1, silent_frames = 0;
    reg [10:0] px, py;
    reg        pvalid, row_future = 1'b0;
    reg [7:0]  want_g, want_b;

    function [7:0] ex;
        input [5:0] v;
        ex = {v, v[5:4]};
    endfunction
    function [7:0] third;               // a quarter u, three quarters v
        input [5:0] u, v;
        third = (ex(u) + 3 * ex(v)) >> 2;
    endfunction
    function [7:0] model;                   // channel k of line n at output x
        input integer n, xo, kk;
        integer q;
        begin
            q = 2 * (xo / 3);
            case (xo % 3)
                0: model = ex(hash(n, X0 + q, kk));
                1: model = third(hash(n, X0 + q, kk), hash(n, X0 + q + 1, kk));
                default: model = third(hash(n, X0 + q + 2, kk), hash(n, X0 + q + 1, kk));
            endcase
        end
    endfunction

    // The line latest at time tt.
    function integer latest_at;
        input integer tt;
        integer i;
        begin
            latest_at = -1;
            for (i = npub - 1; i >= 0 && i >= npub - 400; i = i - 1)
                if (latest_at < 0 && pub_t[i % 8192] <= tt) latest_at = pub_n[i % 8192];
        end
    endfunction

    integer tau_next = 0, tau_row = 0, fld_at_row0 = 0, par = 0;
    always @(posedge clk) if (rst_n) begin
        // The model's own row time, kept exactly as the store is specified.
        if (x == 11'd640) begin
            if (y < 11'd479) tau_next = tau_next + STEP;
            else if (field_k > 0 && t + 161 - (field_t + OFF) >= 0 &&
                     t + 161 - (field_t + OFF) < 6408) begin
                tau_next = field_t + OFF;
                fld_at_row0 = field_k - 1;
            end else begin
                tau_next = t + 161;
                fld_at_row0 = -1;
            end
        end
        if (x == 11'd0) begin
            tau_row = tau_next;
            if (y == 11'd0) begin
                frame = frame + 1;
                first_row_y = -1;
                par = fld_at_row0 & 1;
                if (frame == SILENT_FROM) fields_on = 0;
                if (frame == SILENT_TO) fields_on = 1;
            end
            // A row whose time has not come shows the latest line there is,
            // which is not checked here; while the servo holds the frame, there
            // must be none.
            row_future = (y < 11'd480) && (tau_row > t - 150);
            if (row_future && frame >= CHECK_FROM && frame < SILENT_FROM)
                future_rows = future_rows + 1;
        end
        pvalid <= (x < 11'd640) && (y < 11'd480);
        px <= x; py <= y;
        if (pvalid && rd_valid && frame >= CHECK_FROM && !row_future) begin
            if (px == 0) begin
                row_line = -1;
                // Red is the line number mod 64; find the line it means,
                // nearest the one the model wants.
                want_n = latest_at(tau_row);
                for (k = want_n - 100; k <= want_n + 32; k = k + 1)
                    if (k >= 0 && (k % 64) == rd_data[23:18]) row_line = k;
                if (row_line != want_n) begin
                    if (errors < 10)
                        $display("frame %0d row %0d: line %0d, want %0d (the latest at its time)",
                                 frame, py, row_line, want_n);
                    errors = errors + 1;
                end
                lag = line_n - row_line;
                if (lag > max_lag) max_lag = lag;
                rows_checked = rows_checked + 1;
                // Without field events row 0's time is its own start, which
                // the check skips; the span then runs from row 1.
                if (py == 0 || (py == 1 && first_row_y != 0)) begin
                    first_row_n = row_line;
                    first_row_y = py;
                end
                if (py == 479) begin
                    last_row_n = row_line;
                    if (last_row_n - first_row_n < 158 - first_row_y ||
                        last_row_n - first_row_n > 161) begin
                        if (errors < 10)
                            $display("frame %0d: rows span lines %0d..%0d", frame, first_row_n, last_row_n);
                        errors = errors + 1;
                    end
                end
                // Stability, while the fields run: the same line relative to
                // the field every frame (every other, interlaced).
                if (frame < SILENT_FROM && fld_at_row0 >= 0) begin
                    k = INTERLACED ? par : 0;
                    if (have_rel[k] && rel[k][py] != row_line - field_line[fld_at_row0 % 128]) begin
                        if (errors < 10)
                            $display("frame %0d row %0d: line %0d after the field, was %0d",
                                     frame, py, row_line - field_line[fld_at_row0 % 128], rel[k][py]);
                        errors = errors + 1;
                    end
                    rel[k][py] = row_line - field_line[fld_at_row0 % 128];
                    if (py == 479) have_rel[k] = 1;
                end
                if (frame >= SILENT_TO - 2 && frame < SILENT_TO && py == 479) silent_frames = silent_frames + 1;
            end
            if (row_line >= 0) begin
                want_g = model(row_line, px, 1);
                want_b = model(row_line, px, 2);
                if (rd_data[23:18] != (row_line % 64) || rd_data[15:8] != want_g || rd_data[7:0] != want_b) begin
                    if (errors < 10)
                        $display("frame %0d row %0d x %0d: %h, want line %0d g %h b %h",
                                 frame, py, px, rd_data, row_line, want_g, want_b);
                    errors = errors + 1;
                end
                px_checked = px_checked + 1;
            end
        end
    end

    initial begin
        have_rel[0] = 0; have_rel[1] = 0;
        next_field = 400 * 801 + 300;       // the event on row 400
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        wait (frame == FRAMES);
        $display("zoom: V_TOT=%0d interlaced=%0d NS=%0d rows %0d, pixels %0d, errors %0d, trims while checked %0d, rows ahead of their time %0d, largest lag %0d lines, silent frames %0d",
                 V_TOT, INTERLACED, NS, rows_checked, px_checked, errors, trims_checked,
                 future_rows, max_lag, silent_frames);
        if (EXPECT_FAIL) begin
            if (errors == 0) $fatal(1, "negative control: a ring too short went unnoticed");
        end else begin
            if (errors != 0) $fatal(1, "zoomed rows wrong");
            if (trims_checked == 0) $fatal(1, "no servo trim while checked: stability untested");
            if (future_rows != 0) $fatal(1, "a row's time had not come when it started");
            if (silent_frames == 0) $fatal(1, "the fallback without field events was not checked");
        end
        $display("RESULT PASS");
        $finish;
    end
endmodule

`default_nettype wire
