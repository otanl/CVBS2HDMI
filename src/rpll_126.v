`default_nettype none

// 27 MHz -> 126 MHz TMDS serial clock for 640x480p60.
//
// CLKOUT = FCLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1) = 27 * 14 / 3 = 126 MHz
// VCO    = CLKOUT * ODIV_SEL                     = 126 * 4    = 504 MHz
// CLKDIV by five gives a 25.2 MHz pixel clock.  VGA nominally wants 25.175,
// which is 0.1% away -- well inside what any sink accepts.  These are the
// same settings Apicula's own DVI example uses on this device.
module rpll_126 (
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
    defparam rpll_inst.IDIV_SEL         = 2;
    defparam rpll_inst.DYN_FBDIV_SEL    = "false";
    defparam rpll_inst.FBDIV_SEL        = 13;
    defparam rpll_inst.DYN_ODIV_SEL     = "false";
    defparam rpll_inst.ODIV_SEL         = 4;
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
