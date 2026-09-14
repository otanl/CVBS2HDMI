`default_nettype none
`timescale 1ns/1ps
module hdmi_pipeline_tb;
    reg clk27=0;
    always #18.518518 clk27=~clk27;
    top_ntsc_hdmi dut (
        .clk27(clk27), .adc_d(8'd100), .adc_otr(1'b0),
        .adc_clk(), .adc_clamp(), .btn_n(2'b11), .led_n(), .uart_tx_pin(),
        .tmds_clk_p(), .tmds_clk_n(), .tmds_d_p(), .tmds_d_n()
    );
    integer count=0, lines=0, pixels=0, frames=0;
    reg measuring=0;
    always @(negedge dut.pixel_clk) if (measuring) begin
        if (^({dut.x,dut.y}) === 1'bx ||
            (dut.active_d && ^({dut.out_r,dut.out_g,dut.out_b}) === 1'bx))
            $fatal(1,"unknown output after power-up");
        count=count+1;
        if (dut.active) pixels=pixels+1;
        if (dut.x==800) begin
            if (count!=801) $fatal(1,"line has %0d clocks",count);
            count=0; lines=lines+1;
            if (dut.y==524) begin
                if (lines!=525 || pixels!=640*480)
                    $fatal(1,"invalid HDMI frame: lines=%0d pixels=%0d",lines,pixels);
                frames=frames+1;
                measuring=0;
            end
        end
    end
    initial begin
        repeat(6000) @(negedge dut.serial_clk);
        if (dut.cap_rst_n !== 1 || dut.vid_rst_n !== 1)
            $fatal(1,"PLL/reset never initialised");
        force dut.vid_lock=0;
        @(negedge dut.serial_clk);
        release dut.vid_lock;
        repeat(10) @(negedge dut.serial_clk);
        if (dut.cap_rst_n !== 1 || dut.vid_rst_n !== 1)
            $fatal(1,"single-cycle lock glitch reset HDMI");
        // Start immediately before x=0/y=0, after initial partial frame.
        wait(dut.x==800 && dut.y==524);
        @(posedge dut.pixel_clk);
        measuring=1;
        wait(frames==1);
        $display("RESULT PASS: reset, lock glitch, 801x525 timing, 640x480 active pixels");
        $finish;
    end
    initial begin
        #50000000;
        $fatal(1,"HDMI simulation timed out");
    end
endmodule
`default_nettype wire
