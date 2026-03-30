// ICS2115 WaveFront Synthesizer — Top-Level Module
// Wires package, tables, oscillator into a working system.
// Voice state array, sample tick generator, voice processing sequencer,
// ROM arbiter, audio clamping, and stub host bus for S02 testbench.

module ics2115
    import ics2115_pkg::*;
(
    input  logic        clk,
    input  logic        ce,         // clock enable (~33.8688 MHz)
    input  logic        reset_n,

    // Host bus interface — matches one-shot port signature for testbench reuse
    input  logic [1:0]  host_addr,
    input  logic [7:0]  host_din,
    output logic [7:0]  host_dout,
    input  logic        host_cs_n,
    input  logic        host_rd_n,
    input  logic        host_wr_n,
    output logic        host_irq,
    output logic        host_ready,

    // ROM interface (16-bit wide, synchronous, 1-cycle latency)
    output logic [22:0] rom_addr,    // word address
    input  logic [15:0] rom_data,
    output logic        rom_rd,

    // Audio output (parallel, directly captured by testbench)
    output logic signed [15:0] audio_left,
    output logic signed [15:0] audio_right,
    output logic               audio_valid
);

    // =========================================================================
    // Voice state array
    // =========================================================================
    voice_state_t voice_regs [0:NUM_VOICES-1];

    // =========================================================================
    // Global registers
    // =========================================================================
    logic [4:0] active_osc;
    logic [4:0] osc_select;
    logic [7:0] reg_select;     // latched register address from port 1
    logic [7:0] vmode;

    // =========================================================================
    // IRQ system registers
    // =========================================================================
    logic [7:0] irq_pending;    // system IRQ pending bitmap (bits 0-1 = timers)
    logic [7:0] irq_enabled;    // system IRQ enable mask (register 0x4A write)
    logic       irq_on;         // computed IRQ state

    // IRQV auto-clear side-effect signals (registered — cleared one cycle after host read)
    logic       irqv_clear_osc;
    logic       irqv_clear_vol;
    logic [4:0] irqv_clear_voice;

    // =========================================================================
    // Timer registers (two independent programmable timers)
    // =========================================================================
    logic [7:0]  timer_preset [0:1];   // 8-bit preset values
    logic [7:0]  timer_scale  [0:1];   // 8-bit prescale values
    logic [23:0] timer_count  [0:1];   // 24-bit down-counters
    logic [23:0] timer_period [0:1];   // computed period values
    logic        timer_running [0:1];  // whether timer is active

    // Timer IRQ clear side-effect signals (like IRQV clear — registered)
    logic        timer_irq_clear [0:1];

    // =========================================================================
    // Tables instance
    // =========================================================================
    logic [11:0] vol_tbl_addr;
    logic [15:0] vol_tbl_data;
    logic [7:0]  pan_tbl_addr;
    logic [11:0] pan_tbl_data;
    logic [7:0]  ulaw_tbl_addr;
    logic signed [15:0] ulaw_tbl_data;

    ics2115_tables u_tables (
        .clk       (clk),
        .vol_addr  (vol_tbl_addr),
        .vol_data  (vol_tbl_data),
        .pan_addr  (pan_tbl_addr),
        .pan_data  (pan_tbl_data),
        .ulaw_addr (ulaw_tbl_addr),
        .ulaw_data (ulaw_tbl_data)
    );

    // =========================================================================
    // Sample tick generator
    // =========================================================================
    // Period = (active_osc + 1) * 32 CE clocks per sample
    logic [15:0] sample_div_counter;
    logic [15:0] sample_div_period;
    logic        sample_tick;

    assign sample_div_period = ({11'd0, active_osc} + 16'd1) * 16'd32;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sample_div_counter <= 16'd0;
            sample_tick        <= 1'b0;
        end else begin
            sample_tick <= 1'b0;
            if (ce) begin
                if (sample_div_counter >= sample_div_period - 16'd1) begin
                    sample_div_counter <= 16'd0;
                    sample_tick        <= 1'b1;
                end else begin
                    sample_div_counter <= sample_div_counter + 16'd1;
                end
            end
        end
    end

    // =========================================================================
    // Volume envelope rate counter
    // =========================================================================
    logic [8:0]  ramp_cnt;              // 9-bit counter, increments on sample_tick
    logic        vol_rate_enable;       // gating signal for current voice's envelope

    // Rate divider logic based on vol_incr[7:6] and ramp_cnt
    always_comb begin
        case (voice_regs[seq_voice_idx].vol_incr[7:6])
            2'd0: vol_rate_enable = 1'b1;                                       // every tick
            2'd1: vol_rate_enable = (ramp_cnt[2:0] == seq_voice_idx[2:0]);      // every 8th
            2'd2: vol_rate_enable = (ramp_cnt[5:0] == {3'd0, seq_voice_idx[2:0]});  // every 64th
            2'd3: vol_rate_enable = (ramp_cnt[8:0] == {6'd0, seq_voice_idx[2:0]});  // every 512th
        endcase
    end

    // ramp_cnt increments once per sample_tick
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            ramp_cnt <= 9'd0;
        else if (sample_tick)
            ramp_cnt <= ramp_cnt + 9'd1;
    end

    // =========================================================================
    // Voice processing sequencer
    // =========================================================================
    typedef enum logic [2:0] {
        SEQ_IDLE    = 3'd0,
        SEQ_LOAD    = 3'd1,
        SEQ_WAIT    = 3'd2,
        SEQ_STORE   = 3'd3,
        SEQ_OUTPUT  = 3'd4
    } seq_state_t;

    seq_state_t seq_state;
    logic [4:0] seq_voice_idx;

    // Audio accumulators (24-bit signed to sum across all voices)
    logic signed [23:0] acc_left;
    logic signed [23:0] acc_right;

    // Sequencer output signals for voice write-back
    logic        seq_voice_wr;      // pulse: write back voice state
    logic [4:0]  seq_wr_idx;        // which voice to write back
    voice_state_t seq_wr_data;      // data to write back

    // Oscillator instance signals
    logic        osc_start;
    logic        osc_done;
    logic        osc_irq_osc;
    logic        osc_irq_vol;
    voice_state_t osc_voice_in;
    voice_state_t osc_voice_out;
    logic [23:0] osc_rom_byte_addr;
    logic        osc_rom_rd;
    logic [11:0] osc_vol_tbl_addr;
    logic [7:0]  osc_pan_tbl_addr;
    logic [7:0]  osc_ulaw_tbl_addr;
    logic signed [23:0] osc_audio_left;
    logic signed [23:0] osc_audio_right;
    logic        osc_audio_valid;

    ics2115_osc u_osc (
        .clk           (clk),
        .reset_n       (reset_n),
        .start         (osc_start),
        .done          (osc_done),
        .irq_osc       (osc_irq_osc),
        .irq_vol       (osc_irq_vol),
        .voice_in      (osc_voice_in),
        .voice_out     (osc_voice_out),
        .vmode         (vmode),
        .vol_rate_enable(vol_rate_enable),
        .rom_byte_addr (osc_rom_byte_addr),
        .rom_rd        (osc_rom_rd),
        .rom_data      (rom_data),
        .vol_tbl_addr  (osc_vol_tbl_addr),
        .vol_tbl_data  (vol_tbl_data),
        .pan_tbl_addr  (osc_pan_tbl_addr),
        .pan_tbl_data  (pan_tbl_data),
        .ulaw_tbl_addr (osc_ulaw_tbl_addr),
        .ulaw_tbl_data (ulaw_tbl_data),
        .audio_left    (osc_audio_left),
        .audio_right   (osc_audio_right),
        .audio_valid   (osc_audio_valid)
    );

    // Connect oscillator table ports to tables module
    assign vol_tbl_addr  = osc_vol_tbl_addr;
    assign pan_tbl_addr  = osc_pan_tbl_addr;
    assign ulaw_tbl_addr = osc_ulaw_tbl_addr;

    // ROM address translation: byte address → word address
    assign rom_addr = osc_rom_byte_addr[23:1];
    assign rom_rd   = osc_rom_rd;

    // Sequencer FSM — drives osc_start, accumulates audio, signals write-back
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            seq_state     <= SEQ_IDLE;
            seq_voice_idx <= 5'd0;
            osc_start     <= 1'b0;
            osc_voice_in  <= '0;
            acc_left      <= 24'sd0;
            acc_right     <= 24'sd0;
            audio_left    <= 16'sd0;
            audio_right   <= 16'sd0;
            audio_valid   <= 1'b0;
            seq_voice_wr  <= 1'b0;
            seq_wr_idx    <= 5'd0;
            seq_wr_data   <= '0;
        end else begin
            // Defaults
            osc_start    <= 1'b0;
            audio_valid  <= 1'b0;
            seq_voice_wr <= 1'b0;

            case (seq_state)
                SEQ_IDLE: begin
                    if (sample_tick) begin
                        seq_voice_idx <= 5'd0;
                        acc_left      <= 24'sd0;
                        acc_right     <= 24'sd0;
                        seq_state     <= SEQ_LOAD;
                    end
                end

                SEQ_LOAD: begin
                    osc_voice_in <= voice_regs[seq_voice_idx];
                    osc_start    <= 1'b1;
                    seq_state    <= SEQ_WAIT;
                end

                SEQ_WAIT: begin
                    if (osc_done) begin
                        seq_state <= SEQ_STORE;
                    end
                end

                SEQ_STORE: begin
                    // Signal write-back to unified register block
                    seq_voice_wr <= 1'b1;
                    seq_wr_idx   <= seq_voice_idx;
                    seq_wr_data  <= osc_voice_out;

                    // Accumulate audio
                    acc_left  <= acc_left  + osc_audio_left;
                    acc_right <= acc_right + osc_audio_right;

                    if (seq_voice_idx >= active_osc) begin
                        seq_state <= SEQ_OUTPUT;
                    end else begin
                        seq_voice_idx <= seq_voice_idx + 5'd1;
                        seq_state     <= SEQ_LOAD;
                    end
                end

                SEQ_OUTPUT: begin
                    // Clamp 24-bit accumulators to 16-bit signed range
                    if (acc_left > 24'sd32767)
                        audio_left <= 16'sd32767;
                    else if (acc_left < -24'sd32768)
                        audio_left <= -16'sd32768;
                    else
                        audio_left <= acc_left[15:0];

                    if (acc_right > 24'sd32767)
                        audio_right <= 16'sd32767;
                    else if (acc_right < -24'sd32768)
                        audio_right <= -16'sd32768;
                    else
                        audio_right <= acc_right[15:0];

                    audio_valid <= 1'b1;
                    seq_state   <= SEQ_IDLE;
                end

                default: seq_state <= SEQ_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Host bus write detection
    // =========================================================================
    logic host_wr_pulse;
    logic host_wr_prev;

    assign host_wr_pulse = ~host_cs_n & ~host_wr_n & host_wr_prev;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            host_wr_prev <= 1'b1;
        else
            host_wr_prev <= host_cs_n | host_wr_n;
    end

    // =========================================================================
    // Host bus read detection
    // =========================================================================
    logic host_rd_pulse;
    logic host_rd_prev;

    assign host_rd_pulse = ~host_cs_n & ~host_rd_n & host_rd_prev;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            host_rd_prev <= 1'b1;
        else
            host_rd_prev <= host_cs_n | host_rd_n;
    end

    // =========================================================================
    // recalc_irq — combinational IRQ state computation
    // Matches MAME recalc_irq(): scans all 32 voices for pending IRQs
    // =========================================================================
    always_comb begin
        irq_on = |(irq_pending & irq_enabled);
        for (int i = 0; i < NUM_VOICES; i++) begin
            irq_on = irq_on |
                (voice_regs[i].osc_conf[OSC_IRQ] & voice_regs[i].osc_conf[OSC_IRQ_PEND]) |
                (voice_regs[i].vol_ctrl[VOL_IRQ] & voice_regs[i].vol_ctrl[VOL_IRQ_PEND]);
        end
    end

    assign host_irq = irq_on;

    // =========================================================================
    // Register read mux — matches MAME reg_read() layout
    // =========================================================================
    logic [15:0] reg_read_data;
    logic        irqv_found;  // used in IRQV scan to find first match

    always_comb begin
        reg_read_data = 16'd0;
		  irqv_found = 0;

        if (reg_select < 8'h20) begin
            case (reg_select[4:0])
                // 0x00: Oscillator Configuration — osc_conf with state_on merged into bit 3
                5'h00: begin
                    reg_read_data = {voice_regs[osc_select].osc_conf | (voice_regs[osc_select].state_on ? 8'h08 : 8'h00), 8'h00};
                end

                // 0x01: Wavesample frequency (16-bit, no shift)
                5'h01: reg_read_data = voice_regs[osc_select].osc_fc;

                // 0x02: Wavesample loop start high (bits 28:13 of 29-bit addr)
                5'h02: reg_read_data = voice_regs[osc_select].osc_start[28:13];

                // 0x03: Wavesample loop start low (bits 12:5 in high byte)
                5'h03: reg_read_data = {voice_regs[osc_select].osc_start[12:5], 8'h00};

                // 0x04: Wavesample loop end high
                5'h04: reg_read_data = voice_regs[osc_select].osc_end[28:13];

                // 0x05: Wavesample loop end low
                5'h05: reg_read_data = {voice_regs[osc_select].osc_end[12:5], 8'h00};

                // 0x06: Volume Increment (8-bit)
                5'h06: reg_read_data = {8'h00, voice_regs[osc_select].vol_incr};

                // 0x07: Volume Start — top 8 bits of 26-bit value (bits 25:18)
                5'h07: reg_read_data = {8'h00, voice_regs[osc_select].vol_start[25:18]};

                // 0x08: Volume End — top 8 bits
                5'h08: reg_read_data = {8'h00, voice_regs[osc_select].vol_end[25:18]};

                // 0x09: Volume accumulator (bits 25:10 of 26-bit value)
                5'h09: reg_read_data = voice_regs[osc_select].vol_acc[25:10];

                // 0x0A: Wavesample address high (osc_acc bits 28:13)
                5'h0A: reg_read_data = voice_regs[osc_select].osc_acc[28:13];

                // 0x0B: Wavesample address low — MAME returns (acc >> 0) & 0xFFF8
                // Our 29-bit acc maps: MAME bits [15:0] = our bits [15:0].
                // Mask 0xFFF8 clears bits [2:0]. So return {osc_acc[15:3], 3'b000}.
                5'h0B: reg_read_data = {voice_regs[osc_select].osc_acc[15:3], 3'b000};

                // 0x0C: Pan — pan value in high byte
                5'h0C: reg_read_data = {voice_regs[osc_select].vol_pan, 8'h00};

                // 0x0D: Volume Envelope Control — stub for T02 IRQ work
                5'h0D: begin
                    if (vmode == 8'd0)
                        reg_read_data = {(voice_regs[osc_select].vol_ctrl[VOL_IRQ_PEND] ? 8'h81 : 8'h01), 8'h00};
                    else
                        reg_read_data = {8'h01, 8'h00};
                end

                // 0x0E: Active Voices (5-bit)
                5'h0E: reg_read_data = {11'h000, active_osc};

                // 0x0F: IRQV — scan voices for first pending IRQ
                // Returns voice_idx | 0xE0, bit 7 cleared if osc pending, bit 6 cleared if vol pending
                5'h0F: begin
                    reg_read_data = 16'hFF00;  // default: no pending
                    irqv_found = 1'b0;
                    for (int i = 0; i < NUM_VOICES; i++) begin
                        if (i[4:0] <= active_osc && !irqv_found) begin
                            if (voice_regs[i].osc_conf[OSC_IRQ_PEND] || voice_regs[i].vol_ctrl[VOL_IRQ_PEND]) begin
                                irqv_found = 1'b1;
                                reg_read_data[15:8] = {3'b111, i[4:0]};
                                if (voice_regs[i].osc_conf[OSC_IRQ_PEND])
                                    reg_read_data[15] = 1'b0;  // clear bit 7 = osc source
                                if (voice_regs[i].vol_ctrl[VOL_IRQ_PEND])
                                    reg_read_data[14] = 1'b0;  // clear bit 6 = vol source
                            end
                        end
                    end
                end

                // 0x10: Oscillator Control — osc_ctl in high byte
                5'h10: reg_read_data = {voice_regs[osc_select].osc_ctl, 8'h00};

                // 0x11: Wavesample static address — saddr in high byte
                5'h11: reg_read_data = {voice_regs[osc_select].osc_saddr, 8'h00};

                default: reg_read_data = 16'd0;
            endcase
        end else begin
            case (reg_select)
                // 0x40/0x41: Timer presets — read returns preset, side effect clears IRQ
                8'h40: reg_read_data = {8'h00, timer_preset[0]};
                8'h41: reg_read_data = {8'h00, timer_preset[1]};

                // 0x43: Timer status — returns pending bits 0-1
                8'h43: reg_read_data = {8'h00, 6'd0, irq_pending[1:0]};

                // 0x4A: IRQ enabled/pending — read returns irq_pending
                8'h4A: reg_read_data = {8'h00, irq_pending};

                // 0x4B: Address of Interrupting Oscillator — fixed 0x80
                8'h4B: reg_read_data = {8'h00, 8'h80};

                // 0x4C: Chip Revision
                8'h4C: reg_read_data = {8'h00, CHIP_REVISION};

                default: reg_read_data = 16'd0;
            endcase
        end
    end

    // =========================================================================
    // Host bus read output mux — matches MAME read() at offsets 0-3
    // =========================================================================
    // Port 0: IRQ status register
    // Port 1: reg_select echo
    // Port 2: low byte of reg_read_data
    // Port 3: high byte of reg_read_data

    // Port 0 status register: compute "any voice has osc IRQ pending"
    logic any_voice_osc_irq;
    always_comb begin
        any_voice_osc_irq = 1'b0;
        for (int i = 0; i < NUM_VOICES; i++) begin
            if (i[4:0] <= active_osc)
                any_voice_osc_irq = any_voice_osc_irq | voice_regs[i].osc_conf[OSC_IRQ_PEND];
        end
    end

    // IRQV auto-clear computation: combinational scan for which voice to clear
    // Used by the registered irqv_clear_* signals below
    logic       irqv_clear_osc_next;
    logic       irqv_clear_vol_next;
    logic [4:0] irqv_clear_voice_next;
    logic       irqv_clear_found;
    always_comb begin
        irqv_clear_osc_next   = 1'b0;
        irqv_clear_vol_next   = 1'b0;
        irqv_clear_voice_next = 5'd0;
        irqv_clear_found      = 1'b0;
        if (host_rd_pulse && host_addr == 2'd3 && reg_select == 8'h0F) begin
            for (int i = 0; i < NUM_VOICES; i++) begin
                if (i[4:0] <= active_osc && !irqv_clear_found) begin
                    if (voice_regs[i].osc_conf[OSC_IRQ_PEND] || voice_regs[i].vol_ctrl[VOL_IRQ_PEND]) begin
                        irqv_clear_found      = 1'b1;
                        irqv_clear_voice_next = i[4:0];
                        irqv_clear_osc_next   = voice_regs[i].osc_conf[OSC_IRQ_PEND];
                        irqv_clear_vol_next   = voice_regs[i].vol_ctrl[VOL_IRQ_PEND];
                    end
                end
            end
        end
    end

    // Timer IRQ auto-clear computation: detect reads of 0x40 or 0x41
    // Reading timer preset clears the corresponding timer IRQ pending bit
    logic timer_irq_clear_next [0:1];
    always_comb begin
        timer_irq_clear_next[0] = 1'b0;
        timer_irq_clear_next[1] = 1'b0;
        if (host_rd_pulse && (host_addr == 2'd2 || host_addr == 2'd3)) begin
            if (reg_select == 8'h40)
                timer_irq_clear_next[0] = 1'b1;
            else if (reg_select == 8'h41)
                timer_irq_clear_next[1] = 1'b1;
        end
    end

    always_comb begin
        case (host_addr)
            2'd0: begin
                // Port 0: IRQ status — MAME read() case 0
                host_dout = 8'd0;
                if (irq_on) begin
                    host_dout[7] = 1'b1;  // bit 7: any IRQ active
                    if (irq_enabled != 8'd0 && (irq_pending & 8'h03) != 8'h00)
                        host_dout[0] = 1'b1;  // bit 0: timer IRQ pending & enabled
                    if (any_voice_osc_irq)
                        host_dout[1] = 1'b1;  // bit 1: voice osc IRQ pending
                end
            end
            2'd1: host_dout = reg_select;                    // reg_select echo
            2'd2: host_dout = reg_read_data[7:0];            // low byte
            2'd3: host_dout = reg_read_data[15:8];           // high byte
            default: host_dout = 8'd0;
        endcase
    end

    assign host_ready = 1'b1;
    // host_irq driven by recalc_irq logic above

    // =========================================================================
    // Unified voice_regs + global register write block
    // =========================================================================
    // Single always_ff drives voice_regs to avoid MULTIDRIVEN.
    // Priority: sequencer write-back > host writes (sequencer is pipeline-hot).

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            active_osc <= DEFAULT_ACTIVE_OSC;
            osc_select <= 5'd0;
            reg_select <= 8'd0;
            vmode      <= 8'd0;
            irq_pending <= 8'd0;
            irq_enabled <= 8'd0;
            irqv_clear_osc   <= 1'b0;
            irqv_clear_vol   <= 1'b0;
            irqv_clear_voice <= 5'd0;
            timer_irq_clear[0] <= 1'b0;
            timer_irq_clear[1] <= 1'b0;
            for (int i = 0; i < 2; i++) begin
                timer_preset[i]   <= 8'd0;
                timer_scale[i]    <= 8'd0;
                timer_count[i]    <= 24'd0;
                timer_period[i]   <= 24'd0;
                timer_running[i]  <= 1'b0;
            end
            for (int i = 0; i < NUM_VOICES; i++) begin
                voice_regs[i].osc_acc   <= 29'd0;
                voice_regs[i].osc_fc    <= 16'd0;
                voice_regs[i].osc_start <= 29'd0;
                voice_regs[i].osc_end   <= 29'd0;
                voice_regs[i].osc_saddr <= 8'd0;
                voice_regs[i].osc_conf  <= 8'h02;  // stop=1
                voice_regs[i].osc_ctl   <= 8'd0;
                voice_regs[i].vol_acc   <= 26'd0;
                voice_regs[i].vol_start <= 26'd0;
                voice_regs[i].vol_end   <= 26'd0;
                voice_regs[i].vol_incr  <= 8'd0;
                voice_regs[i].vol_pan   <= 8'h7F;  // center
                voice_regs[i].vol_ctrl  <= 8'h01;  // done=1
                voice_regs[i].vol_mode  <= 8'd0;
                voice_regs[i].state_on  <= 1'b0;
                voice_regs[i].state_ramp <= 7'd0;
            end
        end else begin

            // ── Sequencer voice write-back (highest priority) ──
            if (seq_voice_wr) begin
                voice_regs[seq_wr_idx] <= seq_wr_data;
            end

            // ── Host bus port writes ──
            if (host_wr_pulse) begin
                case (host_addr)
                    2'd1: begin
                        reg_select <= host_din[7:0];
                    end
                    2'd3: begin
                        // High-byte write — per-voice and global registers
                        if (reg_select < 8'h20) begin
                            case (reg_select[4:0])
                                5'h00: voice_regs[osc_select].osc_conf[6:0]  <= host_din[6:0];
                                5'h01: voice_regs[osc_select].osc_fc[15:8]   <= host_din[7:0];
                                5'h02: voice_regs[osc_select].osc_start[28:21] <= host_din[7:0];
                                5'h03: voice_regs[osc_select].osc_start[12:5]  <= host_din[7:0];
                                5'h04: voice_regs[osc_select].osc_end[28:21]   <= host_din[7:0];
                                5'h05: voice_regs[osc_select].osc_end[12:5]    <= host_din[7:0];
                                5'h06: voice_regs[osc_select].vol_incr         <= host_din[7:0];
                                5'h09: voice_regs[osc_select].vol_acc[25:18]   <= host_din[7:0];
                                5'h0A: voice_regs[osc_select].osc_acc[28:21]   <= host_din[7:0];
                                5'h0B: voice_regs[osc_select].osc_acc[12:5]    <= host_din[7:0];
                                5'h0C: voice_regs[osc_select].vol_pan          <= host_din[7:0];
                                5'h0D: voice_regs[osc_select].vol_ctrl[6:0]    <= host_din[6:0];
                                5'h0E: active_osc                              <= host_din[4:0];
                                5'h10: begin
                                    voice_regs[osc_select].osc_ctl <= host_din[7:0];
                                    if (host_din[7:0] == 8'h00) begin
                                        // Keyon
                                        voice_regs[osc_select].state_on        <= 1'b1;
                                        voice_regs[osc_select].state_ramp      <= MAX_RAMP;
                                        voice_regs[osc_select].osc_conf[OSC_STOP] <= 1'b0;
                                    end else if (host_din[7:0] == 8'h0F) begin
                                        // Keyoff
                                        voice_regs[osc_select].state_on        <= 1'b0;
                                        voice_regs[osc_select].osc_conf[OSC_STOP] <= 1'b1;
                                        voice_regs[osc_select].vol_ctrl[VOL_STOP] <= 1'b1;
                                    end
                                end
                                5'h11: voice_regs[osc_select].osc_saddr        <= host_din[7:0];
                                5'h12: vmode                                    <= host_din[7:0];
                                default: ;
                            endcase
                        end else begin
                            case (reg_select)
                                // No high-byte global registers currently
                                default: ;
                            endcase
                        end
                    end
                    2'd2: begin
                        // Low-byte write — per-voice registers that need low byte
                        if (reg_select < 8'h20) begin
                            case (reg_select[4:0])
                                5'h01: voice_regs[osc_select].osc_fc[7:0]      <= host_din[7:0];
                                5'h02: voice_regs[osc_select].osc_start[20:13]  <= host_din[7:0];
                                5'h04: voice_regs[osc_select].osc_end[20:13]    <= host_din[7:0];
                                5'h07: voice_regs[osc_select].vol_start         <= {host_din[7:0], 18'd0};
                                5'h08: voice_regs[osc_select].vol_end           <= {host_din[7:0], 18'd0};
                                5'h09: begin
                                    voice_regs[osc_select].vol_acc[17:10] <= host_din[7:0];
                                    voice_regs[osc_select].vol_acc[9:0]   <= 10'd0;
                                end
                                5'h0A: voice_regs[osc_select].osc_acc[20:13]    <= host_din[7:0];
                                5'h0B: voice_regs[osc_select].osc_acc[4:0]      <= host_din[7:3];
                                default: ;
                            endcase
                        end else begin
                            case (reg_select)
                                8'h40: begin
                                    timer_preset[0] <= host_din[7:0];
                                    timer_period[0] <= (({19'd0, timer_scale[0][4:0]} + 24'd1) * ({16'd0, host_din[7:0]} + 24'd1)) << (4 + timer_scale[0][7:5]);
                                    timer_count[0]  <= (({19'd0, timer_scale[0][4:0]} + 24'd1) * ({16'd0, host_din[7:0]} + 24'd1)) << (4 + timer_scale[0][7:5]);
                                    timer_running[0] <= 1'b1;
                                end
                                8'h41: begin
                                    timer_preset[1] <= host_din[7:0];
                                    timer_period[1] <= (({19'd0, timer_scale[1][4:0]} + 24'd1) * ({16'd0, host_din[7:0]} + 24'd1)) << (4 + timer_scale[1][7:5]);
                                    timer_count[1]  <= (({19'd0, timer_scale[1][4:0]} + 24'd1) * ({16'd0, host_din[7:0]} + 24'd1)) << (4 + timer_scale[1][7:5]);
                                    timer_running[1] <= 1'b1;
                                end
                                8'h42: begin
                                    timer_scale[0] <= host_din[7:0];
                                    timer_period[0] <= (({19'd0, host_din[4:0]} + 24'd1) * ({16'd0, timer_preset[0]} + 24'd1)) << (4 + host_din[7:5]);
                                    timer_count[0]  <= (({19'd0, host_din[4:0]} + 24'd1) * ({16'd0, timer_preset[0]} + 24'd1)) << (4 + host_din[7:5]);
                                    timer_running[0] <= 1'b1;
                                end
                                8'h43: begin
                                    timer_scale[1] <= host_din[7:0];
                                    timer_period[1] <= (({19'd0, host_din[4:0]} + 24'd1) * ({16'd0, timer_preset[1]} + 24'd1)) << (4 + host_din[7:5]);
                                    timer_count[1]  <= (({19'd0, host_din[4:0]} + 24'd1) * ({16'd0, timer_preset[1]} + 24'd1)) << (4 + host_din[7:5]);
                                    timer_running[1] <= 1'b1;
                                end
                                8'h4A: irq_enabled <= host_din[7:0];
                                8'h4F: osc_select <= host_din[4:0];
                                default: ;
                            endcase
                        end
                    end
                    default: ;
                endcase
            end

            // ── IRQV auto-clear side-effect ──
            // Register the clear request from the combinational scan
            irqv_clear_osc   <= irqv_clear_osc_next;
            irqv_clear_vol   <= irqv_clear_vol_next;
            irqv_clear_voice <= irqv_clear_voice_next;

            // Apply the clear from the PREVIOUS cycle's registered values
            if (irqv_clear_osc || irqv_clear_vol) begin
                if (!(seq_voice_wr && seq_wr_idx == irqv_clear_voice)) begin
                    if (irqv_clear_osc)
                        voice_regs[irqv_clear_voice].osc_conf[OSC_IRQ_PEND] <= 1'b0;
                    if (irqv_clear_vol)
                        voice_regs[irqv_clear_voice].vol_ctrl[VOL_IRQ_PEND] <= 1'b0;
                end
            end

            // ── Timer IRQ auto-clear side-effect ──
            // Register the clear request, apply one cycle later (same pattern as IRQV)
            timer_irq_clear[0] <= timer_irq_clear_next[0];
            timer_irq_clear[1] <= timer_irq_clear_next[1];

            if (timer_irq_clear[0])
                irq_pending[0] <= 1'b0;
            if (timer_irq_clear[1])
                irq_pending[1] <= 1'b0;

            // ── Timer counter logic (gated by ce) ──
            if (ce) begin
                for (int t = 0; t < 2; t++) begin
                    if (timer_running[t]) begin
                        if (timer_count[t] == 24'd0) begin
                            // Timer expired: set IRQ pending, reload
                            irq_pending[t] <= 1'b1;
                            timer_count[t] <= timer_period[t] - 24'd1;
                        end else begin
                            timer_count[t] <= timer_count[t] - 24'd1;
                        end
                    end
                end
            end
        end
    end

endmodule
