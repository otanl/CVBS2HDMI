`default_nettype none
`timescale 1ns/1ps

// A DC/no-sync input must still be observable. The gated instance is the
// negative control: it must not claim that its untouched buffer is a dump.
module scope_freerun_tb;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst_n = 0;
    reg [7:0] adc = 8'hCC;
    wire we, ready, gated_we, gated_ready;
    wire [10:0] addr;
    wire [7:0] data;
    integer writes = 0;
    reg [7:0] expected = 8'hCC;

    ntsc_capture #(.SCOPE_FREERUN(1), .SCOPE_TEST_RAMP(3)) dut (
        .clk_cap(clk), .rst_n(rst_n), .adc_d(adc), .adc_otr(1'b0),
        .phase_sel(3'd2), .gain_sel(2'd0), .dmp_ack(1'b0),
        .dmp_we(we), .dmp_addr(addr), .dmp_data(data), .dmp_rdy(ready)
    );
    ntsc_capture #(.SCOPE_FREERUN(0), .SCOPE_TEST_RAMP(3)) gated (
        .clk_cap(clk), .rst_n(rst_n), .adc_d(adc), .adc_otr(1'b0),
        .phase_sel(3'd2), .gain_sel(2'd0), .dmp_ack(1'b0),
        .dmp_we(gated_we), .dmp_rdy(gated_ready)
    );

    always @(negedge clk) if (rst_n) begin
        if (gated_we || gated_ready)
            $fatal(1, "sync-gated control reported a dump without a line");
        if (we) begin
            if (data !== expected)
                $fatal(1, "raw dump data mismatch: %h != %h", data, expected);
            if (addr !== ((writes + 1) % 2048))
                $fatal(1, "dump address skipped or repeated: %0d", addr);
            writes = writes + 1;
        end
        if (ready && writes < 2048)
            $fatal(1, "dump ready before a complete buffer");
    end

    initial begin
        repeat (10) @(posedge clk);
        #1 rst_n = 1;
        repeat (100) @(posedge clk);
        // Skip the 66 ms timer, not the acquisition or sample timing logic.
        #1 dut.dmp_arm = 23'h7FFFFF;
        gated.dmp_arm = 23'h7FFFFF;
        wait (writes == 2048);
        @(posedge clk); #1;
        if (!ready || dut.dmp_cap) $fatal(1, "first dump did not complete");

        // Live mode must refresh even without a UART acknowledgement or sync.
        adc = 8'h33;
        expected = 8'h33;
        repeat (100) @(posedge clk);
        #1 dut.dmp_arm = 23'h7FFFFF;
        wait (writes == 4096);
        @(posedge clk); #1;
        if (!ready || dut.dmp_cap) $fatal(1, "live dump did not refresh");
        $display("RESULT PASS: two complete raw ADC dumps without sync; gated negative control stayed idle");
        $finish;
    end

    initial begin
        #250000;
        $fatal(1, "no-sync acquisition timed out");
    end
endmodule
`default_nettype wire
