// ICS2115 Voice Oscillator — Sequential FSM Processing Pipeline
// Processes one voice per invocation: ROM fetch → interpolation → volume/pan → mix
//
// Processing order per spec §8.4 and MAME fill_output():
//   1. Volume/pan/ramp lookup (using CURRENT vol.acc)
//   2. Sample fetch and interpolation (at CURRENT osc.acc position)
//   3. Scale sample by volume, accumulate into stereo bus
//   4. Ramp update (slow attack/release)
//   5. Oscillator accumulator update — happens AFTER sample fetch
//   6. Oscillator boundary check (loop/stop)

module ics2115_osc
    import ics2115_pkg::*;
(
    input  logic        clk,
    input  logic        ce,
    input  logic        reset_n,
    input  logic        clear,

    // Control interface
    input  logic        start,          // pulse to begin processing
    output logic        done,           // asserted when processing complete
    output logic        irq_osc,        // oscillator boundary IRQ fired
    output logic        irq_vol,        // volume boundary IRQ fired

    // Volume envelope rate control
    input  logic        vol_rate_enable, // from top-level rate counter

    // Voice state — read at start, written back at done
    input  voice_state_t voice_in,
    output voice_state_t voice_out,

    // Vmode control — when 0, all voices contribute; when 1, only playing
    input  logic [7:0]  vmode,

    // ROM interface — top-level translates byte addr to word addr
    output logic [23:0] rom_byte_addr,  // 24-bit byte address
    output logic        rom_rd,         // read strobe
    input  logic [15:0] rom_data,       // 16-bit word from ROM
    input  logic        rom_data_valid, // handshake: data is valid this cycle

    // Table interfaces — directly wired to ics2115_tables
    output logic [11:0] vol_tbl_addr,
    input  logic [15:0] vol_tbl_data,
    output logic [7:0]  pan_tbl_addr,
    input  logic [11:0] pan_tbl_data,
    output logic [7:0]  ulaw_tbl_addr,
    input  logic signed [15:0] ulaw_tbl_data,

    // Audio accumulation — signed accumulators, caller sums across voices
    output logic signed [23:0] audio_left,
    output logic signed [23:0] audio_right,
    output logic               audio_valid     // pulse when this voice's contribution is ready
);

    // =========================================================================
    // FSM state encoding
    // =========================================================================
    typedef enum logic [4:0] {
        ST_IDLE             = 5'd0,
        ST_VOL_LOOKUP       = 5'd1,
        ST_PAN_LOOKUP_L     = 5'd2,
        ST_PAN_LOOKUP_R     = 5'd3,
        ST_VOL_WAIT_L       = 5'd4,     // wait for left vol table result
        ST_SAMPLE_FETCH_1   = 5'd5,
        ST_VOL_WAIT_R       = 5'd6,     // wait for right vol table result
        ST_SAMPLE_FETCH_2   = 5'd7,
        ST_SAMPLE_WAIT      = 5'd8,
        ST_INTERPOLATE      = 5'd9,
        ST_MIX              = 5'd10,
        ST_OSC_UPDATE       = 5'd11,
        ST_BOUNDARY_CHECK   = 5'd12,
        ST_RAMP_UPDATE      = 5'd13,
        ST_VOL_ENV_UPDATE   = 5'd14,    // volume envelope accumulator update
        ST_VOL_ENV_BOUNDARY = 5'd15,    // volume envelope boundary handling
        ST_DONE             = 5'd16
    } osc_state_t;

    osc_state_t state, state_next;

    // =========================================================================
    // Internal registers
    // =========================================================================
    voice_state_t v;                    // working copy of voice state

    logic [11:0] volacc;                // (vol.acc >> 14) & 0xFFF
    logic signed [12:0] vlefti_s;       // signed left vol index
    logic signed [12:0] vrighti_s;      // signed right vol index
    logic [15:0] vleft;                 // left volume after ramp
    logic [15:0] vright;                // right volume after ramp

    logic signed [15:0] sample1;
    logic signed [15:0] sample2;
    logic [19:0] cur_addr;              // acc >> 12, 20-bit byte addr in bank
    logic [19:0] next_addr;             // next sample addr for interpolation
    logic signed [15:0] interp_sample;

    logic irq_osc_r, irq_vol_r;

    // Volume envelope working registers
    logic [14:0] vol_add;               // vol_incr[5:0] << 9, set in ST_VOL_ENV_UPDATE

    logic osc_conf_8bit;
    logic osc_conf_ulaw;
    logic osc_conf_8bit_linear;

    always_comb begin
        osc_conf_8bit = 0;
        osc_conf_ulaw = 0;
        osc_conf_8bit_linear = 0;

        if (~v.osc_conf[OSC_EIGHTBIT]) begin
            osc_conf_8bit = 1;
            if (v.osc_conf[OSC_ULAW])
                osc_conf_ulaw = 1;
            else
                osc_conf_8bit_linear = 1;
        end
    end

    // =========================================================================
    // Combinational signals for boundary/interpolation/mix
    // =========================================================================
    logic voice_playing;
    assign voice_playing = v.state_on && !v.osc_conf[OSC_STOP];

    // Boundary check: osc_left = distance to boundary (signed)
    logic signed [29:0] osc_left;
    always_comb begin
        if (v.osc_conf[OSC_INVERT])
            osc_left = $signed({1'b0, v.osc_acc}) - $signed({1'b0, v.osc_start});
        else
            osc_left = $signed({1'b0, v.osc_end}) - $signed({1'b0, v.osc_acc});
    end

    // Next-addr boundary proximity check
    logic signed [29:0] osc_left_pre;  // pre-update left for next-addr calc
    always_comb begin
        if (voice_in.osc_conf[OSC_INVERT])
            osc_left_pre = $signed({1'b0, voice_in.osc_acc}) - $signed({1'b0, voice_in.osc_start});
        else
            osc_left_pre = $signed({1'b0, voice_in.osc_end}) - $signed({1'b0, voice_in.osc_acc});
    end

    // Interpolation fraction: acc[8:0] = 9-bit (29-bit storage, not MAME's 32-bit [11:3])
    logic [8:0] interp_fract;
    assign interp_fract = v.osc_acc[8:0];

    // Interpolation: combinational from sample1, sample2, fract
    logic signed [16:0] interp_diff;
    logic signed [24:0] interp_raw;
    assign interp_diff = sample2 - sample1;
    assign interp_raw  = ($signed({sample1[15], sample1}) <<< 9) +
                         (interp_diff * $signed({1'b0, interp_fract}));

    // Mix: sample × volume (signed × unsigned)
    logic signed [31:0] mix_l, mix_r;
    assign mix_l = interp_sample * $signed({1'b0, vleft});
    assign mix_r = interp_sample * $signed({1'b0, vright});

    // Direction after bidir flip
    logic new_invert;
    always_comb begin
        if (v.osc_conf[OSC_BIDIR])
            new_invert = ~v.osc_conf[OSC_INVERT];
        else
            new_invert = v.osc_conf[OSC_INVERT];
    end

    // Construct byte address: (saddr[3:0] << 20) | addr[19:0]
    // saddr is 8-bit but only low 4 bits used for 24-bit addressing
    function automatic logic [23:0] make_rom_addr(
        input logic [7:0]  saddr,
        input logic [19:0] addr
    );
        return {saddr[3:0], addr};
    endfunction

    // =========================================================================
    // FSM next-state logic
    // =========================================================================
    always_comb begin
        state_next = state;
        case (state)
            ST_IDLE:           if (start) state_next = ST_VOL_LOOKUP;
            ST_VOL_LOOKUP:     state_next = ST_PAN_LOOKUP_L;
            ST_PAN_LOOKUP_L:   state_next = ST_PAN_LOOKUP_R;
            ST_PAN_LOOKUP_R:   state_next = ST_VOL_WAIT_L;
            ST_VOL_WAIT_L:     state_next = ST_SAMPLE_FETCH_1;
            ST_SAMPLE_FETCH_1: state_next = ST_VOL_WAIT_R;
            ST_VOL_WAIT_R:     if (rom_data_valid) state_next = ST_SAMPLE_FETCH_2;
            ST_SAMPLE_FETCH_2: state_next = ST_SAMPLE_WAIT;
            ST_SAMPLE_WAIT:    if (rom_data_valid) state_next = ST_INTERPOLATE;
            ST_INTERPOLATE:    state_next = ST_MIX;
            ST_MIX:            state_next = ST_OSC_UPDATE;
            ST_OSC_UPDATE:     state_next = ST_BOUNDARY_CHECK;
            ST_BOUNDARY_CHECK: state_next = ST_RAMP_UPDATE;
            ST_RAMP_UPDATE:      state_next = ST_VOL_ENV_UPDATE;
            ST_VOL_ENV_UPDATE:   state_next = ST_VOL_ENV_BOUNDARY;  // overridden to ST_DONE in datapath
            ST_VOL_ENV_BOUNDARY: state_next = ST_DONE;
            ST_DONE:             state_next = ST_IDLE;
            default:           state_next = ST_IDLE;
        endcase
    end

    // =========================================================================
    // FSM — registered data processing
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!reset_n || clear) begin
            state         <= ST_IDLE;
            done          <= 1'b0;
            audio_valid   <= 1'b0;
            irq_osc_r    <= 1'b0;
            irq_vol_r    <= 1'b0;
            rom_rd        <= 1'b0;
            rom_byte_addr <= 24'd0;
            vleft         <= 16'd0;
            vright        <= 16'd0;
            sample1       <= 16'sd0;
            sample2       <= 16'sd0;
            interp_sample <= 16'sd0;
            audio_left    <= 24'sd0;
            audio_right   <= 24'sd0;
            volacc        <= 12'd0;
            vlefti_s      <= 13'sd0;
            vrighti_s     <= 13'sd0;
            cur_addr      <= 20'd0;
            next_addr     <= 20'd0;
            vol_tbl_addr  <= 12'd0;
            pan_tbl_addr  <= 8'd0;
            ulaw_tbl_addr <= 8'd0;
            v             <= '0;
            vol_add       <= 15'd0;
        end else if (ce) begin
            // Defaults — pulsed signals cleared each cycle
            done        <= 1'b0;
            audio_valid <= 1'b0;
            rom_rd      <= 1'b0;

            state <= state_next;

            case (state)

                // ─────────────────────────────────────────────────────────────
                // IDLE: Latch voice state on start
                // ─────────────────────────────────────────────────────────────
                ST_IDLE: begin
                    if (start) begin
                        v           <= voice_in;
                        irq_osc_r   <= 1'b0;
                        irq_vol_r   <= 1'b0;
                        audio_left  <= 24'sd0;
                        audio_right <= 24'sd0;
                    end
                end

                // ─────────────────────────────────────────────────────────────
                // VOL_LOOKUP: Extract 12-bit vol index, request left pan atten
                // ─────────────────────────────────────────────────────────────
                ST_VOL_LOOKUP: begin
                    volacc       <= v.vol_acc[25:14];
                    pan_tbl_addr <= 8'd255 - v.vol_pan;
                end

                // ─────────────────────────────────────────────────────────────
                // PAN_LOOKUP_L: Pan table returns left atten (combinational).
                // Compute left vol index. Request right pan atten.
                // ─────────────────────────────────────────────────────────────
                ST_PAN_LOOKUP_L: begin
                    // left index = volacc - panlaw[255-pan]
                    vlefti_s     <= $signed({1'b0, volacc}) - $signed({1'b0, pan_tbl_data});
                    pan_tbl_addr <= v.vol_pan;
                end

                // ─────────────────────────────────────────────────────────────
                // PAN_LOOKUP_R: Pan table returns right atten. Compute right
                // vol index. Issue left volume table lookup.
                // Precompute cur_addr and next_addr for sample fetch.
                // ─────────────────────────────────────────────────────────────
                ST_PAN_LOOKUP_R: begin
                    // right index = volacc - panlaw[pan]
                    vrighti_s <= $signed({1'b0, volacc}) - $signed({1'b0, pan_tbl_data});

                    // Issue left volume table lookup (registered, 1-cycle latency)
                    if (vlefti_s > 13'sd0)
                        vol_tbl_addr <= vlefti_s[11:0];
                    else
                        vol_tbl_addr <= 12'd0;

                    // acc is 29-bit 20.9 format. acc[28:9] = 20-bit integer address
                    cur_addr <= v.osc_acc[28:9];

                    // Compute next_addr for interpolation
                    // If near loop end (forward, non-bidir), wrap to start[28:9]
                    if (v.state_on && v.osc_conf[OSC_LOOP] && !v.osc_conf[OSC_BIDIR] &&
                        (osc_left_pre < $signed({15'd0, v.osc_fc[15:1]})))
                    begin
                        next_addr <= v.osc_start[28:9];
                    end else begin
                        if (osc_conf_8bit)
                            next_addr <= v.osc_acc[28:9] + 20'd1;
                        else
                            next_addr <= v.osc_acc[28:9] + 20'd2;
                    end
                end

                // ─────────────────────────────────────────────────────────────
                // VOL_WAIT_L: Wait for left volume table registered output.
                // The vol_tbl_addr was set in ST_PAN_LOOKUP_R. Table registers
                // it this cycle. Result available next cycle (ST_SAMPLE_FETCH_1).
                // ─────────────────────────────────────────────────────────────
                ST_VOL_WAIT_L: begin
                    // Nothing to do — just waiting for vol table pipeline
                end

                // ─────────────────────────────────────────────────────────────
                // SAMPLE_FETCH_1: Read left vol result, issue right vol lookup,
                // issue first ROM read (sample1)
                // ─────────────────────────────────────────────────────────────
                ST_SAMPLE_FETCH_1: begin
                    // Left volume arrived (1-cycle latency). Apply ramp.
                    if (vlefti_s > 13'sd0)
                        vleft <= ({16'd0, vol_tbl_data} * {25'd0, v.state_ramp}) >> RAMP_SHIFT;
                    else
                        vleft <= 16'd0;

                    // Issue right volume lookup
                    if (vrighti_s > 13'sd0)
                        vol_tbl_addr <= vrighti_s[11:0];
                    else
                        vol_tbl_addr <= 12'd0;

                    // Issue ROM read for sample1
                    rom_byte_addr <= make_rom_addr(v.osc_saddr, cur_addr);
                    rom_rd        <= 1'b1;
                end

                // ─────────────────────────────────────────────────────────────
                // VOL_WAIT_R: Wait for right volume table + ROM data pipeline.
                // vol_tbl_addr for right was set in ST_SAMPLE_FETCH_1.
                // ROM read for sample1 was issued in ST_SAMPLE_FETCH_1.
                // Both registered outputs arrive next cycle (ST_SAMPLE_FETCH_2).
                // ─────────────────────────────────────────────────────────────
                ST_VOL_WAIT_R: begin
                    // Nothing to do — just waiting for vol table + ROM pipeline
                end

                // ─────────────────────────────────────────────────────────────
                // SAMPLE_FETCH_2: ROM data for sample1 arrived. Latch sample1.
                // Read right vol result. Issue ROM read for sample2.
                // ─────────────────────────────────────────────────────────────
                ST_SAMPLE_FETCH_2: begin
                    // Right volume arrived. Apply ramp.
                    if (vrighti_s > 13'sd0)
                        vright <= ({16'd0, vol_tbl_data} * {25'd0, v.state_ramp}) >> RAMP_SHIFT;
                    else
                        vright <= 16'd0;

                    // Decode sample1 from ROM data
                    if (osc_conf_ulaw) begin
                        // µ-law: extract byte, send to decode table
                        if (~cur_addr[0])
                            ulaw_tbl_addr <= rom_data[15:8];
                        else
                            ulaw_tbl_addr <= rom_data[7:0];
                        // sample1 will be latched from ulaw_tbl_data next cycle
                    end else if (osc_conf_8bit_linear) begin
                        // 8-bit signed: extract byte and shift left by 8.
                        // MAME/reference: (s8(sample_byte) << 8).  The low
                        // byte must be zero, not sign/LSB replicated.
                        if (~cur_addr[0])
                            sample1 <= $signed({ rom_data[15:8], 8'h00 });
                        else
                            sample1 <= $signed({ rom_data[7:0],  8'h00 });
                    end else begin
                        // 16-bit: ROM word is the sample (word-aligned assumption)
                        sample1 <= $signed(rom_data);
                    end

                    // Issue ROM read for sample2
                    rom_byte_addr <= make_rom_addr(v.osc_saddr, next_addr);
                    rom_rd        <= 1'b1;
                end

                // ─────────────────────────────────────────────────────────────
                // SAMPLE_WAIT: ROM data for sample2 arrived. Latch sample2.
                // For µ-law: latch sample1 from table, setup sample2 decode.
                // ─────────────────────────────────────────────────────────────
                ST_SAMPLE_WAIT: begin
                    // For µ-law: sample1 decode is ready (combinational table)
                    if (osc_conf_ulaw) begin
                        sample1 <= ulaw_tbl_data;
                        // Now decode sample2
                        if (~next_addr[0])
                            ulaw_tbl_addr <= rom_data[15:8];
                        else
                            ulaw_tbl_addr <= rom_data[7:0];
                    end else if (osc_conf_8bit_linear) begin
                        // Decode sample2 from ROM data: (s8(sample_byte) << 8).
                        if (~next_addr[0])
                            sample2 <= $signed({ rom_data[15:8], 8'h00 });
                        else
                            sample2 <= $signed({ rom_data[7:0],  8'h00 });
                    end else begin
                        sample2 <= $signed(rom_data);
                    end
                end

                // ─────────────────────────────────────────────────────────────
                // INTERPOLATE: Linear interpolation between sample1 & sample2
                // For µ-law: sample2 decode completes this cycle (combinational)
                // ─────────────────────────────────────────────────────────────
                ST_INTERPOLATE: begin
                    // For µ-law: latch sample2 from table and use for interp
                    if (osc_conf_ulaw) begin
                        sample2 <= ulaw_tbl_data;
                        // Use ulaw_tbl_data directly in combinational interp
                        // Recalculate with correct sample2
                        interp_sample <= (($signed({1'b0, sample1}) <<< 9) +
                                         ((ulaw_tbl_data - sample1) *
                                          $signed({1'b0, interp_fract}))) >>> 9;
                    end else begin
                        // Normal path: samples already latched
                        interp_sample <= interp_raw[24:9];
                    end
                end

                // ─────────────────────────────────────────────────────────────
                // MIX: Scale interpolated sample by volume, output audio
                // ─────────────────────────────────────────────────────────────
                ST_MIX: begin
                    // Contribute if vmode==0 OR voice is playing (spec §8.3)
                    if (vmode == 8'd0 || voice_playing) begin
                        // MAME: >> 20 = >> (5 + VOLUME_BITS)
                        // MJD_TODO: Changed to just 15, I don't think it is
                        // adjusting my voice count here
                        audio_left  <= mix_l >>> 15;
                        audio_right <= mix_r >>> 15;
                    end else begin
                        audio_left  <= 24'sd0;
                        audio_right <= 24'sd0;
                    end
                    audio_valid <= 1'b1;
                end

                // ─────────────────────────────────────────────────────────────
                // OSC_UPDATE: Advance oscillator accumulator (spec §6.1)
                // fc bit 0 is unused; MAME uses fc<<2 on 32-bit acc,
                // equivalent to fc>>1 in 29-bit space. Step = fc[15:1].
                // ─────────────────────────────────────────────────────────────
                ST_OSC_UPDATE: begin
                    if (voice_playing) begin
                        if (v.osc_conf[OSC_INVERT])
                            v.osc_acc <= v.osc_acc - {14'd0, v.osc_fc[15:1]};
                        else
                            v.osc_acc <= v.osc_acc + {14'd0, v.osc_fc[15:1]};
                    end
                end

                // ─────────────────────────────────────────────────────────────
                // BOUNDARY_CHECK: Handle loop/stop on boundary crossing (§6.2)
                // osc_left is computed combinationally from current v state
                // ─────────────────────────────────────────────────────────────
                ST_BOUNDARY_CHECK: begin
                    if (voice_playing && (osc_left <= 30'sd0)) begin
                        // Fire IRQ if enabled
                        if (v.osc_conf[OSC_IRQ]) begin
                            v.osc_conf[OSC_IRQ_PEND] <= 1'b1;
                            irq_osc_r <= 1'b1;
                        end

                        if (v.osc_conf[OSC_LOOP]) begin
                            // Bidirectional: flip direction
                            if (v.osc_conf[OSC_BIDIR])
                                v.osc_conf[OSC_INVERT] <= ~v.osc_conf[OSC_INVERT];

                            // Wrap accumulator using new_invert (post-flip direction)
                            if (new_invert) begin
                                // Now heading reverse: acc = end + left
                                // left is negative, so acc = end - |overshoot|
                                v.osc_acc <= v.osc_end[28:0] + osc_left[28:0];
                            end else begin
                                // Now heading forward: acc = start - left
                                // left is negative, so acc = start + |overshoot|
                                v.osc_acc <= v.osc_start[28:0] - osc_left[28:0];
                            end
                        end else begin
                            // One-shot: stop voice, clamp to boundary
                            v.state_on <= 1'b0;
                            v.osc_conf[OSC_STOP] <= 1'b1;
                            if (!v.osc_conf[OSC_INVERT])
                                v.osc_acc <= v.osc_end;
                            else
                                v.osc_acc <= v.osc_start;
                        end
                    end
                end

                // ─────────────────────────────────────────────────────────────
                // RAMP_UPDATE: Slow attack/release (spec §7.5)
                // ─────────────────────────────────────────────────────────────
                ST_RAMP_UPDATE: begin
                    if (v.state_on && !v.osc_conf[OSC_STOP]) begin
                        // Slow attack
                        if (v.state_ramp < MAX_RAMP)
                            v.state_ramp <= v.state_ramp + 7'd1;
                    end else begin
                        // Slow release
                        if (v.state_ramp > 7'd0)
                            v.state_ramp <= v.state_ramp - 7'd1;
                    end
                end

                // ─────────────────────────────────────────────────────────────
                // VOL_ENV_UPDATE: Volume envelope accumulator update
                // Advance vol_acc by vol_incr magnitude, check boundary
                // ─────────────────────────────────────────────────────────────
                ST_VOL_ENV_UPDATE: begin
                    // Skip envelope if done, stopped, or rate not enabled
                    if (v.vol_ctrl[VOL_DONE] || v.vol_ctrl[VOL_STOP] || !vol_rate_enable) begin
                        // Jump straight to DONE, bypassing boundary check
                        state <= ST_DONE;
                    end else begin
                        // vol_add = {vol_incr[5:0], 9'd0} — 6-bit magnitude left-shifted by 9
                        vol_add <= {v.vol_incr[5:0], 9'd0};

                        // Update accumulator: add or subtract vol_add (zero-extended to 26 bits)
                        if (v.vol_ctrl[VOL_INVERT]) begin
                            v.vol_acc <= v.vol_acc - {11'd0, v.vol_incr[5:0], 9'd0};
                        end else begin
                            v.vol_acc <= v.vol_acc + {11'd0, v.vol_incr[5:0], 9'd0};
                        end
                    end
                end

                // ─────────────────────────────────────────────────────────────
                // VOL_ENV_BOUNDARY: Check boundary and handle loop/wrap/done
                // Runs after VOL_ENV_UPDATE; vol_add was latched there
                // ─────────────────────────────────────────────────────────────
                ST_VOL_ENV_BOUNDARY: begin : vol_env_boundary_blk
                    // Compute distance to boundary using signed arithmetic
                    // vol_acc was already updated in the previous state
                    logic signed [26:0] vol_left;
                    logic signed [26:0] new_vol;

                    if (v.vol_ctrl[VOL_INVERT])
                        vol_left = $signed({1'b0, v.vol_acc}) - $signed({1'b0, v.vol_start});
                    else
                        vol_left = $signed({1'b0, v.vol_end}) - $signed({1'b0, v.vol_acc});

                    if (vol_left > 27'sd0) begin
                        // Still within bounds — nothing to do, proceed to DONE
                    end else begin
                        // Boundary crossed or exactly reached

                        // Fire IRQ if enabled
                        if (v.vol_ctrl[VOL_IRQ]) begin
                            v.vol_ctrl[VOL_IRQ_PEND] <= 1'b1;
                            irq_vol_r <= 1'b1;
                        end

                        // 8-bit mode exception: skip wrap logic (per MAME)
                        if (!osc_conf_8bit) begin
                            if (v.vol_ctrl[VOL_LOOP]) begin
                                if (!v.vol_ctrl[VOL_BIDIR]) begin
                                    // Unidirectional loop: wrap around
                                    // overshoot = -vol_left (positive magnitude)
                                    if (!v.vol_ctrl[VOL_INVERT]) begin
                                        // Forward: new = start + overshoot
                                        new_vol = $signed({1'b0, v.vol_start}) - vol_left;
                                        v.vol_acc <= new_vol[25:0];
                                    end else begin
                                        // Reverse: new = end - overshoot
                                        new_vol = $signed({1'b0, v.vol_end}) + vol_left;
                                        v.vol_acc <= new_vol[25:0];
                                    end
                                end else begin
                                    // Bidirectional loop: bounce and flip direction
                                    if (!v.vol_ctrl[VOL_INVERT]) begin
                                        // Was going up, bounce from end: new = end - overshoot
                                        new_vol = $signed({1'b0, v.vol_end}) + vol_left;
                                        v.vol_acc <= new_vol[25:0];
                                    end else begin
                                        // Was going down, bounce from start: new = start + overshoot
                                        new_vol = $signed({1'b0, v.vol_start}) - vol_left;
                                        v.vol_acc <= new_vol[25:0];
                                    end
                                    // Flip direction
                                    v.vol_ctrl[VOL_INVERT] <= ~v.vol_ctrl[VOL_INVERT];
                                end
                            end else begin
                                // No loop: envelope is done
                                v.vol_ctrl[VOL_DONE] <= 1'b1;
                            end
                        end else begin
                            // 8-bit mode: just mark done if no loop
                            if (!v.vol_ctrl[VOL_LOOP])
                                v.vol_ctrl[VOL_DONE] <= 1'b1;
                        end
                    end
                end

                // ─────────────────────────────────────────────────────────────
                // DONE: Signal completion
                // ─────────────────────────────────────────────────────────────
                ST_DONE: begin
                    done <= 1'b1;
                end

                default: ;
            endcase
        end
    end

    // =========================================================================
    // Output assignments
    // =========================================================================
    assign voice_out = v;
    assign irq_osc  = irq_osc_r;
    assign irq_vol  = irq_vol_r;

endmodule
