`default_nettype none

// Latest complete line, with independent capture and display clocks.
// Four banks allow a writer, the published line, the reader, and one spare.
// A two-bank ping-pong alone can overwrite a line while HDMI still reads it.
module video_line_store (
    input wire wr_clk,
    input wire wr_reset_n,
    input wire wr_en,
    input wire [9:0] wr_x,
    input wire [23:0] wr_data,
    input wire wr_done,
    input wire rd_clk,
    input wire rd_reset_n,
    input wire rd_line_end,
    input wire [9:0] rd_x,
    output reg [23:0] rd_data,
    output reg rd_valid
);
    (* ram_style = "block" *) reg [23:0] mem [0:4095];
    reg [1:0] write_bank, published_bank, read_bank, latest_bank;
    reg publish_toggle, have_line;
    (* async_reg = "true" *) reg [1:0] reader_meta, reader_sync;
    (* async_reg = "true" *) reg [1:0] pub_meta, pub_sync;
    (* async_reg = "true" *) reg [2:0] publish_sync;

    function [1:0] spare_bank;
        input [1:0] writing, published, reading;
        begin
            if (writing != 0 && published != 0 && reading != 0) spare_bank = 0;
            else if (writing != 1 && published != 1 && reading != 1) spare_bank = 1;
            else if (writing != 2 && published != 2 && reading != 2) spare_bank = 2;
            else spare_bank = 3;
        end
    endfunction

    always @(posedge wr_clk) begin
        if (wr_en) mem[{write_bank, wr_x}] <= wr_data;
    end
    always @(posedge rd_clk) rd_data <= mem[{read_bank, rd_x}];

    always @(posedge wr_clk or negedge wr_reset_n) begin
        if (!wr_reset_n) begin
            write_bank <= 0; published_bank <= 1; publish_toggle <= 0;
            reader_meta <= 2; reader_sync <= 2;
        end else begin
            reader_meta <= read_bank;
            reader_sync <= reader_meta;
            if (wr_done) begin
                published_bank <= write_bank;
                publish_toggle <= ~publish_toggle;
                // Keep the previous publication safe too: the display may
                // have selected it just before seeing this new publication.
                write_bank <= spare_bank(write_bank, published_bank, reader_sync);
            end
        end
    end
    always @(posedge rd_clk or negedge rd_reset_n) begin
        if (!rd_reset_n) begin
            pub_meta <= 1; pub_sync <= 1; publish_sync <= 0;
            latest_bank <= 1; read_bank <= 2; have_line <= 0; rd_valid <= 0;
        end else begin
            pub_meta <= published_bank;
            pub_sync <= pub_meta;
            publish_sync <= {publish_sync[1:0], publish_toggle};
            // The held two-bit payload has settled before its toggle arrives.
            if (publish_sync[2] ^ publish_sync[1]) begin
                latest_bank <= pub_sync;
                have_line <= 1;
            end
            if (rd_line_end) begin
                read_bank <= latest_bank;
                rd_valid <= have_line;
            end
        end
    end
endmodule
`default_nettype wire
