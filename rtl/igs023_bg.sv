module IGS023_BG(
    input clk,
    input ce_pixel,

    input start_read,
    input scan_active,

    input [10:0] x,
    input [10:0] y,
    input [7:0] screen_y,

    output [9:0] color_out,

    input [31:0] scale_bits_x,
    input [31:0] scale_bits_y,
    input        zoom_mode_x,
    input        zoom_mode_y,

    // VRAM interface
    output logic [14:0] vram_addr,
    input        [7:0]  vram_din,
    output              vram_master,
    
    // ROM interface
    output reg [23:0] rom_address,
    input      [31:0] rom_data,
    output reg        rom_req,
    input             rom_ack
);


reg [4:0] buffer[32];
reg [4:0] pal_buffer[32];

reg [31:0] scale_shifter_x;

reg load_buffer;
reg [31:0] stage_data;
reg [2:0] load_slot;

logic [8:0] slot_increment[5] = '{ 6, 6, 7, 6, 7 };
reg [8:0] pixel_in_idx, pixel_out_idx;

wire buffer_ready = (slot_increment[load_slot] + pixel_in_idx) < pixel_out_idx;

typedef enum logic[3:0] {
    READ_SCROLL0, READ_SCROLL1, READ_SCROLL2, APPLY_SCROLL,
    READ0, READ1, READ2, READ3,
    ROM_REQ0, ROM_WAIT0,
    ROM_WAIT1,
    ROM_WAIT2,
    ROM_WAIT3,
    ROM_WAIT4,
    DONE
} state_t;

state_t state = DONE;

assign vram_master = (state <= READ3);

reg [14:0] scroll_addr;
reg [15:0] scroll;
reg [6:0] vram_row_addr;
reg [7:0] tile_addr;

wire [10:0] scrolled_x = x + scroll[10:0];

reg [15:0] tile_code;
reg [7:0] tile_attrib;

reg flip_x;
reg [4:0] palette;

assign vram_addr = ( state < APPLY_SCROLL ) ? scroll_addr : { vram_row_addr, tile_addr };

assign color_out = { pal_buffer[pixel_out_idx[4:0]], buffer[pixel_out_idx[4:0]] };

reg prev_scan_active;

