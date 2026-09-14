`default_nettype none

// 27 MHz -> 135 MHz TMDS serial clock for 720x480p60.
//
// rPLL:  CLKOUT = FCLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1) = 27 * 5 / 1 = 135 MHz
//        VCO    = CLKOUT * ODIV_SEL                     = 135 * 4   = 540 MHz
// A CLKDIV by five turns this back into a phase-aligned 27 MHz pixel clock,
// which is exactly the CTA-861 VIC 2 (720x480p59.94) pixel rate.
module rpll_135 (
    input  wire clkin,
    output wire clkout,
    output wire lock
);
    wire clkoutp_o;
    wire clkoutd_o;
    wire clkoutd3_o;

    rPLL rpll_inst (
        .CLKOUT   (clkout),
        .LOCK     (lock),
        .CLKOUTP  (clkoutp_o),
        .CLKOUTD  (clkoutd_o),
        .CLKOUTD3 (clkoutd3_o),
        .RESET    (1'b0),
        .RESET_P  (1'b0),
        .CLKIN    (clkin),
        .CLKFB    (1'b0),
        .FBDSEL   (6'b0),
        .IDSEL    (6'b0),
        .ODSEL    (6'b0),
        .PSDA     (4'b0),
        .DUTYDA   (4'b0),
        .FDLY     (4'b0)
    );

    defparam rpll_inst.FCLKIN           = "27";
    defparam rpll_inst.DYN_IDIV_SEL     = "false";
    defparam rpll_inst.IDIV_SEL         = 0;
    defparam rpll_inst.DYN_FBDIV_SEL    = "false";
    defparam rpll_inst.FBDIV_SEL        = 4;
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
