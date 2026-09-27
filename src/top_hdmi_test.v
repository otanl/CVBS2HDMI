`default_nettype none

// HDMI bring-up for the Tang Nano 20K, independent of anything NTSC.
//
// This exists so the output chain can be proven on its own: rPLL, CLKDIV by
// five to the pixel clock, CTA-861 timing, TMDS encode, OSER10 serialisation
// and true-LVDS output -- plus whether the sink accepts the link at all.
// It also reports lock / frame rate / line rate over the serial port, so
// "no signal" can be attributed to the right side of the cable.
//
// MODE picks the output format, because sinks differ about what they accept:
//   0 = 720x480p59.94  (CEA VIC 2, the TV format NTSC maps onto naturally)
//   1 = 1280x720p60     (universally accepted)
//   2 = 640x480p60      (VGA/DMT; capture devices that refuse 720x480 often
//                        take this, and it keeps the 525-line 60 Hz structure
//                        so one NTSC line still maps to exactly two output
//                        lines)
module top_hdmi_test #(
    parameter [1:0] MODE          = 2'd0,
    parameter       CLK_LANE_OSER = 1'b0
) (
    input  wire       clk27,
    output wire [5:0] led_n,
    output wire       uart_tx_pin,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);
    localparam [10:0] H_ACT   = (MODE == 2'd1) ? 11'd1280 :
                                (MODE == 2'd2) ? 11'd640  : 11'd720;
    localparam [10:0] H_FRONT = (MODE == 2'd1) ? 11'd110  :
                                (MODE == 2'd2) ? 11'd16   : 11'd16;
    localparam [10:0] H_SYNC  = (MODE == 2'd1) ? 11'd40   :
                                (MODE == 2'd2) ? 11'd96   : 11'd62;
    localparam [10:0] H_TOT   = (MODE == 2'd1) ? 11'd1650 :
                                (MODE == 2'd2) ? 11'd800  : 11'd858;
    localparam [10:0] V_ACT   = (MODE == 2'd1) ? 11'd720  : 11'd480;
    localparam [10:0] V_FRONT = (MODE == 2'd1) ? 11'd5    :
                                (MODE == 2'd2) ? 11'd10   : 11'd9;
    localparam [10:0] V_SYNC  = (MODE == 2'd1) ? 11'd5    :
                                (MODE == 2'd2) ? 11'd2    : 11'd6;
    localparam [10:0] V_TOT   = (MODE == 2'd1) ? 11'd750  : 11'd525;
    // 720p60 uses positive sync; both 480-line formats use negative.
    localparam        SYNC_POS = (MODE == 2'd1);

    wire serial_clk;
    wire pixel_clk;
    wire pll_lock;

    generate
        if (MODE == 2'd1) begin : g_pll720
            rpll_371 pll (.clkin(clk27), .clkout(serial_clk), .lock(pll_lock));
        end else if (MODE == 2'd2) begin : g_pll640
            rpll_126 pll (.clkin(clk27), .clkout(serial_clk), .lock(pll_lock));
        end else begin : g_pll480
            rpll_135 pll (.clkin(clk27), .clkout(serial_clk), .lock(pll_lock));
        end
    endgenerate

    CLKDIV pixel_clock_divider (
        .CLKOUT(pixel_clk), .HCLKIN(serial_clk),
        .RESETN(pll_lock), .CALIB(1'b0)
    );
    defparam pixel_clock_divider.DIV_MODE = "5";
    defparam pixel_clock_divider.GSREN    = "false";

    reg [3:0] reset_pipe = 4'b0000;
    always @(posedge pixel_clk) begin
        if (!pll_lock) reset_pipe <= 4'b0000;
        else           reset_pipe <= {reset_pipe[2:0], 1'b1};
    end
    wire video_reset_n = reset_pipe[3];

    wire [10:0] x, y;
    wire        active, hsync, vsync;

    video_timing #(
        .H_ACTIVE(H_ACT), .H_FRONT(H_FRONT), .H_SYNC(H_SYNC), .H_TOTAL(H_TOT),
        .V_ACTIVE(V_ACT), .V_FRONT(V_FRONT), .V_SYNC(V_SYNC), .V_TOTAL(V_TOT),
        .SYNC_POS(SYNC_POS)
    ) timing (
        .pixel_clk(pixel_clk), .reset_n(video_reset_n),
        .vsync_align(1'b0),
        .x(x), .y(y), .active(active), .hsync(hsync), .vsync(vsync)
    );

    // One bar steps across once per frame so a frozen picture is obvious.
    reg [10:0] bar_x;
    reg        vsync_d;
    always @(posedge pixel_clk or negedge video_reset_n) begin
        if (!video_reset_n) begin
            bar_x   <= 11'd0;
            vsync_d <= 1'b1;
        end else begin
            vsync_d <= vsync;
            if (vsync != vsync_d && vsync == SYNC_POS)
                bar_x <= (bar_x + 11'd12 >= H_ACT) ? 11'd0 : bar_x + 11'd12;
        end
    end

    reg [7:0] red, green, blue;
    always @* begin
        red = 8'h00; green = 8'h00; blue = 8'h00;
        if (active) begin
            // Eight-step grey ramp, the same shape the monochrome NTSC path
            // will produce, so luma problems later look familiar.
            red   = {x[9:7], 5'b11111};
            green = red;
            blue  = red;

            // Colour bars across the bottom third prove all three channels.
            if (y >= (V_ACT - (V_ACT >> 2))) begin
                red   = x[9] ? 8'hff : 8'h00;
                green = x[8] ? 8'hff : 8'h00;
                blue  = x[7] ? 8'hff : 8'h00;
            end

            // A white border makes overscan immediately visible.
            if ((x < 11'd4) || (x >= H_ACT - 11'd4) ||
                (y < 11'd4) || (y >= V_ACT - 11'd4)) begin
                red = 8'hff; green = 8'hff; blue = 8'hff;
            end

            if ((x >= bar_x) && (x < bar_x + 11'd12)) begin
                red = 8'hff; green = 8'h00; blue = 8'h00;
            end
        end
    end

    hdmi_out #(.CLK_LANE_OSER(CLK_LANE_OSER)) out (
        .pixel_clk(pixel_clk), .serial_clk(serial_clk), .reset_n(video_reset_n),
        .active(active), .hsync(hsync), .vsync(vsync),
        .red(red), .green(green), .blue(blue), .sparkle(8'd0),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    reg [3:0] sys_reset_pipe = 4'b0000;
    always @(posedge clk27) sys_reset_pipe <= {sys_reset_pipe[2:0], 1'b1};

    hdmi_status status (
        .clk27(clk27), .rst_n(sys_reset_pipe[3]),
        .pll_lock(pll_lock), .vsync_pix(vsync), .hsync_pix(hsync),
        .uart_tx_pin(uart_tx_pin)
    );

    reg [25:0] hb;
    always @(posedge clk27) hb <= hb + 26'd1;
    assign led_n = ~{4'b0000, pll_lock, hb[24]};
endmodule

`default_nettype wire
