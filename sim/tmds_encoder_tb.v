`default_nettype none
`timescale 1ns/1ps
module tmds_encoder_tb;
    reg clk=0, rst_n=0, en=0;
    always #5 clk=~clk;
    reg [7:0] data=0;
    reg [1:0] control=0;
    wire [9:0] word;
    tmds_encoder dut (.pixel_clk(clk),.reset_n(rst_n),.data_enable(en),
                      .control(control),.video_data(data),.tmds_word(word));
    integer n,k,ones,disparity=0;
    reg [7:0] qm, decoded;
    reg [9:0] expected_control;
    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        for(n=0;n<4096;n=n+1) begin
            en=(n%257)!=0;
            data=(n*73+n/256)%256;
            control=n/257;
            @(negedge clk);
            if (^word === 1'bx) $fatal(1,"unknown TMDS word");
            if(en) begin
                qm=word[9] ? ~word[7:0] : word[7:0];
                decoded[0]=qm[0];
                for(k=1;k<8;k=k+1)
                    decoded[k]=word[8] ? (qm[k]^qm[k-1]) : ~(qm[k]^qm[k-1]);
                if(decoded!==data) $fatal(1,"TMDS round trip %h != %h",decoded,data);
                ones=0;
                for(k=0;k<10;k=k+1) ones=ones+word[k];
                disparity=disparity+2*ones-10;
                if(disparity!=$signed(dut.disparity) || disparity>8 || disparity< -8)
                    $fatal(1,"TMDS disparity is wrong: %0d",disparity);
            end else begin
                case(control)
                    0: expected_control=10'b1101010100;
                    1: expected_control=10'b0010101011;
                    2: expected_control=10'b0101010100;
                    3: expected_control=10'b1010101011;
                endcase
                if(word!==expected_control) $fatal(1,"wrong TMDS control word");
                disparity=0;
            end
        end
        $display("RESULT PASS: 4096 TMDS symbols, all controls and running disparity");
        $finish;
    end
endmodule
`default_nettype wire
