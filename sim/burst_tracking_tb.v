`default_nettype none
`timescale 1ns/1ps

// A rotating burst like the M5, including a full vertical blanking interval.
// Check the first returning line, not just colour after a long settling time.
module burst_tracking_tb;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst_n = 0, sample_en = 0, gate = 0;
    reg [7:0] sample = 100;
    wire [31:0] phase_ref;
    wire locked;
    burst_nco dut (
        .clk(clk), .rst_n(rst_n), .sample_en(sample_en), .sample(sample),
        .blank_ref(8'd100), .burst_gate(gate), .phase(), .inc(),
        .burst_i(), .burst_q(), .locked(locked), .good_lines(),
        .phase_ref(phase_ref)
    );
    integer ln, pos, n = 0, checks = 0, failures = 0;
    real angle, got, error, worst = 0.0;
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
        for (ln = 0; ln < 140; ln = ln + 1) begin
            for (pos = 0; pos < 1602; pos = pos + 1) begin
                angle = 2.0*PI*n*(315000000.0/88.0)/25200000.0 +
                        ln*137.0*PI/180.0;
                gate = pos >= 136 && pos < 196 && !(ln >= 64 && ln < 88);
                sample = gate ? $rtoi(100.0+20.0*$cos(angle)+0.5) : 100;
                if (ln >= 64 && ln < 88 && !locked)
                    $fatal(1, "valid vertical blanking lost colour lock");
                if (pos == 300 && ln >= 32 && !(ln >= 64 && ln < 88)) begin
                    got = phase_ref * 2.0*PI/4294967296.0;
                    error = $atan2($sin(got-angle), $cos(got-angle))*180.0/PI;
                    if (error < 0) error = -error;
                    if (error > worst) worst = error;
                    if (error > 12.0) begin
                        failures = failures + 1;
                        $display("bad burst line=%0d error=%.2f deg", ln, error);
                    end
                    checks = checks + 1;
                end
                tick;
                n = n + 1;
            end
        end
        $display("tracking: checks=%0d failures=%0d worst=%.2f deg", checks, failures, worst);
        if (failures || !locked) $fatal(1, "burst tracking failed across vertical blanking");
        $display("RESULT PASS");
        $finish;
    end
endmodule
`default_nettype wire
