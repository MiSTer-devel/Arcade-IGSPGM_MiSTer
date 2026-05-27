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
    logic [31:0] vol_irq_en;
    logic [31:0] vol_irq_pending;

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
    localparam int SS_WORD_COUNT = SS_STATE_BASE + 13;

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
                && !(irqv_clear_osc || irqv_clear_vol)
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

    // =========================================================================
    // IRQ system registers
    // =========================================================================
    logic [7:0] irq_pending;    // system IRQ pending bitmap (bits 0-1 = timers)
    logic [7:0] irq_enabled;    // system IRQ enable mask (register 0x4A write)
    logic       irq_on;         // computed IRQ state

    // IRQV auto-clear side-effect signals (registered — cleared after the host read cycle completes)
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
            if (ss_state_write_pulse && ss_state_write_addr == SS_WORD_SAMPLE) begin
                sample_div_counter <= ss_state_write_data[15:0];
            end else if (!ss_busy_local && ce) begin
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
        SEQ_OUTPUT       = 4'd7
    } seq_state_t;

    seq_state_t seq_state;
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
    logic [7:0]  osc_ulaw_tbl_addr;
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
            for (int i = 0; i < NUM_VOICES; i++) begin
                debug_voice_sample_left[i] <= 24'sd0;
                debug_voice_sample_right[i] <= 24'sd0;
            end
        end else begin
            // Defaults
            osc_start    <= 1'b0;
            audio_valid  <= 1'b0;
            seq_voice_wr <= 1'b0;

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
                        seq_voice_rd_addr <= 5'd0;
                        acc_left      <= 24'sd0;
                        acc_right     <= 24'sd0;
                        seq_state     <= SEQ_LOAD_ADDR;
                    end
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
                        seq_voice_rd_addr <= seq_voice_idx + 5'd1;
                        seq_state     <= SEQ_LOAD_ADDR;
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
        irq_on = |(irq_pending & irq_enabled)
              | |((osc_irq_en & osc_irq_pending) | (vol_irq_en & vol_irq_pending));
    end

    assign host_irq = irq_on;

    // =========================================================================
    // Register read mux — matches MAME reg_read() layout
    // =========================================================================
    logic [15:0] reg_read_data;
    logic        irqv_found;  // used in IRQV scan to find first match
    voice_state_t reg_read_voice;
    assign reg_read_voice = host_voice_data;

    always_comb begin
        reg_read_data = 16'd0;
        irqv_found = 0;

        if (reg_select < 8'h20) begin
            case (reg_select[4:0])
                // 0x00: Oscillator Configuration 
                5'h00: begin
                    reg_read_data = { reg_read_voice.osc_conf, 8'h00 };
                end

                // 0x01: Wavesample frequency (16-bit, no shift)
                5'h01: reg_read_data = reg_read_voice.osc_fc;

                // 0x02: Wavesample loop start high (bits 28:13 of 29-bit addr)
                5'h02: reg_read_data = reg_read_voice.osc_start[28:13];

                // 0x03: Wavesample loop start low (bits 12:5 in high byte)
                5'h03: reg_read_data = {reg_read_voice.osc_start[12:5], 8'h00};

                // 0x04: Wavesample loop end high
                5'h04: reg_read_data = reg_read_voice.osc_end[28:13];

                // 0x05: Wavesample loop end low
                5'h05: reg_read_data = {reg_read_voice.osc_end[12:5], 8'h00};

                // 0x06: Volume Increment — high byte
                5'h06: reg_read_data = {reg_read_voice.vol_incr, 8'h00};

                // 0x07: Volume Start — high byte maps to bits 25:18
                5'h07: reg_read_data = {reg_read_voice.vol_start[25:18], 8'h00};

                // 0x08: Volume End — high byte maps to bits 25:18
                5'h08: reg_read_data = {reg_read_voice.vol_end[25:18], 8'h00};

                // 0x09: Volume accumulator (bits 25:10 of 26-bit value)
                5'h09: reg_read_data = reg_read_voice.vol_acc[25:10];

                // 0x0A: Wavesample address high (osc_acc bits 28:13)
                5'h0A: reg_read_data = reg_read_voice.osc_acc[28:13];

                // 0x0B: Wavesample address low — MAME returns (acc >> 0) & 0xFFF8
                // Our 29-bit acc maps: MAME bits [15:3] → our bits [12:0]
                // Mask 0xFFF8 clears bottom 3 bits. Return {osc_acc[12:0], 3'b000}.
                5'h0B: reg_read_data = {reg_read_voice.osc_acc[12:0], 3'b000};

                // 0x0C: Pan — pan value in high byte
                5'h0C: reg_read_data = {reg_read_voice.vol_pan, 8'h00};

                // 0x0D: Volume Envelope Control — stub for T02 IRQ work
                5'h0D: begin
                    if (reg_read_voice.vol_mode[1:0] == 2'd0)
                        reg_read_data = {(reg_read_voice.vol_ctrl[VOL_IRQ] ? 8'h81 : 8'h01), 8'h00};
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
                            if (osc_irq_pending[i] || vol_irq_pending[i]) begin
                                irqv_found = 1'b1;
                                reg_read_data[15:8] = {3'b111, i[4:0]};
                                if (osc_irq_pending[i])
                                    reg_read_data[15] = 1'b0;  // clear bit 7 = osc source
                                if (vol_irq_pending[i])
                                    reg_read_data[14] = 1'b0;  // clear bit 6 = vol source
                            end
                        end
                    end
                end

                // 0x10: Oscillator Control — osc_ctl in high byte
                5'h10: reg_read_data = {6'b111111, reg_read_voice.osc_ctl[1:0], 8'h00};

                // 0x11: Wavesample static address — saddr in high byte
                5'h11: reg_read_data = {reg_read_voice.osc_saddr, 8'h00};

                // 0x12: Per-voice VMode — only low two bits affect the rate family
                5'h12: reg_read_data = {reg_read_voice.vol_mode, 8'h00};

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
        any_voice_osc_irq = |osc_irq_pending;
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
        if (host_rd_done_pulse && host_addr == 2'd3 && reg_select == 8'h0F) begin
            for (int i = 0; i < NUM_VOICES; i++) begin
                if (i[4:0] <= active_osc && !irqv_clear_found) begin
                    if (osc_irq_pending[i] || vol_irq_pending[i]) begin
                        irqv_clear_found      = 1'b1;
                        irqv_clear_voice_next = i[4:0];
                        irqv_clear_osc_next   = osc_irq_pending[i];
                        irqv_clear_vol_next   = vol_irq_pending[i];
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
        if (host_rd_done_pulse && (host_addr == 2'd2 || host_addr == 2'd3)) begin
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
                host_dout[6] = (host_fifo_count != '0) | (|host_voice_wr_pending) | (host_state != HOST_IDLE);  // bit 6: buffered voice write pending
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
                5'h00: result.osc_conf[6:0]  = data[6:0];
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
                5'h0D: result.vol_ctrl[6:0]    = data[6:0];
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
    wire host_voice_wr_busy = (seq_state != SEQ_IDLE && seq_state != SEQ_OUTPUT)
                           && (host_next_voice == seq_voice_idx);
    wire host_fifo_pop_now = (host_state == HOST_IDLE) && !irqv_ram_clear_pending && !host_fifo_empty && !host_voice_wr_busy;

    always_comb begin
        host_voice_wr_data = host_voice_data;
        if (host_voice_wr_pending[1])
            host_voice_wr_data = apply_voice_reg_byte(host_voice_wr_data, host_voice_wr_reg, host_voice_wr_value[15:8], 1'b1);
        if (host_voice_wr_pending[0])
            host_voice_wr_data = apply_voice_reg_byte(host_voice_wr_data, host_voice_wr_reg, host_voice_wr_value[7:0], 1'b0);
    end

    wire host_voice_wr_can_buffer = !host_fifo_full || host_fifo_pop_now;

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
                                SS_WORD_GLOBAL0: ssbus.read_response(SS_IDX, {32'd0, 8'd0, vmode, reg_select, osc_select, active_osc});
                                SS_WORD_GLOBAL1: ssbus.read_response(SS_IDX, {32'd0, 8'd0, irq_enabled, irq_pending});
                                SS_WORD_SAMPLE: ssbus.read_response(SS_IDX, {32'd0, 7'd0, ramp_cnt, sample_div_counter});
                                SS_WORD_TIMER0_CFG: ssbus.read_response(SS_IDX, {32'd0, 15'd0, timer_running[0], timer_scale[0], timer_preset[0]});
                                SS_WORD_TIMER0_COUNT: ssbus.read_response(SS_IDX, {40'd0, timer_count[0]});
                                SS_WORD_TIMER0_PERIOD: ssbus.read_response(SS_IDX, {40'd0, timer_period[0]});
                                SS_WORD_TIMER1_CFG: ssbus.read_response(SS_IDX, {32'd0, 15'd0, timer_running[1], timer_scale[1], timer_preset[1]});
                                SS_WORD_TIMER1_COUNT: ssbus.read_response(SS_IDX, {40'd0, timer_count[1]});
                                SS_WORD_TIMER1_PERIOD: ssbus.read_response(SS_IDX, {40'd0, timer_period[1]});
                                SS_WORD_OSC_IRQ_EN: ssbus.read_response(SS_IDX, {32'd0, osc_irq_en});
                                SS_WORD_OSC_IRQ_PENDING: ssbus.read_response(SS_IDX, {32'd0, osc_irq_pending});
                                SS_WORD_VOL_IRQ_EN: ssbus.read_response(SS_IDX, {32'd0, vol_irq_en});
                                SS_WORD_VOL_IRQ_PENDING: ssbus.read_response(SS_IDX, {32'd0, vol_irq_pending});
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
            irqv_clear_osc   <= 1'b0;
            irqv_clear_vol   <= 1'b0;
            irqv_clear_voice <= 5'd0;
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
                irqv_clear_osc <= 1'b0;
                irqv_clear_vol <= 1'b0;
                timer_irq_clear[0] <= 1'b0;
                timer_irq_clear[1] <= 1'b0;
                case (ss_state_write_addr)
                    SS_WORD_GLOBAL0: begin
                        active_osc <= ss_state_write_data[4:0];
                        osc_select <= ss_state_write_data[9:5];
                        reg_select <= ss_state_write_data[17:10];
                        vmode <= ss_state_write_data[25:18];
                    end
                    SS_WORD_GLOBAL1: begin
                        irq_pending <= ss_state_write_data[7:0];
                        irq_enabled <= ss_state_write_data[15:8];
                    end
                    SS_WORD_TIMER0_CFG: begin
                        timer_preset[0] <= ss_state_write_data[7:0];
                        timer_scale[0] <= ss_state_write_data[15:8];
                        timer_running[0] <= ss_state_write_data[16];
                    end
                    SS_WORD_TIMER0_COUNT: timer_count[0] <= ss_state_write_data[23:0];
                    SS_WORD_TIMER0_PERIOD: timer_period[0] <= ss_state_write_data[23:0];
                    SS_WORD_TIMER1_CFG: begin
                        timer_preset[1] <= ss_state_write_data[7:0];
                        timer_scale[1] <= ss_state_write_data[15:8];
                        timer_running[1] <= ss_state_write_data[16];
                    end
                    SS_WORD_TIMER1_COUNT: timer_count[1] <= ss_state_write_data[23:0];
                    SS_WORD_TIMER1_PERIOD: timer_period[1] <= ss_state_write_data[23:0];
                    SS_WORD_OSC_IRQ_EN: osc_irq_en <= ss_state_write_data;
                    SS_WORD_OSC_IRQ_PENDING: osc_irq_pending <= ss_state_write_data;
                    SS_WORD_VOL_IRQ_EN: vol_irq_en <= ss_state_write_data;
                    SS_WORD_VOL_IRQ_PENDING: vol_irq_pending <= ss_state_write_data;
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

            if (seq_voice_wr) begin
                osc_irq_en[seq_wr_idx] <= seq_wr_data.osc_conf[OSC_IRQ];
                osc_irq_pending[seq_wr_idx] <= seq_wr_data.osc_conf[OSC_IRQ_PEND];
                vol_irq_en[seq_wr_idx] <= seq_wr_data.vol_ctrl[VOL_IRQ];
                vol_irq_pending[seq_wr_idx] <= seq_wr_data.vol_ctrl[VOL_IRQ_PEND];
            end

            if (host_voice_wr_apply) begin
                osc_irq_en[host_voice_wr_voice] <= host_voice_wr_data.osc_conf[OSC_IRQ];
                osc_irq_pending[host_voice_wr_voice] <= host_voice_wr_data.osc_conf[OSC_IRQ_PEND];
                vol_irq_en[host_voice_wr_voice] <= host_voice_wr_data.vol_ctrl[VOL_IRQ];
                vol_irq_pending[host_voice_wr_voice] <= host_voice_wr_data.vol_ctrl[VOL_IRQ_PEND];
            end

            // ── Host bus port writes ──
            if (host_wr_pulse) begin
                case (host_addr)
                    2'd1: begin
                        reg_select <= host_din[7:0];
                    end
                    2'd3: begin
                        // High-byte write — per-voice writes are buffered, globals are direct.
                        if (reg_select < 8'h20) begin
                            case (reg_select[4:0])
                                5'h0E: active_osc <= host_din[4:0];
                                default: begin
                                    if (host_voice_wr_can_buffer) begin
                                        host_fifo_voice[host_fifo_tail] <= osc_select;
                                        host_fifo_reg[host_fifo_tail] <= reg_select;
                                        host_fifo_data[host_fifo_tail] <= host_din[7:0];
                                        host_fifo_high[host_fifo_tail] <= 1'b1;
                                        host_fifo_tail <= host_fifo_tail + 1'b1;
                                        host_fifo_count <= host_fifo_pop_now ? host_fifo_count : (host_fifo_count + 1'b1);
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
                        // Low-byte write — per-voice writes are buffered, globals are direct.
                        if (reg_select < 8'h20) begin
                            case (reg_select[4:0])
                                5'h0E: ;
                                default: begin
                                    if (host_voice_wr_can_buffer) begin
                                        host_fifo_voice[host_fifo_tail] <= osc_select;
                                        host_fifo_reg[host_fifo_tail] <= reg_select;
                                        host_fifo_data[host_fifo_tail] <= host_din[7:0];
                                        host_fifo_high[host_fifo_tail] <= 1'b0;
                                        host_fifo_tail <= host_fifo_tail + 1'b1;
                                        host_fifo_count <= host_fifo_pop_now ? host_fifo_count : (host_fifo_count + 1'b1);
                                    end
                                end
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

            // Apply the clear from the PREVIOUS cycle's registered values.
            // IRQ status is tracked in sideband bitmaps so IRQV does not need
            // a combinational scan of the RAM-backed voice state.
            if (irqv_clear_osc || irqv_clear_vol) begin
                irqv_ram_clear_pending <= 1'b1;
                irqv_ram_clear_voice <= irqv_clear_voice;
                irqv_ram_clear_osc <= irqv_clear_osc;
                irqv_ram_clear_vol <= irqv_clear_vol;
            end
            if (irqv_clear_osc)
                osc_irq_pending[irqv_clear_voice] <= 1'b0;
            if (irqv_clear_vol)
                vol_irq_pending[irqv_clear_voice] <= 1'b0;

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
    end

endmodule
