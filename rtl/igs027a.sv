import system_consts::*;

module igs027a #(
    parameter int TYPE = 1,
    parameter int SS_IDX       = -1,
    parameter int SS_IDX_IRAM  = -1,
    parameter int SS_IDX_SHARE = -1,
    parameter int SS_IDX_XOR   = -1
)(
    input  logic        clk,
    input  logic        reset,        // active-high, synchronous (matches core)
    input  logic        ce,           // ARM advance enable (e.g. ce_16m)

    // ---- savestate ----
    input  logic        ss_restore,   // pulse: load defaults, then stream restores
    input  logic        ss_pause,     // high for the whole save AND restore window
    output logic        ss_ready,     // 1 when ARM is frozen at a safe point
    ssbus_if.slave      ssbus,        // SSIDX_IGS027A:       ARM core + wrapper regs
    ssbus_if.slave      ssbus_iram,   // SSIDX_IGS027A_IRAM:  internal RAM (via ram_cache)
    ssbus_if.slave      ssbus_share,  // SSIDX_IGS027A_SHARE: 68k/ARM shared RAM
    ssbus_if.slave      ssbus_xor,    // SSIDX_IGS027A_XOR:   exrom XOR table

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
    ddr_if.to_host      ddr_share0,     // 68k/ARM shared RAM chip0 cache (DDR)
    ddr_if.to_host      ddr_share1,     // 68k/ARM shared RAM chip1 cache (DDR)
    input  logic        arm_has_exrom,  // 1 = game has an external ARM ROM in DDR (type2/3)
    input  logic        arm_type3,      // 1 = type3 (55857G): banked share, swapped latch/share map
    input  logic        m68k_fiq_set,   // 68k wrote the type2 latch (asserts FIQ)
    input  logic        m68k_nmi_set,   // 68k wrote the type3 NMI addr 0x5c0000 (asserts FIQ)
    output logic        m68k_share_ready, // 0 = 68k shared access stalled on a cache miss

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

    // ---- savestate freeze handshake (gamebub ARM core io_saveReq/io_safe) ----
    wire        save_window = ss_pause;        // high for whole save AND restore window
    wire        io_saveReq  = save_window;
    wire        arm_io_safe;
    wire        arm_frozen  = arm_io_safe;     // core frozen at a pipeline boundary
    assign      ss_ready    = ~save_window | arm_frozen;

    // During the save window step the core on raw clk (ce_arm is dead while paused)
    // until it reaches a safe point; otherwise use the normal catch-up enable.
    wire        arm_en_normal    = (arm_run_count != arm_steady_count);
    wire        arm_en_saveflush = save_window & ~arm_frozen;
    wire        arm_en      = save_window ? arm_en_saveflush : arm_en_normal;
    wire        arm_advance = arm_en & mem_ready;

    // ---- ssbus (core + wrapper) decode helpers ----
    wire        ss_sel = (ssbus.select == SS_IDX[7:0]) & ~ssbus.query;
    wire        ss_wr  = ss_sel & ssbus.write;       // restore (pre-frozen ack is gated below)
    wire [7:0]  ss_a   = ssbus.addr[7:0];
    wire        ss_wr_f = arm_frozen & ss_wr;        // gated restore write strobe
    localparam int SS_COUNT = 'h48;                  // 0x00-0x3f core + 0x40-0x47 wrapper

    // ARM core savestate port bridge (writes gated on frozen so the running core
    // cannot un-restore its own registers mid-stream).
    wire [31:0] arm_state_rdata;
    wire [5:0]  arm_io_state_address = ssbus.addr[5:0];
    wire [31:0] arm_io_state_wdata   = ssbus.data[31:0];
    wire        arm_io_state_we      = ss_wr_f & (ssbus.addr < 32'h40);

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
        .io_IRQ(1'b0),

        // ---- savestate ----
        .io_state_address(arm_io_state_address),
        .io_state_writeData(arm_io_state_wdata),
        .io_state_writeEnable(arm_io_state_we),
        .io_state_readData(arm_state_rdata),
        .io_saveReq(io_saveReq),
        .io_safe(arm_io_safe)
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
    wire [31:0] q_share;       // ARM read result (shared chip cache)
    wire        arm_share_ready; // ARM shared access ready (both chip caches)
    logic [31:0] latch_arm_w /* verilator public_flat */;   // ARM -> 68k
    logic [31:0] latch_68k_w /* verilator public_flat */;   // 68k -> ARM
    logic [31:0] counter /* verilator public_flat */;
    logic        ram_sel /* verilator public_flat */;       // type3 double-buffered share bank

    wire sel_rom    = (arm_addr[31:14] == 18'd0);                  // 0x0-0x3fff internal ROM

    // Only route 0x08xxxxxx into the DDR external-ROM cache for games that have
    // one (type2/3).  type1 (kovsh/photoy2k) probes the 0x08100000-0x083fffff
    // stub region but has no ARM ROM in DDR; without this gate those reads stall
    // the cache (mem_ready=cache_ready never completes) and hang the ARM.
    wire sel_exrom  = arm_has_exrom & (arm_addr[31:24] == 8'h08);   // 0x08000000 external (type2/3)
    wire sel_iram   = (arm_addr[31:24] == 8'h10) ||
                      (arm_addr[31:24] == 8'h18);                  // type1/2 RAM; type3 arm_ram2(0x10)/arm_ram(0x18)
    wire sel_lat_t1 = (arm_addr[31:4]  == 28'h4000000);            // 0x40000000-0x4000000f (type1)
    // type2: 0x38=latch, 0x48=share.  type3 swaps them: 0x38=share, 0x48=latch.
    wire sel_lat_t2 = ~arm_type3 & (arm_addr[31:2] == 30'h0e000000); // 0x38000000 (type2 latch)
    wire sel_lat_t3 =  arm_type3 & (arm_addr[31:2] == 30'h12000000); // 0x48000000 (type3 latch)
    wire sel_latch  = sel_lat_t1 || sel_lat_t2 || sel_lat_t3;
    wire sel_sh_t1  = (arm_addr[31:8]  == 24'h508000);            // 0x50800000 (type1)
    wire sel_sh_t2  = ~arm_type3 & (arm_addr[31:16] == 16'h4800); // 0x48000000 (type2 share)
    wire sel_sh_t3  =  arm_type3 & (arm_addr[31:16] == 16'h3800); // 0x38000000 (type3 share, banked)
    wire sel_share  = sel_sh_t1 || sel_sh_t2 || sel_sh_t3;
    wire sel_bsel   =  arm_type3 & (arm_addr[31:2] == 30'h10000006); // 0x40000018 (type3 RAM bank select)
    wire sel_xor    = (arm_addr[31:12] == 20'h50000);             // 0x50000000-0x500003ff (xortab / type3 scratch)

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

    // type1/2: external_rom_r = rom ^ xor_table[off&0xff] (runtime xortab).
    // type3: the external ROM is fully decrypted at load and read raw (its
    // 0x50000000 region is plain scratch RAM, not a decrypt key).
    wire [7:0]  exrom_xb   = q_xor[7:0];
    wire [31:0] exrom_word = arm_type3 ? exrom_raw
                                       : (exrom_raw ^ {exrom_xb, 8'h00, exrom_xb, 8'h00});

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
        if (reset || ss_restore)        arm_rdata <= 32'd0;
        else if (ss_wr_f & (ss_a == 8'h40)) arm_rdata <= ssbus.data[31:0];
        else if (arm_advance)           arm_rdata <= arm_rd_comb;
    end

    logic [31:0] arm_addr_q;
    wire         arm_addr_stable = (arm_addr == arm_addr_q);

    wire base_mem_ready = sel_rom   ? cache_ready
                        : sel_exrom ? exrom_ready
                        : sel_iram  ? ramc_rd_ready
                        : sel_xor   ? arm_addr_stable
                        :             1'b1;
    // sel_share readiness comes from the per-chip share caches (arm_share_ready),
    // ANDed in globally so it also covers the deferred ARM shared-write commit.
    assign mem_ready = base_mem_ready & ramc_wr_ready & arm_share_ready;
    logic arm_frozen_q;
    always_ff @(posedge clk) begin
        if (reset || ss_restore) begin
            arm_steady_count <= 10'd0;
            arm_run_count    <= 10'd0;
            arm_addr_q       <= 32'd0;
            arm_frozen_q     <= 1'b0;
        end else begin
            arm_frozen_q <= arm_frozen;
            arm_addr_q <= arm_addr;
            if (ce)          arm_steady_count <= arm_steady_count + 10'd1;
            if (arm_advance) arm_run_count    <= arm_run_count    + 10'd1;
            // At the freeze edge, sync run to steady so resume after restore idles
            // until the next ce tick (matches the normal catch-up cadence).
            if (save_window & arm_frozen & ~arm_frozen_q)
                arm_run_count <= arm_steady_count;
            // SS restore (overrides normal; system is paused so no contention)
            if (ss_wr_f) begin
                case (ss_a)
                    8'h41: {arm_run_count, arm_steady_count} <= {ssbus.data[19:10], ssbus.data[9:0]};
                    8'h42: arm_addr_q <= ssbus.data[31:0];
                    default: ;
                endcase
            end
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
    wire wsel_share  = (wr_addr[31:8]  == 24'h508000)                       // 0x50800000 (type1)
                     | (~arm_type3 & (wr_addr[31:16] == 16'h4800))          // 0x48000000 (type2)
                     | ( arm_type3 & (wr_addr[31:16] == 16'h3800));         // 0x38000000 (type3)
    wire wsel_lat_t1 = (wr_addr[31:4]  == 28'h4000000) && (wr_addr[3:2] == 2'd0);
    wire wsel_lat_t2 = ~arm_type3 & (wr_addr[31:2] == 30'h0e000000);        // 0x38000000 (type2)
    wire wsel_lat_t3 =  arm_type3 & (wr_addr[31:2] == 30'h12000000);        // 0x48000000 (type3)
    wire wsel_latch  = wsel_lat_t1 || wsel_lat_t2 || wsel_lat_t3;
    wire wsel_bsel   =  arm_type3 & (wr_addr[31:2] == 30'h10000006);        // 0x40000018 bank select
    wire [13:0] wiram_idx  = wr_addr[15:2];
    wire [7:0]  wxor_idx   = wr_addr[9:2];
    wire [13:0] wshare_idx = wr_addr[15:2];

    function automatic logic [31:0] wmerge(input logic [31:0] old, input logic [31:0] wd, input logic [31:0] m);
        return (old & ~m) | (wd & m);
    endfunction

    wire [13:0] m68k_sw  = m68k_share_hw[14:1];
    wire        m68k_shi = arm_has_exrom ?  m68k_share_hw[0]    // type2/3
                                         : ~m68k_share_hw[0];   // type1 (unchanged)

    assign m68k_latch_q = m68k_latch_off ? latch_arm_w[31:16] : latch_arm_w[15:0];

    wire xor_we   = arm_advance & wr_pend & wsel_xor;

    wire        ramc_rd_ready, ramc_wr_ready;

    // ---- savestate access to iram, routed through the write-back cache so the
    //      cache stays the coherence point (no separate flush/invalidate). The
    //      ARM is frozen during the SS window, so SS owns the cache ports. ----
    typedef enum logic [1:0] { SI_IDLE, SI_RD, SI_WR, SI_WAIT } si_t;
    si_t         si_state;
    logic        ss_iram_rd, ss_iram_wr;
    logic [13:0] ss_iram_word;
    wire         ss_iram_own  = arm_frozen;
    wire [31:0]  ss_iram_addr = PROT_IRAM_DDR_BASE + {16'd0, ss_iram_word, 2'b00};

    // type3 has two distinct internal RAMs: arm_ram (0x18000000, 256KB) and
    // arm_ram2 (0x10000000, 1KB).  Map to non-overlapping windows in the iram
    // DDR region (arm_ram 0..0x3ffff, arm_ram2 0x40000..0x403ff).  type1/2 alias
    // 0x10/0x18 to a single 64KB window (unchanged).
    function automatic logic [18:0] iram_off(input logic [31:0] a);
        if (arm_type3)
            iram_off = (a[31:24] == 8'h10) ? (19'h40000 | {9'd0, a[9:0]})  // arm_ram2 1KB
                                           : {1'b0, a[17:0]};               // arm_ram 256KB
        else
            iram_off = {3'd0, a[15:0]};                                     // type1/2 64KB
    endfunction

    wire        ramc_rd_req  = ss_iram_own ? ss_iram_rd  : sel_iram;
    wire [31:0] ramc_rd_addr = ss_iram_own ? ss_iram_addr
                                           : (PROT_IRAM_DDR_BASE + {13'd0, iram_off(arm_addr)});
    wire        ramc_wr_req  = ss_iram_own ? ss_iram_wr  : (wr_pend & wsel_iram);
    wire [31:0] ramc_wr_addr = ss_iram_own ? ss_iram_addr
                                           : (PROT_IRAM_DDR_BASE + {13'd0, iram_off(wr_addr)});
    wire [31:0] ramc_wr_data = ss_iram_own ? ssbus_iram.data[31:0] : arm_wdata;
    wire [3:0]  ramc_wr_be   = ss_iram_own ? 4'hf : wr_be;

    ram_cache #(.LINES(512), .DDR_BASE(PROT_IRAM_DDR_BASE)) iram_cache (
        .clk(clk), .reset(reset),
        .rd_req(ramc_rd_req),
        .rd_addr(ramc_rd_addr),
        .rd_data(q_iram), .rd_ready(ramc_rd_ready),
        .wr_req(ramc_wr_req),
        .wr_addr(ramc_wr_addr),
        .wr_data(ramc_wr_data), .wr_be(ramc_wr_be), .wr_ready(ramc_wr_ready),
        .ddr(ddr_iram)
    );

    always_ff @(posedge clk) begin
        ssbus_iram.setup(SS_IDX_IRAM, 32'd16384, 2);
        if (reset) begin
            si_state   <= SI_IDLE;
            ss_iram_rd <= 1'b0;
            ss_iram_wr <= 1'b0;
        end else begin
            case (si_state)
                SI_IDLE: begin
                    ss_iram_rd <= 1'b0;
                    ss_iram_wr <= 1'b0;
                    if (arm_frozen && ssbus_iram.access(SS_IDX_IRAM)) begin
                        ss_iram_word <= ssbus_iram.addr[13:0];
                        if (ssbus_iram.write)      begin ss_iram_wr <= 1'b1; si_state <= SI_WR; end
                        else if (ssbus_iram.read)  begin ss_iram_rd <= 1'b1; si_state <= SI_RD; end
                    end
                end
                SI_RD: if (ramc_rd_ready) begin
                    ss_iram_rd <= 1'b0;
                    ssbus_iram.read_response(SS_IDX_IRAM, {32'd0, q_iram});
                    si_state <= SI_WAIT;
                end
                SI_WR: if (ramc_wr_ready) begin
                    ss_iram_wr <= 1'b0;
                    ssbus_iram.write_ack(SS_IDX_IRAM);
                    si_state <= SI_WAIT;
                end
                SI_WAIT: if (~(ssbus_iram.read | ssbus_iram.write)) si_state <= SI_IDLE;
                default: si_state <= SI_IDLE;
            endcase
        end
    end

    // xortab: port A = ARM write, port B = read (serves ARM read and exrom XOR).
    // SS borrows port A (writes) and port B (reads) while the ARM is frozen.
    wire        ss_xor_sel = arm_frozen & (ssbus_xor.select == SS_IDX_XOR[7:0])
                            & ~ssbus_xor.query & (ssbus_xor.read | ssbus_xor.write);
    wire        ss_xor_wr  = ss_xor_sel & ssbus_xor.write;
    wire        xr_wren_a  = ss_xor_sel ? ss_xor_wr            : xor_we;
    wire [3:0]  xr_be_a    = ss_xor_sel ? 4'hf                 : wr_be;
    wire [7:0]  xr_addr_a  = ss_xor_sel ? ssbus_xor.addr[7:0]  : wxor_idx;
    wire [31:0] xr_data_a  = ss_xor_sel ? ssbus_xor.data[31:0] : arm_wdata;
    wire [7:0]  xr_addr_b  = ss_xor_sel ? ssbus_xor.addr[7:0]  : arm_addr[9:2];

    dualport_ram_be #(.BYTES(4), .WIDTHAD(8)) xortab (
        .clock_a(clk), .wren_a(xr_wren_a), .byteena_a(xr_be_a), .address_a(xr_addr_a), .data_a(xr_data_a), .q_a(),
        .clock_b(clk), .wren_b(1'b0),      .byteena_b(4'b0),    .address_b(xr_addr_b), .data_b(32'd0),     .q_b(q_xor)
    );

    typedef enum logic [1:0] { SX_IDLE, SX_RD, SX_WAIT } sx_t;
    sx_t sx_state;
    always_ff @(posedge clk) begin
        ssbus_xor.setup(SS_IDX_XOR, 32'd256, 2);
        if (reset) sx_state <= SX_IDLE;
        else case (sx_state)
            SX_IDLE: if (ss_xor_sel) begin
                if (ssbus_xor.write) begin ssbus_xor.write_ack(SS_IDX_XOR); sx_state <= SX_WAIT; end
                else                 sx_state <= SX_RD;
            end
            SX_RD:   begin ssbus_xor.read_response(SS_IDX_XOR, {32'd0, q_xor}); sx_state <= SX_WAIT; end
            SX_WAIT: if (~(ssbus_xor.read | ssbus_xor.write)) sx_state <= SX_IDLE;
            default: sx_state <= SX_IDLE;
        endcase
    end

    // ---- 68k/ARM shared RAM: one DDR-backed cache per 64KB "chip" ----------
    // Real hw is two single-port 64KB chips.  type3: ARM on chip ram_sel, 68k on
    // chip ~ram_sel (always opposite).  type1/2: both on chip0 (68k priority,
    // handled inside share_cache).  The (undumped) internal ROM's shared-RAM seed
    // is now done by the synthesized dummy ARM ROM (ARM stores), not here.
    wire        bank_arm = arm_type3 ? ram_sel  : 1'b0;
    wire        bank_68k = arm_type3 ? ~ram_sel : 1'b0;

    // 68k access (gated off while frozen so SS owns the chips)
    wire        m68k_we    = m68k_share_we_u | m68k_share_we_l;
    wire        m68k_acc   = ~m68k_share_cs_n & ~arm_frozen;
    wire        m68k_rd_q  = m68k_acc & ~m68k_we;
    wire        m68k_wr_q  = m68k_acc &  m68k_we;
    wire [15:0] m68k_off   = {m68k_sw, 2'b00};
    wire [3:0]  m68k_be    = m68k_shi ? {m68k_share_we_u, m68k_share_we_l, 2'b00}
                                      : {2'b00, m68k_share_we_u, m68k_share_we_l};
    wire [31:0] m68k_wd    = {m68k_share_din, m68k_share_din};

    // ARM access (read uses arm_addr, deferred write uses wr_addr)
    wire        arm_sh_rd  = sel_share & ~arm_frozen;
    wire        arm_sh_wr  = wr_pend & wsel_share & ~arm_frozen;
    wire [15:0] arm_rd_off = {arm_addr[15:2], 2'b00};
    wire [15:0] arm_wr_off = {wr_addr[15:2],  2'b00};

    // savestate (128KB = 2 chips; ssbus word-addr bit14 selects the chip)
    wire        ss_share_sel = arm_frozen & (ssbus_share.select == SS_IDX_SHARE[7:0])
                              & ~ssbus_share.query & (ssbus_share.read | ssbus_share.write);
    wire        ss_chip = ssbus_share.addr[14];
    wire [15:0] ss_off  = {ssbus_share.addr[13:0], 2'b00};
    logic       ss_sh_rd, ss_sh_wr;

    wire [31:0] c0_arm_q, c1_arm_q, c0_m68k_q, c1_m68k_q, c0_ss_q, c1_ss_q;
    wire        c0_arm_rdy, c1_arm_rdy, c0_m68k_rdy, c1_m68k_rdy, c0_ss_rdy, c1_ss_rdy;

    share_cache #(.CHIP_BASE(PROT_SHARE_DDR_BASE)) chip0 (
        .clk(clk), .reset(reset),
        .arm_rd (arm_sh_rd & ~bank_arm), .arm_rd_off(arm_rd_off),
        .arm_wr (arm_sh_wr & ~bank_arm), .arm_wr_off(arm_wr_off),
        .arm_wdata(arm_wdata), .arm_be(wr_be), .arm_q(c0_arm_q), .arm_ready(c0_arm_rdy),
        .m68k_rd(m68k_rd_q & ~bank_68k), .m68k_wr(m68k_wr_q & ~bank_68k),
        .m68k_off(m68k_off), .m68k_wdata(m68k_wd), .m68k_be(m68k_be),
        .m68k_q(c0_m68k_q), .m68k_ready(c0_m68k_rdy),
        .ss_rd(ss_sh_rd & ~ss_chip), .ss_wr(ss_sh_wr & ~ss_chip),
        .ss_off(ss_off), .ss_wdata(ssbus_share.data[31:0]), .ss_q(c0_ss_q), .ss_ready(c0_ss_rdy),
        .ddr(ddr_share0)
    );
    share_cache #(.CHIP_BASE(PROT_SHARE_DDR_BASE + 32'h0001_0000)) chip1 (
        .clk(clk), .reset(reset),
        .arm_rd (arm_sh_rd & bank_arm), .arm_rd_off(arm_rd_off),
        .arm_wr (arm_sh_wr & bank_arm), .arm_wr_off(arm_wr_off),
        .arm_wdata(arm_wdata), .arm_be(wr_be), .arm_q(c1_arm_q), .arm_ready(c1_arm_rdy),
        .m68k_rd(m68k_rd_q & bank_68k), .m68k_wr(m68k_wr_q & bank_68k),
        .m68k_off(m68k_off), .m68k_wdata(m68k_wd), .m68k_be(m68k_be),
        .m68k_q(c1_m68k_q), .m68k_ready(c1_m68k_rdy),
        .ss_rd(ss_sh_rd & ss_chip), .ss_wr(ss_sh_wr & ss_chip),
        .ss_off(ss_off), .ss_wdata(ssbus_share.data[31:0]), .ss_q(c1_ss_q), .ss_ready(c1_ss_rdy),
        .ddr(ddr_share1)
    );

    // ARM read result + readiness (non-target chip is idle -> ready=1)
    assign q_share         = bank_arm ? c1_arm_q : c0_arm_q;
    assign arm_share_ready = c0_arm_rdy & c1_arm_rdy;

    // 68k read result (halfword) + stall to the 68k (via PGM ce-defer)
    wire [31:0] m68k_share_word = bank_68k ? c1_m68k_q : c0_m68k_q;
    assign m68k_share_q    = m68k_shi ? m68k_share_word[31:16] : m68k_share_word[15:0];
    assign m68k_share_ready = c0_m68k_rdy & c1_m68k_rdy;

    // savestate read result + readiness
    wire [31:0] ss_share_q   = ss_chip ? c1_ss_q : c0_ss_q;
    wire        ss_share_rdy = c0_ss_rdy & c1_ss_rdy;

    typedef enum logic [1:0] { SH_IDLE, SH_RD, SH_WR, SH_WAIT } sh_t;
    sh_t sh_state;
    always_ff @(posedge clk) begin
        ssbus_share.setup(SS_IDX_SHARE, 32'd32768, 2);   // 2x 64KB chips
        if (reset) begin
            sh_state <= SH_IDLE; ss_sh_rd <= 1'b0; ss_sh_wr <= 1'b0;
        end else begin
            case (sh_state)
                SH_IDLE: begin
                    ss_sh_rd <= 1'b0; ss_sh_wr <= 1'b0;
                    if (ss_share_sel) begin
                        if (ssbus_share.write) begin ss_sh_wr <= 1'b1; sh_state <= SH_WR; end
                        else                   begin ss_sh_rd <= 1'b1; sh_state <= SH_RD; end
                    end
                end
                SH_RD: if (ss_share_rdy) begin
                    ss_sh_rd <= 1'b0;
                    ssbus_share.read_response(SS_IDX_SHARE, {32'd0, ss_share_q});
                    sh_state <= SH_WAIT;
                end
                SH_WR: if (ss_share_rdy) begin
                    ss_sh_wr <= 1'b0;
                    ssbus_share.write_ack(SS_IDX_SHARE);
                    sh_state <= SH_WAIT;
                end
                SH_WAIT: if (~(ssbus_share.read | ssbus_share.write)) sh_state <= SH_IDLE;
                default: sh_state <= SH_IDLE;
            endcase
        end
    end

    integer i;
    always_ff @(posedge clk) begin
        ssbus.setup(SS_IDX, SS_COUNT, 2);
        if (reset || ss_restore) begin
            latch_arm_w <= 32'd0;
            latch_68k_w <= 32'd0;
            counter     <= 32'd1;       // MAME inits counter to 1
            wr_pend     <= 1'b0;
            fiq_level   <= 1'b0;
            fiq_set_count <= 16'd0;
            fiq_clr_count <= 16'd0;
            ram_sel     <= 1'b1;        // type3 dmnfrnt boots with bank 1 selected
        end else begin
            // ---- ARM write request capture (address phase) ----
            if (arm_advance) begin
                wr_pend <= arm_mreq & arm_write;
                wr_addr <= arm_addr;
                wr_be   <= arm_byte_we;
            end

            // type3 share-RAM bank select (ARM write to 0x40000018)
            if (arm_advance && wr_pend && wsel_bsel)
                ram_sel <= arm_wdata[0];

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

            // type2 sets FIQ via the latch write (0xd10000) and clears on the ARM
            // latch read (0x38000000); type3 sets via the NMI write (0x5c0000) and
            // clears on the ARM latch read (0x48000000).
            if (m68k_fiq_set || m68k_nmi_set)            fiq_level <= 1'b1;
            else if (arm_rd && (sel_lat_t2 || sel_lat_t3)) fiq_level <= 1'b0;
            if (m68k_fiq_set || m68k_nmi_set) fiq_set_count <= fiq_set_count + 16'd1;   // debug
            if (arm_rd && (sel_lat_t2 || sel_lat_t3)) fiq_clr_count <= fiq_clr_count + 16'd1;

            if (~m68k_latch_cs_n && m68k_latch_we) begin
                if (m68k_latch_off)
                    latch_68k_w[31:16] <= m68k_latch_din;
                else
                    latch_68k_w[15:0]  <= m68k_latch_din;
            end

            // ---- savestate: ARM core (0x00-0x3f) + wrapper regs (0x40-0x47).
            //      Gated on arm_frozen so save reads / restore writes only happen
            //      once the core is at a safe point and cannot self-mutate.  The
            //      core words are bridged combinationally via io_state_* (read) and
            //      arm_io_state_we (write); wrapper regs are (de)serialised here. ----
            if (arm_frozen && ssbus.access(SS_IDX)) begin
                if (ssbus.write) begin
                    case (ssbus.addr)
                        32'h43: latch_arm_w <= ssbus.data[31:0];
                        32'h44: latch_68k_w <= ssbus.data[31:0];
                        32'h45: counter     <= ssbus.data[31:0];
                        32'h46: begin ram_sel <= ssbus.data[6]; fiq_level <= ssbus.data[5]; wr_pend <= ssbus.data[4]; wr_be <= ssbus.data[3:0]; end
                        32'h47: wr_addr     <= ssbus.data[31:0];
                        default: ;   // 0x00-0x3f core (io_state_*); 0x40-0x42 in other blocks
                    endcase
                    ssbus.write_ack(SS_IDX);
                end else if (ssbus.read) begin
                    case (ssbus.addr)
                        32'h40: ssbus.read_response(SS_IDX, {32'd0, arm_rdata});
                        32'h41: ssbus.read_response(SS_IDX, {32'd0, 12'd0, arm_run_count, arm_steady_count});
                        32'h42: ssbus.read_response(SS_IDX, {32'd0, arm_addr_q});
                        32'h43: ssbus.read_response(SS_IDX, {32'd0, latch_arm_w});
                        32'h44: ssbus.read_response(SS_IDX, {32'd0, latch_68k_w});
                        32'h45: ssbus.read_response(SS_IDX, {32'd0, counter});
                        32'h46: ssbus.read_response(SS_IDX, {57'd0, ram_sel, fiq_level, wr_pend, wr_be});
                        32'h47: ssbus.read_response(SS_IDX, {32'd0, wr_addr});
                        default: ssbus.read_response(SS_IDX, {32'd0, arm_state_rdata}); // 0x00-0x3f
                    endcase
                end
            end
        end
    end

endmodule
