module tc0100scn_shifter #(
    parameter TILE_WIDTH=8,
    parameter LENGTH=4
    )
(
    input                                         clk,
    input                                         ce,

    input                                         load,
    input [$clog2(LENGTH)-1:0]                    load_index,
    input [4:0]                                   load_color,
    input [(TILE_WIDTH*4)-1:0]                    load_data,
    input                                         load_flip,

    input [$clog2(LENGTH)+$clog2(TILE_WIDTH)-1:0] tap,
    output reg [9:0]                             dot_out
);

reg [4:0] color_buf[LENGTH];
reg [(TILE_WIDTH*4)-1:0] pixel_buf[LENGTH];

wire [$clog2(LENGTH)-1:0] tap_index = tap[$left(tap):$clog2(TILE_WIDTH)];
wire [$clog2(TILE_WIDTH)-1:0] tap_pixel = tap[$clog2(TILE_WIDTH)-1:0];

always_ff @(posedge clk) begin
    if (load) begin

        color_buf[load_index] <= load_color;
        if (~load_flip) begin
            int i;
            for( i = 0; i < TILE_WIDTH; i = i + 1 ) begin
                pixel_buf[load_index][(4 * ((TILE_WIDTH-1) - i)) +: 4] <= load_data[(4 * i) +: 4];
            end
        end else begin
            pixel_buf[load_index] <= load_data;
        end
    end

    if (ce) begin
        dot_out <= { color_buf[tap_index], 1'b0, pixel_buf[tap_index][(4 * tap_pixel) +: 4] };
    end
end

endmodule

module IGS023 #(parameter SS_IDX=-1) (
    input clk,
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

    // VRAM interface
    output logic [15:0] vram_addr,
    input        [15:0] vram_din,
    output       [15:0] vram_dout,
    output logic        vram_we_u_n,
    output logic        vram_we_l_n,
    
    output logic [14:0] pal_addr,
    input         [7:0] pal_din,
    output        [7:0] pal_dout,
    output logic        pal_we_n,


    // ROM interface
    output reg [20:0] rom_address,
    input      [31:0] rom_data,
    output reg        rom_req,
    input             rom_ack,

    output reg        vblank_irq,

    // Video interface
    output reg [14:0] color,
    output hsync,
    output hblank,
    output vsync,
    output vblank,

    ssbus_if.slave ssbus
);

typedef enum bit [2:0]
{
    CPU_ACCESS_0,
    FG_ATTRIB0,
    CPU_ACCESS_1,
    FG_ATTRIB1,
    IDLE0,
    IDLE1,
    IDLE2,
    IDLE3
} access_state_t;

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

reg dtack_n;
reg prev_cs_n;
wire is_reg_access = cpu_addr[21:20] == 2'b11;
wire is_vram_access = cpu_addr[21:20] == 2'b01;
wire is_pal_access = cpu_addr[21:20] == 2'b10;

reg ram_pending = 0;
reg [1:0] ram_access = 0;

reg [8:0] hcnt_actual, vcnt_actual;

reg [15:0] sprite_data[256 * 8];
reg [15:0] zoom_table[32];
reg [15:0] ctrl[16];

wire [15:0] bg_x = ctrl[3];
wire [15:0] bg_y = ctrl[2];
wire [15:0] fg_x = ctrl[6];
wire [15:0] fg_y = ctrl[5];
wire [15:0] ctrl_flags = ctrl[14];
wire bg_en = ~ctrl_flags[12];
wire fg_en = ~ctrl_flags[11];

wire [8:0] vcnt = vcnt_actual;
wire [8:0] hcnt = hcnt_actual;

assign cpu_dtack_n = cpu_cs_n ? 0 : dtack_n;

assign pal_dout = pal_addr[0] ? cpu_din[7:0] : cpu_din[15:8];
assign vram_dout = cpu_din;

assign hsync = ~(hcnt_actual >= 25 && hcnt_actual < 345);
assign hblank = hsync;
assign vsync = ~(vcnt_actual >= 2 && vcnt_actual < 226);
assign vblank = vsync;


