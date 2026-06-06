// IGS022 encrypted-DMA protection device (The Killing Blade, Dragon World 3).
// Converted from MAME src/mame/igs/igs022.cpp.  copyright-holders: David Haywood, ElSemi.

import system_consts::*;

module igs022 #(
    parameter int SS_IDX = -1,            // engine regs/stack/stack_ptr
    parameter int SS_IDX_RAM_LO = -1,     // shared RAM low bytes
    parameter int SS_IDX_RAM_HI = -1      // shared RAM high bytes
)(
    input  logic        clk,
    input  logic        reset,

    input  logic        trigger,        // 1-cycle pulse from IGS025
    output logic        busy,           // high from trigger until command completes

    // 68000 access to the shared protection RAM (port A).
    input  logic [12:0] cpu_word_addr,  // word index into the 8K-word RAM
    input  logic [15:0] cpu_din,
    output logic [15:0] cpu_dout,
    input  logic        cpu_uds_n,
    input  logic        cpu_lds_n,
    input  logic        cpu_rw,         // 1 = read, 0 = write
    input  logic        cpu_cs_n,

    // Shared DDR protection cache: private 64KB data ROM in DDR at
    // PROT_ROM_DDR_BASE (shared with igs027a, mutually exclusive per game).
    output logic [31:0] cache_addr,
    output logic        cache_req,
    input  logic [31:0] cache_rdata,
    input  logic        cache_ready,

    ssbus_if.slave ssbus,
    ssbus_if.slave ss_ram_lo,
    ssbus_if.slave ss_ram_hi
);

    // Shared protection RAM: byte-wide hi/lo dual-port RAMs.  68000 does UDS/LDS
    // byte writes on port A; engine reads/writes full words on port B.
    logic [12:0] eng_sh_addr;
    logic        eng_sh_we;
    logic [15:0] eng_sh_wdata;
    logic [15:0] eng_sh_rdata;

    wire cpu_we_hi = ~cpu_cs_n & ~cpu_rw & ~cpu_uds_n;
    wire cpu_we_lo = ~cpu_cs_n & ~cpu_rw & ~cpu_lds_n;
    wire [7:0] cpu_q_hi, cpu_q_lo;
    wire [7:0] eng_q_hi, eng_q_lo;

    // Port B routed through ram_ss_adaptors so the savestate machine can r/w the
    // whole shared RAM (CPU paused + engine idle during savestate).
    wire [12:0] pbhi_addr, pblo_addr;
    wire        pbhi_we, pblo_we;
    wire [7:0]  pbhi_data, pblo_data;

    ram_ss_adaptor #(.WIDTH(8), .WIDTHAD(13), .SS_IDX(SS_IDX_RAM_HI)) sram_hi_ss(
        .clk,
        .wren_in(eng_sh_we), .addr_in(eng_sh_addr), .data_in(eng_sh_wdata[15:8]),
        .wren_out(pbhi_we), .addr_out(pbhi_addr), .data_out(pbhi_data),
        .q(eng_q_hi), .ssbus(ss_ram_hi)
    );
    ram_ss_adaptor #(.WIDTH(8), .WIDTHAD(13), .SS_IDX(SS_IDX_RAM_LO)) sram_lo_ss(
        .clk,
        .wren_in(eng_sh_we), .addr_in(eng_sh_addr), .data_in(eng_sh_wdata[7:0]),
        .wren_out(pblo_we), .addr_out(pblo_addr), .data_out(pblo_data),
        .q(eng_q_lo), .ssbus(ss_ram_lo)
    );

    dualport_ram_unreg #(.WIDTH(8), .WIDTHAD(13)) sharedram_hi(
        .clock_a(clk), .wren_a(cpu_we_hi), .address_a(cpu_word_addr), .data_a(cpu_din[15:8]), .q_a(cpu_q_hi),
        .clock_b(clk), .wren_b(pbhi_we),   .address_b(pbhi_addr),     .data_b(pbhi_data),      .q_b(eng_q_hi)
    );
    dualport_ram_unreg #(.WIDTH(8), .WIDTHAD(13)) sharedram_lo(
        .clock_a(clk), .wren_a(cpu_we_lo), .address_a(cpu_word_addr), .data_a(cpu_din[7:0]),  .q_a(cpu_q_lo),
        .clock_b(clk), .wren_b(pblo_we),   .address_b(pblo_addr),     .data_b(pblo_data),      .q_b(eng_q_lo)
    );

    assign cpu_dout      = {cpu_q_hi, cpu_q_lo};
    assign eng_sh_rdata  = {eng_q_hi, eng_q_lo};

    // Private 64KB data ROM in DDR, served by prot_cache.  Engine reads single
    // bytes; rom_byte extracts the addressed byte from the 32-bit word.  Reads
    // have variable latency, so the ROM-read states spin until cache_ready.
    logic [15:0] eng_rom_addr;
    wire  [7:0]  rom_byte = cache_rdata[{cache_addr[1:0], 3'b000} +: 8];

    // Engine state.  regs[768] and stack[256] are block RAM (see regs/stack below).
    logic [7:0]  stack_ptr;

    // Shared-RAM word indices (byte offset / 2).
    localparam logic [12:0] A_CMD   = 13'h100; // 0x200
    localparam logic [12:0] A_STAT  = 13'h101; // 0x202
    localparam logic [12:0] A_288   = 13'h144;
    localparam logic [12:0] A_28A   = 13'h145;
    localparam logic [12:0] A_28C   = 13'h146;
    localparam logic [12:0] A_28E   = 13'h147;
    localparam logic [12:0] A_290   = 13'h148;
    localparam logic [12:0] A_292   = 13'h149;
    localparam logic [12:0] A_294   = 13'h14a;
    localparam logic [12:0] A_296   = 13'h14b;
    localparam logic [12:0] A_298   = 13'h14c;
    localparam logic [12:0] A_29A   = 13'h14d;
    localparam logic [12:0] A_29C   = 13'h14e;
    localparam logic [12:0] A_29E   = 13'h14f;
    localparam logic [12:0] A_2A2   = 13'h151;

    // ROM word indices for the reset auto-DMA params.
    localparam logic [15:0] W_100 = 16'h0080;
    localparam logic [15:0] W_102 = 16'h0081;
    localparam logic [15:0] W_104 = 16'h0082;
    localparam logic [15:0] W_106 = 16'h0083;
    localparam logic [15:0] W_114 = 16'h008a;

    typedef enum logic [5:0] {
        S_IDLE,
        // generic micro-ops
        RDSH_SET, RDSH_GET,
        WRSH,
        WRREG, WRSTK,
        RDRW_SET0, RDRW_GET0, RDRW_GET1,
        RDTB_SET, RDTB_G0, RDTB_G1,
        // reset / auto-DMA init
        S_INIT_FILL,
        S_INIT_SRC, S_INIT_DST, S_INIT_SIZE, S_INIT_MODE,
        S_INIT_VER, S_INIT_VER2,
        // command dispatch
        S_CMD_RD, S_CMD_DECODE,
        S_PUSH_RDH, S_PUSH_RDL, S_PUSH_DO,
        S_POP, S_POP_WH, S_POP_WL, S_POP_STAT,
        S_DMA_RDSRC, S_DMA_RDDST, S_DMA_RDSIZE, S_DMA_RDMODE, S_DMA_START,
        S_6D_RD_298, S_6D_RD_29A, S_6D_RD_29C, S_6D_RD_29E, S_6D_DO, S_6D_GET_WH, S_6D_GET_WL,
        // dma loop
        DMA_CHECK, DMA_AFTER_WORD, DMA_AFTER_TAB, DMA_WRITE, DMA_NEXT,
        S_SETSTAT
    } state_t;

    state_t state, ret_state;

    logic [12:0] m_sh_addr;
    logic [15:0] m_w;        // rom word index for RDRW
    logic [15:0] m_b;        // rom byte addr for RDTB
    logic [15:0] rd_word;    // result of RDSH / RDRW / RDTB
    logic [15:0] wr_word;    // data for WRSH
    logic [15:0] status_val;

    logic [12:0] fill_idx;
    logic        init_active;

    // DMA working set
    logic [15:0] dma_src, dma_dst, dma_size, dma_x;
    logic [2:0]  dma_mode;
    logic [7:0]  dma_param;
    logic [15:0] dma_dat;

    // command-6d working set
    logic [15:0] p1hi, p1lo, p2hi, p2lo;
    logic [15:0] push_hi;
    logic [31:0] pop_data;

    // helpers
    function automatic logic [15:0] byteswap(input logic [15:0] d);
        return {d[7:0], d[15:8]};
    endfunction
    function automatic logic [15:0] nibbleswap(input logic [15:0] d);
        return {d[11:8], d[15:12], d[3:0], d[7:4]};
    endfunction
    // mode-4 fixed 'IGS ' pattern
    function automatic logic [15:0] mode4_xor(input logic [15:0] x);
        logic [7:0] lo, hi;
        unique case (x[1:0])
            2'd0: lo = 8'h49; 2'd1: lo = 8'h47; 2'd2: lo = 8'h53; default: lo = 8'h20;
        endcase
        unique case (x[9:8])
            2'd0: hi = 8'h49; 2'd1: hi = 8'h47; 2'd2: hi = 8'h53; default: hi = 8'h20;
        endcase
        return {hi, lo};
    endfunction
    wire [7:0] dma_taboff = (({dma_x[6:0], 1'b0}) + dma_param);  // ((x*2)+param)&0xff

    wire ss_access = ssbus.access(SS_IDX);

    // regs[768] / stack[256] block RAM.  Registered reads; addresses driven
    // continuously so q is valid when used.
    //   regs : port A = p1hi read / result write / savestate r-w; port B = p1lo read
    //   stack: port A = pop read (stack_ptr) / savestate r-w;     port B = push write
    logic [9:0]  reg_wr_idx;   // regs result-write index (WRREG)
    logic [31:0] reg_wr_val;
    logic [7:0]  stk_wr_idx;   // stack push index (WRSTK)
    logic [31:0] stk_wr_val;
    logic        ss_read_delay;

    logic [9:0]  regs_addr_a;
    logic        regs_we_a;
    logic [31:0] regs_data_a;
    wire  [31:0] q_regs_a;
    wire  [31:0] q_regs_b;

    logic [7:0]  stk_addr_a;
    logic        stk_we_a;
    wire  [31:0] q_stack_a;

    always_comb begin
        // regs port A: reads p1hi by default; writes result in WRREG; SS borrows.
        regs_addr_a = p1hi[9:0];
        regs_we_a   = 1'b0;
        regs_data_a = reg_wr_val;
        if (ss_access) begin
            regs_addr_a = ssbus.addr[9:0];
            regs_we_a   = ssbus.write & (ssbus.addr < SS_STACK_BASE);
            regs_data_a = ssbus.data[31:0];
        end else if (state == WRREG) begin
            regs_addr_a = reg_wr_idx;
            regs_we_a   = 1'b1;
        end

        // stack port A: reads stack[stack_ptr] (pop); savestate borrows.
        stk_addr_a = stack_ptr;
        stk_we_a   = 1'b0;
        if (ss_access) begin
            stk_addr_a = ssbus.addr[7:0];
            stk_we_a   = ssbus.write & (ssbus.addr >= SS_STACK_BASE) & (ssbus.addr < SS_PTR_ADDR);
        end
    end

    dualport_ram_unreg #(.WIDTH(32), .WIDTHAD(10)) regs(
        .clock_a(clk), .wren_a(regs_we_a), .address_a(regs_addr_a), .data_a(regs_data_a), .q_a(q_regs_a),
        .clock_b(clk), .wren_b(1'b0),      .address_b(p1lo[9:0]),   .data_b(32'd0),       .q_b(q_regs_b)
    );
    dualport_ram_unreg #(.WIDTH(32), .WIDTHAD(8)) stack(
        .clock_a(clk), .wren_a(stk_we_a),       .address_a(stk_addr_a), .data_a(ssbus.data[31:0]), .q_a(q_stack_a),
        .clock_b(clk), .wren_b(state == WRSTK), .address_b(stk_wr_idx), .data_b(stk_wr_val),       .q_b()
    );

    // cmd-6d arithmetic operands (regs[]; index >=768 -> 0).
    wire [31:0] opnd_hi = (p1hi < 16'd768) ? q_regs_a : 32'd0;
    wire [31:0] opnd_lo = (p1lo < 16'd768) ? q_regs_b : 32'd0;
    logic [31:0] val_6d;
    always_comb begin
        unique case (p2lo)
            16'h0000: val_6d = opnd_hi + opnd_lo; // add
            16'h0001: val_6d = opnd_hi - opnd_lo; // sub src1-src2
            16'h0006: val_6d = opnd_lo - opnd_hi; // sub src2-src1
            16'h0009: val_6d = {p1hi, p1lo};      // set
            default:  val_6d = 32'd0;
        endcase
    end
    // Engine savestate: regs[768], stack[256], stack_ptr (1025 words).  Taken only
    // while the engine is idle, so the FSM state need not be serialized.
    localparam int SS_REGS_BASE  = 0;
    localparam int SS_STACK_BASE = 768;
    localparam int SS_PTR_ADDR   = 1024;
    localparam int SS_WORD_COUNT = 1025;

    // Busy whenever a command is in flight.  trigger is folded in so busy rises
    // the same cycle the command starts, stalling the 68000 atomically.
    assign busy = (state != S_IDLE) | trigger;

    // Engine memory-control combinational outputs.
    always_comb begin
        eng_sh_addr  = m_sh_addr;
        eng_sh_we    = 1'b0;
        eng_sh_wdata = wr_word;
        eng_rom_addr = 16'd0;
        cache_req    = 1'b0;

        unique case (state)
            WRSH: begin
                eng_sh_we = 1'b1;
            end
            S_INIT_FILL: begin
                eng_sh_addr  = fill_idx;
                eng_sh_wdata = 16'ha55a;
                eng_sh_we    = 1'b1;
            end
            RDRW_SET0: begin eng_rom_addr = {m_w[14:0], 1'b0};        cache_req = 1'b1; end
            RDRW_GET0: begin eng_rom_addr = {m_w[14:0], 1'b0} | 16'd1; cache_req = 1'b1; end
            RDTB_SET:  begin eng_rom_addr = m_b;                       cache_req = 1'b1; end
            RDTB_G0:   begin eng_rom_addr = m_b + 16'd1;               cache_req = 1'b1; end
            default: ;
        endcase
    end

    // ROM byte address -> full DDR address for the shared cache.
    assign cache_addr = PROT_ROM_DDR_BASE + {16'd0, eng_rom_addr};

    // Engine FSM.
    always_ff @(posedge clk) begin
        if (reset) begin
            state       <= S_INIT_FILL;
            ret_state   <= S_IDLE;
            fill_idx    <= 13'd0;
            init_active <= 1'b1;
            stack_ptr   <= 8'd0;
            status_val  <= 16'd0;
            dma_x       <= 16'd0;
            ss_read_delay <= 1'b0;
        end else begin
            ssbus.setup(SS_IDX, SS_WORD_COUNT[31:0], 2);
            if (ss_access) begin
                if (ssbus.read) begin
                    // Registered block RAM: present the address (regs_addr_a/
                    // stk_addr_a above) and respond one cycle later when q is valid.
                    if (ss_read_delay) begin
                        if (ssbus.addr < SS_STACK_BASE)
                            ssbus.read_response(SS_IDX, {32'd0, q_regs_a});
                        else if (ssbus.addr < SS_PTR_ADDR)
                            ssbus.read_response(SS_IDX, {32'd0, q_stack_a});
                        else
                            ssbus.read_response(SS_IDX, {56'd0, stack_ptr});
                    end
                    ss_read_delay <= 1'b1;
                end else if (ssbus.write) begin
                    // regs/stack writes commit via the RAM ports; only stack_ptr here.
                    if (ssbus.addr >= SS_PTR_ADDR)
                        stack_ptr <= ssbus.data[7:0];
                    ssbus.write_ack(SS_IDX);
                end
            end else begin
                ss_read_delay <= 1'b0;
            end

            if (!ss_access)
            unique case (state)
                // idle
                S_IDLE: begin
                    if (trigger) begin
`ifdef IGS_PROT_DEBUG
                        $display("[IGS022] trigger received");
`endif
                        state <= S_CMD_RD;
                    end
                end

                // generic micro-ops
                RDSH_SET: state <= RDSH_GET;
                RDSH_GET: begin rd_word <= eng_sh_rdata; state <= ret_state; end
                WRSH:     state <= ret_state;
                WRREG:    state <= ret_state;   // regs[reg_wr_idx] <= reg_wr_val (port A)
                WRSTK:    state <= ret_state;   // stack[stk_wr_idx] <= stk_wr_val (port B)
                // DDR-cached ROM reads: spin until cache_ready, then latch.  Two
                // bytes (low then high) per word.
                RDRW_SET0: if (cache_ready) begin rd_word[7:0] <= rom_byte; state <= RDRW_GET0; end
                RDRW_GET0: if (cache_ready) begin rd_word <= {rom_byte, rd_word[7:0]}; state <= ret_state; end
                RDTB_SET:  if (cache_ready) begin rd_word[7:0] <= rom_byte; state <= RDTB_G0; end
                RDTB_G0:   if (cache_ready) begin rd_word <= {rom_byte, rd_word[7:0]}; state <= ret_state; end

                // reset auto-DMA
                S_INIT_FILL: begin
                    if (fill_idx == 13'h1fff) begin
                        m_w <= W_100; ret_state <= S_INIT_SRC; state <= RDRW_SET0;
                    end else begin
                        fill_idx <= fill_idx + 13'd1;
                    end
                end
                S_INIT_SRC:  begin dma_src  <= {1'b0, rd_word[15:1]}; m_w <= W_102; ret_state <= S_INIT_DST;  state <= RDRW_SET0; end // src >>= 1
                S_INIT_DST:  begin dma_dst  <= rd_word;               m_w <= W_104; ret_state <= S_INIT_SIZE; state <= RDRW_SET0; end
                S_INIT_SIZE: begin dma_size <= rd_word;               m_w <= W_106; ret_state <= S_INIT_MODE; state <= RDRW_SET0; end
                S_INIT_MODE: begin
                    // mode = swapendian(rom word)
                    dma_mode  <= rd_word[10:8];          // swapped[2:0] = original[10:8]
                    dma_param <= rd_word[7:0];           // swapped>>8 = original[7:0]
                    dma_x <= 16'd0; init_active <= 1'b1;
                    state <= DMA_CHECK;
                end
                S_INIT_VER:  begin m_w <= W_114; ret_state <= S_INIT_VER2; state <= RDRW_SET0; end
                S_INIT_VER2: begin m_sh_addr <= A_2A2; wr_word <= rd_word; ret_state <= S_IDLE; init_active <= 1'b0; state <= WRSH; end

                // command fetch / decode
                S_CMD_RD: begin m_sh_addr <= A_CMD; ret_state <= S_CMD_DECODE; state <= RDSH_SET; end
                S_CMD_DECODE: begin
`ifdef IGS_PROT_DEBUG
                    $display("[IGS022] cmd=%04x", rd_word);
`endif
                    unique case (rd_word)
                        16'h0012: begin m_sh_addr <= A_288; ret_state <= S_PUSH_RDH;  state <= RDSH_SET; end
                        16'h0045: begin state <= S_POP; end
                        16'h004f: begin m_sh_addr <= A_290; ret_state <= S_DMA_RDSRC; state <= RDSH_SET; end
                        16'h002d: begin status_val <= 16'h003c; state <= S_SETSTAT; end
                        16'h005a: begin status_val <= 16'h004b; state <= S_SETSTAT; end
                        16'h006d: begin m_sh_addr <= A_298; ret_state <= S_6D_RD_298; state <= RDSH_SET; end
                        default:  state <= S_IDLE; // unknown: no status write
                    endcase
                end

                // push (0x12)
                S_PUSH_RDH: begin push_hi <= rd_word; m_sh_addr <= A_28A; ret_state <= S_PUSH_RDL; state <= RDSH_SET; end
                S_PUSH_RDL: begin state <= S_PUSH_DO; end // rd_word now holds 0x28a
                S_PUSH_DO: begin
                    if (stack_ptr != 8'hff) stack_ptr <= stack_ptr + 8'd1;
                    stk_wr_idx <= (stack_ptr != 8'hff) ? (stack_ptr + 8'd1) : stack_ptr;
                    stk_wr_val <= {push_hi, rd_word};
                    status_val <= 16'h0023; ret_state <= S_SETSTAT; state <= WRSTK;
                end

                // pop (0x45)
                S_POP: begin
                    pop_data <= q_stack_a;   // stack[stack_ptr], registered read
                    if (stack_ptr != 8'd0) stack_ptr <= stack_ptr - 8'd1;
                    state <= S_POP_WH;
                end
                S_POP_WH: begin m_sh_addr <= A_28C; wr_word <= pop_data[31:16]; ret_state <= S_POP_WL;   state <= WRSH; end
                S_POP_WL: begin m_sh_addr <= A_28E; wr_word <= pop_data[15:0];  ret_state <= S_POP_STAT; state <= WRSH; end
                S_POP_STAT: begin status_val <= 16'h0056; state <= S_SETSTAT; end

                // dma (0x4f)
                S_DMA_RDSRC:  begin dma_src  <= {1'b0, rd_word[15:1]}; m_sh_addr <= A_292; ret_state <= S_DMA_RDDST;  state <= RDSH_SET; end
                S_DMA_RDDST:  begin dma_dst  <= rd_word;               m_sh_addr <= A_294; ret_state <= S_DMA_RDSIZE; state <= RDSH_SET; end
                S_DMA_RDSIZE: begin dma_size <= rd_word;               m_sh_addr <= A_296; ret_state <= S_DMA_RDMODE; state <= RDSH_SET; end
                S_DMA_RDMODE: begin
                    dma_mode  <= rd_word[2:0];
                    dma_param <= rd_word[15:8];
                    dma_x <= 16'd0; init_active <= 1'b0; status_val <= 16'h005e;
`ifdef IGS_PROT_DEBUG
                    $display("[IGS022] DMA src=%04x dst=%04x size=%04x mode=%04x",
                             dma_src, dma_dst, dma_size, rd_word);
`endif
                    state <= DMA_CHECK;
                end

                // command 6d
                S_6D_RD_298: begin p1hi <= rd_word; m_sh_addr <= A_29A; ret_state <= S_6D_RD_29A; state <= RDSH_SET; end
                S_6D_RD_29A: begin p1lo <= rd_word; m_sh_addr <= A_29C; ret_state <= S_6D_RD_29C; state <= RDSH_SET; end
                S_6D_RD_29C: begin p2hi <= rd_word; m_sh_addr <= A_29E; ret_state <= S_6D_RD_29E; state <= RDSH_SET; end
                S_6D_RD_29E: begin p2lo <= rd_word; state <= S_6D_DO; end
                S_6D_DO: begin
                    // op=p2lo, src1=p1hi, src2=p1lo, dst=p2hi.  val_6d combinational
                    // on registered reads (q_regs_a/q_regs_b), valid here.
                    status_val <= 16'h007c;
`ifdef IGS_PROT_DEBUG
                    $display("[IGS022] 6d op=%04x p1=%04x%04x p2=%04x%04x", p2lo, p1hi, p1lo, p2hi, p2lo);
`endif
                    unique case (p2lo)
                        16'h0000, 16'h0001, 16'h0006, 16'h0009: begin // add / sub / sub / set
                            if (p2hi == 16'h0300) begin
                                if (stack_ptr != 8'hff) stack_ptr <= stack_ptr + 8'd1;
                                stk_wr_idx <= (stack_ptr != 8'hff) ? (stack_ptr + 8'd1) : stack_ptr;
                                stk_wr_val <= val_6d;
                                ret_state  <= S_SETSTAT; state <= WRSTK;
                            end else if (p2hi < 16'd768) begin
                                reg_wr_idx <= p2hi[9:0];
                                reg_wr_val <= val_6d;
                                ret_state  <= S_SETSTAT; state <= WRREG;
                            end else begin
                                state <= S_SETSTAT;
                            end
                        end
                        16'h000a: begin // get: shared[0x29c/0x29e] = regs[p1hi]
                            pop_data <= opnd_hi;
                            state <= S_6D_GET_WH;
                        end
                        default: state <= S_SETSTAT;
                    endcase
                end
                S_6D_GET_WH: begin m_sh_addr <= A_29C; wr_word <= pop_data[31:16]; ret_state <= S_6D_GET_WL; state <= WRSH; end
                S_6D_GET_WL: begin m_sh_addr <= A_29E; wr_word <= pop_data[15:0];  ret_state <= S_SETSTAT;   state <= WRSH; end

                // dma transfer loop
                DMA_CHECK: begin
                    if ((dma_mode == 3'd7) || (dma_x >= dma_size)) begin
                        if (init_active) state <= S_INIT_VER;
                        else             state <= S_SETSTAT;
                    end else begin
                        m_w <= dma_src + dma_x; ret_state <= DMA_AFTER_WORD; state <= RDRW_SET0;
                    end
                end
                DMA_AFTER_WORD: begin
                    dma_dat <= rd_word;
                    unique case (dma_mode)
                        3'd0: state <= DMA_WRITE;
                        3'd1, 3'd2, 3'd3: begin m_b <= {8'd0, dma_taboff}; ret_state <= DMA_AFTER_TAB; state <= RDTB_SET; end
                        3'd4: begin dma_dat <= rd_word - mode4_xor(dma_x); state <= DMA_WRITE; end
                        3'd5: begin dma_dat <= byteswap(rd_word);          state <= DMA_WRITE; end
                        3'd6: begin dma_dat <= nibbleswap(rd_word);        state <= DMA_WRITE; end
                        default: state <= DMA_WRITE;
                    endcase
                end
                DMA_AFTER_TAB: begin
                    unique case (dma_mode)
                        3'd1: dma_dat <= dma_dat - rd_word;
                        3'd2: dma_dat <= dma_dat + rd_word;
                        3'd3: dma_dat <= dma_dat ^ rd_word;
                        default: ;
                    endcase
                    state <= DMA_WRITE;
                end
                DMA_WRITE: begin
                    m_sh_addr <= dma_dst[12:0] + dma_x[12:0];
                    wr_word   <= dma_dat;
                    ret_state <= DMA_NEXT;
                    state     <= WRSH;
                end
                DMA_NEXT: begin dma_x <= dma_x + 16'd1; state <= DMA_CHECK; end

                // write completion byte
                S_SETSTAT: begin m_sh_addr <= A_STAT; wr_word <= status_val; ret_state <= S_IDLE; state <= WRSH; end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
