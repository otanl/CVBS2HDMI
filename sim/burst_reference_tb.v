`default_nettype none
`timescale 1ns/1ps

// Check the reference actually used by the colour decoder, not just the
// oscillator's diagnostic I/Q. Each line has a different, known burst phase.
module burst_reference_tb;
    parameter integer HALFWAVE = 0;
    parameter integer PPM = 0;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst_n = 0;
    reg sample_en = 0;
    reg [7:0] sample = 100;
    reg gate = 0;
    wire [31:0] phase_ref;
    wire locked;
    burst_nco dut (
        .clk(clk), .rst_n(rst_n), .sample_en(sample_en),
        .sample(sample), .blank_ref(8'd100), .burst_gate(gate),
        .phase(), .inc(), .burst_i(), .burst_q(),
        .locked(locked), .good_lines(), .phase_ref(phase_ref)
    );
    integer line_no, pos, n = 0, checks = 0, failures = 0;
    real angle, value, got, error, worst = 0.0;
    localparam real PI = 3.141592653589793;
    task tick;
        begin
            sample_en = 1;
            @(negedge clk);
            sample_en = 0;
            repeat (4) @(negedge clk);
        end
    endtask
    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1;
        // Include abrupt changes exceeding 90/180 degrees. NTSC burst and
        // picture change together; a decoder must not unwrap modulo 180.
        for (line_no = 0; line_no < 96; line_no = line_no + 1) begin
            for (pos = 0; pos < 1602; pos = pos + 1) begin
                angle = 2.0*PI*n*(315000000.0/88.0)/25200000.0 *
                        (1.0 + PPM/1000000.0) + line_no*137.0*PI/180.0;
                gate = pos >= 136 && pos < 196;
                value = 20.0*$cos(angle);
                if (HALFWAVE && value < 0.0) value = 0.0;
                sample = gate ? $rtoi(100.0 + value + 0.5) : 100;
                // Sample before the enabled edge: phase_ref describes the
                // sample consumed at that edge, not the following sample.
                if (pos == 300 && line_no > 4) begin
                    got = phase_ref * 2.0*PI / 4294967296.0;
                    error = $atan2($sin(got-angle), $cos(got-angle))*180.0/PI;
                    if (error < 0) error = -error;
                    if (error > worst) worst = error;
                    if (error > 12.0) failures = failures + 1;
                    checks = checks + 1;
                end
                tick;
                n = n + 1;
            end
        end
        $display("reference: halfwave=%0d ppm=%0d checks=%0d failures=%0d worst=%.2f deg",
                 HALFWAVE, PPM, checks, failures, worst);
        if (failures || !locked) $fatal(1, "burst phase reference is incorrect");
        // A disconnected/monochrome source must lose colour lock.
        repeat (300*1602) begin gate = 0; sample = 100; tick; end
        if (locked) $fatal(1, "colour lock survived missing bursts");
        $display("RESULT PASS");
        $finish;
    end
endmodule
`default_nettype wire
