import system_consts::*;

module PGM(
    input             clk_50m,
    input             reset,

    input  game_t     game,

    output            ce_pixel,
    output            hsync,
    output            hblank,
    output            vsync,
    output            vblank,
    output      [7:0] red,
    output      [7:0] green,
    output      [7:0] blue,

    input       [9:0] joystick_p1,
    input       [9:0] joystick_p2,
    input       [9:0] joystick_p3,
    input       [9:0] joystick_p4,
    input       [3:0] start,
    input       [3:0] coin,

    input             analog_inc,
    input             analog_abs,
    input       [7:0] analog_p1,
    input       [7:0] analog_p2,

    input       [7:0] dipswitch,

    output reg [26:0] sdr_cpu_addr,
    input      [63:0] sdr_cpu_q,
    output reg        sdr_cpu_req,
    input             sdr_cpu_ack,

    output reg [26:0] sdr_tile_addr,
    input      [31:0] sdr_tile_q,
    output reg        sdr_tile_req,
    input             sdr_tile_ack,

    output reg [26:0] sdr_sprite_addr,
    input      [63:0] sdr_sprite_q,
    output reg        sdr_sprite_req,
    input             sdr_sprite_ack,

    output reg [26:0] sdr_arom_addr,
    input      [63:0] sdr_arom_q,
    output reg        sdr_arom_req,
    input             sdr_arom_ack,

    output reg [26:0] sdr_audio_addr,
    input      [63:0] sdr_audio_q,
    output reg        sdr_audio_req,
    input             sdr_audio_ack,

    ddr_if.to_host    ddr,

    output logic [15:0] audio_out,
    input       [1:0] audio_filter_en,

    input             ss_do_save,
    input             ss_do_restore,
    input       [1:0] ss_index,
    output      [3:0] ss_state_out,

    input             sync_fix,

    input             pause,

    input             cart_present,
    input      [23:0] cart_prog_base,
    input      [23:0] cart_tile_base,
    input      [23:0] cart_music_base
);

wire clk = clk_50m;

ddr_if ddr_ss(), ddr_arm(), ddr_prot(), ddr_iram(), ddr_share0(), ddr_share1(),
       ddr_lo(), ddr_lo2(), ddr_lo3(), ddr_lo4();

// DDR arbitration (priority: savestates > external ARM ROM > protection ROM
// cache > internal RAM cache > shared-RAM chip caches).  Each protection memory
// has its own cache so they never thrash each other (exrom 8MB, internal ROM,
// iram, 2x shared-RAM chips).  The sprite A-ROM moved to SDRAM (ch5).
ddr_mux ddr_mux_hi(
    .clk,
    .x(ddr),
    .a(ddr_ss),
    .b(ddr_lo)
);
ddr_mux ddr_mux_lo(
    .clk,
    .x(ddr_lo),
    .a(ddr_arm),
    .b(ddr_lo2)
);
ddr_mux ddr_mux_lo2(
    .clk,
    .x(ddr_lo2),
    .a(ddr_prot),
    .b(ddr_lo3)
);
ddr_mux ddr_mux_lo3(
    .clk,
    .x(ddr_lo3),
    .a(ddr_iram),
    .b(ddr_lo4)
);
ddr_mux ddr_mux_lo4(
    .clk,
    .x(ddr_lo4),
    .a(ddr_share0),
    .b(ddr_share1)
);

/////////////////////////////
//// Clock Enable Signals
wire paused;
wire ce_20m, ce_dummy_10m;
reg ce_cpu, ce_cpu_180;
wire ce_8m, ce_16m, ce_33m;
wire ce_50m = 1;
wire igs027a_share_ready;   // 0 = 68k shared-RAM access stalled (defer 68k ce)
/////////////////////////////


