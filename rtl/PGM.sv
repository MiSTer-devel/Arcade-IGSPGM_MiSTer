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

    input       [7:0] dswa,
    input       [7:0] dswb,

    output reg [26:0] sdr_cpu_addr,
    input      [63:0] sdr_cpu_q,
    output reg        sdr_cpu_req,
    input             sdr_cpu_ack,

    output reg [26:0] sdr_scn0_addr,
    input      [31:0] sdr_scn0_q,
    output reg        sdr_scn0_req,
    input             sdr_scn0_ack,

    output reg [26:0] sdr_scn_mux_addr,
    input      [63:0] sdr_scn_mux_q,
    output reg        sdr_scn_mux_req,
    input             sdr_scn_mux_ack,

    output reg [26:0] sdr_audio_addr,
    input      [15:0] sdr_audio_q,
    output reg        sdr_audio_req,
    input             sdr_audio_ack,

    ddr_if.to_host    ddr,

    input      [12:0] obj_debug_idx,

    output     [15:0] audio_out,
    input       [1:0] audio_filter_en,

    input             ss_do_save,
    input             ss_do_restore,
    input       [1:0] ss_index,
    output      [3:0] ss_state_out,

    input      [23:0] bram_addr,
    input       [7:0] bram_data,
    input             bram_wr,

    input             sync_fix,

    input             pause
);

wire clk = clk_50m;

ddr_if ddr_ss(), ddr_obj();

ddr_mux ddr_mux(
    .clk,
    .x(ddr),
    .a(ddr_ss),
    .b(ddr_obj)
);

/////////////////////////////
//// Clock Enable Signals
wire ce_20m, ce_dummy_10m;
reg ce_cpu, ce_cpu_180;
wire ce_8m, ce_4m;
wire ce_50m = 1;
/////////////////////////////


