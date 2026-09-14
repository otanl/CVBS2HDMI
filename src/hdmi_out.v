`default_nettype none

// TMDS encode + 10:1 serialise + differential output for one DVI link.
//
// The Tang Nano 20K's HDMI pins are TRUE LVDS pairs, so this uses TLVDS_OBUF.
// Do not copy the 9K project's ELVDS_OBUF here: Apicula checks the pin class
// and rejects it outright --
//   "X23Y54/IOBA (tmds_clk_p_OBUF_O) cannot be placed - location is a True
//    LVDS pin"
// Apicula also requires P on the IOBA pin and N on the IOBB pin of the pair,
// which is the 33/34, 35/36, 37/38, 39/40 ordering in the constraints file.
module hdmi_out #(
    // 0 = drive the clock lane straight from pixel_clk.  This is what the
    //     proven Tang Nano 9K design does.
    // 1 = serialise 1111100000 through an OSER10 like the data lanes, which
    //     matches their path delay and gives better clock-to-data alignment.
    parameter CLK_LANE_OSER = 1'b0
) (
    input  wire       pixel_clk,
    input  wire       serial_clk,
    input  wire       reset_n,
    input  wire       active,
    input  wire       hsync,
    input  wire       vsync,
    input  wire [7:0] red,
    input  wire [7:0] green,
    input  wire [7:0] blue,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);
    wire [9:0] tmds_blue, tmds_green, tmds_red;

    // Channel 0 carries blue plus the sync pair during blanking.
    tmds_encoder encode_blue (
        .pixel_clk(pixel_clk), .reset_n(reset_n),
        .data_enable(active), .control({vsync, hsync}),
        .video_data(blue), .tmds_word(tmds_blue)
    );
    tmds_encoder encode_green (
        .pixel_clk(pixel_clk), .reset_n(reset_n),
        .data_enable(active), .control(2'b00),
        .video_data(green), .tmds_word(tmds_green)
    );
    tmds_encoder encode_red (
        .pixel_clk(pixel_clk), .reset_n(reset_n),
        .data_enable(active), .control(2'b00),
        .video_data(red), .tmds_word(tmds_red)
    );

    // The clock lane is serialised through an OSER10 exactly like the data
    // lanes, emitting 1111100000 once per pixel.  Do NOT route pixel_clk
    // straight to the output buffer instead: the global clock network and the
    // OSER10 output path have very different delays, and the resulting
    // clock-to-data skew is enough to stop a receiver locking at all.
    localparam [9:0] CLK_PATTERN = 10'b1111100000;

    wire [2:0] serial_data;
    wire       serial_clock_lane;

    OSER10 serialize_blue (
        .Q(serial_data[0]),
        .D0(tmds_blue[0]), .D1(tmds_blue[1]), .D2(tmds_blue[2]),
        .D3(tmds_blue[3]), .D4(tmds_blue[4]), .D5(tmds_blue[5]),
        .D6(tmds_blue[6]), .D7(tmds_blue[7]), .D8(tmds_blue[8]),
        .D9(tmds_blue[9]),
        .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(~reset_n)
    );
    OSER10 serialize_green (
        .Q(serial_data[1]),
        .D0(tmds_green[0]), .D1(tmds_green[1]), .D2(tmds_green[2]),
        .D3(tmds_green[3]), .D4(tmds_green[4]), .D5(tmds_green[5]),
        .D6(tmds_green[6]), .D7(tmds_green[7]), .D8(tmds_green[8]),
        .D9(tmds_green[9]),
        .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(~reset_n)
    );
    OSER10 serialize_red (
        .Q(serial_data[2]),
        .D0(tmds_red[0]), .D1(tmds_red[1]), .D2(tmds_red[2]),
        .D3(tmds_red[3]), .D4(tmds_red[4]), .D5(tmds_red[5]),
        .D6(tmds_red[6]), .D7(tmds_red[7]), .D8(tmds_red[8]),
        .D9(tmds_red[9]),
        .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(~reset_n)
    );

    generate if (CLK_LANE_OSER) begin : g_clk_oser
    OSER10 serialize_clock (
        .Q(serial_clock_lane),
        .D0(CLK_PATTERN[0]), .D1(CLK_PATTERN[1]), .D2(CLK_PATTERN[2]),
        .D3(CLK_PATTERN[3]), .D4(CLK_PATTERN[4]), .D5(CLK_PATTERN[5]),
        .D6(CLK_PATTERN[6]), .D7(CLK_PATTERN[7]), .D8(CLK_PATTERN[8]),
        .D9(CLK_PATTERN[9]),
        .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(~reset_n)
    );
    end else begin : g_clk_direct
        assign serial_clock_lane = pixel_clk;
    end endgenerate

    TLVDS_OBUF out_blue  (.I(serial_data[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    TLVDS_OBUF out_green (.I(serial_data[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    TLVDS_OBUF out_red   (.I(serial_data[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
    TLVDS_OBUF out_clock (.I(serial_clock_lane), .O(tmds_clk_p), .OB(tmds_clk_n));
endmodule

`default_nettype wire