/////////////////////////////
//// CPU Signals
wire        cpu_rw, cpu_as_n;
wire [1:0]  cpu_ds_n;
wire [2:0]  cpu_fc;
wire        cpu_bg_n;
wire        cpu_br_n;
wire        cpu_bgack_n;
wire [15:0] cpu_data_in /* verilator public_flat */;
wire [15:0] cpu_data_out;
wire [22:0] cpu_addr;
wire [23:0] cpu_word_addr /* verilator public_flat */ = { cpu_addr, 1'b0 };
wire IACKn = ~&cpu_fc;
wire asic3_cs_n = !((cpu_word_addr[23:4] == 20'hc0400) && (~&cpu_ds_n));
/////////////////////////////


logic SS_SAVEn, SS_RESETn, SS_VECn;
reg [31:0] ss_saved_ssp;
reg [31:0] ss_restore_ssp;
reg ss_write = 0;
reg ss_read = 0;
wire ss_busy;

ssbus_if ssbus();
ssbus_if ssb[20]();

ssbus_mux #(.COUNT(20)) ssmux(
    .clk,
    .slave(ssbus),
    .masters(ssb)
);

always_ff @(posedge clk) begin
    ssb[SSIDX_GLOBAL].setup(SSIDX_GLOBAL, 1, 2); // 1, 32-bit value
    if (ssb[SSIDX_GLOBAL].access(SSIDX_GLOBAL)) begin
        if (ssb[SSIDX_GLOBAL].read) begin
            ssb[SSIDX_GLOBAL].read_response(SSIDX_GLOBAL, { 32'd0, ss_saved_ssp });
        end else if (ssb[SSIDX_GLOBAL].write) begin
            ss_restore_ssp <= ssb[SSIDX_GLOBAL].data[31:0];
            ssb[SSIDX_GLOBAL].write_ack(SSIDX_GLOBAL);
        end
    end
end

logic [15:0] ss_irq_handler[16] = '{
    16'h48e7, 16'hfffe,            // movem.l %d0-%d7/%a0-%a6,%a7@-
    16'h4e6e,                      // move.l %usp, %a6
    16'h2f0e,                      // move.l %a6, %a7@-

    // 0x8 - stop/restart pos
    16'h4df9, 16'h00ff, 16'h0000,  // lea 0xff0000, %a6

    16'h2c8f,                      // move.l %a7, %a6@

    16'h2c5f,                      // move.l %a7@+, %a6
    16'h4e66,                      // move.l %a6, %usp
    16'h4cdf, 16'h7fff,            // movem.l %a7@+, %d0-%d7/%a0-%a6
    16'h4e73,                      // rte

    16'h0000,
    16'h0000,
    16'h0000
};


typedef enum bit [3:0] {
    SST_IDLE,

    SST_SAVE_WAIT_PAUSE,
    SST_SAVE_WAIT_IRQ,
    SST_SAVE_WAIT_WRITE,
    SST_SAVE_WAIT_IRQ_EXIT,
    SST_SAVE_WAIT_SSP_SAVE,

    SST_RESTORE_WAIT_PAUSE,
    SST_RESTORE_WAIT_READ,
    SST_RESTORE_HOLD_RESET,
    SST_RESTORE_WAIT_RESET
} ss_state_t;

ss_state_t ss_state = SST_IDLE;
reg [4:0] ss_reset_counter;
reg [15:0] ss_reset_vector[4];

logic ss_pause;
logic ss_irq;
logic ss_override;
logic ss_cpu_execute;
logic ss_reset;
wire ss_paused = ss_pause & paused;

assign ss_state_out = ss_state;

always_comb begin
    ss_pause = 1;
    ss_cpu_execute = 0;
    ss_override = 0;
    ss_irq = 0;
    ss_reset = 0;

    case(ss_state)
        SST_IDLE: begin
            ss_pause = 0;
        end

        SST_SAVE_WAIT_PAUSE: begin
        end

        SST_SAVE_WAIT_IRQ: begin
            ss_cpu_execute = 1;
            ss_irq = 1;
        end


        SST_SAVE_WAIT_SSP_SAVE: begin
            ss_override = 1;
            ss_cpu_execute = 1;
        end

        SST_SAVE_WAIT_WRITE: begin
        end

        SST_SAVE_WAIT_IRQ_EXIT: begin
            ss_cpu_execute = 1;
            ss_override = 1;
        end

        SST_RESTORE_WAIT_PAUSE: begin
        end

        SST_RESTORE_WAIT_READ: begin
        end

        SST_RESTORE_HOLD_RESET: begin
            ss_override = 1;
            ss_cpu_execute = 1;
            ss_reset = 1;
        end

        SST_RESTORE_WAIT_RESET: begin
            ss_override = 1;
            ss_cpu_execute = 1;
        end

        default: begin
        end
    endcase
end


always_ff @(posedge clk) begin
    case(ss_state)
        SST_IDLE: begin
            if (ss_do_save) begin
                ss_state <= SST_SAVE_WAIT_PAUSE;
            end

            if (ss_do_restore) begin
                ss_state <= SST_RESTORE_WAIT_PAUSE;
            end
        end

        SST_SAVE_WAIT_PAUSE: begin
            if (ss_paused) begin
                ss_state <= SST_SAVE_WAIT_IRQ;
            end
        end

        SST_SAVE_WAIT_IRQ: begin
            // Interrupt acknowledged
            if (~IACKn & (cpu_addr[2:0] == 3'b111) & ~cpu_ds_n[0]) begin
                ss_state <= SST_SAVE_WAIT_SSP_SAVE;
            end
        end


        SST_SAVE_WAIT_SSP_SAVE: begin
            if (cpu_ds_n == 2'b00 && !cpu_rw & cpu_word_addr == 24'hff0000) begin
                ss_saved_ssp[31:16] <= cpu_data_out;
            end

            if (cpu_ds_n == 2'b00 && !cpu_rw && cpu_word_addr == 24'hff0002) begin
                ss_saved_ssp[15:0] <= cpu_data_out;
                ss_write <= 1;
                ss_state <= SST_SAVE_WAIT_WRITE;
            end
        end

        SST_SAVE_WAIT_WRITE: begin
            if (ss_busy & ss_write) begin
                ss_write <= 0;
            end else if (~ss_busy & ~ss_write) begin
                ss_state <= SST_SAVE_WAIT_IRQ_EXIT;
            end
        end

        SST_SAVE_WAIT_IRQ_EXIT: begin
            if (cpu_ds_n == 2'b00 && cpu_rw && cpu_fc == 3'b110 && SS_SAVEn) begin
                ss_state <= SST_IDLE;
            end
        end

        SST_RESTORE_WAIT_PAUSE: begin
            if (ss_paused) begin
                ss_read <= 1;
                ss_state <= SST_RESTORE_WAIT_READ;
            end
        end

        SST_RESTORE_WAIT_READ: begin
            if (ss_busy & ss_read) begin
                ss_read <= 0;
            end else if (~ss_busy & ~ss_read) begin
                ss_reset_vector[0] <= ss_restore_ssp[31:16];
                ss_reset_vector[1] <= ss_restore_ssp[15:0];
                ss_reset_vector[2] <= 16'h00ff;
                ss_reset_vector[3] <= 16'h0008;

                ss_state <= SST_RESTORE_HOLD_RESET;
                ss_reset_counter <= 0;
            end
        end


        SST_RESTORE_HOLD_RESET: begin
            if (ce_20m) begin
                ss_reset_counter <= ss_reset_counter + 1;
                if (&ss_reset_counter) begin
                    ss_state <= SST_RESTORE_WAIT_RESET;
                end
            end
        end

        SST_RESTORE_WAIT_RESET: begin
            if (cpu_ds_n == 2'b00 && cpu_rw && cpu_fc == 3'b110 && SS_SAVEn && SS_RESETn) begin
                ss_state <= SST_IDLE;
            end
        end

        default: begin
            ss_state <= SST_IDLE;
        end
    endcase
end

//////////////////////////////////
//// CHIP SELECTS

logic ROMn;
logic WORKRAMn;
logic IGS023n;
logic IGS026_Xn;
logic IOn;
logic IGS025n;
logic IGS022_RAMn;
logic ARM_SHAREn;
logic ARM_LATCHn;
logic ARM_NMIn;

//wire sdr_dtack_n = sdr_cpu_req != sdr_cpu_ack;
wire sdr_dtack_n;

wire igs023_dtack_n;

// Stall the 68000 while the IGS022 protection engine is running so that an
// IGS025 "execute" write completes only after the command (DMA/6d/...) has
// finished 
// TODO - this can't be what games do because the carts can't access DTACK
wire igs022_busy;
wire prot_dtack_n = ~IGS025n & igs022_busy;

wire dtack_n = sdr_dtack_n
             | pre_sdr_dtack_n
             | igs023_dtack_n
             | prot_dtack_n;

wire [2:0] IPLn;
wire DTACKn = dtack_n;

wire irq6;
wire irq4;

wire clocks_enabled = ss_cpu_execute | ~paused;

//////////////////////////////////
//// CLOCK ENABLES
jtframe_frac_cen #(2) cen_steady
(
    .clk(clk),
    .cen_in(clocks_enabled),
    .n(10'd2),
    .m(10'd5),
    .cen({ce_dummy_10m, ce_20m}),
    .cenb()
);

reg [9:0] ce_steady_count;
reg [10:0] ce_cpu_count;
always_ff @(posedge clk) begin
    if (ce_20m) begin
        ce_steady_count <= ce_steady_count + 10'd1;
    end

    ce_cpu <= 0;
    ce_cpu_180 <= 0;

    // Defer the 68k while a shared-RAM access is stalled on a DDR cache miss
    // (igs027a_share_ready=0), the same way the ROM path stalls via sdr_cpu sync.
    if (sdr_cpu_req == sdr_cpu_ack && clocks_enabled && igs027a_share_ready) begin
        if (ce_cpu_count[10:1] != ce_steady_count) begin
            ce_cpu <= ~ce_cpu_count[0];
            ce_cpu_180 <= ce_cpu_count[0];
            ce_cpu_count <= ce_cpu_count + 11'd1;
        end
    end
end

jtframe_frac_cen #(3) audio_cen
(
    .clk(clk),
    .cen_in(1),
    .n(10'd464),
    .m(10'd685),
    .cen({ce_8m, ce_16m, ce_33m}),
    .cenb()
);

wire ce_16khz, ce_32khz;
jtframe_frac_cen #(2) rtc_cen
(
    .clk(clk),
    .cen_in(ce_8m & clocks_enabled),
    .n(10'd1),
    .m(10'd228),
    .cen({ce_16khz, ce_32khz}),
    .cenb()
);

//////////////////////////////////
//// CPU

fx68k m68000(
    .clk(clk),
    .HALTn(1),
    .extReset(reset | ss_reset),
    .pwrUp(reset | ss_reset),
    .enPhi1(ce_cpu),
    .enPhi2(ce_cpu_180),

    .eRWn(cpu_rw), .ASn(cpu_as_n), .LDSn(cpu_ds_n[0]), .UDSn(cpu_ds_n[1]),
    .E(), .VMAn(),

    .FC0(cpu_fc[0]), .FC1(cpu_fc[1]), .FC2(cpu_fc[2]),
    .BGn(cpu_bg_n),
    .oRESETn(), .oHALTEDn(),
    .DTACKn(DTACKn | ~IACKn), .VPAn(IACKn),
    .BERRn(1),
    .BRn(cpu_br_n), .BGACKn(cpu_bgack_n),
    .IPL0n(IPLn[0]), .IPL1n(IPLn[1]), .IPL2n(IPLn[2]),
    .iEdb(cpu_data_in), .oEdb(cpu_data_out),
    .eab(cpu_addr)
);

wire [15:0] IN0 = { 
    joystick_p2[6:4], joystick_p2[0], joystick_p2[1], joystick_p2[2], joystick_p2[3], start[1],
    joystick_p1[6:4], joystick_p1[0], joystick_p1[1], joystick_p1[2], joystick_p1[3], start[0]
};

wire [15:0] IN1 = { 
    joystick_p4[6:4], joystick_p4[0], joystick_p4[1], joystick_p4[2], joystick_p4[3], start[3],
    joystick_p3[6:4], joystick_p3[0], joystick_p3[1], joystick_p3[2], joystick_p3[3], start[2]
};


// TODO - missing service, test and reset
wire [15:0] IN2 = { 4'b0, joystick_p4[7], joystick_p3[7], joystick_p2[7], joystick_p1[7], 4'b0, coin[3:0] };
wire [15:0] IN3 = { 8'b0, dipswitch };


assign IPLn = ss_irq ? ~3'b111 :
              irq6 ? ~3'b110 :
              irq4 ? ~3'b100 :
              ~3'b000;

address_translator address_translator(
    .game,
    .cpu_ds_n,
    .cpu_word_addr,

    .ss_override,

    .WORKRAMn,
    .ROMn,
    .IOn,
    .IGS023n,
    .IGS026_Xn,
    .IGS025n,
    .IGS022_RAMn,
    .ARM_SHAREn,
    .ARM_LATCHn,
    .ARM_NMIn,

    .SS_SAVEn,
    .SS_RESETn,
    .SS_VECn
);

assign cpu_data_in = ~SS_SAVEn ? ss_irq_handler[cpu_addr[3:0]] :
                     ~SS_RESETn ? ss_reset_vector[cpu_addr[1:0]] :
                     ~SS_VECn ? ( cpu_addr[0] ? 16'h0000 : 16'h00ff ) :
                     ~ROMn ? rom_q :
                     ~WORKRAMn ? workram_q :
                     ~IGS023n ? igs023_q :
                     ~IOn ? io_q :
                     ~asic3_cs_n ? asic3_q :
                     ~IGS026_Xn ? igs026_x_q :
                     ~IGS025n ? igs025_q :
                     ~IGS022_RAMn ? igs022_ram_q :
                     ~ARM_SHAREn ? igs027a_share_q :
                     ~ARM_LATCHn ? igs027a_latch_q :
                     16'd0;

wire [15:0] workram_addr;
wire workram_lds_n, workram_uds_n;
wire [15:0] workram_data, workram_q;

wire workram_dma = ~cpu_bgack_n;

m68k_ram #(.WIDTHAD(16)) work_ram(
    .clock(clk),
    .address(workram_addr),
    .we_lds_n(workram_lds_n),
    .we_uds_n(workram_uds_n),
    .data(workram_data),
    .q(workram_q)
);

m68k_ram_ss_adaptor #(.WIDTHAD(16), .SS_IDX(SSIDX_WORK_RAM)) workram_ss(
    .clk,
    .addr_in(workram_dma ? igs023_dma_addr : cpu_addr[15:0]),
    .lds_n_in(workram_dma ? 1 : WORKRAMn | cpu_ds_n[0] | cpu_rw),
    .uds_n_in(workram_dma ? 1 : WORKRAMn | cpu_ds_n[1] | cpu_rw),
    .data_in(cpu_data_out),

    .q(workram_q),

    .addr_out(workram_addr),
    .lds_n_out(workram_lds_n),
    .uds_n_out(workram_uds_n),
    .data_out(workram_data),

    .ssbus(ssb[SSIDX_WORK_RAM])
);

wire [14:0] aram_addr;
wire aram_lds_n, aram_uds_n;
wire [15:0] aram_data, aram_q;

m68k_ram #(.WIDTHAD(15)) aram(
    .clock(clk),
    .address(aram_addr),
    .we_lds_n(aram_lds_n),
    .we_uds_n(aram_uds_n),
    .data(aram_data),
    .q(aram_q)
);

m68k_ram_ss_adaptor #(.WIDTHAD(15), .SS_IDX(SSIDX_Z80_RAM)) aram_ss(
    .clk,
    .addr_in(igs026_x_aram_addr),
    .lds_n_in(igs026_x_aram_lds_n),
    .uds_n_in(igs026_x_aram_uds_n),
    .data_in(igs026_x_aram_dout),

    .q(aram_q),

    .addr_out(aram_addr),
    .lds_n_out(aram_lds_n),
    .uds_n_out(aram_uds_n),
    .data_out(aram_data),

    .ssbus(ssb[SSIDX_Z80_RAM])
);


wire [11:0] pal_addr;
wire pal_lds_n, pal_uds_n;
wire [15:0] pal_data;

wire [12:0] igs023_pal_addr;
wire [15:0] igs023_q, igs023_pal_data, igs023_pal_q;
wire igs023_pal_we_l_n, igs023_pal_we_u_n;

wire [14:0] igs023_vram_addr;
wire [7:0] igs023_vram_q, igs023_vram_data;
wire igs023_vram_we_n;

wire [14:0] vram_addr;
wire [7:0] vram_data;
wire       vram_wren;

singleport_ram #(.WIDTH(8), .WIDTHAD(15)) vram(
    .clock(clk),
    .wren(vram_wren),
    .address(vram_addr),
    .data(vram_data),
    .q(igs023_vram_q)
);

ram_ss_adaptor #(.WIDTH(8), .WIDTHAD(15), .SS_IDX(SSIDX_VIDEO_RAM)) vram_ss(
    .clk,
    .addr_in(igs023_vram_addr[14:0]),
    .wren_in(~igs023_vram_we_n),
    .data_in(igs023_vram_data),

    .q(igs023_vram_q),

    .addr_out(vram_addr),
    .wren_out(vram_wren),
    .data_out(vram_data),

    .ssbus(ssb[SSIDX_VIDEO_RAM])
);

m68k_ram #(.WIDTHAD(12)) palram(
    .clock(clk),
    .address(pal_addr),
    .we_lds_n(pal_lds_n),
    .we_uds_n(pal_uds_n),
    .data(pal_data),
    .q(igs023_pal_q)
);

m68k_ram_ss_adaptor #(.WIDTHAD(12), .SS_IDX(SSIDX_PAL_RAM)) palram_ss(
    .clk,
    .addr_in(igs023_pal_addr[12:1]),
    .lds_n_in(igs023_pal_we_l_n),
    .uds_n_in(igs023_pal_we_u_n),
    .data_in(igs023_pal_data),

    .q(igs023_pal_q),

    .addr_out(pal_addr),
    .lds_n_out(pal_lds_n),
    .uds_n_out(pal_uds_n),
    .data_out(pal_data),

    .ssbus(ssb[SSIDX_PAL_RAM])
);

wire [14:0] igs023_color;
assign red = { igs023_color[14:10], igs023_color[14:12] };
assign green = { igs023_color[9:5], igs023_color[9:7] };
assign blue = { igs023_color[4:0], igs023_color[4:2] };

wire [23:0] igs023_sdr_tile_addr;
wire [23:0] igs023_sdr_sprite_addr;
wire [24:0] igs023_sdr_arom_addr;
wire [15:0] igs023_dma_addr;
assign sdr_tile_addr = (cart_present && (igs023_sdr_tile_addr >= cart_tile_base))
                        ? CART_TILE_ROM_SDR_BASE[26:0] + { 3'd0, igs023_sdr_tile_addr - cart_tile_base }
                        : BIOS_TILE_ROM_SDR_BASE[26:0] + { 3'd0, igs023_sdr_tile_addr };

assign sdr_sprite_addr = CART_B_ROM_SDR_BASE[26:0] + { 3'd0, igs023_sdr_sprite_addr };

// Sprite A-ROM (colour) lives in SDRAM at CART_A_ROM_SDR_BASE (its own channel).
assign sdr_arom_addr   = CART_A_ROM_SDR_BASE[26:0] + { 2'd0, igs023_sdr_arom_addr };



IGS023 #(.SS_IDX(SSIDX_IGS023)) igs023(
    .clk,
    .ce_33m,
    .ce_50m,
    .ce_pixel,

    .reset,

    // CPU interface
    .cpu_addr(cpu_word_addr),
    .cpu_din(cpu_data_out),
    .cpu_dout(igs023_q),
    .cpu_lds_n(cpu_ds_n[0]),
    .cpu_uds_n(cpu_ds_n[1]),
    .cpu_rw(cpu_rw),
    .cpu_cs_n(IGS023n),
    .cpu_dtack_n(igs023_dtack_n),

    .cpu_br_n(cpu_br_n),
    .cpu_bgack_n(cpu_bgack_n),
    .cpu_bg_n(cpu_bg_n),
    .cpu_as_n(cpu_as_n),
    .cpu_dtack_in_n(DTACKn),

    .dma_addr(igs023_dma_addr),
    .dma_din(workram_q),

    // VRAM interface
    .vram_addr(igs023_vram_addr),
    .vram_din(igs023_vram_q),
    .vram_dout(igs023_vram_data),
    .vram_we_n(igs023_vram_we_n),
   
    .pal_addr(igs023_pal_addr),
    .pal_din(igs023_pal_q),
    .pal_dout(igs023_pal_data),
    .pal_we_u_n(igs023_pal_we_u_n),
    .pal_we_l_n(igs023_pal_we_l_n),
 
    // ROM interface
    .tile_rom_address(igs023_sdr_tile_addr),
    .tile_rom_data(sdr_tile_q),
    .tile_rom_req(sdr_tile_req),
    .tile_rom_ack(sdr_tile_ack),

    .sprite_brom_address(igs023_sdr_sprite_addr),
    .sprite_brom_data(sdr_sprite_q),
    .sprite_brom_req(sdr_sprite_req),
    .sprite_brom_ack(sdr_sprite_ack),

    .sprite_arom_address(igs023_sdr_arom_addr),
    .sprite_arom_data(sdr_arom_q),
    .sprite_arom_req(sdr_arom_req),
    .sprite_arom_ack(sdr_arom_ack),

    .irq6(irq6),
    .irq4(irq4),

    // Video interface
    .vid_color(igs023_color),
    .vid_hsync(hsync),
    .vid_hblank(hblank),
    .vid_vsync(vsync),
    .vid_vblank(vblank),

    .pause_req(pause | ss_pause),
    .pause_ack(paused),

    .ssbus(ssb[SSIDX_IGS023])
);

wire [15:0] igs026_x_q;
wire [15:0] asic3_q;
wire v3021_cs_n, v3021_wr_n;
wire v3021_din, v3021_dout;

wire [14:0] igs026_x_aram_addr;
wire [15:0] igs026_x_aram_dout;

wire igs026_x_aram_uds_n, igs026_x_aram_lds_n;

wire z80_reset_n, z80_wait_n, z80_busrq_n, z80_busak_n, z80_int_n, z80_nmi_n;
wire z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n;
wire [15:0] z80_addr;
wire [7:0] z80_din;
wire [7:0] z80_dout;

wire [1:0] ics2115_addr;
wire [7:0] ics2115_din, ics2115_dout;
wire ics2115_cs_n, ics2115_rd_n, ics2115_wr_n;
wire ics2115_irq, ics2115_ready;
wire ics2115_reset_n /* verilator public_flat */;

wire [22:0] ics2115_rom_addr /* verilator public_flat */;
wire [15:0] ics2115_rom_q;
wire        ics2115_rom_read;
wire        ics2115_data_valid /* verilator public_flat */;
wire  [4:0] ics2115_voice_id;
wire signed [15:0] ics2115_audio_left;
wire signed [15:0] ics2115_audio_right;
wire               ics2115_audio_valid;

wire [26:0] ics2115_sdr_addr = (cart_present && ics2115_rom_addr[22:0] >= cart_music_base[23:1])
                               ? CART_MUSIC_ROM_SDR_BASE + { 3'b0, ics2115_rom_addr[22:0] - cart_music_base[23:1], 1'b0 }
                               : BIOS_MUSIC_ROM_SDR_BASE + { 3'b0, ics2115_rom_addr[22:0], 1'b0 };

audio_rom_cache audio_rom_cache(
    .clk,

    .sdr_addr(sdr_audio_addr),
    .sdr_data(sdr_audio_q),
    .sdr_req(sdr_audio_req),
    .sdr_ack(sdr_audio_ack),

    .addr(ics2115_sdr_addr),
    .read(ics2115_rom_read),
    .channel(ics2115_voice_id),
    .data({ics2115_rom_q[7:0], ics2115_rom_q[15:8]}),
    .data_valid(ics2115_data_valid)
);

IGS026_X #(.SS_IDX(SSIDX_IGS026_X)) igs026_x(
    .clk,
    .reset,
    .ss_restore(ss_do_restore),

    // CPU interface
    .cpu_addr(cpu_word_addr),
    .cpu_din(cpu_data_out),
    .cpu_dout(igs026_x_q),
    .cpu_lds_n(cpu_ds_n[0]),
    .cpu_uds_n(cpu_ds_n[1]),
    .cpu_rw(cpu_rw),
    .cpu_cs_n(IGS026_Xn | ~asic3_cs_n),

    .v3021_cs_n,
    .v3021_wr_n,
    .v3021_dout(v3021_din),
    .v3021_din(v3021_dout),

    .aram_addr(igs026_x_aram_addr),
    .aram_din(aram_q),
    .aram_dout(igs026_x_aram_dout),
    .aram_lds_n(igs026_x_aram_lds_n),
    .aram_uds_n(igs026_x_aram_uds_n),

    .z80_reset_n,
    .z80_wait_n,
    .z80_busrq_n,
    .z80_busak_n,
    .z80_int_n,
    .z80_nmi_n,
    .z80_mreq_n,
    .z80_iorq_n,
    .z80_rd_n,
    .z80_wr_n,
    .z80_addr,
    .z80_din(z80_dout),
    .z80_dout(z80_din),

    .ics2115_reset_n,
    .ics2115_addr,
    .ics2115_din(ics2115_dout),
    .ics2115_dout(ics2115_din),
    .ics2115_cs_n,
    .ics2115_rd_n,
    .ics2115_wr_n,
    .ics2115_irq,
    .ics2115_ready,

    .ssbus(ssb[SSIDX_IGS026_X])
);

pgm_asic3 #(.SS_IDX(SSIDX_ASIC3)) asic3(
    .clk,
    .reset,
    .region(3'd0),

    .cpu_addr(cpu_word_addr[3:0]),
    .cpu_din(cpu_data_out),
    .cpu_dout(asic3_q),
    .cpu_lds_n(cpu_ds_n[0]),
    .cpu_uds_n(cpu_ds_n[1]),
    .cpu_rw(cpu_rw),
    .cpu_cs_n(asic3_cs_n),

    .ssbus(ssb[SSIDX_ASIC3])
);

// ---- Shared DDR protection cache --------------------------------------------
// igs027a (ARM) and igs022 are mutually exclusive per game, so one cache (its
// tag/data block RAM) serves whichever is active.  The active engine drives the
// single request port; rdata/ready fan out to both.
// IGS027A ARM type2/3 games: 64KB shared RAM @0xd00000, latch @0xd10000 (FIQ),
wire arm_type2 = (game == GAME_KOV2)  || (game == GAME_KOV2P)   || (game == GAME_DDP2) ||
                 (game == GAME_MARTMAST) || (game == GAME_DW2001) || (game == GAME_DWPC);
// IGS027A type3 (55857G): dmnfrnt/theglad.  68k share 0x500000 (double-buffered),
// latch 0x5c0300, ARM FIQ pulse on 68k write to 0x5c0000.
wire arm_type3 = (game == GAME_DMNFRNT) || (game == GAME_THEGLAD);
wire arm_game = (game == GAME_KOVSH) || (game == GAME_PHOTOY2K) || arm_type2 || arm_type3;
wire i22_game = (game == GAME_KILLBLD) || (game == GAME_DRGW3);

wire [31:0] a27_cache_addr, i22_cache_addr;
wire        a27_cache_req,  i22_cache_req;
wire        a27_cache_write;
wire [31:0] a27_cache_wdata;
wire [3:0]  a27_cache_be;
wire [31:0] prot_cache_rdata;
wire        prot_cache_ready;

prot_cache prot_cache(
    .clk, .reset,
    .req    (arm_game ? a27_cache_req   : (i22_game ? i22_cache_req : 1'b0)),
    .write  (arm_game ? a27_cache_write : 1'b0),
    .addr   (arm_game ? a27_cache_addr  : i22_cache_addr),
    .wdata  (a27_cache_wdata),
    .byteena(a27_cache_be),
    .rdata  (prot_cache_rdata),
    .ready  (prot_cache_ready),
    .ddr    (ddr_prot)
);

// IGS022 + IGS025 protection (The Killing Blade / Dragon World 3).
wire [15:0] igs025_q, igs022_ram_q;
wire        prot_trigger;
wire [7:0]  prot_region = (game == GAME_KILLBLD) ? 8'h21 :  // World
                          (game == GAME_DRGW3)   ? 8'h06 :  // World
                          8'h00;

igs025 #(.SS_IDX(SSIDX_IGS025)) igs025(
    .clk,
    .reset,
    .game,
    .region(prot_region),

    .cpu_addr(cpu_word_addr[3:0]),
    .cpu_din(cpu_data_out),
    .cpu_dout(igs025_q),
    .cpu_uds_n(cpu_ds_n[1]),
    .cpu_lds_n(cpu_ds_n[0]),
    .cpu_rw(cpu_rw),
    .cpu_cs_n(IGS025n),

    .trigger(prot_trigger),

    .ssbus(ssb[SSIDX_IGS025])
);

igs022 #(
    .SS_IDX(SSIDX_IGS022),
    .SS_IDX_RAM_LO(SSIDX_IGS022_RAM_LO),
    .SS_IDX_RAM_HI(SSIDX_IGS022_RAM_HI)
) igs022(
    .clk,
    .reset,

    .trigger(prot_trigger),
    .busy(igs022_busy),

    .cpu_word_addr(cpu_word_addr[13:1]),
    .cpu_din(cpu_data_out),
    .cpu_dout(igs022_ram_q),
    .cpu_uds_n(cpu_ds_n[1]),
    .cpu_lds_n(cpu_ds_n[0]),
    .cpu_rw(cpu_rw),
    .cpu_cs_n(IGS022_RAMn),

    // private data ROM via the shared DDR cache
    .cache_addr(i22_cache_addr),
    .cache_req(i22_cache_req),
    .cache_rdata(prot_cache_rdata),
    .cache_ready(prot_cache_ready),

    .ssbus(ssb[SSIDX_IGS022]),
    .ss_ram_lo(ssb[SSIDX_IGS022_RAM_LO]),
    .ss_ram_hi(ssb[SSIDX_IGS022_RAM_HI])
);

// IGS027A ARM7 protection (pgm_arm type1/2/3).  TYPE1 (kovsh/photoy2k).
//
// The protection MCU runs from a device-specific XTAL, so its clock enable is
// configurable per game (master clk is 50MHz, cen = clk * n/m):
//   20 MHz (2/5)  : type1 (kovsh/photoy2k), type2/3 base parts (55857E/F/G)
//   22 MHz (11/25): martmast/dw2001/dwpc (type2), dmnfrnt/theglad (type3)
//   24 MHz (12/25): dmnfrntpcb/happy6 (type3)
logic [9:0] arm_cen_n, arm_cen_m;
always_comb begin
    case (game)
        // 22 MHz (11/25) parts: martmast / dw2001 / dwpc (type2), dmnfrnt / theglad (type3).
        GAME_MARTMAST,
        GAME_DW2001,
        GAME_DWPC,
        GAME_DMNFRNT,
        GAME_THEGLAD: begin arm_cen_n = 10'd11; arm_cen_m = 10'd25; end // 22 MHz
        // 20 MHz (2/5): kovsh/photoy2k (type1), kov2/kov2p/ddp2 (type2 55857F).
        default:   begin arm_cen_n = 10'd2;  arm_cen_m = 10'd5;  end // 20 MHz
    endcase
end

wire ce_arm, ce_arm_ph2;
jtframe_frac_cen #(2) arm_cen (
    .clk(clk),
    .cen_in(clocks_enabled),
    .n(arm_cen_n),
    .m(arm_cen_m),
    .cen({ce_arm_ph2, ce_arm}),
    .cenb()
);

wire [31:0] arm_dbg_pc /* verilator public_flat */;
wire [31:0] arm_dbg_cpsr /* verilator public_flat */;
wire [15:0] igs027a_latch_q, igs027a_share_q;
wire        igs027a_ss_ready;

// Shared-RAM halfword offset within the window: type1 64B @0x4f0000 (5-bit),
// type2 64KB @0xd00000 (15-bit).  FIQ is set by the type2 latch write (0xd10000).
// Shared-RAM halfword index: type1 64B (5-bit), type2 64KB @0xd00000 and type3
// 64KB @0x500000 both use the full 15-bit halfword index.
wire [14:0] arm_share_hw = (arm_type2 | arm_type3) ? cpu_word_addr[15:1]
                                                   : {10'd0, cpu_word_addr[5:1]};
// type2 asserts FIQ on the latch write (0xd10000); type3 on a write to the
// dedicated NMI address (0x5c0000).
wire        arm_fiq_set  = arm_type2 & ~ARM_LATCHn & ~cpu_rw & ~(&cpu_ds_n);
wire        arm_nmi_set  = arm_type3 & ~ARM_NMIn   & ~cpu_rw & ~(&cpu_ds_n);
// type2/3 games have an external ARM ROM served from DDR; type1 (kovsh/photoy2k)
// does not, and must not route its 0x08xxxxxx stub probes into the DDR cache.
wire        arm_has_exrom = arm_type2 | arm_type3;

igs027a #(
    .TYPE(1),
    .SS_IDX(SSIDX_IGS027A),
    .SS_IDX_IRAM(SSIDX_IGS027A_IRAM),
    .SS_IDX_SHARE(SSIDX_IGS027A_SHARE),
    .SS_IDX_XOR(SSIDX_IGS027A_XOR)
) igs027a(
    .clk,
    .reset,
    .ce(ce_arm),

    // savestate.  Freeze the ARM only once the system is actually paused
    // (ss_pause & paused): requesting the freeze earlier would stop the ARM
    // mid-protection-handshake and the 68k could never reach its pause point.
    .ss_restore(ss_do_restore),
    .ss_pause(ss_paused),
    .ss_ready(igs027a_ss_ready),
    .ssbus(ssb[SSIDX_IGS027A]),
    .ssbus_iram(ssb[SSIDX_IGS027A_IRAM]),
    .ssbus_share(ssb[SSIDX_IGS027A_SHARE]),
    .ssbus_xor(ssb[SSIDX_IGS027A_XOR]),

    // 68k command/response latch (type1 0x500000 / type2 0xd10000)
    .m68k_latch_cs_n(ARM_LATCHn),
    .m68k_latch_off(cpu_word_addr[1]),
    .m68k_latch_din(cpu_data_out),
    .m68k_latch_q(igs027a_latch_q),
    .m68k_latch_we(~cpu_rw & ~(&cpu_ds_n)),

    // 68k shared-RAM window (type1 0x4f0000 / type2 0xd00000)
    .m68k_share_cs_n(ARM_SHAREn),
    .m68k_share_hw(arm_share_hw),
    .m68k_share_din(cpu_data_out),
    .m68k_share_q(igs027a_share_q),
    .m68k_share_we_u(~cpu_rw & ~cpu_ds_n[1]),
    .m68k_share_we_l(~cpu_rw & ~cpu_ds_n[0]),

    // internal ROM via the shared prot_cache; external ARM ROM via its own cache
    .cache_addr(a27_cache_addr),
    .cache_req(a27_cache_req),
    .cache_write(a27_cache_write),
    .cache_wdata(a27_cache_wdata),
    .cache_be(a27_cache_be),
    .cache_rdata(prot_cache_rdata),
    .cache_ready(prot_cache_ready),
    .ddr(ddr_arm),
    .ddr_iram(ddr_iram),
    .ddr_share0(ddr_share0),
    .ddr_share1(ddr_share1),
    .arm_has_exrom(arm_has_exrom),
    .arm_type3(arm_type3),
    .m68k_fiq_set(arm_fiq_set),
    .m68k_nmi_set(arm_nmi_set),
    .m68k_share_ready(igs027a_share_ready),

    .dbg_pc(arm_dbg_pc),
    .dbg_cpsr(arm_dbg_cpsr)
);

V3021 v3021(
    .clk,
    .ce_32khz,

    .cs_n(v3021_cs_n),
    .wr_n(v3021_wr_n),

    .in(v3021_din),
    .out(v3021_dout)
);


wire ics2115_ss_ready;

ics2115 #(.SS_IDX(SSIDX_ICS2115)) ics2115(
    .clk,
    .ce(ce_33m & clocks_enabled),
    .ce_50m(ce_50m & (clocks_enabled || !ics2115_ss_ready)),
    .reset_n(ics2115_reset_n),
    .host_addr(ics2115_addr),
    .host_din(ics2115_din),
    .host_dout(ics2115_dout),
    .host_cs_n(ics2115_cs_n),
    .host_rd_n(ics2115_rd_n),
    .host_wr_n(ics2115_wr_n),
    .host_irq(ics2115_irq),
    .host_ready(ics2115_ready),

    .rom_addr(ics2115_rom_addr),
    .rom_data(ics2115_rom_q),
    .rom_rd(ics2115_rom_read),
    .rom_voice_id(ics2115_voice_id),
    .rom_data_valid(ics2115_data_valid),

    .audio_left(ics2115_audio_left),
    .audio_right(ics2115_audio_right),
    .audio_valid(ics2115_audio_valid),

    .ss_ready(ics2115_ss_ready),
    .ssbus(ssb[SSIDX_ICS2115])
);


always_comb begin
    logic [17:0] audio_combined;
    audio_combined = {{2{ics2115_audio_left[15]}}, ics2115_audio_left } + {{2{ics2115_audio_right[15]}}, ics2115_audio_right};
    audio_out = audio_combined[17:2];
end

logic [15:0] io_q;
always_comb begin
    io_q = 16'hffff;

    if (~IOn) begin
        case(cpu_addr[1:0])
            0: io_q = ~IN0;
            1: io_q = ~IN1;
            2: io_q = ~IN2;
            3: io_q = ~IN3;
        endcase
    end
end

reg prev_ds_n;

wire pre_sdr_dtack_n = ~ROMn & prev_ds_n;
wire [15:0] rom_q;

rom_cache rom_cache(
    .clk,
    .reset,
    .sdr_addr(sdr_cpu_addr),
    .sdr_data(sdr_cpu_q),
    .sdr_req(sdr_cpu_req),
    .sdr_ack(sdr_cpu_ack),

    .cart_present,
    .cart_base_addr(cart_prog_base[23:1]),

    .as_n(ROMn | cpu_as_n),
    .dtack_n(sdr_dtack_n),
    .cpu_addr(cpu_addr),
    .data(rom_q)
);

always_ff @(posedge clk) begin
    prev_ds_n <= cpu_as_n;
end

`ifdef USE_AUTO_SS
wire [31:0] z80_ss_in, z80_ss_out;
wire z80_ss_wr, z80_ss_rd, z80_ss_ack;
wire [15:0] z80_ss_state_idx;
wire [7:0] z80_ss_device_idx;

auto_save_adaptor2 #(.SS_IDX(SSIDX_Z80)) z80_ss_adaptor(
    .clk,
    .ssbus(ssb[SSIDX_Z80]),
    .rd(z80_ss_rd),
    .wr(z80_ss_wr),
    .ack(z80_ss_ack),
    .device_idx(z80_ss_device_idx),
    .state_idx(z80_ss_state_idx),
    .wr_data(z80_ss_in),
    .rd_data(z80_ss_out)
);
`endif

tv80s z80(

`ifdef USE_AUTO_SS
    .auto_ss_rd(z80_ss_rd),
    .auto_ss_wr(z80_ss_wr),
    .auto_ss_device_idx(z80_ss_device_idx),
    .auto_ss_state_idx(z80_ss_state_idx),
    .auto_ss_base_device_idx(0),
    .auto_ss_data_in(z80_ss_in),
    .auto_ss_data_out(z80_ss_out),
    .auto_ss_ack(z80_ss_ack),
`endif

    .clk(clk),
    .cen(ce_8m & clocks_enabled),
    .reset_n(z80_reset_n),
    .wait_n(z80_wait_n),
    .int_n(z80_int_n),
    .nmi_n(z80_nmi_n),
    .busrq_n(z80_busrq_n),
    .m1_n(),
    .mreq_n(z80_mreq_n),
    .iorq_n(z80_iorq_n),
    .rd_n(z80_rd_n),
    .wr_n(z80_wr_n),
    .rfsh_n(),
    .halt_n(),
    .busak_n(z80_busak_n),
    .A(z80_addr),
    .di(z80_din),
    .dout(z80_dout)
);

save_state_data save_state_data(
    .clk,
    .reset(0),

    .ddr(ddr_ss),

    .index(ss_index),
    .read_start(ss_read),
    .write_start(ss_write),
    .busy(ss_busy),

    .ssbus(ssbus)
);


endmodule
