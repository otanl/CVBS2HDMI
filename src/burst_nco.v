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
    // Burst-angle tracking: blend each line's measurement into a prediction
    // instead of taking it raw.  TRACK_P is how much of the error to apply to
    // the angle, TRACK_I how much to the learned per-line step, both as right
    // shifts -- so larger means slower and quieter.
    parameter         BURST_TRACK = 1'b1,
    // 2, chosen against how many picture rows come out correct -- not against
    // the streaking figure that first suggested 4.
    //
    // That first sweep used the median row-to-row colour difference, which
    // measures chroma noise and nothing else.  Being a median it is robust to
    // outliers by construction, so rows that are dropped or torn do not move
    // it: it rated 4 (1.7 codes) over 2 (1.8) while the picture at 4 was
    // visibly worse.  Counting rows instead, over ten thousand of them:
    //
    //           correct   dropped   wrong order
    //   off      95.2%      3.0%        1.8%
    //   P=2      97.0%      2.8%        0.2%
    //   P=4      94.5%      3.6%        1.9%
    //
    // Tracking helps, and only at the right weight.  A tenfold difference in
    // torn rows between 2 and 4 was entirely invisible to the first metric.
    parameter integer TRACK_P     = 2,
    parameter integer TRACK_I     = 5,
    parameter         THREE_LEVEL = 1'b1,
    parameter         SINE_REF = 1'b1,
    parameter integer AVG_LOG2  = 2,
    parameter         SNAP_PER_LINE = 1'b0,
    parameter [31:0]  SNAP_PHASE    = 32'd0,
    parameter [31:0]  HUE_OFFSET    = 32'd0,
    // A burst gap longer than this invalidates the per-line step prediction.
    // 8010 samples is five lines at 25.2 MHz: long enough to ride out an
    // occasional line whose burst falls under MAG_MIN -- the M5 source runs
    // about 19 codes against a spec 40 -- and short enough to fire inside the
    // ~20-line vertical interval, which is the gap that actually matters.
    parameter integer TRACK_GAP_SAMPLES = 8010
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_en,     // one cycle per ADC sample
    input  wire [7:0]  sample,
    input  wire [7:0]  blank_ref,     // back porch level, the burst's centre
    input  wire        burst_gate,    // high across the burst
    input  wire        gate_restart,  // discard what the gate has gathered

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
    reg signed [8:0] sample_centred;
    reg signed [7:0] sample_i_weight, sample_q_weight;
    reg signed [17:0] i_product, q_product;
    reg input_pending, product_pending;
    chroma_sincos reference_lut (.phase(phase[31:26]),
                                .cosine(lut_cosine), .sine(lut_sine));
    reg               gate_d;
    wire              gate_fall = gate_d && !burst_gate;
    // The gate's fall is acted on three clocks after it is seen, whatever the
    // sample rate.  The last gated sample's product takes two clocks to reach
    // the accumulators and a third to reach sum_r/mag_r; with five clocks per
    // sample that had always happened by the next strobe, and at one sample
    // per clock it has not.  Acting on a clock count rather than on a strobe
    // makes both correct.
    reg  [2:0]        fall_d;
    wire              proc = fall_d[2];
    wire [31:0]       step_now = sample_en ? inc : 32'd0;

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
    reg [31:0] burst_step;      // angle advance per line, learned
    reg        have_step, have_prev;
    reg        gap_resync;
    // Registered a clock before it is used.  The chain -- add the correlation
    // adjust, subtract the prediction, shift twice, add twice -- does not fit
    // in one cycle at 126 MHz: it came in at 125.87 against the 125.94 needed.
    // There is a whole line before the answer matters, so the split is free.
    reg  [31:0] track_meas;
    reg         track_valid;
    wire [31:0] track_pred = burst_off + burst_step;
    wire signed [31:0] track_err = $signed(track_meas - track_pred);
    // Evaluate the shifts in a signed context and only then add them to the
    // unsigned accumulators.  Inline, `track_pred + (track_err >>> TRACK_P)`
    // is an unsigned expression -- track_pred is unsigned -- so the arithmetic
    // right shift silently becomes a logical one and a negative error arrives
    // as a number near 2^32.  Third time in this design; see also the loop
    // filter's freq_adj and the note on vs_seen.
    wire signed [31:0] track_p_adj = track_err >>> TRACK_P;
    wire signed [31:0] track_i_adj = track_err >>> TRACK_I;
    reg [17:0] burst_age;

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
    // Registered every clock.  The last burst product lands three clocks after
    // the last gated sample and the gate's fall is noticed two clocks later,
    // so both hold the final correlation by then -- and taking them from a
    // register keeps the correlation's carry chains out of the loop update,
    // which with the NCO clamp behind them ran at 100 MHz against 126.
    reg signed [19:0] sum_r;
    reg        [16:0] mag_r;
    wire signed [31:0] sum_ext  = {{12{sum_r[19]}}, sum_r};
    // A negative shift count is not a right shift in Verilog.
    wire signed [31:0] phase_adj = (KP_SHIFT >= AVG_LOG2)
                                ? (sum_ext <<< (KP_SHIFT - AVG_LOG2))
                                : (sum_ext >>> (AVG_LOG2 - KP_SHIFT));
    wire signed [31:0] freq_adj  = sum_ext >>> (KI_SHIFT + AVG_LOG2);
    localparam [31:0] INC_RANGE = INC_NOM / 1000; // +/-1000 ppm, no wind-up
    wire signed [32:0] inc_next = $signed({1'b0, inc}) +
                                  $signed({freq_adj[31], freq_adj});
    // The increment is clamped a clock after the loop update, from a register.
    // The next sample strobe is still three clocks away, so it is the first to
    // use the new increment, exactly as before.
    reg signed [32:0] inc_next_r;
    reg               inc_pend;
    // The clamp without a signed comparison.  Apicula miscompiles those on this
    // part depending only on placement (YosysHQ/apicula#541): the same RTL
    // decoded the M5 recording with stable hue in simulation and scrambled the
    // hue line to line on the board.  Both bounds are positive constants, so
    // the sign bit picks the answer for a negative value and an unsigned
    // compare against a constant -- the same carry chain -- settles the rest.
    wire inc_over  = !inc_next_r[32] && (inc_next_r[31:0] > INC_NOM + INC_RANGE);
    wire inc_under =  inc_next_r[32] || (inc_next_r[31:0] < INC_NOM - INC_RANGE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase      <= 32'd0;
            inc        <= INC_NOM;
            i_acc      <= 16'sd0;
            q_acc      <= 16'sd0;
            i_weight <= 0; q_weight <= 0;
            sample_centred <= 0; sample_i_weight <= 0; sample_q_weight <= 0;
            input_pending <= 0;
            i_product <= 0; q_product <= 0; product_pending <= 0;
            burst_i    <= 16'sd0;
            burst_q    <= 16'sd0;
            gate_d     <= 1'b0;
            fall_d     <= 3'd0;
            good_lines <= 8'd0;
            err_sum    <= 20'sd0;
            avg_cnt    <= 8'd0;
            burst_off  <= 32'd0;
            sect_r     <= 32'd0;
            sect_new   <= 1'b0;
            correlation_adjust <= 32'd0;
            track_meas <= 32'd0; track_valid <= 1'b0;
            burst_step <= 32'd0;
            have_step  <= 1'b0;
            have_prev  <= 1'b0;
            burst_age  <= 18'd0;
            gap_resync <= 1'b0;
            cordic_start <= 1'b0;
            locked     <= 1'b0;
            sum_r <= 20'sd0; mag_r <= 17'd0;
            inc_next_r <= 33'sd0; inc_pend <= 1'b0;
        end else begin
            i_weight <= SINE_REF ? lut_cosine : (ci_pos ? 8'sd64 : ci_neg ? -8'sd64 : 8'sd0);
            q_weight <= SINE_REF ? lut_sine : (cq_pos ? 8'sd64 : cq_neg ? -8'sd64 : 8'sd0);
            // Subtraction plus a LUT multiplier missed 126 MHz (118.4 MHz
            // routed). There are five clocks per sample, so separate them.
            // Latch BOTH operands on the original strobe: continuously
            // registering centred alone would select a different ADC phase.
            // A restart also drops whatever is still in the pipeline, and the
            // sample taken with it: all of it was gated on the old timing.
            input_pending <= sample_en && burst_gate && !gate_restart;
            product_pending <= input_pending && !gate_restart;
            if (sample_en && burst_gate) begin
                sample_centred <= centred;
                sample_i_weight <= i_weight;
                sample_q_weight <= q_weight;
            end
            if (input_pending) begin
                i_product <= sample_centred * sample_i_weight;
                q_product <= sample_centred * sample_q_weight;
            end
            if (gate_restart) begin
                i_acc <= 24'sd0;
                q_acc <= 24'sd0;
            end else if (product_pending) begin
                i_acc <= i_acc + {{6{i_product[17]}}, i_product};
                q_acc <= q_acc + {{6{q_product[17]}}, q_product};
            end
            if (cordic_start) cordic_start <= 1'b0;
            sum_r      <= sum_now;
            mag_r      <= mag;
            inc_next_r <= inc_next;
            if (inc_pend) begin
                inc_pend <= 1'b0;
                inc <= inc_over  ? INC_NOM + INC_RANGE
                     : inc_under ? INC_NOM - INC_RANGE : inc_next_r[31:0];
            end
            if (cordic_done) begin
                sect_r   <= cordic_angle;
                sect_new <= 1'b1;
            end else if (sect_new) begin
                sect_new   <= 1'b0;
                // Stage one: settle the measurement.  Burst and active chroma
                // share the same phase, and any PLL step made after the
                // correlation has to be folded in here.
                track_meas  <= sect_r + correlation_adjust;
                track_valid <= 1'b1;
            end else if (track_valid) begin
                track_valid <= 1'b0;
                // Stage two: track the burst angle rather than believing each
                // line's measurement outright.
                //
                // The angle is not random from line to line -- it advances by a
                // nearly constant step, because the source's subcarrier and
                // line rate are in a fixed ratio.  124.8 degrees per line on
                // this one, where a source honouring fsc = 227.5 fh would step
                // 180.  So predict from the last angle plus the learned step
                // and blend the measurement in, rather than replacing with it:
                // noise falls and the systematic rotation is still followed.
                //
                // The subtraction is modular, so track_err is the shortest way
                // round between predicted and measured with no wrapping logic.
                // That is the one place 32-bit phase arithmetic is a gift.
                //
                // Split across two clocks because the whole chain -- add the
                // adjust, subtract the prediction, shift twice, add twice --
                // came in at 125.87 MHz against the 125.94 required.  There is
                // a line's worth of clocks spare before the answer matters.
                if (gap_resync) begin
                    burst_off  <= track_meas;   // phase only; step survives
                    gap_resync <= 1'b0;
                end else if (BURST_TRACK && have_step) begin
                    burst_off  <= track_pred + track_p_adj;
                    burst_step <= burst_step + track_i_adj;
                end else if (have_prev) begin
                    // The step is the difference between two consecutive
                    // angles, so it needs two of them.  Seeding it from one
                    // makes the step the angle itself, and the loop then has to
                    // unwind a whole turn of wrong prediction.
                    burst_off  <= track_meas;
                    burst_step <= track_meas - burst_off;
                    have_step  <= 1'b1;
                end else begin
                    burst_off <= track_meas;
                    have_prev <= 1'b1;
                end
            end

            if (sample_en) begin
            phase  <= phase + inc;
            gate_d <= burst_gate;
            // 2^18 samples, about 164 lines.  15 bits -- 32767 samples, or 20.5
            // lines -- sat just under the vertical interval, which carries no
            // burst at all, so this timed out once per field, every field,
            // throwing away the lock and the learned frequency sixty times a
            // second.  On the board that left two thirds of the live frames in
            // the monochrome fallback: 33 of 50, measured.
            if (burst_age != 18'h3ffff) burst_age <= burst_age + 18'd1;
            else begin
                locked <= 1'b0;
                good_lines <= 8'd0;
                have_step <= 1'b0;   // relearn the step after a dropout
                have_prev <= 1'b0;
                err_sum <= 20'sd0;
                avg_cnt <= 8'd0;
                inc <= INC_NOM;
                inc_pend <= 1'b0;
            end
            // Snap the phase after a gap, but keep the learned step.
            //
            // The tracker extrapolates burst_off by burst_step every line, and
            // the vertical interval carries no burst for about twenty of them,
            // so the first line back was up to 38 degrees out.
            //
            // Discarding have_step there is the obvious remedy and it is wrong:
            // the next measurement then rebuilds the step from a single line's
            // difference, throwing away an estimate averaged over a field.  On
            // this source that is not rare.  The burst is 19 codes against a
            // spec 40, so individual lines fall under MAG_MIN in the middle of
            // active video, and re-learning on each of those cost 17 points of
            // good rows and left seven times as many out of order.
            //
            // The step is a property of the source -- 124.8 degrees a line here,
            // 180 on a standard one -- and a gap is no evidence against it.
            // Only the absolute phase goes stale, so only that is re-measured.
            if (burst_age == TRACK_GAP_SAMPLES[17:0]) gap_resync <= 1'b1;
            end

            fall_d <= {fall_d[1:0], sample_en && gate_fall};
            if (proc) begin
                burst_i <= i_scaled;
                burst_q <= q_scaled;
                i_acc   <= 16'sd0;
                q_acc   <= 16'sd0;

                if (mag_r >= MAG_MIN) begin
                    burst_age <= 18'd0;
                    cordic_start <= 1'b1;
                    correlation_adjust <= SNAP_PER_LINE ? (SNAP_PHASE - phase - step_now)
                        : ((avg_cnt == ((1 << AVG_LOG2) - 1)) ? phase_adj : 32'd0);
                    if (avg_cnt == ((1 << AVG_LOG2) - 1)) begin
                        avg_cnt <= 8'd0;
                        err_sum <= 20'sd0;
                        phase   <= SNAP_PER_LINE ? SNAP_PHASE
                                                 : (phase + step_now + phase_adj);
                        inc_pend <= 1'b1;
                    end else begin
                        avg_cnt <= avg_cnt + 8'd1;
                        err_sum <= sum_r;
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
endmodule

`default_nettype wire
