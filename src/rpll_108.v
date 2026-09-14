`default_nettype none

// 27 MHz -> 108 MHz (4x oversampling of the 27 MHz ADC sample clock).
//
// rPLL:  CLKOUT = FCLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1)  = 27 * 4 / 1 = 108 MHz
//        VCO    = CLKOUT * ODIV_SEL                      = 108 * 8   = 864 MHz
// The GW2A VCO must stay inside 400..1200 MHz, so ODIV_SEL = 8.
//
// rPLL (not PLLVR) is the correct primitive for the GW2AR-LV18QN88C8/I7 on the
// Tang Nano 20K; this matches Sipeed's own TangNano-20K-example/hdmi IP wrapper,
// including the DEVICE = "GW2AR-18C" defparam.
module rpll_108 (
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
    defparam rpll_inst.FBDIV_SEL        = 3;
    defparam rpll_inst.DYN_ODIV_SEL     = "false";
    defparam rpll_inst.ODIV_SEL         = 8;
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
