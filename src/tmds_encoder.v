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
    // Counts are unsigned and signs are read from sign bits: no signed
    // comparison anywhere (apicula#541 miscompiles those on the GW2A
    // depending only on placement).
    integer i;
    reg [3:0] ones_data;
    reg [3:0] ones_qm;
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
            ones_data = 4'd0;
            for (i = 0; i < 8; i = i + 1)
                ones_data = ones_data + {3'd0, video_data[i]};

            q_m[0] = video_data[0];
            if ((ones_data > 4'd4) || ((ones_data == 4'd4) && !video_data[0])) begin
                for (i = 1; i < 8; i = i + 1)
                    q_m[i] = ~(q_m[i-1] ^ video_data[i]);
                q_m[8] = 1'b0;
            end else begin
                for (i = 1; i < 8; i = i + 1)
                    q_m[i] = q_m[i-1] ^ video_data[i];
                q_m[8] = 1'b1;
            end

            ones_qm = 4'd0;
            for (i = 0; i < 8; i = i + 1)
                ones_qm = ones_qm + {3'd0, q_m[i]};
            balance = ({28'd0, ones_qm} * 2) - 8;

            if ((disparity == 0) || (balance == 0)) begin
                tmds_word[9]   <= ~q_m[8];
                tmds_word[8]   <= q_m[8];
                tmds_word[7:0] <= q_m[8] ? q_m[7:0] : ~q_m[7:0];
                disparity <= disparity + (q_m[8] ? balance : -balance);
            end else if ((!disparity[5] && (ones_qm > 4'd4)) ||
                         ( disparity[5] && (ones_qm < 4'd4))) begin
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

