import system_consts::*;

module sim_top(
    input             clk,
    input             reset,

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

    output reg [26:0] sdr_addr,
    input      [63:0] sdr_q,
    output reg [63:0] sdr_data,
    output reg        sdr_req,
    output reg        sdr_rw,
    output reg  [7:0] sdr_be,
    input             sdr_ack,

    // DDR interface
    output            ddr_acquire,
    output     [31:0] ddr_addr,
    output     [63:0] ddr_wdata,
    input      [63:0] ddr_rdata,
    output            ddr_read,
    output            ddr_write,
    output      [7:0] ddr_burstcnt,
    output      [7:0] ddr_byteenable,
    input             ddr_busy,
    input             ddr_read_complete,

    // IOCTL interface
    input             ioctl_download,
    input       [7:0] ioctl_index,
    input             ioctl_wr,
    input      [26:0] ioctl_addr,
    input       [7:0] ioctl_dout,
    output            ioctl_wait,

    input      [12:0] obj_debug_idx,

    output     [15:0] audio_out,
    input       [1:0] audio_filter_en,

    input             ss_do_save,
    input             ss_do_restore,
    input       [1:0] ss_index,
    output      [3:0] ss_state_out,

    input             sync_fix,

    input             pause
);

wire [26:0] sdr_cpu_addr, sdr_tile_addr, sdr_sprite_addr, sdr_audio_addr, sdr_rom_addr;
wire sdr_cpu_req, sdr_tile_req, sdr_sprite_req, sdr_audio_req, sdr_rom_req;
reg  sdr_cpu_ack, sdr_tile_ack, sdr_sprite_ack, sdr_audio_ack, sdr_rom_ack;
wire sdr_rom_rw;
wire [1:0] sdr_rom_be;
reg [63:0] sdr_cpu_q;
reg [31:0] sdr_tile_q;
reg [63:0] sdr_sprite_q;
reg [63:0] sdr_audio_q;
wire [15:0] sdr_rom_data;




ddr_if ddr_host(), ddr_romload(), ddr_x(), ddr_romload_adaptor(), ddr_romload_loader(), ddr_pgm();

ddr_mux ddr_mux(
    .clk(clk),
    .x(ddr_host),
    .a(ddr_pgm),
    .b(ddr_romload)
);

ddr_mux ddr_mux2(
    .clk(clk),
    .x(ddr_romload),
    .a(ddr_romload_adaptor),
    .b(ddr_romload_loader)
);

assign ddr_addr = ddr_host.addr;
assign ddr_byteenable = ddr_host.byteenable;
assign ddr_write = ddr_host.write;
assign ddr_read = ddr_host.read;
assign ddr_wdata = ddr_host.wdata;
assign ddr_burstcnt = ddr_host.burstcnt;
assign ddr_host.rdata = ddr_rdata;
assign ddr_host.rdata_ready = ddr_read_complete;
assign ddr_host.busy = ddr_busy;

wire rom_load_busy /* verilator public_flat */;
wire rom_data_wait;
wire rom_data_strobe;
wire [7:0] rom_data;

wire rom_set_map_base;
wire [3:0] rom_base_idx;
wire [31:0] rom_map_base;

wire [23:0] bram_addr;
wire  [7:0] bram_data;
wire        bram_wr;

board_cfg_t board_cfg;

reg cart_present /* verilator public_flat */;
reg [23:0] cart_tile_base /* verilator public_flat */;
reg [23:0] cart_prog_base /* verilator public_flat */;
reg [23:0] cart_music_base /* verilator public_flat */;

ddr_rom_loader_adaptor ddr_rom_loader(
    .clk(clk),

    .ioctl_download,
    .ioctl_addr,
    .ioctl_index,
    .ioctl_wr,
    .ioctl_data(ioctl_dout),
    .ioctl_wait,

    .busy(rom_load_busy),

    .data_wait(rom_data_wait),
    .data_strobe(rom_data_strobe),
    .data(rom_data),

    .ddr(ddr_romload_adaptor)
);

rom_loader rom_loader(
    .sys_clk(clk),

    .ioctl_wr(rom_data_strobe),
    .ioctl_data(rom_data),
    .ioctl_wait(rom_data_wait),

    .sdr_addr(sdr_rom_addr),
    .sdr_data(sdr_rom_data),
    .sdr_be(sdr_rom_be),
    .sdr_req(sdr_rom_req),
    .sdr_ack(sdr_rom_ack),
    .sdr_rw(sdr_rom_rw),

    .ddr(ddr_romload_loader),

    .bram_addr(bram_addr),
    .bram_data(bram_data),
    .bram_wr(bram_wr),

    .board_cfg(board_cfg),

    .set_map_base(rom_set_map_base),
    .map_base(rom_map_base),
    .base_idx(rom_base_idx)
);

reg prev_rom_load_busy;

always_ff @(posedge clk) begin
    prev_rom_load_busy <= rom_load_busy;

    if (rom_load_busy & ~prev_rom_load_busy) begin
        cart_present <= 0;
    end

    if (rom_set_map_base) begin
        case (rom_base_idx)
            1: begin
                cart_prog_base <= rom_map_base[23:0];
                cart_present <= 1;
            end
            2: begin
                cart_tile_base <= rom_map_base[23:0];
                cart_present <= 1;
            end
            3: begin
                cart_music_base <= rom_map_base[23:0];
                cart_present <= 1;
            end
            default: begin end
        endcase
    end
