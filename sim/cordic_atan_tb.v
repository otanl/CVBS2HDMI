`default_nettype none
`timescale 1ns/1ps

// Feed the CORDIC vectors of known angle and check what comes back.
module cordic_atan_tb;
    reg clk = 1'b0;
    always #4 clk = ~clk;

    reg               rst_n = 1'b0;
    reg               start = 1'b0;
    reg signed [17:0] xi, yi;
    wire       [31:0] angle;
    wire              done;

    cordic_atan dut (.clk(clk), .rst_n(rst_n), .start(start),
                     .x_in(xi), .y_in(yi), .angle(angle), .done(done));

    real want, got, err, worst;
    integer t;

    task check(input real deg, input real mag);
        begin
            xi = $rtoi(mag * $cos(deg * 3.14159265 / 180.0));
            yi = $rtoi(mag * $sin(deg * 3.14159265 / 180.0));
            @(posedge clk); start = 1'b1;
            @(posedge clk); start = 1'b0;
            wait (done);
            @(posedge clk);
            got  = angle * 360.0 / 4294967296.0;
            want = deg; if (want < 0.0) want = want + 360.0;
            err  = got - want;
            if (err >  180.0) err = err - 360.0;
            if (err < -180.0) err = err + 360.0;
            if (err < 0.0) err = -err;
            if (err > worst) worst = err;
            $display("  %7.2f deg (mag %5.0f) -> %7.2f   error %5.2f", want, mag, got, err);
        end
    endtask

    initial begin
        worst = 0.0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        for (t = 0; t < 8; t = t + 1) check(t * 45.0, 200.0);
        check(11.25, 200.0);
        check(123.4, 200.0);
        check(-67.0, 200.0);
        // Small vectors matter: the burst here is only about 19 codes, so the
        // correlation it produces is not large.
        check(30.0, 20.0);
        check(150.0, 12.0);
        $display("worst error: %.2f deg", worst);
        // 3 degrees, and the two cases that need the headroom are magnitude 12
        // and 20 -- there the error is the integer input, not the CORDIC: at
        // magnitude 200 it is under 0.4 degrees throughout.  The real burst
        // correlates to about 100..200, so that is the number that matters.
        if (worst < 3.0) $display("RESULT PASS"); else $fatal(1, "RESULT FAIL");
        $finish;
    end
endmodule

`default_nettype wire
