`default_nettype none

// Burst-locked subcarrier oscillator at 25.2 MSPS.
// Correlate each burst with sine/cosine weights, retain its measured vector
// for CORDIC, and reference this line's chroma to the complete 360-degree
// angle. The bounded PI loop follows frequency drift. Burst absence clears
// colour lock; SNAP_PER_LINE and non-sinusoidal weights are diagnostic modes.

module burst_nco #(
    parameter [31:0] INC_NOM = 32'h245D16F8,
    parameter integer KP_SHIFT = 19,
    parameter integer KI_SHIFT = 6,
    parameter integer LOCK_LINES = 32,
    parameter integer MAG_MIN    = 64,
    parameter         THREE_LEVEL = 1'b1,
    parameter         SINE_REF = 1'b1,
    parameter integer AVG_LOG2  = 2,
    parameter         SNAP_PER_LINE = 1'b0,
    parameter [31:0]  SNAP_PHASE    = 32'd0,
    parameter [31:0]  HUE_OFFSET    = 32'd0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_en,     // one cycle per ADC sample
    input  wire [7:0]  sample,
    input  wire [7:0]  blank_ref,     // back porch level, the burst's centre
    input  wire        burst_gate,    // high across the burst

    output reg  [31:0] phase,
    output reg  [31:0] inc,
    output reg  signed [15:0] burst_i,
    output reg  signed [15:0] burst_q,
    output reg         locked,
    output reg  [7:0]  good_lines,
    output wire [31:0] phase_ref
);
    wire [31:0] phase_c = phase + 32'h4000_0000;

    localparam [7:0] DEG60  = 8'd43;
    localparam [7:0] DEG120 = 8'd85;
    localparam [7:0] DEG240 = 8'd171;
    localparam [7:0] DEG300 = 8'd213;

    wire [31:0] phase_s = phase - 32'h4000_0000;
    // The three-level waveform is cosine-shaped. Shift it by -90 degrees
    // for sine; the sign-only waveform below is already sine-shaped.
    wire [7:0] pc = phase[31:24];
    wire [7:0] ps = phase_s[31:24];

    wire ci_pos = THREE_LEVEL ? ((pc < DEG60) || (pc >= DEG300)) : ~phase_c[31];
    wire ci_neg = THREE_LEVEL ? ((pc >= DEG120) && (pc < DEG240)) : phase_c[31];
    wire cq_pos = THREE_LEVEL ? ((ps < DEG60) || (ps >= DEG300)) : ~phase[31];
    wire cq_neg = THREE_LEVEL ? ((ps >= DEG120) && (ps < DEG240)) : phase[31];

    wire signed [8:0] centred = {1'b0, sample} - {1'b0, blank_ref};

    reg signed [23:0] i_acc, q_acc;
    wire signed [15:0] i_scaled = i_acc >>> 6;
    wire signed [15:0] q_scaled = q_acc >>> 6;
    wire signed [7:0] lut_cosine, lut_sine;
    reg signed [7:0] i_weight, q_weight;
    reg signed [17:0] i_product, q_product;
    reg product_pending;
    chroma_sincos reference_lut (.phase(phase[31:26]),
                                .cosine(lut_cosine), .sine(lut_sine));
    reg               gate_d;
    wire              gate_fall = gate_d && !burst_gate;

    wire signed [15:0] i_abs = i_scaled[15] ? -i_scaled : i_scaled;
    wire signed [15:0] q_abs = q_scaled[15] ? -q_scaled : q_scaled;
    wire [16:0]        mag   = {1'b0, i_abs} + {1'b0, q_abs};

    wire signed [15:0] err = -q_scaled;
    wire signed [31:0] err_ext = {{16{err[15]}}, err};

    reg signed [19:0] err_sum;
    reg [7:0]         avg_cnt;

    reg [31:0] burst_off;
    reg [31:0] sect_r;
    reg        sect_new;
    reg [31:0] correlation_adjust;
    reg [14:0] burst_age;

    wire [31:0] cordic_angle;
    wire        cordic_done;
    reg         cordic_start;

    cordic_atan u_atan (
        .clk(clk), .rst_n(rst_n), .start(cordic_start),
        // cordic_start is registered. The accumulators have already been
        // cleared when CORDIC consumes it, so use the latched measurement.
        .x_in({{2{burst_i[15]}}, burst_i}), .y_in({{2{burst_q[15]}}, burst_q}),
        .angle(cordic_angle), .done(cordic_done)
    );
    assign phase_ref = phase - burst_off + HUE_OFFSET;

    wire signed [19:0] sum_now  = err_sum + {{4{err[15]}}, err};
    wire signed [31:0] sum_ext  = {{12{sum_now[19]}}, sum_now};
    // A negative shift count is not a right shift in Verilog.
    wire signed [31:0] phase_adj = (KP_SHIFT >= AVG_LOG2)
                                ? (sum_ext <<< (KP_SHIFT - AVG_LOG2))
                                : (sum_ext >>> (AVG_LOG2 - KP_SHIFT));
    wire signed [31:0] freq_adj  = sum_ext >>> (KI_SHIFT + AVG_LOG2);
    localparam [31:0] INC_RANGE = INC_NOM / 1000; // +/-1000 ppm, no wind-up
    wire signed [32:0] inc_next = $signed({1'b0, inc}) +
                                  $signed({freq_adj[31], freq_adj});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase      <= 32'd0;
            inc        <= INC_NOM;
            i_acc      <= 16'sd0;
            q_acc      <= 16'sd0;
            i_weight <= 0; q_weight <= 0;
            i_product <= 0; q_product <= 0; product_pending <= 0;
            burst_i    <= 16'sd0;
            burst_q    <= 16'sd0;
            gate_d     <= 1'b0;
            good_lines <= 8'd0;
            err_sum    <= 20'sd0;
            avg_cnt    <= 8'd0;
            burst_off  <= 32'd0;
            sect_r     <= 32'd0;
            sect_new   <= 1'b0;
            correlation_adjust <= 32'd0;
            burst_age  <= 15'd0;
            cordic_start <= 1'b0;
            locked     <= 1'b0;
        end else begin
            i_weight <= SINE_REF ? lut_cosine : (ci_pos ? 8'sd64 : ci_neg ? -8'sd64 : 8'sd0);
            q_weight <= SINE_REF ? lut_sine : (cq_pos ? 8'sd64 : cq_neg ? -8'sd64 : 8'sd0);
            product_pending <= sample_en && burst_gate;
            if (sample_en && burst_gate) begin
                i_product <= centred * i_weight;
                q_product <= centred * q_weight;
            end
            if (product_pending) begin
                i_acc <= i_acc + {{6{i_product[17]}}, i_product};
                q_acc <= q_acc + {{6{q_product[17]}}, q_product};
            end
            if (cordic_start) cordic_start <= 1'b0;
            if (cordic_done) begin
                sect_r   <= cordic_angle;
                sect_new <= 1'b1;
            end else if (sect_new) begin
                sect_new  <= 1'b0;
                // Burst and active chroma share the same phase. Folding this
                // angle modulo 180 degrees reverses both colour components.
                // Include any PLL step made after measuring the correlation.
                burst_off <= sect_r + correlation_adjust;
            end

            if (sample_en) begin
            phase  <= phase + inc;
            gate_d <= burst_gate;
            if (burst_age != 15'h7fff) burst_age <= burst_age + 15'd1;
            else begin
                locked <= 1'b0;
                good_lines <= 8'd0;
                err_sum <= 20'sd0;
                avg_cnt <= 8'd0;
                inc <= INC_NOM;
            end

            if (gate_fall) begin
                burst_i <= i_scaled;
                burst_q <= q_scaled;
                i_acc   <= 16'sd0;
                q_acc   <= 16'sd0;

                if (mag >= MAG_MIN) begin
                    burst_age <= 15'd0;
                    cordic_start <= 1'b1;
                    correlation_adjust <= SNAP_PER_LINE ? (SNAP_PHASE - phase - inc)
                        : ((avg_cnt == ((1 << AVG_LOG2) - 1)) ? phase_adj : 32'd0);
                    if (avg_cnt == ((1 << AVG_LOG2) - 1)) begin
                        avg_cnt <= 8'd0;
                        err_sum <= 20'sd0;
                        phase   <= SNAP_PER_LINE ? SNAP_PHASE
                                                 : (phase + inc + phase_adj);
                        inc <= (inc_next > $signed({1'b0, INC_NOM + INC_RANGE}))
                             ? INC_NOM + INC_RANGE
                             : ((inc_next < $signed({1'b0, INC_NOM - INC_RANGE}))
                                ? INC_NOM - INC_RANGE : inc_next[31:0]);
                    end else begin
                        avg_cnt <= avg_cnt + 8'd1;
                        err_sum <= sum_now;
                        if (SNAP_PER_LINE) phase <= SNAP_PHASE;
                    end
                    if (good_lines != 8'hFF) good_lines <= good_lines + 8'd1;
                end else if (good_lines != 8'd0) begin
                    good_lines <= good_lines - 8'd1;
                end

                locked <= (good_lines >= LOCK_LINES);
            end
            end
        end
    end
endmodule

`default_nettype wire
