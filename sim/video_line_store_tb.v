`default_nettype none
`timescale 1ns/1ps
module video_line_store_tb;
    reg wr_clk=0, rd_clk=0, rst_n=0;
    always #4 wr_clk=~wr_clk;
    always #20.1 rd_clk=~rd_clk;
    reg wr_en=0, wr_done=0;
    reg [9:0] wr_x=0;
    reg [23:0] wr_data=0;
    reg [9:0] x=0;
    wire [23:0] pixel;
    wire valid;
    integer line_no, col, checks=0;
    reg [7:0] row_id;
    reg [9:0] x_d=0;
    video_line_store dut (
        .wr_clk(wr_clk), .wr_reset_n(rst_n), .wr_en(wr_en), .wr_x(wr_x),
        .wr_data(wr_data), .wr_done(wr_done),
        .rd_clk(rd_clk), .rd_reset_n(rst_n), .rd_line_end(x==800),
        .rd_x(x), .rd_data(pixel), .rd_valid(valid)
    );
    always @(posedge rd_clk) if (rst_n) begin
        x <= x==800 ? 0 : x+1;
        x_d <= x;
    end
    always @(negedge rd_clk) if (valid && x_d<640) begin
        if (x_d==0) row_id=pixel[23:16];
        if (^pixel === 1'bx || pixel[23:16] != row_id || pixel[9:0] != x_d)
            $fatal(1,"torn line x=%0d pixel=%h row=%0d",x_d,pixel,row_id);
        checks=checks+1;
    end
    initial begin
        repeat(8) @(negedge wr_clk);
        rst_n=1;
        // Vary producer phase so publication and reader handoff cross.
        for (line_no=1;line_no<=80;line_no=line_no+1) begin
            repeat (1350 + line_no%13) @(negedge wr_clk);
            for(col=0;col<640;col=col+1) begin
                wr_en=1; wr_x=col; wr_data={line_no[7:0],6'd0,col[9:0]};
                wr_done=col==639;
                @(negedge wr_clk);
                wr_en=0; wr_done=0;
                repeat(9) @(negedge wr_clk);
            end
        end
        repeat(2000) @(negedge wr_clk);
        if(checks<50000) $fatal(1,"reader did not run");
        $display("RESULT PASS: %0d pixels, no uninitialised/overwritten/torn lines",checks);
        $finish;
    end
endmodule
`default_nettype wire
