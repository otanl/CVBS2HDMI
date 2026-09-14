`default_nettype none

// Two-bank dual-clock line buffer.  The capture side fills one bank while the
// display side reads the other; the bank index is the address MSB so a single
// block RAM holds both.  Gowin infers BSRAM from this coding style.  The read
// port has one clock of latency.
module line_buffer #(
    parameter ADDR_WIDTH = 11,        // 1 bank bit + 10 address bits
    parameter DATA_WIDTH = 8
) (
    input  wire                  wr_clk,
    input  wire                  wr_en,
    input  wire [ADDR_WIDTH-1:0] wr_addr,
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire                  rd_clk,
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output reg  [DATA_WIDTH-1:0] rd_data
);
    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] mem [0:(1 << ADDR_WIDTH)-1];

    always @(posedge wr_clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
    end

    always @(posedge rd_clk) begin
        rd_data <= mem[rd_addr];
    end
endmodule

`default_nettype wire