always @(posedge clk) begin
    if (reset) begin
        hcnt_actual <= 0;
        vcnt_actual <= 0;
    end else if (ce_pixel) begin
        hcnt_actual <= hcnt_actual + 1;

        // TODO - random numbers
        if (hcnt_actual == 424) begin
            hcnt_actual <= 504;
            vcnt_actual <= vcnt_actual + 1;
            if (vcnt_actual == 250) begin
                vcnt_actual <= 0;
            end
        end
    end
end

access_state_t access_cycle;
access_state_t next_access_cycle;

wire [8:0] bg_hofs = bg_x[8:0] + bg_rowscroll[8:0];
wire [9:0] bg_dot, fg_dot;
reg [15:0] bg_rowscroll;
reg [15:0] bg_code, bg_attrib;
reg [15:0] fg_code, fg_attrib;

reg bg_load, fg_load;
reg bg_rom_req, fg_rom_req;
reg [20:0] bg_rom_address;
reg [20:0] fg_rom_address;

reg [1:0] rom_req_ch;

wire bg_flipx = bg_attrib[6];
wire bg_flipy = bg_attrib[7];
wire fg_flipx = fg_attrib[6];
wire fg_flipy = fg_attrib[7];

wire [8:0] bg_draw_hcnt = (hcnt - bg_hofs);
wire [8:0] fg_draw_hcnt = (hcnt - fg_x[8:0]);

reg [1:0] bg_load_index;
reg [8:0] bg_load_hcnt, fg_load_hcnt;

tc0100scn_shifter bg_shift(
    .clk, .ce(ce_pixel),
    .tap(bg_draw_hcnt[4:0]),
    .load_index(bg_load_index),
    .load_data({rom_data[15:8], rom_data[7:0], rom_data[31:24], rom_data[23:16]}),
    .load_color(bg_attrib[5:1]),
    .load_flip(bg_flipx),
    .dot_out(bg_dot),
    .load(bg_load)
);

tc0100scn_shifter fg_shift(
    .clk, .ce(ce_pixel),
    .tap(fg_draw_hcnt[4:0]),
    .load_index(fg_load_hcnt[4:3]),
    .load_data({rom_data}),
    .load_color(fg_attrib[5:1]),
    .load_flip(~fg_flipx),
    .dot_out(fg_dot),
    .load(fg_load)
);

wire [15:0] bg_addr           = 16'h0000;
wire [15:0] fg_addr           = 16'h4000;
wire [15:0] bg_rowscroll_addr = 16'h7000;

reg [6:0] color_read;
reg [14:0] color_addr;

always_ff @(posedge clk) begin
    if (ce_pixel) begin
        color <= {color_read, pal_din[7:0]};
        color_addr <= 14'h1000 + { 4'd0, fg_dot[9:5], fg_dot[3:0], 1'b0 };
    end else if (ce_pixel_post2) begin
        color_addr <= 14'h1000 + { 4'd0, fg_dot[9:5], fg_dot[3:0], 1'b1 };
        color_read <= pal_din[6:0];
    end
end