end

// Instantiate the PGM module
PGM pgm_inst(
    .clk_50m(clk),
    .reset(reset | rom_load_busy),
    .game(board_cfg.game),
    
    .ce_pixel(ce_pixel),
    .hsync(hsync),
    .hblank(hblank),
    .vsync(vsync),
    .vblank(vblank),
    .red(red),
    .green(green),
    .blue(blue),
    
    .joystick_p1(joystick_p1),
    .joystick_p2(joystick_p2),
    .joystick_p3(joystick_p3),
    .joystick_p4(joystick_p4),
    .start(start),
    .coin(coin),
    
    .analog_inc(analog_inc),
    .analog_abs(analog_abs),
    .analog_p1(analog_p1),
    .analog_p2(analog_p2),
    
    .dswa(dswa),
    .dswb(dswb),
    
    .sdr_cpu_addr(sdr_cpu_addr),
    .sdr_cpu_q(sdr_cpu_q),
    .sdr_cpu_req(sdr_cpu_req),
    .sdr_cpu_ack(sdr_cpu_ack),
    
    .sdr_tile_addr(sdr_tile_addr),
    .sdr_tile_q(sdr_tile_q),
    .sdr_tile_req(sdr_tile_req),
    .sdr_tile_ack(sdr_tile_ack),
    
    .sdr_sprite_addr(sdr_sprite_addr),
    .sdr_sprite_q(sdr_sprite_q),
    .sdr_sprite_req(sdr_sprite_req),
    .sdr_sprite_ack(sdr_sprite_ack),
    
    .sdr_audio_addr(sdr_audio_addr),
    .sdr_audio_q(sdr_audio_q),
    .sdr_audio_req(sdr_audio_req),
    .sdr_audio_ack(sdr_audio_ack),

    .cart_present,
    .cart_prog_base,
    .cart_tile_base,
    .cart_music_base,
    
    .ddr(ddr_pgm),
    
    .obj_debug_idx(obj_debug_idx),

    .audio_out(audio_out),
    .audio_filter_en(audio_filter_en),
    
    .ss_do_save(ss_do_save),
    .ss_do_restore(ss_do_restore),
    .ss_index(ss_index),
    .ss_state_out(ss_state_out),
    
    .bram_addr(bram_addr),
    .bram_data(bram_data),
    .bram_wr(bram_wr),
    
    .sync_fix(sync_fix),
    
    .pause(pause)
);

reg sdr_active;
reg sdr_refresh;
reg [2:0] sdr_active_ch;
reg [2:0] sdr_dly_count;

always_ff @(posedge clk) begin
    sdr_dly_count <= sdr_dly_count + 1;

    if (sdr_refresh) begin
        if (sdr_dly_count == 3) begin
            sdr_refresh <= 0;
        end
    end else if (sdr_active) begin
        if (sdr_req == sdr_ack && sdr_dly_count == 4) begin
            case(sdr_active_ch)
            0: begin
                sdr_cpu_ack <= sdr_cpu_req;
                sdr_cpu_q <= sdr_q;
            end
            1: begin
                sdr_tile_ack <= sdr_tile_req;
                sdr_tile_q <= sdr_q[31:0];
            end
            2: begin
                sdr_sprite_ack <= sdr_sprite_req;
                sdr_sprite_q <= sdr_q;
            end
            3: begin
                sdr_audio_ack <= sdr_audio_req;
                sdr_audio_q <= sdr_q;
            end
            4: begin
                sdr_rom_ack <= sdr_rom_req;
            end
            default: begin end
            endcase

            sdr_active <= 0;
        end
    end else begin
        sdr_dly_count <= 0;
        if (sdr_audio_req != sdr_audio_ack) begin
            sdr_rw <= 1;
            sdr_addr <= sdr_audio_addr;
            sdr_req <= ~sdr_req;
            sdr_active <= 1;
            sdr_active_ch <= 3;
        end else if (sdr_tile_req != sdr_tile_ack) begin
            sdr_rw <= 1;
            sdr_addr <= sdr_tile_addr;
            sdr_req <= ~sdr_req;
            sdr_active <= 1;
            sdr_active_ch <= 1;
        end else if (sdr_sprite_req != sdr_sprite_ack) begin
            sdr_rw <= 1;
            sdr_addr <= sdr_sprite_addr;
            sdr_req <= ~sdr_req;
            sdr_active <= 1;
            sdr_active_ch <= 2;
        end else if (sdr_cpu_req != sdr_cpu_ack) begin
            sdr_rw <= 1;
            sdr_addr <= sdr_cpu_addr;
            sdr_req <= ~sdr_req;
            sdr_active <= 1;
            sdr_active_ch <= 0;
        end else if (sdr_rom_req != sdr_rom_ack) begin
            sdr_rw <= sdr_rom_rw;
            sdr_addr <= sdr_rom_addr;
            sdr_data <= { 48'd0, sdr_rom_data[15:0] };
            sdr_be <= { 6'd0, sdr_rom_be };
            sdr_req <= ~sdr_req;
            sdr_active <= 1;
            sdr_active_ch <= 4;
        end else begin
            sdr_refresh <= 0;
        end
    end
end

endmodule
