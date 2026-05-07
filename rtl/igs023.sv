module IGS023 #(parameter SS_IDX=-1) (
    input clk,
    input ce_33m,
    input ce_50m,
    output ce_pixel,

    input reset,

    // CPU interface
    input [23:0] cpu_addr,
    input [15:0] cpu_din,
    output reg [15:0] cpu_dout,
    input cpu_lds_n,
    input cpu_uds_n,
    input cpu_rw,
    input cpu_cs_n,
    output cpu_dtack_n,
    input cpu_dtack_in_n,

    output cpu_br_n,
    output cpu_bgack_n,
    input cpu_bg_n,
    input cpu_as_n,

    output reg [15:0] dma_addr,
    input [15:0] dma_din,

    // VRAM interface
    output logic [14:0] vram_addr,
    input         [7:0] vram_din,
    output        [7:0] vram_dout,
    output logic        vram_we_n,
   
    output logic [12:0] pal_addr,
    input        [15:0] pal_din,
    output       [15:0] pal_dout,
    output logic        pal_we_u_n,
    output logic        pal_we_l_n,
 

    // ROM interface
    output reg [23:0] tile_rom_address,
    input      [31:0] tile_rom_data,
    output reg        tile_rom_req,
    input             tile_rom_ack,

    output reg [23:0] sprite_brom_address,
    input      [63:0] sprite_brom_data,
    output reg        sprite_brom_req,
    input             sprite_brom_ack,

    ddr_if.to_host    ddr,

    output reg        irq6,
    output reg        irq4,

    // Video interface
    output reg [14:0] vid_color,
    output reg vid_hsync,
    output reg vid_hblank,
    output reg vid_vsync,
    output reg vid_vblank,

    ssbus_if.slave ssbus
);

reg [4:0] ce_pixel_shift;
assign ce_pixel = ce_50m & ce_pixel_shift[4];
wire ce_pixel_pre1 = ce_50m & ce_pixel_shift[3];
wire ce_pixel_pre2 = ce_50m & ce_pixel_shift[2];
wire ce_pixel_post1 = ce_50m & ce_pixel_shift[0];
wire ce_pixel_post2 = ce_50m & ce_pixel_shift[1];
wire ce_pixel_post3 = ce_50m & ce_pixel_shift[2];

always_ff @(posedge clk) begin
    if (~|ce_pixel_shift) begin
        ce_pixel_shift <= 5'b00001;
    end else if (ce_50m) begin
        ce_pixel_shift <= {ce_pixel_shift[3:0], ce_pixel_shift[4]};
    end
end

assign tile_rom_address = fg_rom_master ? fg_rom_address : bg_rom_address;
assign tile_rom_req = fg_rom_master ? fg_rom_req : bg_rom_req;

reg dtack_n;
reg prev_cs_n;
wire is_reg_access = cpu_addr[21:20] == 2'b11;
wire is_vram_access = cpu_addr[21:20] == 2'b01;
wire is_pal_access = cpu_addr[21:20] == 2'b10;

reg ram_pending = 0;
reg [1:0] ram_access = 0;
wire vram_cpu_bus_free = ~fg_real_vram_master & ~bg_vram_master;
reg vram_cpu_bus_free_d;

reg [15:0] sprite_data[256 * 8];
reg [15:0] zoom_table[32];
reg [15:0] ctrl[16];
reg dma_start;

wire [15:0] bg_x = ctrl[3];
wire [15:0] bg_y = ctrl[2];
wire [15:0] fg_x = ctrl[6];
wire [15:0] fg_y = ctrl[5];
wire [15:0] ctrl_flags = ctrl[14];
wire bg_en = 1; // ~ctrl_flags[12];
wire fg_en = 1; // ~ctrl_flags[11];
wire dma_en = ctrl_flags[0];

assign cpu_dtack_n = cpu_cs_n ? 0 : dtack_n;

assign pal_dout = cpu_din[15:0];
assign vram_dout = vram_addr[0] ? cpu_din[15:8] : cpu_din[7:0]; // little endian ordering in vram

// 0 is the start of blanking
reg [8:0] vcnt;
reg [9:0] hcnt;

