`default_nettype none

// DVI/HDMI TMDS encoder for one 8-bit colour channel.
module tmds_encoder (
    input  wire       pixel_clk,
    input  wire       reset_n,
    input  wire       data_enable,
    input  wire [1:0] control,
    input  wire [7:0] video_data,
    output reg  [9:0] tmds_word
);
    integer i;
    integer ones_data;
    integer ones_qm;
    integer balance;
    reg [8:0] q_m;
    reg signed [5:0] disparity;

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            tmds_word <= 10'b1101010100;
            disparity <= 0;
        end else if (!data_enable) begin
            disparity <= 0;
            case (control)
                2'b00: tmds_word <= 10'b1101010100;
                2'b01: tmds_word <= 10'b0010101011;
                2'b10: tmds_word <= 10'b0101010100;
                2'b11: tmds_word <= 10'b1010101011;
            endcase
        end else begin
            ones_data = 0;
            for (i = 0; i < 8; i = i + 1)
                ones_data = ones_data + video_data[i];

            q_m[0] = video_data[0];
            if ((ones_data > 4) || ((ones_data == 4) && !video_data[0])) begin
                for (i = 1; i < 8; i = i + 1)
                    q_m[i] = ~(q_m[i-1] ^ video_data[i]);
                q_m[8] = 1'b0;
            end else begin
                for (i = 1; i < 8; i = i + 1)
                    q_m[i] = q_m[i-1] ^ video_data[i];
                q_m[8] = 1'b1;
            end

            ones_qm = 0;
            for (i = 0; i < 8; i = i + 1)
                ones_qm = ones_qm + q_m[i];
            balance = (ones_qm * 2) - 8;

            if ((disparity == 0) || (balance == 0)) begin
                tmds_word[9]   <= ~q_m[8];
                tmds_word[8]   <= q_m[8];
                tmds_word[7:0] <= q_m[8] ? q_m[7:0] : ~q_m[7:0];
                disparity <= disparity + (q_m[8] ? balance : -balance);
            end else if (((disparity > 0) && (balance > 0)) ||
                         ((disparity < 0) && (balance < 0))) begin
                tmds_word <= {1'b1, q_m[8], ~q_m[7:0]};
                disparity <= disparity + (q_m[8] ? (2 - balance) : -balance);
            end else begin
                tmds_word <= {1'b0, q_m[8], q_m[7:0]};
                disparity <= disparity + (q_m[8] ? balance : (balance - 2));
            end
        end
    end
endmodule

`default_nettype wire

