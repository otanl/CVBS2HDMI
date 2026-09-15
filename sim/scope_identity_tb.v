`default_nettype none
`timescale 1ns/1ps
module scope_identity_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg [10:0] test_x = 8, test_y = 204;
    reg [31:0] expected = 32'hA5245C01;
    integer cell_index;
    reg [7:0] before_frame;
    top_ntsc_hdmi #(.SCOPE_ONLY(1), .SCOPE_FULL_RANGE(1), .SCOPE_TEST_RAMP(2)) dut (
        .clk27(clk), .adc_d(8'd0), .adc_otr(1'b0), .btn_n(2'b11)
    );
    initial begin
        force dut.pixel_clk = clk;
        force dut.vid_rst_n = 1'b1;
        force dut.scope_sync = 1'b1;
        force dut.phase_sel = 3'd2;
        force dut.x = test_x;
        force dut.y = test_y;
        force dut.y_d = test_y;
        force dut.scope_frame = 8'h5C;
        for (cell_index = 0; cell_index < 32; cell_index = cell_index+1) begin
            test_x = cell_index*16+8;
            #1;
            if (dut.out_r !== (expected[31-cell_index] ? 8'hFF : 8'h00) ||
                dut.out_g !== dut.out_r || dut.out_b !== dut.out_r)
                $fatal(1, "scope identity cell %0d mismatch", cell_index);
        end
        test_y = 208;
        #1;
        if (dut.on_scope_id !== 1'b0) $fatal(1, "header overlaps trace area");
        release dut.scope_frame;
        @(negedge clk);
        before_frame = dut.scope_frame;
        test_x = 0; test_y = 0;
        @(posedge clk); #1;
        if (dut.scope_frame !== before_frame+8'd1) $fatal(1, "frame counter did not advance");
        @(negedge clk);
        test_x = 1;
        before_frame = dut.scope_frame;
        @(posedge clk); #1;
        if (dut.scope_frame !== before_frame) $fatal(1, "frame counter advances away from frame start");
        $display("RESULT PASS: scope mode/phase identity, trace separation, frame heartbeat");
        $finish;
    end
endmodule
`default_nettype wire
