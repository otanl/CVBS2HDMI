`default_nettype none

// 27 MHz -> 371.25 MHz TMDS serial clock for 1280x720p60.
//
// rPLL:  CLKOUT = FCLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1) = 27 * 55 / 4 = 371.25
//        VCO    = CLKOUT * ODIV_SEL                     = 371.25 * 2 = 742.5
// These are Sipeed's own settings for this device in their HDMI example.
// A CLKDIV by five gives the 74.25 MHz pixel clock 720p60 needs.
module rpll_371 (
    input  wire clkin,
    output wire clkout,
    output wire lock
);
    wire clkoutp_o, clkoutd_o, clkoutd3_o;

    rPLL rpll_inst (
        .CLKOUT(clkout), .LOCK(lock), .CLKOUTP(clkoutp_o),
        .CLKOUTD(clkoutd_o), .CLKOUTD3(clkoutd3_o),
        .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clkin), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    defparam rpll_inst.FCLKIN           = "27";
    defparam rpll_inst.DYN_IDIV_SEL     = "false";
    defparam rpll_inst.IDIV_SEL         = 3;
    defparam rpll_inst.DYN_FBDIV_SEL    = "false";
    defparam rpll_inst.FBDIV_SEL        = 54;
    defparam rpll_inst.DYN_ODIV_SEL     = "false";
    defparam rpll_inst.ODIV_SEL         = 2;
    defparam rpll_inst.PSDA_SEL         = "0000";
    defparam rpll_inst.DYN_DA_EN        = "true";
    defparam rpll_inst.DUTYDA_SEL       = "1000";
    defparam rpll_inst.CLKOUT_FT_DIR    = 1'b1;
    defparam rpll_inst.CLKOUTP_FT_DIR   = 1'b1;
    defparam rpll_inst.CLKOUT_DLY_STEP  = 0;
    defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
    defparam rpll_inst.CLKFB_SEL        = "internal";
    defparam rpll_inst.CLKOUT_BYPASS    = "false";
    defparam rpll_inst.CLKOUTP_BYPASS   = "false";
    defparam rpll_inst.CLKOUTD_BYPASS   = "false";
    defparam rpll_inst.DYN_SDIV_SEL     = 2;
    defparam rpll_inst.CLKOUTD_SRC      = "CLKOUT";
    defparam rpll_inst.CLKOUTD3_SRC     = "CLKOUT";
    defparam rpll_inst.DEVICE           = "GW2AR-18C";
endmodule

`default_nettype wire
