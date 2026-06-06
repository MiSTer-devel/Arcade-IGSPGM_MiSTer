import system_consts::*;

module igs027a #(
    parameter int TYPE = 1
)(
    input  logic        clk,
    input  logic        reset,        // active-high, synchronous (matches core)
    input  logic        ce,           // ARM advance enable (e.g. ce_16m)

    // ---- 68000 side: command/response latch ----
    // 0x500000/0x500002 (type1).  offset = byte_addr[1].
    input  logic        m68k_latch_cs_n,
    input  logic        m68k_latch_off, // 0 = low 16, 1 = high 16
    input  logic [15:0] m68k_latch_din,
    output logic [15:0] m68k_latch_q,
    input  logic        m68k_latch_we,  // write strobe (one ce_cpu pulse)

    // ---- 68000 side: shared RAM window (type1 0x4f0000-0x4f003f 64B,
    //      type2 0xd00000-0xd0ffff 64KB) ----
    input  logic        m68k_share_cs_n,
    input  logic [14:0] m68k_share_hw,  // halfword index (byte_addr[15:1])
    input  logic [15:0] m68k_share_din,
    output logic [15:0] m68k_share_q,
    input  logic        m68k_share_we_u, // upper byte write strobe
    input  logic        m68k_share_we_l, // lower byte write strobe

    output logic [31:0] cache_addr,
    output logic        cache_req,
    output logic        cache_write,    // Phase 2 (iram writes); 0 for now
    output logic [31:0] cache_wdata,
    output logic [3:0]  cache_be,
    input  logic [31:0] cache_rdata,
    input  logic        cache_ready,

    ddr_if.to_host      ddr,
    ddr_if.to_host      ddr_iram,
    input  logic        arm_has_exrom,  // 1 = game has an external ARM ROM in DDR (type2/3)
    input  logic        m68k_fiq_set,   // 68k wrote the type2 latch (asserts FIQ)

    // ---- debug taps ----
    output logic [31:0] dbg_pc,
    output logic [31:0] dbg_cpsr
);

    wire [31:0] arm_addr /* verilator public_flat */;
    wire [31:0] arm_rdata_dbg /* verilator public_flat */;
    wire [31:0] arm_wdata_dbg /* verilator public_flat */;
    wire        arm_mreq, arm_seq, arm_write, arm_lock;
    wire [1:0]  arm_size;
    wire        arm_prot_priv, arm_prot_data;
    wire [31:0] arm_wdata;
    logic [31:0] arm_rdata;
    wire [31:0] dbg_regs [0:15];

    wire        mem_ready;                 // assigned from the decode below
    logic [9:0] arm_steady_count;
    logic [9:0] arm_run_count;
    wire        arm_en      = (arm_run_count != arm_steady_count);
    wire        arm_advance = arm_en & mem_ready;

    ARM7TDMI arm(
        .clock(clk),
        .reset(reset),
        .io_enable(arm_en),
        .io_mem_CLKEN(mem_ready),

        .io_debug_registers_0(dbg_regs[0]),   .io_debug_registers_1(dbg_regs[1]),
        .io_debug_registers_2(dbg_regs[2]),   .io_debug_registers_3(dbg_regs[3]),
        .io_debug_registers_4(dbg_regs[4]),   .io_debug_registers_5(dbg_regs[5]),
        .io_debug_registers_6(dbg_regs[6]),   .io_debug_registers_7(dbg_regs[7]),
        .io_debug_registers_8(dbg_regs[8]),   .io_debug_registers_9(dbg_regs[9]),
        .io_debug_registers_10(dbg_regs[10]), .io_debug_registers_11(dbg_regs[11]),
        .io_debug_registers_12(dbg_regs[12]), .io_debug_registers_13(dbg_regs[13]),
        .io_debug_registers_14(dbg_regs[14]), .io_debug_registers_15(dbg_regs[15]),
        .io_debug_cpsr(dbg_cpsr),

        .io_mem_WRITE(arm_write),
        .io_mem_SIZE(arm_size),
        .io_mem_PROT_privileged(arm_prot_priv),
        .io_mem_PROT_data(arm_prot_data),
        .io_mem_LOCK(arm_lock),
        .io_mem_ADDR(arm_addr),
        .io_mem_MREQ(arm_mreq),
        .io_mem_SEQ(arm_seq),
        .io_mem_ABORT(1'b0),
        .io_mem_WDATA(arm_wdata),
        .io_mem_RDATA(arm_rdata),

        .io_FIQ(fiq_level),             // type2/3: set by 68k latch write
        .io_IRQ(1'b0)
    );
    logic fiq_level /* verilator public_flat */;
    logic [15:0] fiq_set_count /* verilator public_flat */;
    logic [15:0] fiq_clr_count /* verilator public_flat */;

    assign dbg_pc   = dbg_regs[15];
    wire [31:0] dbg_lr   /* verilator public_flat */ = dbg_regs[14];
    wire [31:0] dbg_sp   /* verilator public_flat */ = dbg_regs[13];
    wire [31:0] dbg_r0   /* verilator public_flat */ = dbg_regs[0];
    wire [31:0] dbg_r1   /* verilator public_flat */ = dbg_regs[1];
    wire [31:0] dbg_r2   /* verilator public_flat */ = dbg_regs[2];
    wire [31:0] dbg_r3   /* verilator public_flat */ = dbg_regs[3];
    wire [31:0] dbg_r4   /* verilator public_flat */ = dbg_regs[4];
    wire [31:0] dbg_r5   /* verilator public_flat */ = dbg_regs[5];
    wire [31:0] dbg_r6   /* verilator public_flat */ = dbg_regs[6];
    wire [31:0] dbg_r7   /* verilator public_flat */ = dbg_regs[7];
    wire [31:0] dbg_r12  /* verilator public_flat */ = dbg_regs[12];
    wire        dbg_we   /* verilator public_flat */ = arm_write;
    wire        dbg_mreq /* verilator public_flat */ = arm_mreq;
    assign arm_rdata_dbg = arm_rdata;
    assign arm_wdata_dbg = arm_wdata;

    wire [31:0] q_iram;        // ARM read port (iram)
    wire [31:0] q_xor;         // ARM/exrom read port (xortab)
    wire [31:0] q_share;       // ARM read port (share)
    wire [31:0] q_share_68k;   // 68k read port (share)
    logic [31:0] latch_arm_w /* verilator public_flat */;   // ARM -> 68k
    logic [31:0] latch_68k_w /* verilator public_flat */;   // 68k -> ARM
    logic [31:0] counter /* verilator public_flat */;

    wire sel_rom    = (arm_addr[31:14] == 18'd0);                  // 0x0-0x3fff internal ROM

    // Only route 0x08xxxxxx into the DDR external-ROM cache for games that have
    // one (type2/3).  type1 (kovsh/photoy2k) probes the 0x08100000-0x083fffff
    // stub region but has no ARM ROM in DDR; without this gate those reads stall
    // the cache (mem_ready=cache_ready never completes) and hang the ARM.
    wire sel_exrom  = arm_has_exrom & (arm_addr[31:24] == 8'h08);   // 0x08000000 external (type2/3)
    wire sel_iram   = (arm_addr[31:24] == 8'h10) ||
                      (arm_addr[31:24] == 8'h18);                  // type1 1KB / type2 64KB RAM
    wire sel_lat_t1 = (arm_addr[31:4]  == 28'h4000000);            // 0x40000000-0x4000000f (type1)
    wire sel_lat_t2 = (arm_addr[31:2]  == 30'h0e000000);           // 0x38000000 (type2)
    wire sel_latch  = sel_lat_t1 || sel_lat_t2;
    wire sel_sh_t1  = (arm_addr[31:8]  == 24'h508000);             // 0x50800000 (type1)
    wire sel_sh_t2  = (arm_addr[31:16] == 16'h4800);               // 0x48000000 (type2)
    wire sel_share  = sel_sh_t1 || sel_sh_t2;
    wire sel_xor    = (arm_addr[31:12] == 20'h50000);              // 0x50000000-0x500003ff

    wire [13:0] iram_idx  = arm_addr[15:2];
    wire [7:0]  xor_idx   = arm_addr[9:2];
    wire [13:0] share_idx = arm_addr[15:2];
    wire [1:0]  latch_sub = arm_addr[3:2];   // type1 0x40000000 word0, 0x4000000c word3

    assign cache_req   = sel_rom;
    assign cache_write = 1'b0;                 // Phase 2 (iram writes)
    assign cache_wdata = 32'd0;
    assign cache_be    = 4'd0;
    assign cache_addr  = PROT_INT_ROM_DDR_BASE + {18'd0, arm_addr[13:0]};

    wire [31:0] exrom_raw;
    wire        exrom_ready;
    arm_rom_cache #(.ADDR_BITS(23), .DDR_BASE(CART_ARM_ROM_DDR_BASE)) exrom_cache (
        .clk(clk), .reset(reset),
        .addr(arm_addr[22:0]), .req(sel_exrom),
        .rdata(exrom_raw), .ready(exrom_ready),
        .ddr(ddr)
    );

    // MAME: external_rom_r = rom ^ xor_table[off&0xff], xor_table[i]=(d<<24)|(d<<8)
    wire [7:0]  exrom_xb   = q_xor[7:0];
    wire [31:0] exrom_word = exrom_raw ^ {exrom_xb, 8'h00, exrom_xb, 8'h00};

    logic [31:0] arm_rd_mux;
    always_comb begin
        if      (sel_rom)   arm_rd_mux = cache_rdata;   // internal ROM via prot_cache
        else if (sel_iram)  arm_rd_mux = q_iram;
        else if (sel_xor)   arm_rd_mux = q_xor;
        else if (sel_share) arm_rd_mux = q_share;
        else if (sel_latch) arm_rd_mux = (sel_lat_t1 && latch_sub == 2'd3) ? counter : latch_68k_w;
        else if (sel_exrom) arm_rd_mux = exrom_word;    // external ROM via dedicated cache
        else                arm_rd_mux = 32'h0000_0000;
    end

    wire [31:0] arm_rd_comb = arm_rd_mux;
    always_ff @(posedge clk) begin
        if (reset)            arm_rdata <= 32'd0;
        else if (arm_advance) arm_rdata <= arm_rd_comb;
    end

    logic [31:0] arm_addr_q;
    wire         arm_addr_stable = (arm_addr == arm_addr_q);

    wire base_mem_ready = sel_rom              ? cache_ready
                        : sel_exrom            ? exrom_ready
                        : sel_iram             ? ramc_rd_ready
                        : (sel_xor | sel_share)? arm_addr_stable
                        :                        1'b1;
    assign mem_ready = base_mem_ready & ramc_wr_ready;
    always_ff @(posedge clk) begin
        if (reset) begin
            arm_steady_count <= 10'd0;
            arm_run_count    <= 10'd0;
            arm_addr_q       <= 32'd0;
        end else begin
            arm_addr_q <= arm_addr;
            if (ce)          arm_steady_count <= arm_steady_count + 10'd1;
            if (arm_advance) arm_run_count    <= arm_run_count    + 10'd1;
        end
    end

    wire [3:0] arm_byte_we =
        (arm_size == 2'd2) ? 4'b1111 :
        (arm_size == 2'd1) ? (arm_addr[1] ? 4'b1100 : 4'b0011) :
                             (4'b0001 << arm_addr[1:0]);
    wire        arm_rd = arm_advance & arm_mreq & ~arm_write;

    logic        wr_pend;
    logic [31:0] wr_addr;
    logic [3:0]  wr_be;
    wire  [31:0] wr_wmask = {{8{wr_be[3]}}, {8{wr_be[2]}}, {8{wr_be[1]}}, {8{wr_be[0]}}};
    wire wsel_iram   = (wr_addr[31:24] == 8'h10) || (wr_addr[31:24] == 8'h18);
    wire wsel_xor    = (wr_addr[31:12] == 20'h50000);
    wire wsel_share  = (wr_addr[31:8]  == 24'h508000) || (wr_addr[31:16] == 16'h4800);
    wire wsel_lat_t1 = (wr_addr[31:4]  == 28'h4000000) && (wr_addr[3:2] == 2'd0);
    wire wsel_lat_t2 = (wr_addr[31:2]  == 30'h0e000000);
    wire wsel_latch  = wsel_lat_t1 || wsel_lat_t2;
    wire [13:0] wiram_idx  = wr_addr[15:2];
    wire [7:0]  wxor_idx   = wr_addr[9:2];
    wire [13:0] wshare_idx = wr_addr[15:2];

    function automatic logic [31:0] wmerge(input logic [31:0] old, input logic [31:0] wd, input logic [31:0] m);
        return (old & ~m) | (wd & m);
    endfunction

    wire [13:0] m68k_sw  = m68k_share_hw[14:1];
    wire        m68k_shi = ~m68k_share_hw[0];   // BYTE_XOR_LE: high half when hw index even

    assign m68k_share_q = m68k_shi ? q_share_68k[31:16] : q_share_68k[15:0];

    assign m68k_latch_q = m68k_latch_off ? latch_arm_w[31:16] : latch_arm_w[15:0];

    wire xor_we   = arm_advance & wr_pend & wsel_xor;
    wire share_we = arm_advance & wr_pend & wsel_share;

    wire        ramc_rd_ready, ramc_wr_ready;
    ram_cache #(.LINES(512), .DDR_BASE(PROT_IRAM_DDR_BASE)) iram_cache (
        .clk(clk), .reset(reset),
        .rd_req(sel_iram),
        .rd_addr(PROT_IRAM_DDR_BASE + {16'd0, arm_addr[15:0]}),
        .rd_data(q_iram), .rd_ready(ramc_rd_ready),
        .wr_req(wr_pend & wsel_iram),
        .wr_addr(PROT_IRAM_DDR_BASE + {16'd0, wr_addr[15:0]}),
        .wr_data(arm_wdata), .wr_be(wr_be), .wr_ready(ramc_wr_ready),
        .ddr(ddr_iram)
    );

    // xortab: port A = ARM write, port B = read (serves ARM read and exrom XOR)
    dualport_ram_be #(.BYTES(4), .WIDTHAD(8)) xortab (
        .clock_a(clk), .wren_a(xor_we), .byteena_a(wr_be), .address_a(wxor_idx),     .data_a(arm_wdata), .q_a(),
        .clock_b(clk), .wren_b(1'b0),   .byteena_b(4'b0),  .address_b(arm_addr[9:2]), .data_b(32'd0),     .q_b(q_xor)
    );

    // share: port A = 68k (16-bit half by m68k_shi), port B = ARM (read, or write commit)
    wire        m68k_share_we = ~m68k_share_cs_n & (m68k_share_we_u | m68k_share_we_l);
    wire [3:0]  m68k_share_be = m68k_shi ? {m68k_share_we_u, m68k_share_we_l, 2'b00}
                                         : {2'b00, m68k_share_we_u, m68k_share_we_l};
    dualport_ram_be #(.BYTES(4), .WIDTHAD(14)) share (
        .clock_a(clk), .wren_a(m68k_share_we), .byteena_a(m68k_share_be),
        .address_a(m68k_sw), .data_a({m68k_share_din, m68k_share_din}), .q_a(q_share_68k),
        .clock_b(clk), .wren_b(share_we), .byteena_b(wr_be),
        .address_b(share_we ? wshare_idx : share_idx), .data_b(arm_wdata), .q_b(q_share)
    );

    integer i;
    always_ff @(posedge clk) begin
        if (reset) begin
            latch_arm_w <= 32'd0;
            latch_68k_w <= 32'd0;
            counter     <= 32'd1;       // MAME inits counter to 1
            wr_pend     <= 1'b0;
            fiq_level   <= 1'b0;
            fiq_set_count <= 16'd0;
            fiq_clr_count <= 16'd0;
        end else begin
            // ---- ARM write request capture (address phase) ----
            if (arm_advance) begin
                wr_pend <= arm_mreq & arm_write;
                wr_addr <= arm_addr;
                wr_be   <= arm_byte_we;
            end

            if (arm_advance && wr_pend) begin
                if (wsel_latch) begin
                    // ARM writes response.  type1 (0x40000000) also clears the
                    // consumed bits of the 68k command; type2 (0x38000000) does not.
                    latch_arm_w <= wmerge(latch_arm_w, arm_wdata, wr_wmask);
                    if (wsel_lat_t1) latch_68k_w <= latch_68k_w & ~wr_wmask;
                end
            end

            if (arm_rd && sel_lat_t1 && latch_sub == 2'd3) begin
                counter <= counter + 32'd1;   // type1 0x4000000c post-increments
            end

            if (m68k_fiq_set)                  fiq_level <= 1'b1;
            else if (arm_rd && sel_lat_t2)     fiq_level <= 1'b0;
            if (m68k_fiq_set) fiq_set_count <= fiq_set_count + 16'd1;   // debug
            if (arm_rd && sel_lat_t2) fiq_clr_count <= fiq_clr_count + 16'd1;

            if (~m68k_latch_cs_n && m68k_latch_we) begin
                if (m68k_latch_off)
                    latch_68k_w[31:16] <= m68k_latch_din;
                else
                    latch_68k_w[15:0]  <= m68k_latch_din;
            end
        end
    end

endmodule
