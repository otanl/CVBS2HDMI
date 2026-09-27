`default_nettype none

// CTA-861 VIC 2: 720x480p59.94 from a 27 MHz pixel clock.
// 27e6 / (858 * 525) = 59.9401 Hz, which is exactly the NTSC field rate --
// the two are the same number, so a free-running output and an NTSC source
// stay in step apart from crystal tolerance.
module video_timing #(
    // Defaults are CTA-861 VIC 2 (720x480p59.94).  720p60 is
    // 1280/110/40/1650 x 720/5/5/750 with POSITIVE sync.
    parameter [10:0] H_ACTIVE = 11'd720,
    parameter [10:0] H_FRONT  = 11'd16,
    parameter [10:0] H_SYNC   = 11'd62,
    parameter [10:0] H_TOTAL  = 11'd858,
    parameter [10:0] V_ACTIVE = 11'd480,
    parameter [10:0] V_FRONT  = 11'd9,
    parameter [10:0] V_SYNC   = 11'd6,
    parameter [10:0] V_TOTAL  = 11'd525,
    parameter        SYNC_POS = 1'b0
) (
    input  wire        pixel_clk,
    input  wire        reset_n,
    // Restart the frame here.  Used to lock vertical position to the incoming
    // field; tie low to free-run.
    //
    // Prefer v_longer/v_shorter below: a restart moves the frame by up to a
    // whole field in one step, and a sink shown that drops the link outright.
    input  wire        vsync_align,
    // Vertical phase servo: make this frame one line longer or one line
    // shorter than V_TOTAL.  A line either way is far inside what any sink
    // tolerates, and repeated every frame it walks the output frame onto the
    // incoming field within a few seconds and then holds it there.  It also
    // absorbs the standing 0.1% between a 60.00 Hz output and a 59.94 Hz
    // source, which a one-shot alignment cannot do at all.
    input  wire        v_longer,
    input  wire        v_shorter,
    // The frame's base length, taken once per frame; V_TOTAL is used until
    // the first.  top_ntsc_hdmi sets it from the input's fields: 525 for
    // interlaced NTSC, 524 for the 240p most game consoles send.
    input  wire [10:0] v_total,
    output reg  [10:0] x,
    output reg  [10:0] y,
    output wire        active,
    output wire        hsync,
    output wire        vsync
);
    // Latched once per frame so the length cannot change underneath the
    // counter mid-frame.
    reg [10:0] v_end;
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n)
            v_end <= V_TOTAL - 11'd1;
        else if ((x == H_TOTAL - 11'd1) && (y == 11'd0))
            v_end <= v_total - 11'd1 + {10'd0, v_longer} - {10'd0, v_shorter};
    end

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            x <= 11'd0;
            y <= 11'd0;
        end else if (x == H_TOTAL - 11'd1) begin
            x <= 11'd0;
            // Align on a line boundary only, so a realignment never produces a
            // short line -- monitors tolerate a varying frame far better than
            // a varying line.
            if (vsync_align)                y <= V_ACTIVE + V_FRONT;
            else if (y == v_end)            y <= 11'd0;
            else                            y <= y + 11'd1;
        end else begin
            x <= x + 11'd1;
        end
    end

    assign active = (x < H_ACTIVE) && (y < V_ACTIVE);

    wire h_in_sync = (x >= H_ACTIVE + H_FRONT) &&
                     (x <  H_ACTIVE + H_FRONT + H_SYNC);
    wire v_in_sync = (y >= V_ACTIVE + V_FRONT) &&
                     (y <  V_ACTIVE + V_FRONT + V_SYNC);

    // 480p is negative sync, 720p is positive.  Getting this wrong is a
    // common cause of a sink refusing the link outright.
    assign hsync = SYNC_POS ? h_in_sync : ~h_in_sync;
    assign vsync = SYNC_POS ? v_in_sync : ~v_in_sync;
endmodule

`default_nettype wire