always_comb begin
    bit [5:0] h;
    bit [8:0] v;

    vram_addr = 16'd0;
    vram_we_l_n = 1;
    vram_we_u_n = 1;

    pal_addr  = color_addr;
    pal_we_n = 1;

    v = 0;

    next_access_cycle = access_state_t'(access_cycle + 3'd1);

    unique case(access_cycle)
        FG_ATTRIB0: begin
            v = vcnt - fg_y[8:0];
            vram_addr = fg_addr + { 2'b0, v[8:3], fg_load_hcnt[8:3], 2'b00 };
        end

        FG_ATTRIB1: begin
            v = vcnt - fg_y[8:0];
            vram_addr = fg_addr + { 2'b0, v[8:3], fg_load_hcnt[8:3], 2'b10 };
        end

        CPU_ACCESS_0,
        CPU_ACCESS_1: begin
            if (is_pal_access && ram_access == 2'd2) begin
                pal_addr = {cpu_addr[14:1], 1'b0};
                pal_we_n = cpu_rw;
            end else if (is_pal_access && ram_access == 2'd1) begin
                pal_addr = {cpu_addr[14:1], 1'b1};
                pal_we_n = cpu_rw;
            end else if (is_vram_access && |ram_access) begin
                vram_addr = cpu_addr[15:0];
                vram_we_l_n = cpu_lds_n | cpu_rw;
                vram_we_u_n = cpu_uds_n | cpu_rw;
            end
        end
        default: begin end
    endcase
end

reg vblank_prev;
always @(posedge clk) begin
    bit [8:0] v;
    bit [5:0] h;

    if (reset) begin
        dtack_n <= 1;
        ram_pending <= 0;
        ram_access <= 0;
        vblank_irq <= 0;
    end begin
        
        vblank_prev <= vblank;
        if (vblank & ~vblank_prev) vblank_irq <= 1;
        if (ctrl[14][3]) begin
            vblank_irq <= 0;
            ctrl[14][3] <= 0;
        end

        // CPU interface handling
        prev_cs_n <= cpu_cs_n;
        if (~cpu_cs_n & prev_cs_n) begin // CS edge
            if (is_reg_access) begin
                if (cpu_rw) begin
                    cpu_dout <= ctrl[cpu_addr[15:12]];
                end else begin
                    if (~cpu_uds_n) ctrl[cpu_addr[15:12]][15:8] <= cpu_din[15:8];
                    if (~cpu_lds_n) ctrl[cpu_addr[15:12]][7:0]  <= cpu_din[7:0];
                end
                dtack_n <= 0;
            end else if (is_vram_access | is_pal_access) begin
                ram_pending <= 1;
             end
        end else if (cpu_cs_n) begin
            dtack_n <= 1;
        end

        if (ce_pixel) begin
            bg_load <= 0;
            fg_load <= 0;
            unique case(access_cycle)
                FG_ATTRIB0: fg_code <= vram_din;
                FG_ATTRIB1: begin
                    fg_attrib <= vram_din;
                    fg_rom_address <= { fg_code, vcnt[2:0], 2'd0 };
                    fg_rom_req <= 1;
                end

                CPU_ACCESS_0,
                CPU_ACCESS_1: begin
                    if (is_pal_access) begin
                        if (ram_access == 2'd2) begin
                            cpu_dout[15:8] <= pal_din;
                            ram_access <= 2'd1;
                        end else if (ram_access == 2'd1) begin
                            cpu_dout[7:0] <= pal_din;
                            ram_access <= 0;
                            dtack_n <= 0;
                        end
                    end else if (is_vram_access) begin
                        if (|ram_access) begin
                            ram_access <= 0;
                            dtack_n <= 0;
                            cpu_dout <= vram_din;
                        end
                    end
                end
                default: begin end
            endcase

            access_cycle <= next_access_cycle;
            case(next_access_cycle)
                CPU_ACCESS_0,
                CPU_ACCESS_1: begin
                    if (ram_pending) begin
                        ram_access <= 2'd2;
                        ram_pending <= 0;
                    end
                end

                FG_ATTRIB0: begin
                    bg_load_hcnt <= (hcnt + 9'd16) - bg_hofs;
                    fg_load_hcnt <= (hcnt + 9'd16) - fg_x[8:0];
                end

                default: begin
                end
            endcase
        end // ce_pixel

        if (rom_req == rom_ack) begin
            if (rom_req_ch == 1) begin
                bg_load <= 1;
                rom_req_ch <= 0;
            end else if (rom_req_ch == 2) begin
                fg_load <= 1;
                rom_req_ch <= 0;
            end else begin
                if (bg_rom_req) begin
                    rom_address <= bg_rom_address;
                    rom_req <= ~rom_req;
                    rom_req_ch <= 1;
                    bg_rom_req <= 0;
                end else if (fg_rom_req) begin
                    rom_address <= fg_rom_address;
                    rom_req <= ~rom_req;
                    rom_req_ch <= 2;
                    fg_rom_req <= 0;
                end
            end
        end
    end

    ssbus.setup(SS_IDX, 16, 1);
    if (ssbus.access(SS_IDX)) begin
        if (ssbus.write) begin
            ctrl[ssbus.addr[3:0]] <= ssbus.data[15:0];
            ssbus.write_ack(SS_IDX);
        end else if (ssbus.read) begin
            ssbus.read_response(SS_IDX, { 48'b0, ctrl[ssbus.addr[3:0]] });
        end
    end
end

endmodule