/////////////////////////////
//// CPU Signals
wire        cpu_rw, cpu_as_n;
wire [1:0]  cpu_ds_n;
wire [2:0]  cpu_fc;
wire [15:0] cpu_data_in, cpu_data_out;
wire [22:0] cpu_addr;
wire [23:0] cpu_word_addr /* verilator public_flat */ = { cpu_addr, 1'b0 };
wire IACKn = ~&cpu_fc;
/////////////////////////////


assign sdr_scn_mux_addr = 0;
assign sdr_scn_mux_req = 0;


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
    ssb[0].setup(SSIDX_GLOBAL, 1, 2); // 1, 32-bit value
    if (ssb[0].access(SSIDX_GLOBAL)) begin
        if (ssb[0].read) begin
            ssb[0].read_response(SSIDX_GLOBAL, { 32'd0, ss_saved_ssp });
        end else if (ssb[0].write) begin
            ss_restore_ssp <= ssb[0].data[31:0];
            ssb[0].write_ack(SSIDX_GLOBAL);
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
wire obj_paused = 0;

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
            if (obj_paused) begin
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
            if (obj_paused) begin
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
logic PROGn;
logic WORKRAMn;
logic IGS023n;
logic IGS026_Z80n;
logic IOn;

//wire sdr_dtack_n = sdr_cpu_req != sdr_cpu_ack;
wire sdr_dtack_n;

wire igs023_dtack_n;

wire dtack_n = sdr_dtack_n
             | pre_sdr_dtack_n
             | igs023_dtack_n;

wire [2:0] IPLn;
wire DTACKn = dtack_n;

wire irq6;
wire irq4 = 0;

//////////////////////////////////
//// CLOCK ENABLES
jtframe_frac_cen #(2) cen_steady
(
    .clk(clk),
    .cen_in(~obj_paused | ss_cpu_execute),
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

    if (sdr_cpu_req == sdr_cpu_ack && (~obj_paused | ss_cpu_execute)) begin
        if (ce_cpu_count[10:1] != ce_steady_count) begin
            ce_cpu <= ~ce_cpu_count[0];
            ce_cpu_180 <= ce_cpu_count[0];
            ce_cpu_count <= ce_cpu_count + 11'd1;
        end
    end
end

jtframe_frac_cen #(2) audio_cen
(
    .clk(clk),
    .cen_in(~obj_paused | ss_cpu_execute),
    .n(10'd137),
    .m(10'd914),
    .cen({ce_4m, ce_8m}),
    .cenb()
);

wire ce_16khz, ce_32khz;
jtframe_frac_cen #(2) rtc_cen
(
    .clk(clk),
    .cen_in(ce_4m),
    .n(10'd1),
    .m(10'd114),
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
    .BGn(),
    .oRESETn(), .oHALTEDn(),
    .DTACKn(DTACKn), .VPAn(IACKn),
    .BERRn(1),
    .BRn(1), .BGACKn(1),
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

wire [15:0] IN2 = { 16'd0 };
wire [15:0] IN3 = { 8'b0, dswa };


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
    .PROGn,
    .IOn,
    .IGS023n,
    .IGS026_Z80n,

    .SS_SAVEn,
    .SS_RESETn,
    .SS_VECn
);

assign cpu_data_in = ~SS_SAVEn ? ss_irq_handler[cpu_addr[3:0]] :
                     ~SS_RESETn ? ss_reset_vector[cpu_addr[1:0]] :
                     ~SS_VECn ? ( cpu_addr[0] ? 16'h0000 : 16'h00ff ) :
                     ~ROMn ? rom_q :
                     ~PROGn ? rom_q :
                     ~WORKRAMn ? workram_q :
                     ~IGS023n ? igs023_q :
                     ~IOn ? io_q :
                     ~IGS026_Z80n ? igs026_z80_q :
                     16'd0;

wire [15:0] workram_addr;
wire workram_lds_n, workram_uds_n;
wire [15:0] workram_data, workram_q;

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
    .addr_in(cpu_addr[15:0]),
    .lds_n_in(WORKRAMn | cpu_ds_n[0] | cpu_rw),
    .uds_n_in(WORKRAMn | cpu_ds_n[1] | cpu_rw),
    .data_in(cpu_data_out),

    .q(workram_q),

    .addr_out(workram_addr),
    .lds_n_out(workram_lds_n),
    .uds_n_out(workram_uds_n),
    .data_out(workram_data),

    .ssbus(ssb[1])
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
    .addr_in(igs026_z80_aram_addr),
    .lds_n_in(igs026_z80_aram_lds_n),
    .uds_n_in(igs026_z80_aram_uds_n),
    .data_in(igs026_z80_aram_dout),

    .q(aram_q),

    .addr_out(aram_addr),
    .lds_n_out(aram_lds_n),
    .uds_n_out(aram_uds_n),
    .data_out(aram_data),

    .ssbus(ssb[4])
);


wire [14:0] vram_addr;
wire vram_lds_n, vram_uds_n;
wire [15:0] vram_data;

wire [15:0] igs023_vram_addr;
wire [15:0] igs023_q, igs023_vram_data, igs023_vram_q;
wire igs023_vram_we_l_n, igs023_vram_we_u_n;

wire [14:0] igs023_pal_addr;
wire [7:0] igs023_pal_q, igs023_pal_data;
wire igs023_pal_we_n;

wire [14:0] pal_addr;
wire [7:0] pal_data;
wire       pal_wren;

singleport_ram #(.WIDTH(8), .WIDTHAD(15)) palram(
    .clock(clk),
    .wren(pal_wren),
    .address(pal_addr),
    .data(pal_data),
    .q(igs023_pal_q)
);

ram_ss_adaptor #(.WIDTH(8), .WIDTHAD(15), .SS_IDX(SSIDX_PAL_RAM)) palram_ss(
    .clk,
    .addr_in(igs023_pal_addr[14:0]),
    .wren_in(~igs023_pal_we_n),
    .data_in(igs023_pal_data),

    .q(igs023_pal_q),

    .addr_out(pal_addr),
    .wren_out(pal_wren),
    .data_out(pal_data),

    .ssbus(ssb[5])
);

m68k_ram #(.WIDTHAD(15)) vram(
    .clock(clk),
    .address(vram_addr),
    .we_lds_n(vram_lds_n),
    .we_uds_n(vram_uds_n),
    .data(vram_data),
    .q(igs023_vram_q)
);

m68k_ram_ss_adaptor #(.WIDTHAD(15), .SS_IDX(SSIDX_VIDEO_RAM)) vram_ss(
    .clk,
    .addr_in(igs023_vram_addr[15:1]),
    .lds_n_in(igs023_vram_we_l_n),
    .uds_n_in(igs023_vram_we_u_n),
    .data_in(igs023_vram_data),

    .q(igs023_vram_q),

    .addr_out(vram_addr),
    .lds_n_out(vram_lds_n),
    .uds_n_out(vram_uds_n),
    .data_out(vram_data),

    .ssbus(ssb[2])
);

wire [14:0] igs023_color;
assign red = { igs023_color[14:10], igs023_color[14:12] };
assign green = { igs023_color[9:5], igs023_color[9:7] };
assign blue = { igs023_color[4:0], igs023_color[4:2] };

wire [23:0] igs023_sdr_addr;
assign sdr_scn0_addr = TILE_ROM_SDR_BASE[26:0] + { 3'd0, igs023_sdr_addr };

IGS023 #(.SS_IDX(SSIDX_IGS023)) igs023(
    .clk,
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

    // VRAM interface
    .vram_addr(igs023_vram_addr),
    .vram_din(igs023_vram_q),
    .vram_dout(igs023_vram_data),
    .vram_we_u_n(igs023_vram_we_u_n),
    .vram_we_l_n(igs023_vram_we_l_n),
    
    .pal_addr(igs023_pal_addr),
    .pal_din(igs023_pal_q),
    .pal_dout(igs023_pal_data),
    .pal_we_n(igs023_pal_we_n),

    // ROM interface
    .rom_address(igs023_sdr_addr),
    .rom_data(sdr_scn0_q),
    .rom_req(sdr_scn0_req),
    .rom_ack(sdr_scn0_ack),

    .vblank_irq(irq6),

    // Video interface
    .color(igs023_color),
    .hsync,
    .hblank,
    .vsync,
    .vblank,

    .ssbus(ssb[3])
);

wire [15:0] igs026_z80_q;
wire v3021_cs_n, v3021_wr_n;
wire v3021_din, v3021_dout;

wire [14:0] igs026_z80_aram_addr;
wire [15:0] igs026_z80_aram_dout;

wire igs026_z80_aram_uds_n, igs026_z80_aram_lds_n;

IGS026_Z80 igs026_z80(
    .clk,

    // CPU interface
    .cpu_addr(cpu_word_addr),
    .cpu_din(cpu_data_out),
    .cpu_dout(igs026_z80_q),
    .cpu_lds_n(cpu_ds_n[0]),
    .cpu_uds_n(cpu_ds_n[1]),
    .cpu_rw(cpu_rw),
    .cpu_cs_n(IGS026_Z80n),

    .v3021_cs_n,
    .v3021_wr_n,
    .v3021_dout(v3021_din),
    .v3021_din(v3021_dout),

    .aram_addr(igs026_z80_aram_addr),
    .aram_din(aram_q),
    .aram_dout(igs026_z80_aram_dout),
    .aram_lds_n(igs026_z80_aram_lds_n),
    .aram_uds_n(igs026_z80_aram_uds_n)
);

V3021 v3021(
    .clk,
    .ce_32khz,

    .cs_n(v3021_cs_n),
    .wr_n(v3021_wr_n),

    .in(v3021_din),
    .out(v3021_dout)
);

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

    .extra_rom_n(1),

    .as_n(ROMn | cpu_as_n),
    .dtack_n(sdr_dtack_n),
    .cpu_addr(cpu_addr),
    .data(rom_q)
);

always_ff @(posedge clk) begin
    prev_ds_n <= cpu_as_n;
end

`ifdef Z80
`ifdef USE_AUTO_SS
wire [31:0] z80_ss_in, z80_ss_out;
wire z80_ss_wr, z80_ss_rd, z80_ss_ack;
wire [15:0] z80_ss_state_idx;
wire [7:0] z80_ss_device_idx;

auto_save_adaptor2 #(.SS_IDX(SSIDX_Z80)) z80_ss_adaptor(
    .clk,
    .ssbus(ssb[4]),
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
    .cen(ce_4m),
    .reset_n(SNRESn),
    .wait_n(1),
    .int_n(SNINTn),
    .nmi_n(1),
    .busrq_n(1),
    .m1_n(),
    .mreq_n(SNMREQn),
    .iorq_n(),
    .rd_n(SNRDn),
    .wr_n(SNWRn),
    .rfsh_n(),
    .halt_n(),
    .busak_n(),
    .A(SND_ADD),
    .di(z80_din),
    .dout(z80_dout)
);
`endif

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
