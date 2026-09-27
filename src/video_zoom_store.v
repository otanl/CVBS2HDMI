`default_nettype none

// The zoomed view: the middle of the picture scaled 1.5 times to fill the
// screen -- every input line on three rows instead of two, and each row
// interpolated from W of the 640 captured pixels.  Made for sources whose
// picture sits inside a wide border (a game console's 256-pixel picture fills
// about 425 x 320 of the plain view); the edges are cropped.
//
// There is no frame buffer.  A zoomed frame walks through the field at two
// thirds of the rate the lines arrive, so the bottom row shows a line about 80
// lines old, 82.4 at worst with the servo's rest zone; the ring keeps NS lines
// of W pixels, 37 block RAMs.  Row r shows
// the line that was the latest at the time
//
//     tau(r) = t_field + OFF + STEP * r
//
// -- the plain view is the same rule with STEP = 801 and tau(0) = now.  Timing
// it from the field event rather than from the output frame keeps the servo's
// one-row trims out of the picture: which line a row shows depends on the
// input alone.  The frame must simply run late enough that tau(0) has passed
// when row 0 starts (top_ntsc_hdmi moves V_TARGET for that), and a row whose
// time has not come yet shows the latest line there is.  Unless tau(0) falls
// in the eight rows before row 0 -- no field event lately, a missed one, the
// servo still sliding the frame after the view was switched -- tau(0) is row
// 0's own start instead, so a signal with no sync is shown zoomed too, and
// the servo's arrival hands over without a jump.
//
// Pixels are stored as RGB666 with a 2x2 ordered dither: 18 bits is one
// 1K x 18 block RAM per 1024 pixels, the same as 16.  The ring is written out
// as 1K banks because, left to itself, Yosys maps it as pairs of 2K x 9 and
// rounds up to a whole pair: 38 blocks, and with the rest of the design that
// is every one the chip has.
module video_zoom_store #(
    parameter integer W      = 427,         // pixels kept of each line
    parameter integer X0     = 106,         // the first of them, of 640
    parameter integer NS     = 88,          // lines in the ring
    parameter [19:0]  STEP   = 20'd534,     // input clocks a row: 801 / 1.5
    parameter [19:0]  OFF    = 20'd96921,   // field event to row 0's time
    parameter [10:0]  H_ACTIVE = 11'd640,
    parameter [10:0]  H_TOTAL  = 11'd801,
    parameter [10:0]  V_ACTIVE = 11'd480
) (
    input  wire        clk,
    input  wire        rst_n,
    // Capture side, as for video_line_store.
    input  wire        wr_en,
    input  wire [9:0]  wr_x,
    input  wire [23:0] wr_data,
    input  wire        wr_done,
    input  wire        field,          // a field event
    // Display side: the timing generator's position.  rd_data is a clock
    // later, like video_line_store's.
    input  wire [10:0] x,
    input  wire [10:0] y,
    output reg  [23:0] rd_data,
    output reg         rd_valid
);
    localparam integer M  = NS * W;
    localparam integer NB = (M + 1023) / 1024;

    (* ram_style = "distributed" *) reg [19:0] ts [0:NS-1];   // publication times

    reg [19:0] now;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) now <= 20'd0;
        else        now <= now + 20'd1;

    // ---- writer ------------------------------------------------------------
    reg  [6:0]  s_w;                   // the slot being written
    reg  [15:0] b_w;                   // its first address
    wire [9:0]  wx   = wr_x - X0[9:0];
    wire        w_in = (wr_x >= X0[9:0]) && (wr_x < X0[9:0] + W[9:0]);
    wire [1:0]  wd   = {wr_x[0] ^ s_w[0], s_w[0]};

    function [5:0] to6;                // v / 4 with dither d, saturated
        input [7:0] v;
        input [1:0] d;
        reg   [8:0] s;
        begin
            s   = {1'b0, v} + {7'd0, d};
            to6 = s[8] ? 6'd63 : s[7:2];
        end
    endfunction

    wire [15:0] w_addr = b_w + {6'd0, wx};
    wire [17:0] w_word = {to6(wr_data[23:16], wd), to6(wr_data[15:8], wd),
                          to6(wr_data[7:0], wd)};
    always @(posedge clk)
        if (wr_done) ts[s_w] <= now;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_w <= 7'd0; b_w <= 16'd0;
        end else if (wr_done) begin
            s_w <= (s_w == NS - 1) ? 7'd0 : s_w + 7'd1;
            b_w <= (s_w == NS - 1) ? 16'd0 : b_w + W[15:0];
        end
    end

    // ---- which line each row shows -----------------------------------------
    reg  [19:0] t_field, tau, ts_q;
    reg  [6:0]  s_r;                   // the slot on show
    reg  [15:0] b_r;
    reg         fresh;
    wire [19:0] t_first = t_field + OFF;
    wire [19:0] t_row0  = now + {9'd0, H_TOTAL - H_ACTIVE};   // set at x = H_ACTIVE
    wire [19:0] early   = t_row0 - t_first;
    wire        anchored = (early < 20'd6408);               // eight rows
    wire [6:0]  s_rn  = (s_r == NS - 1) ? 7'd0 : s_r + 7'd1;
    wire [15:0] b_rn  = (s_r == NS - 1) ? 16'd0 : b_r + W[15:0];
    wire [6:0]  lead  = (s_w >= s_r) ? (s_w - s_r) : (s_w + NS[6:0] - s_r);
    wire [19:0] since = tau - ts_q;    // bit 19 clear: published by tau
    // Move on a slot at a time, in the horizontal blanking only, while the next
    // one was published by this row's time -- or, whatever the time, when the
    // writer is about to come round to the slot on show.  ts_q is a clock
    // behind its address, so every other clock at most.
    wire        adv = (x > H_ACTIVE) && (x < H_TOTAL - 11'd5) && fresh &&
                      (s_rn != s_w) && (!since[19] || lead >= NS[6:0] - 7'd2);

    always @(posedge clk) ts_q <= ts[s_rn];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_field <= 20'd0; tau <= 20'd0;
            s_r <= NS[6:0] - 7'd1; b_r <= (NS[15:0] - 16'd1) * W[15:0];
            fresh <= 1'b0; rd_valid <= 1'b0;
        end else begin
            if (field) t_field <= now;
            // The next row's time, set as this row's blanking starts: the
            // frame's first from the field event (or row 0's own start), then
            // STEP a row.  The blanking rows hold the next frame's first, so
            // the ring is caught up by then.
            if (x == H_ACTIVE)
                tau <= (y < V_ACTIVE - 11'd1) ? tau + STEP
                     : anchored ? t_first : t_row0;
            fresh <= !(adv || wr_done);
            if (adv) begin
                s_r <= s_rn; b_r <= b_rn; rd_valid <= 1'b1;
            end
        end
    end

    // ---- reading a row, 1.5 times wider ------------------------------------
    // Output pixel x is source position 2x/3 of the slot: x = 3k shows s[2k],
    // 3k+1 is between s[2k] and s[2k+1], two thirds of the way, and 3k+2 a
    // third of the way from s[2k+1] to s[2k+2] -- weighted a quarter and three
    // quarters, which needs no divider and cannot be told from thirds.  So two
    // reads every three clocks feed a three-pixel window (s0, s1, s2) that
    // moves on by two each group.  The first window is read in the blanking.
    reg  [1:0]  ph;                    // x mod 3 across the row
    reg  [9:0]  ri;                    // next read, within the slot
    reg  [17:0] mem_q, h0, h1, s0, s1, s2;
    wire        pre   = (x >= H_TOTAL - 11'd4) && (x <= H_TOTAL - 11'd2);
    wire        issue = pre || ((x < H_ACTIVE) && (ph != 2'd2));

    // Every bank reads; the ones not addressed reset their output register,
    // so the word is the OR of all of them -- far smaller than a 37-way mux.
    wire [15:0]     r_addr = b_r + {6'd0, ri};
    wire [18*NB-1:0] bank_q;
    genvar gb;
    generate
        for (gb = 0; gb < NB; gb = gb + 1) begin : g_bank
            (* ram_style = "block" *) reg [17:0] mem [0:1023];
            reg [17:0] q;
            always @(posedge clk) begin
                if (wr_en && w_in && w_addr[15:10] == gb) mem[w_addr[9:0]] <= w_word;
                if (r_addr[15:10] != gb) q <= 18'd0;
                else                     q <= mem[r_addr[9:0]];
            end
            assign bank_q[18*gb +: 18] = q;
        end
    endgenerate
    integer ob;
    always @(*) begin
        mem_q = 18'd0;
        for (ob = 0; ob < NB; ob = ob + 1) mem_q = mem_q | bank_q[18*ob +: 18];
    end

    function [7:0] ex;                 // six bits back to eight
        input [5:0] v;
        ex = {v, v[5:4]};
    endfunction
    function [7:0] mix;                // (u + 3 v) / 4, one channel
        input [5:0] u, v;
        reg [9:0]  s;
        begin
            s   = {2'd0, ex(u)} + {1'd0, ex(v), 1'b0} + {2'd0, ex(v)};
            mix = s[9:2];
        end
    endfunction
    wire [17:0] u = (ph == 2'd1) ? s0 : s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph <= 2'd0; ri <= 10'd0;
        end else begin
            ph <= (x == H_TOTAL - 11'd1 || ph == 2'd2) ? 2'd0 : ph + 2'd1;
            ri <= (x == H_TOTAL - 11'd5) ? 10'd0 : issue ? ri + 10'd1 : ri;
        end
    end
    always @(posedge clk) begin
        if (x == H_TOTAL - 11'd3) h0 <= mem_q;
        if (x == H_TOTAL - 11'd2 || (x < H_ACTIVE && ph == 2'd1)) h1 <= mem_q;
        if (x == H_TOTAL - 11'd1) begin
            s0 <= h0; s1 <= h1; s2 <= mem_q;
        end else if (x < H_ACTIVE && ph == 2'd2) begin
            s0 <= s2; s1 <= h1; s2 <= mem_q;
        end
        rd_data <= (ph == 2'd0) ? {ex(s0[17:12]), ex(s0[11:6]), ex(s0[5:0])}
                 : {mix(u[17:12], s1[17:12]), mix(u[11:6], s1[11:6]),
                    mix(u[5:0], s1[5:0])};
    end
endmodule

`default_nettype wire
