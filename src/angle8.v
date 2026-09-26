`default_nettype none

// Poll an M5Stack Unit 8Angle -- eight potentiometers and a switch behind an
// STM32F030 at I2C address 0x43 -- over the Grove port, for ever.
//
// The unit's firmware (m5stack/M5Unit-8Angle-Internal-FW) answers one register
// per transaction: a write of the register number, then a read returns that
// channel alone -- 0x10 + n is channel n in eight bits, 0x20 the switch.  There
// is no auto-increment, so a scan is nine write/read pairs.  Its I2C runs at
// 100 kHz timing and stretches SCL while it prepares a reply, so the master
// waits for SCL to rise every time it releases it.  Both lines are open drain:
// the outputs here only ever pull low.
//
// A scan takes about 4 ms.  A value is replaced only by a fully acknowledged
// read; present says the last whole scan was acknowledged throughout.
module angle8 #(
    parameter [6:0]  ADDR    = 7'h43,
    parameter integer CLK_HZ = 25_200_000,
    parameter integer I2C_HZ = 100_000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scl_in,
    input  wire        sda_in,
    output reg         scl_low,     // 1 pulls SCL low; 0 releases it
    output reg         sda_low,
    output reg  [63:0] knobs,       // channel n in [8n+7:8n]
    output reg         sw,          // the switch register as read: its pin level
    output reg         present,
    output reg  [7:0]  scans        // completed scans, for liveness
);
    // Quarter of an I2C bit: 63 clocks at 25.2 MHz for 100 kHz.
    localparam integer QUARTER  = CLK_HZ / (4 * I2C_HZ);
    localparam integer QW       = 8;
    // A slave may stretch SCL; one holding it longer than this is stuck.
    localparam integer STRETCH_MAX = CLK_HZ / 1000;          // 1 ms
    localparam integer GAP_Q    = 8;                          // bit times idle, 80 us

    // Operations of one poll: address+write, register, stop, gap, then
    // address+read, one byte, stop, gap.
    localparam [2:0] OP_START = 3'd0, OP_WBYTE = 3'd1, OP_RBYTE = 3'd2,
                     OP_STOP  = 3'd3, OP_GAP   = 3'd4;

    reg [1:0] scl_s, sda_s;
    always @(posedge clk) begin
        scl_s <= {scl_s[0], scl_in};
        sda_s <= {sda_s[0], sda_in};
    end
    wire scl_hi = scl_s[1];
    wire sda_hi = sda_s[1];

    reg [3:0]  item;        // 0..7 channels, 8 the switch
    reg [3:0]  step;        // position in the poll program
    reg [1:0]  quarter;
    reg [QW-1:0] qcnt;
    reg [3:0]  bitn;        // 0..8 within a byte; 8 is the ACK slot
    reg [7:0]  tx;
    reg [8:0]  rx;
    reg [19:0] stretch;
    reg        err;         // this poll failed
    reg        scan_err;    // some poll of this scan failed

    wire [7:0] reg_no = (item == 4'd8) ? 8'h20 : {4'h1, item};

    reg [2:0] op;
    always @(*) begin
        case (step)
            4'd0: op = OP_START;  4'd1: op = OP_WBYTE;  4'd2: op = OP_WBYTE;
            4'd3: op = OP_STOP;   4'd4: op = OP_GAP;    4'd5: op = OP_START;
            4'd6: op = OP_WBYTE;  4'd7: op = OP_RBYTE;  4'd8: op = OP_STOP;
            default: op = OP_GAP;
        endcase
    end
    // What to send in a byte step.
    always @(*) begin
        case (step)
            4'd1:    tx = {ADDR, 1'b0};
            4'd2:    tx = reg_no;
            4'd6:    tx = {ADDR, 1'b1};
            default: tx = 8'hFF;       // reading: release SDA
        endcase
    end

    // The quarter clock pauses while SCL is released and still low: that is
    // the slave stretching it.
    wire want_scl_high = !scl_low;
    wire stretching    = want_scl_high && !scl_hi;
    wire qdone         = (qcnt == QUARTER - 1) && !stretching;
    wire last_quarter  = qdone && (quarter == 2'd3);
    // The last step of a poll, and whether this byte's slot is its last.
    wire byte_end      = (bitn == 4'd8);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_low <= 1'b0; sda_low <= 1'b0;
            knobs <= 64'd0; sw <= 1'b0; present <= 1'b0; scans <= 8'd0;
            item <= 4'd0; step <= 4'd0; quarter <= 2'd0; qcnt <= 0;
            bitn <= 4'd0; rx <= 9'd0; stretch <= 20'd0;
            err <= 1'b0; scan_err <= 1'b0;
        end else begin
            if (stretching) begin
                stretch <= stretch + 20'd1;
            end else begin
                stretch <= 20'd0;
                qcnt <= (qcnt == QUARTER - 1) ? {QW{1'b0}} : qcnt + 1'b1;
            end

            // A line held low too long: give the bus back and fail this poll.
            if (stretch == STRETCH_MAX[19:0]) begin
                scl_low <= 1'b0; sda_low <= 1'b0;
                err <= 1'b1; quarter <= 2'd0; qcnt <= 0; bitn <= 4'd0;
                step <= 4'd4;
            end else if (qdone) begin
                quarter <= quarter + 2'd1;
                case (op)
                    OP_START: case (quarter)
                        2'd0: begin sda_low <= 1'b0; scl_low <= 1'b0; end
                        2'd1: sda_low <= 1'b1;          // SDA falls, SCL high
                        2'd2: ;
                        2'd3: scl_low <= 1'b1;
                    endcase
                    OP_WBYTE, OP_RBYTE: case (quarter)
                        2'd0: sda_low <= (bitn == 4'd8) ? 1'b0 : !tx[3'd7 - bitn[2:0]];
                        2'd1: scl_low <= 1'b0;
                        2'd2: rx <= {rx[7:0], sda_hi};
                        2'd3: scl_low <= 1'b1;
                    endcase
                    OP_STOP: case (quarter)
                        2'd0: sda_low <= 1'b1;
                        2'd1: scl_low <= 1'b0;
                        2'd2: sda_low <= 1'b0;          // SDA rises, SCL high
                        2'd3: ;
                    endcase
                    default: begin scl_low <= 1'b0; sda_low <= 1'b0; end
                endcase

                if (quarter == 2'd3) begin
                    case (op)
                        OP_WBYTE, OP_RBYTE: begin
                            if (!byte_end) begin
                                bitn <= bitn + 4'd1;
                            end else begin
                                bitn <= 4'd0;
                                // rx[0] is the ACK slot: low is an ACK.
                                if (op == OP_WBYTE && rx[0]) begin
                                    err  <= 1'b1;
                                    step <= (step < 4'd3) ? 4'd3 : 4'd8;   // stop now
                                end else begin
                                    if (op == OP_RBYTE && !err) begin
                                        if (item == 4'd8) sw <= rx[1];
                                        else knobs[{item[2:0], 3'd0} +: 8] <= rx[8:1];
                                    end
                                    step <= step + 4'd1;
                                end
                            end
                        end
                        OP_GAP: begin
                            if (bitn == GAP_Q[3:0] - 4'd1) begin
                                bitn <= 4'd0;
                                if (step == 4'd4 && !err) begin
                                    step <= 4'd5;
                                end else begin
                                    // End of a poll, failed or not.
                                    step <= 4'd0;
                                    err  <= 1'b0;
                                    if (item == 4'd8) begin
                                        item     <= 4'd0;
                                        present  <= !(scan_err || err);
                                        scan_err <= 1'b0;
                                        scans    <= scans + 8'd1;
                                    end else begin
                                        item     <= item + 4'd1;
                                        scan_err <= scan_err || err;
                                    end
                                end
                            end else begin
                                bitn <= bitn + 4'd1;
                            end
                        end
                        default: step <= step + 4'd1;
                    endcase
                end
            end
        end
    end
endmodule

`default_nettype wire
