`timescale 1ns/1ps
`default_nettype none

// Drives adc_probe_top with a synthetic NTSC composite signal through a
// behavioural AD9280, prints whatever the design sends over the UART, and
// checks the measured line period.
module adc_probe_tb;
    // Overridable from the command line (iverilog -Padc_probe_tb.PHASE=1) so the
    // same bench can also prove that a *wrong* sampling phase is reported as
    // broken -- otherwise "ln=1716" would be an untested claim.
    parameter integer PHASE = 2;
    // Shrunk so the run finishes quickly; the hardware build uses the defaults.
    localparam integer SAMPLES_PER_WINDOW = 27_000;   // 1 ms
    localparam integer CLKS_PER_BIT       = 8;
    localparam integer DEBOUNCE_CYCLES    = 16;
    localparam integer DUMP_LEN           = 64;

    localparam real CLK27_HALF = 18.518518;           // 27 MHz
    localparam real CLK108     = 9.259259;
    localparam real BIT_NS     = CLKS_PER_BIT * CLK108;

    // NTSC: 15734.264 Hz line rate.
    localparam real LINE_NS  = 63555.555;
    localparam integer SYNC  = 80;                    // clamped sync tip
    localparam integer BLANK = 116;                   // sync tip + 285.7 mV
    localparam integer WHITE = 205;

    localparam real T_OD = 10.0;                      // AD9280 output delay

    reg        clk27 = 1'b0;
    reg  [1:0] btn_n = 2'b11;
    wire [7:0] adc_d;
    wire       adc_clk, adc_clamp, uart_line;
    wire [5:0] led_n;

    always #(CLK27_HALF) clk27 = ~clk27;

    adc_probe_top #(
        .SAMPLES_PER_WINDOW (SAMPLES_PER_WINDOW),
        .CLKS_PER_BIT       (CLKS_PER_BIT),
        .DEBOUNCE_CYCLES    (DEBOUNCE_CYCLES),
        .DUMP_LEN           (DUMP_LEN),
        // The real design stays silent for five seconds after configuration so
        // a flash-booted board does not flood the USB bridge through
        // enumeration; that is far longer than this bench runs.
        .UART_HOLDOFF       (32),
        .DEFAULT_PHASE      (PHASE[1:0])
    ) dut (
        .clk27       (clk27),
        .adc_d       (adc_d),
        .adc_otr     (1'b0),
        .adc_clk     (adc_clk),
        .adc_clamp   (adc_clamp),
        .btn_n       (btn_n),
        .led_n       (led_n),
        .uart_tx_pin (uart_line)
    );

    // ---------------------------------------------------------------- AD9280
    // Composite waveform.  Lines 0..2 of each 262-line field carry half-line
    // broad pulses so the vertical detector and the half-line rejection in the
    // period measurement both get exercised.
    function [7:0] ntsc_code(input real t);
        real    tl, th;
        integer ln, fl;
        begin
            ln = $rtoi(t / LINE_NS);
            tl = t - (ln * LINE_NS);
            fl = ln % 262;
            if (fl < 3) begin
                th = (tl >= LINE_NS / 2.0) ? (tl - LINE_NS / 2.0) : tl;
                ntsc_code = (th < 27100.0) ? SYNC[7:0] : BLANK[7:0];
            end else if (tl < 4700.0) begin
                ntsc_code = SYNC[7:0];
            end else if (tl < 9400.0) begin
                ntsc_code = BLANK[7:0];
            end else begin
                ntsc_code = BLANK +
                    $rtoi(((tl - 9400.0) / (LINE_NS - 9400.0)) * (WHITE - BLANK));
            end
        end
    endfunction

    reg [7:0] adc_model = 8'd0;
    reg [7:0] latched   = 8'd0;
    assign adc_d = adc_model;

    always @(posedge adc_clk) begin
        latched = ntsc_code($realtime);
        // Outputs are indeterminate while they switch: a sampling phase that
        // lands in this window must show up as broken, not as merely stale.
        #(T_OD - 1.0) adc_model = 8'hxx;
        #(2.0)        adc_model = latched;
    end

    // ------------------------------------------------------------ UART print
    reg [7:0] rxb;
    integer   k;
    initial begin
        forever begin
            @(negedge uart_line);
            #(BIT_NS * 1.5);
            for (k = 0; k < 8; k = k + 1) begin
                rxb[k] = uart_line;
                #(BIT_NS);
            end
            $write("%c", rxb);
        end
    end

    // --------------------------------------------------------------- checking
    integer reports   = 0;
    integer ln_1716   = 0;
    integer tog_bad   = 0;
    integer vs_seen   = 0;
    integer otr_seen  = 0;
    integer clean_win = 0;

    always @(posedge dut.clk108) begin
        if (dut.report_req) begin
            reports = reports + 1;
            // Window 1 runs with the seed threshold and cannot measure yet.
            if (reports > 1) begin
                if (dut.val[5] == 24'd1716) ln_1716 = ln_1716 + 1;
                if (dut.val[1] != 24'd255)  tog_bad = tog_bad + 1;
                if (dut.val[10] != 24'd0)   vs_seen = vs_seen + 1;
                if (dut.val[11] != 24'd0)   otr_seen = otr_seen + 1;
                if (dut.val[9] >= 24'd10 && dut.val[8] + 24'd2 >= dut.val[9])
                    clean_win = clean_win + 1;
            end
        end
    end

    integer errors = 0;
    task check(input ok, input [255:0] what);
        begin
            if (!ok) begin
                $display("FAIL: %0s", what);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("build/adc_probe.vcd");
            $dumpvars(0, adc_probe_tb);
        end

        // Request a raw dump once the measurement has settled.
        #25_000_000 btn_n[0] = 1'b0;
        #1_000_000  btn_n[0] = 1'b1;

        #15_000_000;
        $display("");
        $display("--- reports=%0d ln1716=%0d togbad=%0d vs=%0d otr=%0d clean=%0d",
                 reports, ln_1716, tog_bad, vs_seen, otr_seen, clean_win);

        check(reports >= 30, "expected at least 30 report windows");

        if (PHASE == 2) begin
            check(ln_1716   >= 25, "line period should read 1716 in nearly every window");
            check(tog_bad   == 0,  "all eight data bits should toggle every window");
            check(vs_seen   >= 1,  "vertical sync should be detected at least once");
            check(otr_seen  == 0,  "no over-range expected from the model");
            check(clean_win >= 25, "accepted line periods should almost all be in range");
        end else begin
            // Phase 1 samples while the AD9280 outputs are switching.
            check(ln_1716 == 0, "a sampling phase inside the switching window must not read 1716");
        end

        if (errors == 0) $display("PASS: %0s (phase %0d)", (PHASE == 2) ? "ADC capture path measures NTSC correctly" : "wrong sampling phase is correctly reported as broken", PHASE);
        else             $fatal(1, "FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule

`default_nettype wire