// 0 is the top/right of the screen
wire [10:0] logical_vcnt = { 2'b0, vcnt } - 38;

wire hsync = (hcnt >= 63 && hcnt < (63 + 63));
wire hblank = hcnt < 192;
wire vsync = (vcnt >= 14 && vcnt < (14 + 8));
wire vblank = vcnt < 38;

reg prev_fg_fpga_vram_master;
always @(posedge clk) begin
    fg_start_read <= 0;
    bg_start_read <= 0;

    if (ce_pixel) begin
        hcnt <= hcnt + 1;

        if (hcnt == 639) begin
            hcnt <= 0;
            vcnt <= vcnt + 1;
            if (vcnt == 261) begin
                vcnt <= 0;
            end
        end

        if (hcnt == 638 && vcnt > 36 && vcnt < 261) begin
            fg_read_y <= logical_vcnt[7:0] + fg_y[7:0] + 8'd1;
            fg_start_read <= 1;
            bg_read_y <= logical_vcnt[10:0] + bg_y[10:0] + 11'd1;
        end

        prev_fg_fpga_vram_master <= fg_fpga_vram_master;
        if (prev_fg_fpga_vram_master & ~fg_fpga_vram_master) bg_start_read <= 1;
    end
end

wire [9:0] bg_color;
wire [14:0] bg_vram_addr;
wire        bg_vram_master;
wire [23:0] bg_rom_address;
wire        bg_rom_req;

wire [8:0] fg_color;
wire [14:0] fg_vram_addr;
wire        fg_real_vram_master;
wire        fg_fpga_vram_master;
wire        fg_rom_master;
wire [23:0] fg_rom_address;
wire        fg_rom_req;
reg         fg_start_read;
reg   [7:0] fg_read_y;
reg         bg_start_read;
reg  [10:0] bg_read_y;

wire [11:0]  sprite_color;

IGS023_FG fg(
    .clk,
    .ce_33m,
    .ce_pixel,
    .start_read(fg_start_read),
    .scan_active(~(vblank | hblank)),
    .x(fg_x[8:0]),
    .y(fg_read_y),
    .color_out(fg_color),
    .vram_addr(fg_vram_addr),
    .vram_din(vram_din),
    .real_vram_master(fg_real_vram_master),
    .fpga_vram_master(fg_fpga_vram_master),
    .rom_master(fg_rom_master),
    .rom_address(fg_rom_address),
    .rom_data(tile_rom_data),
    .rom_req(fg_rom_req),
    .secondary_rom_req(bg_rom_req),
    .rom_ack(tile_rom_ack)
);

IGS023_BG bg(
    .clk(clk),
    .ce_pixel(ce_pixel),
    .start_read(bg_start_read),
    .scan_active(~(vblank | hblank)),
    .x(bg_x[10:0]),
    .y(bg_read_y),
    .screen_y(logical_vcnt[7:0]),
    .color_out(bg_color),
    .scale_bits_x({zoom_table[1], zoom_table[0]}),
    .scale_bits_y({zoom_table[1], zoom_table[0]}),
    .zoom_mode_x(0),
    .zoom_mode_y(0),
    .vram_addr(bg_vram_addr),
    .vram_din(vram_din),
    .vram_master(bg_vram_master),
    .rom_address(bg_rom_address),
    .rom_data(tile_rom_data),
    .rom_req(bg_rom_req),
    .rom_ack(tile_rom_ack)
);

reg sprite_frame_reset;
reg sprite_next_line;

IGS023_Sprite sprite(
    .clk(clk),
    .ce_pixel(ce_pixel),
    .frame_reset(sprite_frame_reset),
    .scan_active(~(vblank | hblank)),
    .next_line(sprite_next_line),

    .reset(reset),
    .dma_start(dma_start),
    .color_out(sprite_color),
    .cpu_br_n,
    .cpu_bgack_n,
    .cpu_bg_n,
    .cpu_as_n,
    .cpu_dtack_n(cpu_dtack_in_n),
    .dma_addr(dma_addr),
    .dma_din(dma_din),
    .brom_address(sprite_brom_address),
    .brom_data(sprite_brom_data),
    .brom_req(sprite_brom_req),
    .brom_ack(sprite_brom_ack),
    .ddr(ddr)
);

reg [12:0] color_addr;

reg hblank2, vblank2, hsync2, vsync2;
always_ff @(posedge clk) begin
    if (ce_pixel) begin
        vid_color <= pal_din[14:0];
        vsync2 <= vsync; vid_vsync <= vsync2;
        vblank2 <= vblank; vid_vblank <= vblank2;
        hsync2 <= hsync; vid_hsync <= hsync2;
        hblank2 <= hblank; vid_hblank <= hblank2;
        if (~&fg_color[3:0] & fg_en)
            color_addr <= 13'h1000 + { 3'd0, fg_color[8:0], 1'b0 };
        else if (sprite_color[11]) begin
            color_addr <= 13'h0000 + { 2'd0, sprite_color[9:0], 1'b0 };
        end else if (~&bg_color[4:0] & bg_en)
            color_addr <= 13'h0800 + { 2'd0, bg_color[9:0], 1'b0 };
        else
            color_addr <= 13'h07fe; // this seems to be the background color?
    end
end

always_comb begin
    vram_addr = fg_fpga_vram_master ? fg_vram_addr : bg_vram_addr;
    vram_we_n = 1;

    pal_addr  = color_addr;
    pal_we_l_n = 1;
    pal_we_u_n = 1;

    if (vram_cpu_bus_free) begin
        if (is_vram_access && ram_access == 2'd2) begin
            // VRAM stores words little-endian for the renderer.  CPU writes
            // therefore go low-byte/even then high-byte/odd, but CPU reads
            // must fetch high-byte/odd first so a 68000 word read matches the
            // value previously written.
            vram_addr = {cpu_addr[14:1], cpu_rw};
            vram_we_n = cpu_rw;
        end else if (is_vram_access && ram_access == 2'd1) begin
            vram_addr = {cpu_addr[14:1], ~cpu_rw};
            vram_we_n = cpu_rw;
        end else if (is_pal_access && |ram_access) begin
            pal_addr = cpu_addr[12:0];
            pal_we_l_n = cpu_lds_n | cpu_rw;
            pal_we_u_n = cpu_uds_n | cpu_rw;
        end
    end
end

reg vblank_prev;
reg hsync_prev;

wire irq6_en = ctrl[14][3];
wire irq4_en = ctrl[14][2];

reg [5:0] irq4_cnt;
always @(posedge clk) begin

    if (reset) begin
        dtack_n <= 1;
        ram_pending <= 0;
        ram_access <= 0;
        dma_start <= 0;
        irq6 <= 0;
        irq4 <= 0;
    end begin
        dma_start <= 0;
        vram_cpu_bus_free_d <= reset ? 1'b0 : vram_cpu_bus_free;
        
        sprite_frame_reset <= 0;
        sprite_next_line <= 0;

        // IRQ Generation
        vblank_prev <= vblank;
        hsync_prev <= hsync;
        if (vblank & ~vblank_prev & irq6_en) begin
            irq6 <= 1;
        end

        if (~irq6_en) begin
            irq6 <= 0;
        end

        if (~irq4_en) begin
            irq4 <= 0;
        end

        if (~vblank & vblank_prev) begin
            ctrl[7] <= 0;
        end else if (hsync & ~hsync_prev) begin
            sprite_next_line <= ~vblank;

            ctrl[7] <= ctrl[7] + 1;

            if (ctrl[7] == 221 && dma_en) begin
                dma_start <= 1;
            end

            if (irq4_cnt == 61) begin
                if (irq4_en) irq4 <= 1;
                irq4_cnt <= 0;
            end else begin
                irq4_cnt <= irq4_cnt + 1;
            end
        end

        if (vblank & ~vblank_prev) begin
            sprite_frame_reset <= 1;
        end

        // CPU interface handling
        prev_cs_n <= cpu_cs_n;
        if (~cpu_cs_n & prev_cs_n) begin // CS edge
            if (is_reg_access) begin
                if (cpu_rw) begin
                    case(cpu_addr[15:12])
                        1: cpu_dout <= zoom_table[cpu_addr[5:1]];
                        default: cpu_dout <= ctrl[cpu_addr[15:12]];
                    endcase
                end else begin
                    case(cpu_addr[15:12])
                        1: begin
                            if (~cpu_uds_n) zoom_table[cpu_addr[5:1]][15:8] <= cpu_din[15:8];
                            if (~cpu_lds_n) zoom_table[cpu_addr[5:1]][7:0]  <= cpu_din[7:0];
                        end
                        default: begin
                            if (~cpu_uds_n) ctrl[cpu_addr[15:12]][15:8] <= cpu_din[15:8];
                            if (~cpu_lds_n) ctrl[cpu_addr[15:12]][7:0]  <= cpu_din[7:0];
                        end
                    endcase
                end
                dtack_n <= 0;
            end else if (is_vram_access | is_pal_access) begin
                ram_pending <= 1;
             end
        end else if (cpu_cs_n) begin
            dtack_n <= 1;
        end

        if (ce_pixel) begin
            if (vram_cpu_bus_free && vram_cpu_bus_free_d) begin
                if (is_vram_access) begin
                    if (ram_access == 2'd2) begin
                        cpu_dout[15:8] <= vram_din;
                        ram_access <= 2'd1;
                    end else if (ram_access == 2'd1) begin
                        cpu_dout[7:0] <= vram_din;
                        ram_access <= 0;
                        dtack_n <= 0;
                    end
                end else if (is_pal_access) begin
                    if (|ram_access) begin
                        ram_access <= 0;
                        dtack_n <= 0;
                        cpu_dout <= pal_din;
                    end
                end
            end

            if (ram_pending & vram_cpu_bus_free) begin
                ram_access <= 2'd2;
                ram_pending <= 0;
            end
        end // ce_pixel
    end

    ssbus.setup(SS_IDX, 16 + 32 + (256 * 8), 1);
    if (ssbus.access(SS_IDX)) begin
        if (ssbus.write) begin
            if (ssbus.addr < 32) begin
                zoom_table[ssbus.addr[4:0]] <= ssbus.data[15:0];
            end else if (ssbus.addr < 48) begin
                ctrl[ssbus.addr[3:0]] <= ssbus.data[15:0];
            end else begin
                //sprite_data[ssbus.addr - 48] <= ssbus.data[15:0];
            end
            ssbus.write_ack(SS_IDX);
        end else if (ssbus.read) begin
            if (ssbus.addr < 32) begin
                ssbus.read_response(SS_IDX, { 48'b0, zoom_table[ssbus.addr[4:0]] });
            end else if (ssbus.addr < 48) begin
                ssbus.read_response(SS_IDX, { 48'b0, ctrl[ssbus.addr[3:0]] });
            end else begin
                //ssbus.read_response(SS_IDX, { 48'b0, sprite_data[ssbus.addr - 48] });
                ssbus.read_response(SS_IDX, 64'b0); // TODO
            end
        end
    end
end

endmodule

