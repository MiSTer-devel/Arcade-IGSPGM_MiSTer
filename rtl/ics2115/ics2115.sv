//============================================================================
//  Copyright (C) 2026 Martin Donlon
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//============================================================================

// ICS2115 WaveFront Synthesizer — Top-Level Module
// Wires package, tables, oscillator into a working system.
// Voice state array, sample tick generator, voice processing sequencer,
// ROM arbiter, audio clamping, and stub host bus for S02 testbench.

module ics2115
    import ics2115_pkg::*;
#(
    parameter int SS_IDX = -1
) (
    input  logic        clk,
    input  logic        ce,         // clock enable (~33.8688 MHz)
    input  logic        ce_50m,
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

    // ROM interface (16-bit wide, synchronous, variable latency)
    output logic [22:0] rom_addr,       // word address
    input  logic [15:0] rom_data,
    output logic        rom_rd,
    input  logic        rom_data_valid, // handshake: data is valid this cycle
    output logic [4:0]  rom_voice_id,   // current voice being processed

    // Audio output (parallel, directly captured by testbench)
    output logic signed [15:0] audio_left,
    output logic signed [15:0] audio_right,
    output logic               audio_valid,

    output logic               ss_ready,
    ssbus_if.slave ssbus
);

    // =========================================================================
    // Voice state RAM
    // =========================================================================
    localparam VOICE_BITS = $bits(voice_state_t);

    logic [4:0] voice_ram_addr_a;
    logic       voice_ram_wren_a;
    logic [VOICE_BITS-1:0] voice_ram_data_a;
    logic [VOICE_BITS-1:0] voice_ram_q_a;

    logic [4:0] voice_ram_addr_b;
    logic       voice_ram_wren_b;
    logic [VOICE_BITS-1:0] voice_ram_data_b;
    logic [VOICE_BITS-1:0] voice_ram_q_b;

    dualport_ram_unreg #(.WIDTH(VOICE_BITS), .WIDTHAD(5)) voice_ram (
        .clock_a(clk),
        .wren_a(voice_ram_wren_a),
        .address_a(voice_ram_addr_a),
        .data_a(voice_ram_data_a),
        .q_a(voice_ram_q_a),
        .clock_b(clk),
        .wren_b(voice_ram_wren_b),
        .address_b(voice_ram_addr_b),
        .data_b(voice_ram_data_b),
        .q_b(voice_ram_q_b)
    );

    voice_state_t seq_voice_data;
    voice_state_t host_voice_data;
    assign host_voice_data = voice_state_t'(voice_ram_q_b);

    function automatic voice_state_t default_voice_state();
        voice_state_t result;
        result = '0;
        result.osc_conf = 8'h02;  // stop=1
        result.vol_pan = 8'h7F;   // center
        result.vol_ctrl = 8'h01;  // done=1
        return result;
    endfunction

    logic [31:0] osc_irq_en;
    logic [31:0] osc_irq_pending;
    // Per-voice "reached its end via a real engine event" flag (one-shot done).
    // Set on the osc_irq_osc end pulse, cleared when the voice is not done
    // (restart/playing).  Drives the osc-IRQ LEVEL re-assert — using a real end
    // event, NOT osc_ctl[OSC_DONE] (which key-off also sets), per hardware.
    logic [31:0] osc_ended;
    logic [31:0] vol_irq_en;
    logic [31:0] vol_irq_pending;
    // Per-voice "vol envelope reached its end via a real event" flag — the vol
    // analogue of osc_ended (hardware: vol IRQ is the same re-asserting level).
    logic [31:0] vol_ended;

    localparam int VOICE_SS_WORDS = NUM_VOICES * 8;
    localparam int SS_STATE_BASE = VOICE_SS_WORDS;
    localparam int SS_WORD_GLOBAL0 = SS_STATE_BASE + 0;
    localparam int SS_WORD_GLOBAL1 = SS_STATE_BASE + 1;
    localparam int SS_WORD_SAMPLE = SS_STATE_BASE + 2;
    localparam int SS_WORD_TIMER0_CFG = SS_STATE_BASE + 3;
    localparam int SS_WORD_TIMER0_COUNT = SS_STATE_BASE + 4;
    localparam int SS_WORD_TIMER0_PERIOD = SS_STATE_BASE + 5;
    localparam int SS_WORD_TIMER1_CFG = SS_STATE_BASE + 6;
    localparam int SS_WORD_TIMER1_COUNT = SS_STATE_BASE + 7;
    localparam int SS_WORD_TIMER1_PERIOD = SS_STATE_BASE + 8;
    localparam int SS_WORD_OSC_IRQ_EN = SS_STATE_BASE + 9;
    localparam int SS_WORD_OSC_IRQ_PENDING = SS_STATE_BASE + 10;
    localparam int SS_WORD_VOL_IRQ_EN = SS_STATE_BASE + 11;
    localparam int SS_WORD_VOL_IRQ_PENDING = SS_STATE_BASE + 12;
    localparam int SS_WORD_OSC_ENDED = SS_STATE_BASE + 13;
    localparam int SS_WORD_VOL_ENDED = SS_STATE_BASE + 14;
    localparam int SS_WORD_COUNT = SS_STATE_BASE + 15;

    typedef enum logic [2:0] {
        SS_IDLE = 3'd0,
        SS_VOICE_READ_WAIT = 3'd1,
        SS_VOICE_READ_RESP = 3'd2,
        SS_VOICE_WRITE_WAIT = 3'd3,
        SS_VOICE_WRITE_COMMIT = 3'd4,
        SS_WAIT_IDLE = 3'd5
    } ss_state_t;

    ss_state_t ss_state;
    logic [31:0] ss_addr_latched;
    logic [31:0] ss_data_latched;
    logic        ss_state_write_pulse;
    logic [31:0] ss_state_write_addr;
    logic [31:0] ss_state_write_data;

    wire ss_safe = host_fifo_empty
                && (host_state == HOST_IDLE)
                && !(|host_voice_wr_pending)
                && !irqv_ram_clear_pending
                && (seq_state == SEQ_IDLE);
    assign ss_ready = ss_safe;

    wire ss_access_now = ssbus.access(SS_IDX) && ss_safe;
    wire ss_voice_access_now = ss_access_now && (ssbus.addr < VOICE_SS_WORDS[31:0]);
    wire ss_busy_local = (ss_state != SS_IDLE) || ss_voice_access_now;

    // Save-state voice layout compatibility:
    // older save states stored 8 words/voice with a 7-bit legacy ramp field in
    // bits [6:0].  The hardware has no such field, so keep those bits as zero
    // on save and ignore them on load while preserving the old 256-bit layout.
    function automatic logic [255:0] pack_voice_legacy(input logic [VOICE_BITS-1:0] voice);
        voice_state_t v;
        v = voice_state_t'(voice);
        pack_voice_legacy = '0;
        pack_voice_legacy[7]       = 0;
        pack_voice_legacy[15:8]    = v.vol_mode;
        pack_voice_legacy[23:16]   = v.vol_ctrl;
        pack_voice_legacy[31:24]   = v.vol_pan;
        pack_voice_legacy[39:32]   = v.vol_incr;
        pack_voice_legacy[65:40]   = v.vol_end;
        pack_voice_legacy[91:66]   = v.vol_start;
        pack_voice_legacy[117:92]  = v.vol_acc;
        pack_voice_legacy[125:118] = v.osc_ctl;
        pack_voice_legacy[133:126] = v.osc_conf;
        pack_voice_legacy[141:134] = v.osc_saddr;
        pack_voice_legacy[170:142] = v.osc_end;
        pack_voice_legacy[199:171] = v.osc_start;
        pack_voice_legacy[215:200] = v.osc_fc;
        pack_voice_legacy[244:216] = v.osc_acc;
    endfunction

    function automatic voice_state_t unpack_voice_legacy(input logic [255:0] legacy);
        voice_state_t v;
        v = '0;
        v.vol_mode  = legacy[15:8];
        v.vol_ctrl  = legacy[23:16];
        v.vol_pan   = legacy[31:24];
        v.vol_incr  = legacy[39:32];
        v.vol_end   = legacy[65:40];
        v.vol_start = legacy[91:66];
        v.vol_acc   = legacy[117:92];
        v.osc_ctl   = legacy[125:118];
        v.osc_conf  = legacy[133:126];
        v.osc_saddr = legacy[141:134];
        v.osc_end   = legacy[170:142];
        v.osc_start = legacy[199:171];
        v.osc_fc    = legacy[215:200];
        v.osc_acc   = legacy[244:216];
        return v;
    endfunction

    function automatic [31:0] get_voice_word(input logic [VOICE_BITS-1:0] voice, input logic [2:0] word_idx);
        logic [255:0] legacy;
        legacy = pack_voice_legacy(voice);
        case (word_idx)
            3'd0: get_voice_word = legacy[31:0];
            3'd1: get_voice_word = legacy[63:32];
            3'd2: get_voice_word = legacy[95:64];
            3'd3: get_voice_word = legacy[127:96];
            3'd4: get_voice_word = legacy[159:128];
            3'd5: get_voice_word = legacy[191:160];
            3'd6: get_voice_word = legacy[223:192];
            default: get_voice_word = legacy[255:224];
        endcase
    endfunction

    function automatic logic [VOICE_BITS-1:0] set_voice_word(
        input logic [VOICE_BITS-1:0] voice,
        input logic [2:0] word_idx,
        input logic [31:0] data
    );
        logic [255:0] legacy;
        legacy = pack_voice_legacy(voice);
        case (word_idx)
            3'd0: legacy[31:0] = data;
            3'd1: legacy[63:32] = data;
            3'd2: legacy[95:64] = data;
            3'd3: legacy[127:96] = data;
            3'd4: legacy[159:128] = data;
            3'd5: legacy[191:160] = data;
            3'd6: legacy[223:192] = data;
            default: legacy[255:224] = data;
        endcase
        return unpack_voice_legacy(legacy);
    endfunction

    // =========================================================================
    // Global registers
    // =========================================================================
    logic [4:0] active_osc;
    logic [4:0] osc_select;
    logic [7:0] reg_select;     // latched register address from port 1
    logic [7:0] vmode;
    // 0x4D system control: hardware stores only bits 0 and 2 (mask 0x05);
    // bit 0 gates timer counting entirely.
    logic [7:0] sys_ctl;
    // Last voice reported through IRQV/0x4B: hardware retains it in the idle
    // values of both registers (boot value 0x02 observed on real hardware;
    // origin unidentified, kept for record convergence).
    logic [4:0] last_irq_voice;

    // =========================================================================
    // IRQ system registers
    // =========================================================================
    logic [7:0] irq_pending;    // system IRQ pending bitmap (bits 0-1 = timers)
    logic [7:0] irq_enabled;    // system IRQ enable mask (register 0x4A write)
    logic       irq_on;         // computed IRQ state

    // (IRQV is not clear-on-read on hardware; no clear side-effect signals.)

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
    // Timer INT event latches: set on fire (when 0x43-enabled), cleared by a
    // 0x43 read; separate from the persistent pending bits.
    logic [1:0]  timer_int;

    // =========================================================================
    // Tables instance
    // =========================================================================
    logic [11:0] vol_tbl_addr;
    logic [15:0] vol_tbl_data;
    logic [7:0]  pan_tbl_addr;
    logic [11:0] pan_tbl_data;

    ics2115_tables u_tables (
        .clk       (clk),
        .vol_addr  (vol_tbl_addr),
        .vol_data  (vol_tbl_data),
        .pan_addr  (pan_tbl_addr),
        .pan_data  (pan_tbl_data)
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
            if (ss_state_write_pulse && ss_state_write_addr == SS_WORD_SAMPLE) begin
                sample_div_counter <= ss_state_write_data[15:0];
            end else if (!ss_busy_local && ce && sys_ctl[0] && sys_ctl[2]) begin
                // 0x4D bits 0&2 are the master chip-run gate (hw 2026-06-13):
                // with them clear, the oscillator engine freezes — no sample
                // ticks, no voice advance, no audio (output muted below).
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
    // Legacy volume-rate counter
    // =========================================================================
    // Older HDL used ramp_cnt with vol_incr[7:6] as a global rate divider.  The
    // measured VMode/VIncr behavior is now implemented per voice in
    // ics2115_osc.  Keep ramp_cnt saved/restored for save-state compatibility.
    logic [8:0]  ramp_cnt;              // 9-bit counter, increments on sample_tick

    // ramp_cnt increments once per sample_tick
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            ramp_cnt <= 9'd0;
        else if (ss_state_write_pulse && ss_state_write_addr == SS_WORD_SAMPLE)
            ramp_cnt <= ss_state_write_data[24:16];
        else if (!ss_busy_local && sample_tick)
            ramp_cnt <= ramp_cnt + 9'd1;
    end

    // =========================================================================
    // Voice processing sequencer
    // =========================================================================
    typedef enum logic [3:0] {
        SEQ_IDLE         = 4'd0,
        SEQ_LOAD_ADDR    = 4'd1,
        SEQ_LOAD_WAIT    = 4'd2,
        SEQ_LOAD_CAPTURE = 4'd3,
        SEQ_START        = 4'd4,
        SEQ_WAIT         = 4'd5,
        SEQ_STORE        = 4'd6,
        SEQ_OUTPUT       = 4'd7,
        SEQ_START_DELAY  = 4'd8
    } seq_state_t;

    seq_state_t seq_state;
    // Cycles to wait in SEQ_START_DELAY before loading each voice, so an
    // in-flight host voice-RAM write to that voice commits first.  A host RMW
    // commits 3 cycles after its pop, and the latest a write to voice V can be
    // popped is the cycle the sequencer leaves voice V-1 (V is not yet the
    // current voice, so the guard allows it).  Two delay cycles push the
    // sequencer's voice-V read (LOAD_WAIT) past that commit and keep the host's
    // port-B access and the sequencer's port-A access on different cycles.
    localparam int SEQ_START_DELAY_CYCLES = 2;
    logic [1:0] seq_start_cnt;
    logic [4:0] seq_voice_idx;
    logic [4:0] seq_voice_rd_addr;

    // Audio accumulators (24-bit signed to sum across all voices)
    logic signed [23:0] acc_left;
    logic signed [23:0] acc_right;

    // Last per-voice sample contributions for simulator/debug UI.
    logic signed [23:0] debug_voice_sample_left [0:NUM_VOICES-1] /* verilator public_flat */;
    logic signed [23:0] debug_voice_sample_right [0:NUM_VOICES-1] /* verilator public_flat */;

    // Sequencer output signals for voice write-back
    logic        seq_voice_wr;      // pulse: write back voice state
    logic [4:0]  seq_wr_idx;        // which voice to write back
    voice_state_t seq_wr_data;      // data to write back

    // Host writes to per-voice/oscillator registers are buffered and committed
    // only when the selected voice is not in the sample sequencer pipeline.
    logic [4:0]  host_voice_wr_voice;
    logic [7:0]  host_voice_wr_reg;
    logic [15:0] host_voice_wr_value;
    logic [1:0]  host_voice_wr_pending; // bit 1 = high byte, bit 0 = low byte
    logic        host_voice_wr_apply;
    voice_state_t host_voice_wr_data;

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
    logic signed [23:0] osc_audio_left;
    logic signed [23:0] osc_audio_right;
    logic        osc_audio_valid;

    assign voice_ram_wren_a = (seq_state == SEQ_STORE);
    assign voice_ram_addr_a = (seq_state == SEQ_STORE) ? seq_voice_idx : seq_voice_rd_addr;
    assign voice_ram_data_a = voice_state_t'(osc_voice_out);

    ics2115_osc u_osc (
        .clk           (clk),
        .ce            (ce_50m),
        .reset_n       (reset_n),
        .clear         (ss_state_write_pulse || (ss_state == SS_VOICE_WRITE_COMMIT)),
        .start         (osc_start),
        .done          (osc_done),
        .irq_osc       (osc_irq_osc),
        .irq_vol       (osc_irq_vol),
        .voice_in      (osc_voice_in),
        .voice_out     (osc_voice_out),
        .rom_byte_addr (osc_rom_byte_addr),
        .rom_rd        (osc_rom_rd),
        .rom_data      (rom_data),
        .rom_data_valid(rom_data_valid),
        .vol_tbl_addr  (osc_vol_tbl_addr),
        .vol_tbl_data  (vol_tbl_data),
        .pan_tbl_addr  (osc_pan_tbl_addr),
        .pan_tbl_data  (pan_tbl_data),
        .audio_left    (osc_audio_left),
        .audio_right   (osc_audio_right),
        .audio_valid   (osc_audio_valid)
    );

    // Connect oscillator table ports to tables module
    assign vol_tbl_addr  = osc_vol_tbl_addr;
    assign pan_tbl_addr  = osc_pan_tbl_addr;

    // ROM address translation: byte address → word address
    assign rom_addr    = osc_rom_byte_addr[23:1];
    assign rom_rd      = osc_rom_rd;
    assign rom_voice_id = seq_voice_idx;

    // Sequencer FSM — drives osc_start, accumulates audio, signals write-back
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            seq_state     <= SEQ_IDLE;
            seq_voice_idx <= 5'd0;
            seq_voice_rd_addr <= 5'd0;
            seq_voice_data <= default_voice_state();
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
            seq_start_cnt <= 2'd0;
            for (int i = 0; i < NUM_VOICES; i++) begin
                debug_voice_sample_left[i] <= 24'sd0;
                debug_voice_sample_right[i] <= 24'sd0;
            end
        end else begin
            // Defaults
            osc_start    <= 1'b0;
            audio_valid  <= 1'b0;
            seq_voice_wr <= 1'b0;

            // Master run gate (0x4D bits 0&2): mute the output to true silence
            // while frozen (hw shows rms=0, not a held value).
            if (!(sys_ctl[0] & sys_ctl[2])) begin
                audio_left  <= 16'sd0;
                audio_right <= 16'sd0;
            end

            if (ss_state_write_pulse || ss_state == SS_VOICE_WRITE_COMMIT) begin
                seq_state <= SEQ_IDLE;
                seq_voice_idx <= 5'd0;
                seq_voice_rd_addr <= 5'd0;
                seq_voice_data <= default_voice_state();
                acc_left <= 24'sd0;
                acc_right <= 24'sd0;
            end else if (ss_busy_local) begin
                // Hold sequencer state while save-state bus owns the voice RAM.
            end else begin
            case (seq_state)
                SEQ_IDLE: begin
                    if (sample_tick) begin
                        seq_voice_idx <= 5'd0;
                        acc_left      <= 24'sd0;
                        acc_right     <= 24'sd0;
                        // Delay before loading voice 0 (see SEQ_START_DELAY).
                        seq_start_cnt <= 2'(SEQ_START_DELAY_CYCLES - 1);
                        seq_state     <= SEQ_START_DELAY;
                    end
                end

                // Wait a couple of cycles before loading the upcoming voice so an
                // in-flight host write to it commits first.
                SEQ_START_DELAY: begin
                    if (seq_start_cnt == 2'd0)
                        seq_state <= SEQ_LOAD_ADDR;
                    else
                        seq_start_cnt <= seq_start_cnt - 2'd1;
                end

                SEQ_LOAD_ADDR: begin
                    seq_voice_rd_addr <= seq_voice_idx;
                    seq_state <= SEQ_LOAD_WAIT;
                end

                SEQ_LOAD_WAIT: begin
                    seq_state <= SEQ_LOAD_CAPTURE;
                end

                SEQ_LOAD_CAPTURE: begin
                    seq_voice_data <= voice_state_t'(voice_ram_q_a);
                    osc_voice_in <= voice_state_t'(voice_ram_q_a);
                    seq_state <= SEQ_START;
                end

                SEQ_START: begin
                    osc_start <= 1'b1;
                    seq_state <= SEQ_WAIT;
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

                    // Accumulate audio and keep the latest contribution for debug UI.
                    acc_left  <= acc_left  + osc_audio_left;
                    acc_right <= acc_right + osc_audio_right;
                    debug_voice_sample_left[seq_voice_idx] <= osc_audio_left;
                    debug_voice_sample_right[seq_voice_idx] <= osc_audio_right;

                    if (seq_voice_idx >= active_osc) begin
                        seq_state <= SEQ_OUTPUT;
                    end else begin
                        seq_voice_idx <= seq_voice_idx + 5'd1;
                        seq_start_cnt <= 2'(SEQ_START_DELAY_CYCLES - 1);
                        seq_state     <= SEQ_START_DELAY;
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
    end

    // =========================================================================
    // Host bus read detection
    // =========================================================================
    logic host_rd_pulse;
    logic host_rd_done_pulse;
    logic host_rd_prev;
    logic host_wr_pulse;
    logic host_wr_prev;

    assign host_rd_pulse = ~host_cs_n & ~host_rd_n & host_rd_prev;
    assign host_wr_pulse = ~host_cs_n & ~host_wr_n & host_wr_prev;
    // Apply read side effects after RD/CS deasserts so host_dout remains stable
    // for the full Z80 read cycle.  Clearing IRQV on the leading edge makes
    // the Z80 sample 0xFF/no-pending instead of the interrupting voice number.
    assign host_rd_done_pulse = (host_cs_n | host_rd_n) & ~host_rd_prev;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            host_rd_prev <= 1'b1;
            host_wr_prev <= 1'b1;
        end else begin
            host_rd_prev <= host_cs_n | host_rd_n;
            host_wr_prev <= host_cs_n | host_wr_n;
        end
    end

    // =========================================================================
    // recalc_irq — combinational IRQ state computation
    // Matches MAME recalc_irq(): scans all 32 voices for pending IRQs
    // =========================================================================
    always_comb begin
        // Hardware model: the timer INT is an event latch (set on fire when
        // the 0x43 enable bit — bit3 = t0, bit4 = t1 — is set; cleared by a
        // 0x43 read), while the pending BIT persists until the 16-bit preset
        // ack.  Voice INT is a level of (pend & per-voice enable & 0x4A gate)
        // — measured: only clearing the enable/condition deasserts it.
        // Hardware (T-SYS isolation 2026-06-13): 0x4D bits 0 AND 2 are the
        // master IRQ/run gate — with them clear, NEITHER timer NOR voice IRQs
        // reach the host (delivery only at 0x4D=0x05).  Timer counting is
        // already gated in the counter block; gate the voice term here too.
        // Hardware (2026-06-18/19): both the osc AND vol INT lines follow the
        // LATCH (osc/vol_irq_pending), NOT the per-voice enable — clearing the
        // enable without an IRQV read still storms; the enable gates the
        // SET/re-assert (in the seq block), not the line.
        irq_on = |timer_int
              | (sys_ctl[0] & sys_ctl[2] & (|irq_enabled) &
                 |(osc_irq_pending | vol_irq_pending));
    end

    assign host_irq = irq_on;

    // =========================================================================
    // IRQV pend model (hardware-measured 2026-06-12): per-voice pends are
    // event latches set by (bit7&bit5) writes or real oscillator events and
    // cleared ONLY by an IRQV read (a persistent end-condition immediately
    // re-latches — observed as the "IRQ storm").  The scan is ROUND-ROBIN
    // starting after the last reported voice; 0x4B shares the scan but does
    // not consume.
    logic       irqv_rr_found;
    logic [4:0] irqv_rr_voice;
    logic       irqv_rr_osc;
    logic       irqv_rr_vol;
    always_comb begin
        irqv_rr_found = 1'b0;
        irqv_rr_voice = 5'd0;
        irqv_rr_osc   = 1'b0;
        irqv_rr_vol   = 1'b0;
        for (int k = 1; k <= NUM_VOICES; k++) begin
            logic [4:0] v;
            v = last_irq_voice + k[4:0];
            if (v <= active_osc && !irqv_rr_found) begin
                if (osc_irq_pending[v] || vol_irq_pending[v]) begin
                    irqv_rr_found = 1'b1;
                    irqv_rr_voice = v;
                    irqv_rr_osc   = osc_irq_pending[v];
                    irqv_rr_vol   = vol_irq_pending[v];
                end
            end
        end
    end

    // Register read mux — matches MAME reg_read() layout
    // =========================================================================
    logic [15:0] reg_read_data;
    logic        irqv_found;  // used in IRQV scan to find first match
    voice_state_t reg_read_voice;
    assign reg_read_voice = host_voice_data;

    always_comb begin
        reg_read_data = 16'd0;
        irqv_found = 0;

        // Selects 0x20-0x3F mirror the voice registers (5-bit decode,
        // hardware-measured: 0x2F reads IRQV, 0x21 reads OscFC, ...).
        if (reg_select < 8'h40) begin
            case (reg_select[4:0])
                // 0x00: Oscillator Configuration 
                5'h00: begin
                    // Full stored byte; bit7 = pend state (hardware-faithful)
                    reg_read_data = { reg_read_voice.osc_conf, 8'hFF };
                end

                // Hardware readback conventions (measured 2026-06-11): voice
                // registers drive only their implemented lanes/bits; everything
                // unimplemented reads as 1 (pulled high).

                // 0x01: Wavesample frequency — bit 0 reads as 1
                5'h01: reg_read_data = {reg_read_voice.osc_fc[15:1], 1'b1};

                // 0x02: Wavesample loop start high (bits 28:13 of 29-bit addr)
                5'h02: reg_read_data = reg_read_voice.osc_start[28:13];

                // 0x03: Wavesample loop start low (bits 12:5 in high byte)
                5'h03: reg_read_data = {reg_read_voice.osc_start[12:5], 8'hFF};

                // 0x04: Wavesample loop end high
                5'h04: reg_read_data = reg_read_voice.osc_end[28:13];

                // 0x05: Wavesample loop end low
                5'h05: reg_read_data = {reg_read_voice.osc_end[12:5], 8'hFF};

                // 0x06: Volume Increment — high byte
                5'h06: reg_read_data = {reg_read_voice.vol_incr, 8'hFF};

                // 0x07: Volume Start — high byte maps to bits 25:18
                5'h07: reg_read_data = {reg_read_voice.vol_start[25:18], 8'hFF};

                // 0x08: Volume End — high byte maps to bits 25:18
                5'h08: reg_read_data = {reg_read_voice.vol_end[25:18], 8'hFF};

                // 0x09: Volume accumulator (bits 25:10 of 26-bit value)
                5'h09: reg_read_data = reg_read_voice.vol_acc[25:10];

                // 0x0A: Wavesample address high (osc_acc bits 28:13)
                5'h0A: reg_read_data = reg_read_voice.osc_acc[28:13];

                // 0x0B: Wavesample address low — bits 2:0 read as 1 on hardware
                5'h0B: reg_read_data = {reg_read_voice.osc_acc[12:0], 3'b111};

                // 0x0C: Pan — only 4 bits stored (16-step table); low nibble reads 1
                5'h0C: reg_read_data = {reg_read_voice.vol_pan[7:4], 4'hF, 8'hFF};

                // 0x0D: Volume Envelope Control — true stored-byte readback
                5'h0D: reg_read_data = {reg_read_voice.vol_ctrl, 8'hFF};

                // 0x0E: Active Voices — 5 bits stored, upper 3 read as 1
                5'h0E: reg_read_data = {3'b111, active_osc, 8'hFF};

                // 0x0F: IRQV — round-robin scan from the last reported voice;
                // reading consumes the reported pend (side effect in the
                // sequential block); idle retains the last reported voice.
                5'h0F: begin
                    if (irqv_rr_found)
                        reg_read_data = {~irqv_rr_osc, ~irqv_rr_vol, 1'b1, irqv_rr_voice, 8'hFF};
                    else
                        reg_read_data = {3'b111, last_irq_voice, 8'hFF};
                end

                // 0x10: Oscillator Control — 2 bits stored, upper 6 read as 1
                5'h10: reg_read_data = {6'b111111, reg_read_voice.osc_ctl[1:0], 8'hFF};

                // 0x11: Wavesample static address — low lane reads 0x3F on
                // hardware (bits 7:6 driven low; saddr may be wider than 8 bits)
                5'h11: reg_read_data = {reg_read_voice.osc_saddr, 8'h3F};

                // 0x12: Per-voice VMode — 4 bits stored (rate[1:0]+phase[3:2])
                5'h12: reg_read_data = {4'hF, reg_read_voice.vol_mode[3:0], 8'hFF};

                // 0x13-0x1F: reserved, read as pulled-high
                default: reg_read_data = 16'hFFFF;
            endcase
        end else begin
            case (reg_select)
                // 0x40-0x42 are write-only on hardware: reads return the open
                // bus value 0x78 on both lanes (the 0x40/0x41 read still acks
                // the timer IRQ — side effect handled separately).
                8'h40: reg_read_data = 16'h7878;
                8'h41: reg_read_data = 16'h7878;
                8'h42: reg_read_data = 16'h7878;

                // 0x43: control bits [7:3] read back, plus pending bits 1:0
                8'h43: reg_read_data = {timer_scale[1][7:3], 1'b0, irq_pending[1:0],
                                        timer_scale[1][7:3], 1'b0, irq_pending[1:0]};

                // 0x4A: reads constant 0x02 on hardware (not pending, not enable)
                8'h4A: reg_read_data = 16'h0202;

                // 0x4B: osc IRQ vector — 0x80|voice while pending (same
                // round-robin scan as IRQV, but non-consuming), else the last
                // event voice with the valid bit clear
                8'h4B: begin
                    if (irqv_rr_found && irqv_rr_osc)
                        reg_read_data = {{1'b1, 2'b00, irqv_rr_voice}, {1'b1, 2'b00, irqv_rr_voice}};
                    else
                        reg_read_data = {{3'b000, last_irq_voice}, {3'b000, last_irq_voice}};
                end

                // 0x4C: Chip Revision (write-insensitive)
                8'h4C: reg_read_data = {CHIP_REVISION, CHIP_REVISION};

                // 0x4D: system control — stored mask 0x05
                8'h4D: reg_read_data = {sys_ctl, sys_ctl};

                // 0x4F: oscillator select reads back
                8'h4F: reg_read_data = {{3'b000, osc_select}, {3'b000, osc_select}};

                // DMA/monitor block constants (hardware-measured; function
                // unprobed beyond reads)
                8'h46: reg_read_data = 16'h4646;
                8'h47: reg_read_data = 16'h0000;
                8'h48: reg_read_data = 16'hC0C0;
                8'h49: reg_read_data = 16'h0000;
                // Undocumented registers above the select map (hardware-measured)
                8'h50: reg_read_data = 16'h7474;
                8'h51: reg_read_data = 16'h4D4D;
                8'h52: reg_read_data = 16'h7D7D;
                8'h53: reg_read_data = 16'h8888;
                8'h54: reg_read_data = 16'h0000;
                8'h55: reg_read_data = 16'h0000;
                8'h56: reg_read_data = 16'h20A0;
                8'h57: reg_read_data = 16'h5050;
                // 0x44/0x45/0x4E and everything else: open bus
                default: reg_read_data = 16'h7878;
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

    // Port 0 status register: compute "any voice has an IRQ pending".
    // Bit 1 must cover BOTH oscillator and volume-envelope IRQs: the PGM Z80
    // drivers dispatch on it (`if (status & 2) -> IRQV drain loop`), and the
    // IRQV service loop handles both sources.  
    logic any_voice_irq;
    always_comb begin
        any_voice_irq = |osc_irq_pending | |vol_irq_pending;
    end

    // IRQV consume pulse: a high-byte read of 0x0F (or its 0x2F mirror).
    // Hardware (2026-06-18 voice_probe): an IRQV read on EITHER byte consumes the
    // reported voice's pend (was high-byte only).
    wire irqv_consume = host_rd_done_pulse && (host_addr == 2'd2 || host_addr == 2'd3) &&
                        reg_select < 8'h40 && reg_select[4:0] == 5'h0F &&
                        irqv_rr_found;

    // Timer IRQ ack: hardware clears pending only on a full 16-bit preset
    // read (a high-byte read immediately following a low-byte read of the
    // same register); lone lo8 or hi8 reads do not ack.
    logic [7:0] prev_rd_reg;
    logic       prev_rd_was_lo;
    logic timer_irq_clear_next [0:1];
    always_comb begin
        timer_irq_clear_next[0] = 1'b0;
        timer_irq_clear_next[1] = 1'b0;
        // Hardware (2026-06-18): reading the timer
        // preset 0x40/0x41 on EITHER byte acks the timer; nothing else does.
        // (Was: required a 16-bit lo-then-hi read, and reading 0x43 cleared it
        // -- both wrong; a game acking with a single 0x40 read storms/hangs.)
        if (host_rd_done_pulse && (host_addr == 2'd2 || host_addr == 2'd3)) begin
            if (reg_select == 8'h40)
                timer_irq_clear_next[0] = 1'b1;
            else if (reg_select == 8'h41)
                timer_irq_clear_next[1] = 1'b1;
        end
    end

    // (Reading 0x43 does NOT ack the timer on hardware -- matrix 43-C.)

    always_comb begin
        case (host_addr)
            2'd0: begin
                // Port 0: IRQ status — MAME read() case 0
                host_dout = 8'd0;
                host_dout[6] = (host_fifo_count != '0) | (|host_voice_wr_pending) | (host_state != HOST_IDLE);  // bit 6: buffered voice write pending
                if (irq_on) begin
                    host_dout[7] = 1'b1;  // bit 7: any IRQ active
                    if (|timer_int)
                        host_dout[0] = 1'b1;  // bit 0: timer INT latched
                    if (any_voice_irq)
                        host_dout[1] = 1'b1;  // bit 1: voice osc IRQ pending
                end
            end
            2'd1: host_dout = reg_select;                    // reg_select echo
            2'd2: host_dout = reg_read_data[7:0];            // low byte
            2'd3: host_dout = reg_read_data[15:8];           // high byte
            default: host_dout = 8'd0;
        endcase
    end

    // host_irq driven by recalc_irq logic above

    function automatic voice_state_t apply_voice_reg_byte(
        input voice_state_t voice,
        input logic [7:0] reg_addr,
        input logic [7:0] data,
        input logic high_byte
    );
        voice_state_t result;
        result = voice;
        if (high_byte) begin
            case (reg_addr[4:0])
                // Hardware: bit7 (pend) only stores when bit5 (IRQ enable) is
                // also written — 0x80 alone is a no-op, 0xA0 pends.
                5'h00: result.osc_conf       = {data[7] & data[5], data[6:0]};
                5'h01: result.osc_fc[15:8]   = data[7:0];
                5'h02: result.osc_start[28:21] = data[7:0];
                5'h03: result.osc_start[12:5]  = data[7:0];
                5'h04: result.osc_end[28:21]   = data[7:0];
                5'h05: result.osc_end[12:5]    = data[7:0];
                5'h06: result.vol_incr         = data[7:0];
                5'h07: result.vol_start        = {data[7:0], 18'd0};
                5'h08: result.vol_end          = {data[7:0], 18'd0};
                5'h09: result.vol_acc[25:18]   = data[7:0];
                5'h0A: result.osc_acc[28:21]   = data[7:0];
                5'h0B: result.osc_acc[12:5]    = data[7:0];
                5'h0C: result.vol_pan          = data[7:0];
                // VCtl stores all 8 bits (hardware echoes bit7) but a host
                // write never latches a vol PEND — the sideband is set from
                // engine event pulses only.
                5'h0D: result.vol_ctrl         = data[7:0];
                5'h10: begin
                    result.osc_ctl = data[7:0];
                end
                5'h11: result.osc_saddr = data[7:0];
                5'h12: result.vol_mode  = data[7:0];
                default: ;
            endcase
        end else begin
            case (reg_addr[4:0])
                5'h01: result.osc_fc[7:0]       = {data[7:1], 1'b0};
                5'h02: result.osc_start[20:13]  = data[7:0];
                5'h04: result.osc_end[20:13]    = data[7:0];
                5'h09: begin
                    result.vol_acc[17:10] = data[7:0];
                    result.vol_acc[9:0]   = 10'd0;
                end
                5'h0A: result.osc_acc[20:13]    = data[7:0];
                5'h0B: result.osc_acc[4:0]      = data[7:3];
                default: ;
            endcase
        end
        return result;
    endfunction

    typedef enum logic [2:0] {
        HOST_INIT = 3'd0,
        HOST_IDLE = 3'd1,
        HOST_WR_WAIT0 = 3'd2,
        HOST_WR_WAIT1 = 3'd3,
        HOST_WR_COMMIT = 3'd4,
        HOST_CLR_WAIT0 = 3'd5,
        HOST_CLR_WAIT1 = 3'd6,
        HOST_CLR_COMMIT = 3'd7
    } host_state_t;

    host_state_t host_state;
    logic [4:0] host_init_idx;
    logic irqv_ram_clear_pending;
    logic [4:0] irqv_ram_clear_voice;
    logic irqv_ram_clear_osc;
    logic irqv_ram_clear_vol;
    voice_state_t irqv_ram_clear_data;

    localparam HOST_FIFO_BITS = 4;
    localparam HOST_FIFO_DEPTH = 1 << HOST_FIFO_BITS;
    logic [4:0] host_fifo_voice [0:HOST_FIFO_DEPTH-1];
    logic [7:0] host_fifo_reg [0:HOST_FIFO_DEPTH-1];
    logic [7:0] host_fifo_data [0:HOST_FIFO_DEPTH-1];
    logic       host_fifo_high [0:HOST_FIFO_DEPTH-1];
    logic [HOST_FIFO_BITS-1:0] host_fifo_head;
    logic [HOST_FIFO_BITS-1:0] host_fifo_tail;
    logic [HOST_FIFO_BITS:0] host_fifo_count;

    wire host_fifo_full = host_fifo_count == HOST_FIFO_DEPTH[HOST_FIFO_BITS:0];
    wire host_fifo_empty = host_fifo_count == '0;

    wire [4:0] host_next_voice = irqv_ram_clear_pending ? irqv_ram_clear_voice :
                                  (host_fifo_empty ? host_voice_wr_voice : host_fifo_voice[host_fifo_head]);
    wire seq_active = (seq_state != SEQ_IDLE) && (seq_state != SEQ_OUTPUT);
    wire host_voice_wr_busy = seq_active && (host_next_voice == seq_voice_idx);
    wire host_fifo_pop_now = (host_state == HOST_IDLE) && !irqv_ram_clear_pending && !host_fifo_empty && !host_voice_wr_busy;

    always_comb begin
        host_voice_wr_data = host_voice_data;
        if (host_voice_wr_pending[1])
            host_voice_wr_data = apply_voice_reg_byte(host_voice_wr_data, host_voice_wr_reg, host_voice_wr_value[15:8], 1'b1);
        if (host_voice_wr_pending[0])
            host_voice_wr_data = apply_voice_reg_byte(host_voice_wr_data, host_voice_wr_reg, host_voice_wr_value[7:0], 1'b0);
    end

    wire host_voice_wr_can_buffer = !host_fifo_full || host_fifo_pop_now;
    // Commit pushes two entries (latched lo + hi) in one cycle.
    wire host_voice_wr_can_buffer2 =
        (host_fifo_count + (host_fifo_pop_now ? 0 : 1)) <= (HOST_FIFO_DEPTH[HOST_FIFO_BITS:0] - 2'd2);
    // Low-byte holding latch for the voice-register write scheme.
    logic [7:0] host_lo_latch;

    assign host_ready = !host_fifo_full;
    assign host_voice_wr_apply = (host_state == HOST_WR_COMMIT);

    always_comb begin
        irqv_ram_clear_data = host_voice_data;
        if (irqv_ram_clear_osc)
            irqv_ram_clear_data.osc_conf[OSC_IRQ_PEND] = 1'b0;
        if (irqv_ram_clear_vol)
            irqv_ram_clear_data.vol_ctrl[VOL_IRQ_PEND] = 1'b0;
    end

    assign voice_ram_addr_b = ss_voice_access_now ? ssbus.addr[7:3] :
                              (ss_state == SS_VOICE_READ_WAIT || ss_state == SS_VOICE_READ_RESP ||
                               ss_state == SS_VOICE_WRITE_WAIT || ss_state == SS_VOICE_WRITE_COMMIT) ? ss_addr_latched[7:3] :
                              (host_state == HOST_INIT) ? host_init_idx :
                              (host_state == HOST_WR_WAIT0 || host_state == HOST_WR_WAIT1 || host_state == HOST_WR_COMMIT) ? host_voice_wr_voice :
                              (host_state == HOST_CLR_WAIT0 || host_state == HOST_CLR_WAIT1 || host_state == HOST_CLR_COMMIT) ? irqv_ram_clear_voice :
                              osc_select;
    assign voice_ram_wren_b = (ss_state == SS_VOICE_WRITE_COMMIT) ||
                              ((host_state == HOST_INIT) || (host_state == HOST_WR_COMMIT) || (host_state == HOST_CLR_COMMIT)) && !ss_busy_local;
    assign voice_ram_data_b = (ss_state == SS_VOICE_WRITE_COMMIT) ? set_voice_word(voice_ram_q_b, ss_addr_latched[2:0], ss_data_latched) :
                              (host_state == HOST_INIT) ? voice_state_t'(default_voice_state()) :
                              (host_state == HOST_CLR_COMMIT) ? voice_state_t'(irqv_ram_clear_data) :
                              voice_state_t'(host_voice_wr_data);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ss_state <= SS_IDLE;
            ss_addr_latched <= 32'd0;
            ss_data_latched <= 32'd0;
            ss_state_write_pulse <= 1'b0;
            ss_state_write_addr <= 32'd0;
            ss_state_write_data <= 32'd0;
        end else begin
            ss_state_write_pulse <= 1'b0;
            ssbus.setup(SS_IDX, SS_WORD_COUNT[31:0], 2);

            case (ss_state)
                SS_IDLE: begin
                    if (ss_access_now) begin
                        ss_addr_latched <= ssbus.addr;
                        ss_data_latched <= ssbus.data[31:0];
                        if (ssbus.addr < VOICE_SS_WORDS[31:0]) begin
                            ss_state <= ssbus.write ? SS_VOICE_WRITE_WAIT : SS_VOICE_READ_WAIT;
                        end else if (ssbus.write) begin
                            ss_state_write_pulse <= 1'b1;
                            ss_state_write_addr <= ssbus.addr;
                            ss_state_write_data <= ssbus.data[31:0];
                            ssbus.write_ack(SS_IDX);
                            ss_state <= SS_WAIT_IDLE;
                        end else begin
                            case (ssbus.addr)
                                SS_WORD_GLOBAL0: ssbus.read_response(SS_IDX, {32'd0, 1'd0, last_irq_voice, vmode, reg_select, osc_select, active_osc});
                                SS_WORD_GLOBAL1: ssbus.read_response(SS_IDX, {32'd0, 8'd0, irq_enabled, irq_pending});
                                SS_WORD_SAMPLE: ssbus.read_response(SS_IDX, {32'd0, 7'd0, ramp_cnt, sample_div_counter});
                                SS_WORD_TIMER0_CFG: ssbus.read_response(SS_IDX, {32'd0, 5'd0, timer_int, sys_ctl, timer_running[0], timer_scale[0], timer_preset[0]});
                                SS_WORD_TIMER0_COUNT: ssbus.read_response(SS_IDX, {40'd0, timer_count[0]});
                                SS_WORD_TIMER0_PERIOD: ssbus.read_response(SS_IDX, {40'd0, timer_period[0]});
                                SS_WORD_TIMER1_CFG: ssbus.read_response(SS_IDX, {32'd0, 15'd0, timer_running[1], timer_scale[1], timer_preset[1]});
                                SS_WORD_TIMER1_COUNT: ssbus.read_response(SS_IDX, {40'd0, timer_count[1]});
                                SS_WORD_TIMER1_PERIOD: ssbus.read_response(SS_IDX, {40'd0, timer_period[1]});
                                SS_WORD_OSC_IRQ_EN: ssbus.read_response(SS_IDX, {32'd0, osc_irq_en});
                                SS_WORD_OSC_IRQ_PENDING: ssbus.read_response(SS_IDX, {32'd0, osc_irq_pending});
                                SS_WORD_VOL_IRQ_EN: ssbus.read_response(SS_IDX, {32'd0, vol_irq_en});
                                SS_WORD_VOL_IRQ_PENDING: ssbus.read_response(SS_IDX, {32'd0, vol_irq_pending});
                                SS_WORD_OSC_ENDED: ssbus.read_response(SS_IDX, {32'd0, osc_ended});
                                SS_WORD_VOL_ENDED: ssbus.read_response(SS_IDX, {32'd0, vol_ended});
                                default: ssbus.read_response(SS_IDX, 64'd0);
                            endcase
                            ss_state <= SS_WAIT_IDLE;
                        end
                    end
                end

                SS_VOICE_READ_WAIT: begin
                    ss_state <= SS_VOICE_READ_RESP;
                end

                SS_VOICE_READ_RESP: begin
                    ssbus.read_response(SS_IDX, {32'd0, get_voice_word(voice_ram_q_b, ss_addr_latched[2:0])});
                    ss_state <= SS_WAIT_IDLE;
                end

                SS_VOICE_WRITE_WAIT: begin
                    ss_state <= SS_VOICE_WRITE_COMMIT;
                end

                SS_VOICE_WRITE_COMMIT: begin
                    ssbus.write_ack(SS_IDX);
                    ss_state <= SS_WAIT_IDLE;
                end

                SS_WAIT_IDLE: begin
                    if (!(ssbus.read || ssbus.write))
                        ss_state <= SS_IDLE;
                end

                default: ss_state <= SS_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Global register, host command, and voice RAM sideband block
    // =========================================================================

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            active_osc <= DEFAULT_ACTIVE_OSC;
            osc_select <= 5'd0;
            reg_select <= 8'd0;
            vmode      <= 8'd0;
            irq_pending <= 8'd0;
            irq_enabled <= 8'd0;
            sys_ctl     <= 8'd0;
            host_lo_latch <= 8'd0;
            timer_int   <= 2'b00;
            last_irq_voice <= 5'd2;  // observed hardware boot value
            prev_rd_reg    <= 8'd0;
            prev_rd_was_lo <= 1'b0;
            timer_irq_clear[0] <= 1'b0;
            timer_irq_clear[1] <= 1'b0;
            host_voice_wr_voice <= 5'd0;
            host_voice_wr_reg <= 8'd0;
            host_voice_wr_value <= 16'd0;
            host_voice_wr_pending <= 2'b00;
            host_state <= HOST_INIT;
            host_init_idx <= 5'd0;
            host_fifo_head <= '0;
            host_fifo_tail <= '0;
            host_fifo_count <= '0;
            irqv_ram_clear_pending <= 1'b0;
            irqv_ram_clear_voice <= 5'd0;
            irqv_ram_clear_osc <= 1'b0;
            irqv_ram_clear_vol <= 1'b0;
            osc_irq_en <= 32'd0;
            osc_irq_pending <= 32'd0;
            osc_ended <= 32'd0;
            vol_ended <= 32'd0;
            vol_irq_en <= 32'd0;
            vol_irq_pending <= 32'd0;
            for (int i = 0; i < 2; i++) begin
                timer_preset[i]   <= 8'd0;
                timer_scale[i]    <= 8'd0;
                timer_count[i]    <= 24'd0;
                timer_period[i]   <= 24'd0;
                timer_running[i]  <= 1'b0;
            end
        end else begin
            if (ss_state_write_pulse) begin
                host_voice_wr_pending <= 2'b00;
                host_fifo_head <= '0;
                host_fifo_tail <= '0;
                host_fifo_count <= '0;
                irqv_ram_clear_pending <= 1'b0;
                host_state <= HOST_IDLE;
                timer_irq_clear[0] <= 1'b0;
                timer_irq_clear[1] <= 1'b0;
                case (ss_state_write_addr)
                    SS_WORD_GLOBAL0: begin
                        active_osc <= ss_state_write_data[4:0];
                        osc_select <= ss_state_write_data[9:5];
                        reg_select <= ss_state_write_data[17:10];
                        vmode <= ss_state_write_data[25:18];
                        last_irq_voice <= ss_state_write_data[30:26];
                    end
                    SS_WORD_GLOBAL1: begin
                        irq_pending <= ss_state_write_data[7:0];
                        irq_enabled <= ss_state_write_data[15:8];
                    end
                    // "running with preset 0" is unrepresentable now (preset=0
                    // stops a timer), but savestates from before that fix can
                    // contain it; sanitize on restore so they don't re-import
                    // a minimum-period IRQ storm.
                    SS_WORD_TIMER0_CFG: begin
                        timer_preset[0] <= ss_state_write_data[7:0];
                        timer_scale[0] <= ss_state_write_data[15:8];
                        timer_running[0] <= ss_state_write_data[16] & |ss_state_write_data[7:0];
                        // Legacy savestates (pre-sys_ctl) carry 0 here; they
                        // were all captured from BIOS-driven flows where the
                        // 0x4D strobe had run, so a running timer implies the
                        // run bit was set.
                        sys_ctl <= |(ss_state_write_data[24:17]) ? (ss_state_write_data[24:17] & 8'h05)
                                 : (ss_state_write_data[16] ? 8'h05 : 8'h00);
                        // INT event latches (legacy states carry 0: one
                        // in-flight tick may be lost at restore, harmless)
                        timer_int <= ss_state_write_data[26:25];
                    end
                    SS_WORD_TIMER0_COUNT: timer_count[0] <= ss_state_write_data[23:0];
                    SS_WORD_TIMER0_PERIOD: timer_period[0] <= ss_state_write_data[23:0];
                    SS_WORD_TIMER1_CFG: begin
                        timer_preset[1] <= ss_state_write_data[7:0];
                        timer_scale[1] <= ss_state_write_data[15:8];
                        timer_running[1] <= ss_state_write_data[16] & |ss_state_write_data[7:0];
                    end
                    SS_WORD_TIMER1_COUNT: timer_count[1] <= ss_state_write_data[23:0];
                    SS_WORD_TIMER1_PERIOD: timer_period[1] <= ss_state_write_data[23:0];
                    SS_WORD_OSC_IRQ_EN: osc_irq_en <= ss_state_write_data;
                    SS_WORD_OSC_IRQ_PENDING: osc_irq_pending <= ss_state_write_data;
                    SS_WORD_VOL_IRQ_EN: vol_irq_en <= ss_state_write_data;
                    SS_WORD_VOL_IRQ_PENDING: vol_irq_pending <= ss_state_write_data;
                    SS_WORD_OSC_ENDED: osc_ended <= ss_state_write_data;
                    SS_WORD_VOL_ENDED: vol_ended <= ss_state_write_data;
                    default: ;
                endcase
            end else if (!ss_busy_local) begin

            if (host_state == HOST_INIT) begin
                if (host_init_idx == 5'd31) begin
                    host_state <= HOST_IDLE;
                end else begin
                    host_init_idx <= host_init_idx + 5'd1;
                end
            end else begin
                case (host_state)
                    HOST_IDLE: begin
                        if (irqv_ram_clear_pending && !host_voice_wr_busy) begin
                            host_state <= HOST_CLR_WAIT0;
                        end else if (host_fifo_pop_now) begin
                            host_voice_wr_voice <= host_fifo_voice[host_fifo_head];
                            host_voice_wr_reg <= host_fifo_reg[host_fifo_head];
                            if (host_fifo_high[host_fifo_head]) begin
                                host_voice_wr_value[15:8] <= host_fifo_data[host_fifo_head];
                                host_voice_wr_pending <= 2'b10;
                            end else begin
                                host_voice_wr_value[7:0] <= host_fifo_data[host_fifo_head];
                                host_voice_wr_pending <= 2'b01;
                            end
                            host_fifo_head <= host_fifo_head + 1'b1;
                            host_fifo_count <= host_fifo_count - 1'b1;
                            host_state <= HOST_WR_WAIT0;
                        end
                    end
                    HOST_WR_WAIT0: host_state <= HOST_WR_WAIT1;
                    HOST_WR_WAIT1: host_state <= HOST_WR_COMMIT;
                    HOST_WR_COMMIT: begin
                        host_voice_wr_pending <= 2'b00;
                        host_state <= HOST_IDLE;
                    end
                    HOST_CLR_WAIT0: host_state <= HOST_CLR_WAIT1;
                    HOST_CLR_WAIT1: host_state <= HOST_CLR_COMMIT;
                    HOST_CLR_COMMIT: begin
                        irqv_ram_clear_pending <= 1'b0;
                        host_state <= HOST_IDLE;
                    end
                    default: host_state <= HOST_IDLE;
                endcase
            end

            // Pends are event latches: writes/events can only SET them (OR);
            // the only clear is the IRQV consume below (which also scrubs the
            // RAM copy via the irqv_ram_clear path).
            if (seq_voice_wr) begin
                osc_irq_en[seq_wr_idx] <= seq_wr_data.osc_conf[OSC_IRQ];
                // Track "reached its end via a real engine event" (one-shot done
                // -> osc_irq_osc with the voice now DONE; NOT a loop boundary,
                // NOT a host key-off which also sets osc_ctl[OSC_DONE]).  Cleared
                // once the voice is not done (restart/playing).
                if (osc_irq_osc && seq_wr_data.osc_ctl[OSC_DONE])
                    osc_ended[seq_wr_idx] <= 1'b1;
                else if (!seq_wr_data.osc_ctl[OSC_DONE])
                    osc_ended[seq_wr_idx] <= 1'b0;
                // osc IRQ is a re-asserting LEVEL (hardware): the end-event pulse
                // sets it, AND it keeps re-asserting while the voice stays ended
                // AND IRQ-enabled (osc_conf bit5).  Driven by the live enable +
                // the real end event (osc_ended), NOT the stale RAM bit7 echo —
                // so once the host clears the enable the re-assert stops and the
                // next IRQV consume clears it for good (no stuck notes).  An IRQV
                // consume the same cycle wins the race (clear below); the next
                // seq pass re-asserts if still ended+enabled = the hardware
                // "clear-enable + IRQV" ack, ~2 passes to beat the write race.
                if (osc_irq_osc ||
                    (osc_ended[seq_wr_idx] && seq_wr_data.osc_conf[OSC_IRQ]))
                    osc_irq_pending[seq_wr_idx] <= 1'b1;
                vol_irq_en[seq_wr_idx] <= seq_wr_data.vol_ctrl[VOL_IRQ];
                // vol IRQ is the same re-asserting LEVEL as osc (hardware
                // 2026-06-19): track the real envelope-end event in vol_ended
                // (set when osc_irq_vol fires with the envelope now VOL_DONE — a
                // non-loop completion; cleared while not-done), and re-assert
                // vol_irq_pending while (vol_ended & VOL_IRQ enable).
                if (osc_irq_vol && seq_wr_data.vol_ctrl[VOL_DONE])
                    vol_ended[seq_wr_idx] <= 1'b1;
                else if (!seq_wr_data.vol_ctrl[VOL_DONE])
                    vol_ended[seq_wr_idx] <= 1'b0;
                if (osc_irq_vol ||
                    (vol_ended[seq_wr_idx] && seq_wr_data.vol_ctrl[VOL_IRQ]))
                    vol_irq_pending[seq_wr_idx] <= 1'b1;
            end

            if (host_voice_wr_apply) begin
                osc_irq_en[host_voice_wr_voice] <= host_voice_wr_data.osc_conf[OSC_IRQ];
                // A host key-on (osc_ctl write leaving the voice not-done)
                // restarts the voice -> clear the "ended" state so it no longer
                // re-asserts.  Hardware: restarting stops the storm, whereas a
                // key-off or an osc_conf write does NOT (matrix modes 8/12) — so
                // only gate on osc_ctl DONE here, not on osc_conf.
                if (!host_voice_wr_data.osc_ctl[OSC_DONE])
                    osc_ended[host_voice_wr_voice] <= 1'b0;
                // A host write to osc_acc (0x0A/0x0B) REPOSITIONS the voice off
                // its previous end -> clear the sticky "ended" state.  The engine
                // never writes osc_acc for a done voice (it skips done voices), so
                // this only fires on a host reposition, never during playback; a
                // genuinely-done voice left untouched (matrix mode 12) keeps
                // storming.  Fixes the phantom osc IRQ when a game re-points a
                // reused voice (new osc_acc) and enables the IRQ BEFORE the
                // key-on: the stale osc_ended would otherwise re-assert in that
                // window before the key-on clears it.
                if (host_voice_wr_reg == 8'h0A || host_voice_wr_reg == 8'h0B)
                    osc_ended[host_voice_wr_voice] <= 1'b0;
                // Host osc pend requires bit7 (PEND) AND bit5 (IRQ enable) together
                // -- hardware RE (matrix 00-C): 0xA0 latches a pend, 0x80 alone is a
                // no-op.  Gating on bit7 alone let a stale bit7 in an osc_conf write
                // spuriously latch a pend.
                osc_irq_pending[host_voice_wr_voice] <= osc_irq_pending[host_voice_wr_voice]
                    | (host_voice_wr_data.osc_conf[OSC_IRQ_PEND] & host_voice_wr_data.osc_conf[OSC_IRQ]);
                vol_irq_en[host_voice_wr_voice] <= host_voice_wr_data.vol_ctrl[VOL_IRQ];
                // A host vol_ctrl write that clears VOL_DONE restarts the envelope
                // -> clear vol_ended (the vol analogue of the osc key-on clear).
                if (!host_voice_wr_data.vol_ctrl[VOL_DONE])
                    vol_ended[host_voice_wr_voice] <= 1'b0;
                // vol analogue: a host write to vol_acc (0x09) reloads the
                // envelope position -> clear vol_ended (same reposition logic).
                if (host_voice_wr_reg == 8'h09)
                    vol_ended[host_voice_wr_voice] <= 1'b0;
                // vol pends are NOT host-settable (hardware: VCtl bit7 writes
                // latch nothing; only real envelope events pend)
            end

            // ── Host bus port writes ──
            if (host_wr_pulse) begin
                case (host_addr)
                    2'd1: begin
                        reg_select <= host_din[7:0];
                    end
                    2'd3: begin
                        // High-byte write — per-voice writes are buffered, globals are direct.
                        // Hardware write scheme for voice registers (measured
                        // 2026-06-12): the low-byte port only LATCHES; the
                        // high-byte write COMMITS {hi, latched_lo} and clears
                        // the latch.  A lone hi8 write therefore commits lo=0,
                        // and a lone lo8 write changes nothing.
                        if (reg_select < 8'h40) begin
                            case (reg_select[4:0])
                                5'h0E: active_osc <= host_din[4:0];
                                default: begin
                                    if (host_voice_wr_can_buffer2) begin
                                        host_fifo_voice[host_fifo_tail] <= osc_select;
                                        host_fifo_reg[host_fifo_tail] <= reg_select;
                                        host_fifo_data[host_fifo_tail] <= host_lo_latch;
                                        host_fifo_high[host_fifo_tail] <= 1'b0;
                                        host_fifo_voice[host_fifo_tail + 1'b1] <= osc_select;
                                        host_fifo_reg[host_fifo_tail + 1'b1] <= reg_select;
                                        host_fifo_data[host_fifo_tail + 1'b1] <= host_din[7:0];
                                        host_fifo_high[host_fifo_tail + 1'b1] <= 1'b1;
                                        host_fifo_tail <= host_fifo_tail + 2'd2;
                                        host_fifo_count <= host_fifo_pop_now ? (host_fifo_count + 1'b1) : (host_fifo_count + 2'd2);
                                        host_lo_latch <= 8'd0;
                                    end
                                end
                            endcase
                        end else begin
                            case (reg_select)
                                // No high-byte global registers currently
                                default: ;
                            endcase
                        end
                    end
                    2'd2: begin
                        // Low-byte write — voice registers only latch the byte
                        // (committed by the next high-byte write); globals are direct.
                        if (reg_select < 8'h40) begin
                            case (reg_select[4:0])
                                5'h0E: ;
                                default: host_lo_latch <= host_din[7:0];
                            endcase
                        end else begin
                            case (reg_select)
                                // A preset of 0 STOPS the timer: the Turtle Beach
                                // WaveFront firmware disarms timers by writing
                                // preset=0 (including from its own IRQ handler) and
                                // arms a deferred-service alarm with preset=1.
                                // Hardware timer model (measured 2026-06-11):
                                //   timer 0: period = ((scale0[4:0]+1)*(preset0+1)) << (4+scale0[7:5]);
                                //            stops when preset==0 OR scale mult field==0
                                //   timer 1: period = (preset1+1) << (4+ctl[7:5]) — shift-only, no mult
                                //   0x43 (stored in timer_scale[1]) is the control byte:
                                //            [7:5]=t1 shift, bit4=t1 IRQ enable, bit3=t0 IRQ enable
                                8'h40: begin
                                    timer_preset[0] <= host_din[7:0];
                                    timer_period[0] <= (({19'd0, timer_scale[0][4:0]} + 24'd1) * ({16'd0, host_din[7:0]} + 24'd1)) << (4 + timer_scale[0][7:5]);
                                    timer_count[0]  <= (({19'd0, timer_scale[0][4:0]} + 24'd1) * ({16'd0, host_din[7:0]} + 24'd1)) << (4 + timer_scale[0][7:5]);
                                    timer_running[0] <= |host_din[7:0] && |timer_scale[0][4:0];
                                    // Stopping via preset=0 clears pending + INT (hw)
                                    if (host_din[7:0] == 8'd0) begin
                                        irq_pending[0] <= 1'b0;
                                        timer_int[0] <= 1'b0;
                                    end
                                end
                                8'h41: begin
                                    timer_preset[1] <= host_din[7:0];
                                    timer_period[1] <= ({16'd0, host_din[7:0]} + 24'd1) << (4 + timer_scale[1][7:5]);
                                    timer_count[1]  <= ({16'd0, host_din[7:0]} + 24'd1) << (4 + timer_scale[1][7:5]);
                                    // timer 1 runs only with the 0x43 bit4 enable
                                    timer_running[1] <= |host_din[7:0] && timer_scale[1][4];
                                    if (host_din[7:0] == 8'd0) begin
                                        irq_pending[1] <= 1'b0;
                                        timer_int[1] <= 1'b0;
                                    end
                                end
                                8'h42: begin
                                    timer_scale[0] <= host_din[7:0];
                                    timer_period[0] <= (({19'd0, host_din[4:0]} + 24'd1) * ({16'd0, timer_preset[0]} + 24'd1)) << (4 + host_din[7:5]);
                                    timer_count[0]  <= (({19'd0, host_din[4:0]} + 24'd1) * ({16'd0, timer_preset[0]} + 24'd1)) << (4 + host_din[7:5]);
                                    timer_running[0] <= |timer_preset[0] && |host_din[4:0];
                                end
                                8'h43: begin
                                    timer_scale[1] <= host_din[7:0];
                                    timer_period[1] <= ({16'd0, timer_preset[1]} + 24'd1) << (4 + host_din[7:5]);
                                    timer_count[1]  <= ({16'd0, timer_preset[1]} + 24'd1) << (4 + host_din[7:5]);
                                    timer_running[1] <= |timer_preset[1] && host_din[4];
                                    // Enabling with pending already latched delivers
                                    // the INT (hardware: latched_delivery test).
                                    if (host_din[3] && irq_pending[0])
                                        timer_int[0] <= 1'b1;
                                    if (host_din[4] && irq_pending[1])
                                        timer_int[1] <= 1'b1;
                                end
                                // 0x4A: voice-IRQ output gate (NOT a timer enable)
                                8'h4A: irq_enabled <= host_din[7:0];
                                // 0x4D: system control — stores bits 0 and 2 only;
                                // bit 0 gates timer counting
                                8'h4D: sys_ctl <= host_din[7:0] & 8'h05;
                                8'h4F: osc_select <= host_din[4:0];
                                default: ;
                            endcase
                        end
                    end
                    default: ;
                endcase
            end

            // ── IRQV consume: clear the reported voice's pends, remember it ──
            // (placed after the write-apply blocks so the clear wins the
            //  same-cycle race against an OR-set)
            if (irqv_consume) begin
                last_irq_voice <= irqv_rr_voice;
                osc_irq_pending[irqv_rr_voice] <= 1'b0;
                vol_irq_pending[irqv_rr_voice] <= 1'b0;
                irqv_ram_clear_pending <= 1'b1;
                irqv_ram_clear_voice <= irqv_rr_voice;
                irqv_ram_clear_osc <= irqv_rr_osc;
                irqv_ram_clear_vol <= irqv_rr_vol;
            end

            // Track read sequencing for the 16-bit timer ack condition.
            if (host_rd_done_pulse && (host_addr == 2'd2 || host_addr == 2'd3)) begin
                prev_rd_reg    <= reg_select;
                prev_rd_was_lo <= (host_addr == 2'd2);
            end

            // ── Timer IRQ ack side-effect ──
            // Register the clear request, apply one cycle later
            timer_irq_clear[0] <= timer_irq_clear_next[0];
            timer_irq_clear[1] <= timer_irq_clear_next[1];

            // A 0x40/0x41 read (either byte) acks the timer: clear BOTH the raw
            // pending (0x43-register bit) and the enable-gated INT latch (line).
            if (timer_irq_clear[0]) begin
                irq_pending[0] <= 1'b0;
                timer_int[0]   <= 1'b0;
            end
            if (timer_irq_clear[1]) begin
                irq_pending[1] <= 1'b0;
                timer_int[1]   <= 1'b0;
            end

            // ── Timer counter logic ──
            // Hardware (T-SYS 2026-06-13): timer counting requires 0x4D bits 0
            // AND 2 both set (0x01 alone does not run; 0x05 does).  The BIOS
            // post-init state 0x0D has both, so games are unaffected.
            if (ce && sys_ctl[0] && sys_ctl[2]) begin
                for (int t = 0; t < 2; t++) begin
                    if (timer_running[t]) begin
                        if (timer_count[t] == 24'd0) begin
                            // Timer expired: set pending + INT latch, reload
                            irq_pending[t] <= 1'b1;
                            if (timer_scale[1][3 + t])
                                timer_int[t] <= 1'b1;
                            timer_count[t] <= timer_period[t] - 24'd1;
                        end else begin
                            timer_count[t] <= timer_count[t] - 24'd1;
                        end
                    end
                end
            end
            end
        end
    end

endmodule
