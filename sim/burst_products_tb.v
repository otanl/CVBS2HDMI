`default_nettype none
`timescale 1ns/1ps

// The ADC register can change on EVERY capture clock, not only sample_en.
// A timing pipeline must retain the sample, black reference and oscillator
// weight selected on the same strobe, including both ends of the burst gate.
module burst_products_tb;
    parameter integer SINE_REF = 1;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst_n = 0, sample_en = 0, gate = 0;
    reg [7:0] sample = 0, black = 0;
    reg [31:0] lfsr = 32'h93A14C72;
    wire signed [15:0] burst_i, burst_q;
    reg gate_d = 0;
    integer cycle, centre, previous_centre = 0;
    integer sum_i = 0, sum_q = 0, checks = 0, changed = 0, check_in = 0;
    reg signed [15:0] expected_i, expected_q;

    burst_nco #(.SINE_REF(SINE_REF)) dut (
        .clk(clk), .rst_n(rst_n), .sample_en(sample_en),
        .sample(sample), .blank_ref(black), .burst_gate(gate), .gate_restart(1'b0),
        .burst_i(burst_i), .burst_q(burst_q)
    );

    always @(posedge clk) if (rst_n) begin
        centre = integer'(sample) - integer'(black);
        if (sample_en) begin
            if (gate) begin
                sum_i = sum_i + centre * $signed(dut.i_weight);
                sum_q = sum_q + centre * $signed(dut.q_weight);
                if (centre != previous_centre) changed = changed + 1;
            end else if (gate_d) begin
                expected_i = sum_i >>> 6;
                expected_q = sum_q >>> 6;
                sum_i = 0; sum_q = 0;
                check_in = 4;
            end
            gate_d = gate;
        end
        previous_centre = centre;
    end

    // The correlation is published three clocks after the gate's fall is
    // seen (burst_nco's pipeline flush); check it before the next strobe.
    always @(posedge clk) if (check_in != 0) begin
        check_in = check_in - 1;
        if (check_in == 0) begin
            #1;
            if (burst_i !== expected_i || burst_q !== expected_q)
                $fatal(1, "burst product misalignment: got %0d,%0d expected %0d,%0d",
                       burst_i, burst_q, expected_i, expected_q);
            checks = checks + 1;
        end
    end

    initial begin
        repeat (10) @(negedge clk);
        rst_n = 1;
        for (cycle = 0; cycle < 30000; cycle = cycle + 1) begin
            @(negedge clk);
            lfsr = {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            sample = lfsr[7:0]; black = lfsr[15:8];
            sample_en = (cycle % 5 == 0);
            gate = ((cycle / 5) % 96 < 56);
        end
        @(negedge clk);
        sample_en = 0;
        if (checks < 60 || changed < 3000)
            $fatal(1, "insufficient burst/input-change coverage");
        $display("RESULT PASS: %0d exact burst correlations, %0d changing strobe inputs, sine=%0d",
                 checks, changed, SINE_REF);
        $finish;
    end
endmodule
`default_nettype wire
