`default_nettype none

// Minimal 8N1 UART transmitter.  `busy` is asserted combinationally while a
// byte is in flight (and on the accepting cycle itself), so a producer can
// gate on `!busy` without an extra handshake cycle.
module uart_tx #(
    parameter integer CLKS_PER_BIT = 937   // 108 MHz / 115200 = 937.5
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       stb,
    output reg        tx,
    output wire       busy
);
    localparam [1:0] IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;

    reg [1:0]  state;
    reg [15:0] tick;
    reg [2:0]  bit_idx;
    reg [7:0]  shifter;

    assign busy = (state != IDLE) || stb;

    wire tick_done = (tick == CLKS_PER_BIT - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= IDLE;
            tick    <= 16'd0;
            bit_idx <= 3'd0;
            shifter <= 8'd0;
            tx      <= 1'b1;
        end else begin
            case (state)
                IDLE: begin
                    tx   <= 1'b1;
                    tick <= 16'd0;
                    if (stb) begin
                        shifter <= data;
                        state   <= START;
                    end
                end
                START: begin
                    tx <= 1'b0;
                    if (tick_done) begin
                        tick    <= 16'd0;
                        bit_idx <= 3'd0;
                        state   <= DATA;
                    end else begin
                        tick <= tick + 1'b1;
                    end
                end
                DATA: begin
                    tx <= shifter[0];
                    if (tick_done) begin
                        tick    <= 16'd0;
                        shifter <= {1'b0, shifter[7:1]};
                        bit_idx <= bit_idx + 1'b1;
                        if (bit_idx == 3'd7) state <= STOP;
                    end else begin
                        tick <= tick + 1'b1;
                    end
                end
                STOP: begin
                    tx <= 1'b1;
                    if (tick_done) begin
                        tick  <= 16'd0;
                        state <= IDLE;
                    end else begin
                        tick <= tick + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule

`default_nettype wire