always_ff @(posedge clk) begin
    if (start_read) begin
        state <= READ_SCROLL0;
    end

    if (load_buffer) begin
        case(load_slot)
            0: begin
                buffer[0] <= stage_data[4:0]; pal_buffer[0] <= palette;
                buffer[1] <= stage_data[9:5]; pal_buffer[1] <= palette;
                buffer[2] <= stage_data[14:10]; pal_buffer[2] <= palette;
                buffer[3] <= stage_data[19:15]; pal_buffer[3] <= palette;
                buffer[4] <= stage_data[24:20]; pal_buffer[4] <= palette;
                buffer[5] <= stage_data[29:25]; pal_buffer[5] <= palette;
                buffer[6][1:0] <= stage_data[31:30];
            end
            1: begin
                buffer[6][4:2] <= stage_data[2:0]; pal_buffer[6] <= palette;
                buffer[7] <= stage_data[7:3]; pal_buffer[7] <= palette;
                buffer[8] <= stage_data[12:8]; pal_buffer[8] <= palette;
                buffer[9] <= stage_data[17:13]; pal_buffer[9] <= palette;
                buffer[10] <= stage_data[22:18]; pal_buffer[10] <= palette;
                buffer[11] <= stage_data[27:23]; pal_buffer[11] <= palette;
                buffer[12][3:0] <= stage_data[31:28];
            end
            2: begin
                buffer[12][4] <= stage_data[0]; pal_buffer[12] <= palette;
                buffer[13] <= stage_data[5:1]; pal_buffer[13] <= palette;
                buffer[14] <= stage_data[10:6]; pal_buffer[14] <= palette;
                buffer[15] <= stage_data[15:11]; pal_buffer[15] <= palette;
                buffer[16] <= stage_data[20:16]; pal_buffer[16] <= palette;
                buffer[17] <= stage_data[25:21]; pal_buffer[17] <= palette;
                buffer[18] <= stage_data[30:26]; pal_buffer[18] <= palette;
                buffer[19][0] <= stage_data[31];
            end
            3: begin
                buffer[19][4:1] <= stage_data[3:0]; pal_buffer[19] <= palette;
                buffer[20] <= stage_data[8:4]; pal_buffer[20] <= palette;
                buffer[21] <= stage_data[13:9]; pal_buffer[21] <= palette;
                buffer[22] <= stage_data[18:14]; pal_buffer[22] <= palette;
                buffer[23] <= stage_data[23:19]; pal_buffer[23] <= palette;
                buffer[24] <= stage_data[28:24]; pal_buffer[24] <= palette;
                buffer[25][2:0] <= stage_data[31:29];
            end
            4: begin
                buffer[25][4:3] <= stage_data[1:0]; pal_buffer[25] <= palette;
                buffer[26] <= stage_data[6:2]; pal_buffer[26] <= palette;
                buffer[27] <= stage_data[11:7]; pal_buffer[27] <= palette;
                buffer[28] <= stage_data[16:12]; pal_buffer[28] <= palette;
                buffer[29] <= stage_data[21:17]; pal_buffer[29] <= palette;
                buffer[30] <= stage_data[26:22]; pal_buffer[30] <= palette;
                buffer[31] <= stage_data[31:27]; pal_buffer[31] <= palette;
            end
            default: begin end
        endcase
        
        load_buffer <= 0;
        pixel_in_idx <= pixel_in_idx + slot_increment[load_slot];
        load_slot <= load_slot + 1;
        if (load_slot == 4) load_slot <= 0;
    end

    if (scale_shifter_x[0]) begin
        pixel_out_idx <= pixel_out_idx + 1;
        scale_shifter_x <= { scale_shifter_x[0], scale_shifter_x[31:1] };
    end

    if (ce_pixel) begin
        if (scan_active) begin
            pixel_out_idx <= pixel_out_idx + 1;
            scale_shifter_x <= { scale_shifter_x[0], scale_shifter_x[31:1] };
        end

        case(state)
            READ_SCROLL0: begin
                state <= READ_SCROLL1;
                scroll_addr <= 15'h7000 + { 6'b0, screen_y[7:0], 1'b0 };
            end

            READ_SCROLL1: begin
                scroll[7:0] <= vram_din;
                state <= READ_SCROLL2;
                scroll_addr <= 15'h7000 + { 6'b0, screen_y[7:0], 1'b1 };
            end

            READ_SCROLL2: begin
                scroll[15:8] <= vram_din;
                state <= APPLY_SCROLL;
            end

            APPLY_SCROLL: begin
                pixel_out_idx <= { 4'd1, scrolled_x[4:0] };
                scale_shifter_x <= scale_bits_x;
                pixel_in_idx <= 0;
                vram_row_addr <= { 1'b0, y[10:5] };
                tile_addr <= {scrolled_x[10:5], 2'b00};
                state <= READ0;
            end

            READ0: begin
                state <= READ1;
            end
            READ1: begin
                tile_code[7:0] <= vram_din;
                tile_addr <= tile_addr + 1;
                state <= READ2;
            end
            READ2: begin
                tile_code[15:8] <= vram_din;
                tile_addr <= tile_addr + 1;
                state <= READ3;
            end
            READ3: begin
                tile_attrib[7:0] <= vram_din;
                tile_addr <= tile_addr + 2;
                state <= ROM_REQ0;
            end

            ROM_REQ0: begin
                rom_address <= { tile_code[14:0], y[4:0], 4'd0 } + { 2'b0, tile_code[14:0], y[4:0], 2'd0 };
                rom_req <= ~rom_req;
                palette <= tile_attrib[5:1];
                state <= ROM_WAIT0;
            end

            ROM_WAIT0: begin
                if (rom_req == rom_ack && buffer_ready) begin
                    stage_data <= rom_data;
                    load_buffer <= 1;
                    rom_address <= rom_address + 4;
                    rom_req <= ~rom_req;
                    state <= ROM_WAIT1;
                end
            end

            ROM_WAIT1: begin
                if (rom_req == rom_ack && buffer_ready) begin
                    stage_data <= rom_data;
                    load_buffer <= 1;
                    rom_address <= rom_address + 4;
                    rom_req <= ~rom_req;
                    state <= ROM_WAIT2;
                end
            end

            ROM_WAIT2: begin
                if (rom_req == rom_ack && buffer_ready) begin
                    stage_data <= rom_data;
                    load_buffer <= 1;
                    rom_address <= rom_address + 4;
                    rom_req <= ~rom_req;
                    state <= ROM_WAIT3;
                end
            end

            ROM_WAIT3: begin
                if (rom_req == rom_ack && buffer_ready) begin
                    stage_data <= rom_data;
                    load_buffer <= 1;
                    rom_address <= rom_address + 4;
                    rom_req <= ~rom_req;
                    state <= ROM_WAIT4;
                end
            end

            ROM_WAIT4: begin
                if (rom_req == rom_ack && buffer_ready) begin
                    stage_data <= rom_data;
                    load_buffer <= 1;
                    state <= READ0;
                end
            end

            DONE: begin rom_req <= rom_ack; end
            default: begin end
        endcase
    end

    prev_scan_active <= scan_active;
    if (prev_scan_active & ~scan_active) begin
        load_slot <= 0;
        load_buffer <= 0;
        state <= DONE;
    end

end

endmodule
