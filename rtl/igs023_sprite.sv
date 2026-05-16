import system_consts::arom_offset_t;

module IGS023_Sprite(
    input clk,
    input ce_pixel,
    input scan_active,
    input frame_reset,
    input next_line,

    input reset,

    input dma_start,

    output [11:0] color_out,

    // DMA interface
    output reg cpu_br_n,
    output reg cpu_bgack_n,
    input      cpu_bg_n,
    input      cpu_as_n,
    input      cpu_dtack_n,
    output reg [15:0] dma_addr,
    input      [15:0] dma_din,
    
    // ROM interface
    output reg [23:0] brom_address,
    input      [63:0] brom_data,
    output reg        brom_req,
    input             brom_ack,
    
    ddr_if.to_host    ddr
);

typedef enum bit [4:0] {
    DMA_IDLE, DMA_BUS_REQUEST, DMA_READ0, DMA_READ1, DMA_READ2, DMA_READ3, DMA_FINISH,
    PRESCAN_LOAD, PRESCAN_INITIAL_BROM, PRESCAN_INITIAL_BROM_WAIT, PRESCAN_INITIAL_NEXT,
    PRESCAN_NEXT, PRESCAN_SCAN_TO_START, PRESCAN_BROM_WAIT,
    DRAW_INIT, DRAW_LINE_WAIT, DRAW_SEARCH_ACTIVE_LOAD, DRAW_SEARCH_ACTIVE_CHECK,
    DRAW_ROW, DRAW_SPAN, DRAW_ROW_END, DRAW_BROM_WAIT, SKIP_ROW, SKIP_ROW_BROM_WAIT
} dma_state_t;

logic [31:0] scale_pattern [32] =
'{
   32'hAAAAAAAA, 32'hA8AAAAAA, 32'hA8AAA8AA, 32'hA8A8A8AA, 32'hA8A8A8A8, 32'h88A8A8A8, 32'h88A888A8, 32'h888888A8,
   32'h88888888, 32'h80888888, 32'h80888088, 32'h80808088, 32'h80808080, 32'h80008080, 32'h80008000, 32'h00008000,
   32'h00000000, 32'h00010000, 32'h00010001, 32'h01010001, 32'h01010101, 32'h01110101, 32'h01110111, 32'h11110111,
   32'h11111111, 32'h11511111, 32'h11511151, 32'h51511151, 32'h51515151, 32'h51555151, 32'h51555155, 32'h55555155
};

function automatic [11:0] scaled_width(input [4:0] scale, input [5:0] width);
begin
    bit [5:0] width32;
    width32 = { 1'b0, scale } + 6'd16;
    scaled_width = ({ 6'd0, width32 } * { 7'd0, width[5:1] } ) + ( width[0] ? { 7'd0, width32[5:1] } : 12'd0 );
end
endfunction

dma_state_t dma_state = DMA_IDLE;
reg [2:0] sprite_component_index;
reg [8:0] sprite_index;
reg [8:0] sprite_count /* verilator public_flat */;

reg [15:0] sprite_d0[256] /* verilator public_flat */;
reg [15:0] sprite_d1[256] /* verilator public_flat */;
reg [15:0] sprite_d2[256] /* verilator public_flat */;
reg [15:0] sprite_d3[256] /* verilator public_flat */;
reg [15:0] sprite_d4[256] /* verilator public_flat */;

reg [10:0] spr_x;
reg [9:0] spr_y;
reg [22:0] spr_brom_base_addr;
reg spr_prio;
reg [4:0] spr_palette;
reg spr_x_flip;
reg spr_y_flip;
reg [5:0] spr_width;
reg [11:0] spr_scaled_width;
reg [8:0] spr_height;
reg spr_y_zoom;
reg spr_x_zoom;
reg [31:0] spr_x_scale_bits;
reg [31:0] spr_y_scale_bits;


wire [8:0] spr_y_end = spr_height - 9'd1;

typedef struct
{
    bit [63:0]    brom_cache;
    bit [15:0]    brom_offset;
    arom_offset_t arom_offset;
    bit [9:0]     screen_line;
    bit [8:0]     source_line;
    bit           active;
    bit           repeated;
} volatile_sprite_state_t;

volatile_sprite_state_t sprite_state[256];
volatile_sprite_state_t spr, spr_saved;

function automatic [22:0] brom_address_for_offset(input [15:0] offset);
begin
    brom_address_for_offset = spr_y_flip ? (spr_brom_base_addr - { 7'b0, offset }) : (spr_brom_base_addr + { 7'b0, offset });
end
endfunction

function automatic [15:0] brom_extract(input [63:0] cache, input [15:0] offset);
begin
    bit [22:0] addr = brom_address_for_offset(offset);
    case(addr[1:0])
        0: brom_extract = cache[15:0];
        1: brom_extract = cache[31:16];
        2: brom_extract = cache[47:32];
        3: brom_extract = cache[63:48];
        default: brom_extract = 16'd0;
    endcase
end
endfunction

function automatic brom_is_last_in_cache(input [15:0] offset);
begin
    bit [22:0] addra = brom_address_for_offset(offset);
    bit [22:0] addrb = brom_address_for_offset(offset + 16'd1);
    brom_is_last_in_cache = addra[2] ^ addrb[2];
end
endfunction


wire [22:0] brom_word_address = brom_address_for_offset(spr.brom_offset);
wire [22:0] brom_aligned_word_address = { brom_word_address[22:2], 2'b00 };
assign brom_address = { brom_aligned_word_address, 1'b0 };

logic [15:0] spr_brom_data;
always_comb begin
    spr_brom_data = brom_extract(spr.brom_cache, spr.brom_offset);
end

wire spr_load = dma_state == PRESCAN_LOAD || dma_state == DRAW_SEARCH_ACTIVE_LOAD;
wire spr_store = dma_state == PRESCAN_NEXT || dma_state == DRAW_ROW_END;

function automatic [4:0] count_zeros4(input [3:0] v);
begin
   case (v)
       4'h0: count_zeros4 = 5'd4;
       4'h1, 4'h2, 4'h4, 4'h8: count_zeros4 = 5'd3;
       4'h3, 4'h5, 4'h6, 4'h9, 4'hA, 4'hC: count_zeros4 = 5'd2;
       4'h7, 4'hB, 4'hD, 4'hE: count_zeros4 = 5'd1;
       default: count_zeros4 = 5'd0; // 4'hF
   endcase
end
endfunction

function automatic [4:0] count_zeros16(input [15:0] v);
begin
   count_zeros16 = count_zeros4(v[15:12])
                 + count_zeros4(v[11:8])
                 + count_zeros4(v[7:4])
                 + count_zeros4(v[3:0]);
end
endfunction

function automatic [15:0] reverse_bits16(input [15:0] v);
begin
    reverse_bits16 = {
        v[0],
        v[1],
        v[2],
        v[3],
        v[4],
        v[5],
        v[6],
        v[7],
        v[8],
        v[9],
        v[10],
        v[11],
        v[12],
        v[13],
        v[14],
        v[15]
    };
end
endfunction

function automatic arom_offset_t add_offset(input arom_offset_t a, input [4:0] b);
begin
    bit [4:0] num;
    bit [2:0] sum3;
    case(b)
        0:  num = { 3'd0, 2'd0 };
        1:  num = { 3'd0, 2'd1 };
        2:  num = { 3'd0, 2'd2 };
        3:  num = { 3'd1, 2'd0 };
        4:  num = { 3'd1, 2'd1 };
        5:  num = { 3'd1, 2'd2 };
        6:  num = { 3'd2, 2'd0 };
        7:  num = { 3'd2, 2'd1 };
        8:  num = { 3'd2, 2'd2 };
        9:  num = { 3'd3, 2'd0 };
        10: num = { 3'd3, 2'd1 };
        11: num = { 3'd3, 2'd2 };
        12: num = { 3'd4, 2'd0 };
        13: num = { 3'd4, 2'd1 };
        14: num = { 3'd4, 2'd2 };
        15: num = { 3'd5, 2'd0 };
        16: num = { 3'd5, 2'd1 };
        default: num = { 3'd0, 2'd0 };
    endcase

    sum3 = { 1'b0, a[1:0] } + { 1'b0, num[1:0] };
    if (sum3 > 2) begin
        add_offset.words = a.words + { 21'd0, num[4:2] } + 1;
        sum3 = sum3 - 3'd3;
        add_offset.sub = sum3[1:0];
    end else begin
        add_offset.words = a.words + { 21'd0, num[4:2] };
        add_offset.sub[1:0] = sum3[1:0];
    end
end
endfunction

function automatic arom_offset_t sub_offset(input arom_offset_t a, input [4:0] b);
begin
    bit [4:0] num;
    bit [2:0] diff3;
    case(b)
        0:  num = { 3'd0, 2'd0 };
        1:  num = { 3'd0, 2'd1 };
        2:  num = { 3'd0, 2'd2 };
        3:  num = { 3'd1, 2'd0 };
        4:  num = { 3'd1, 2'd1 };
        5:  num = { 3'd1, 2'd2 };
        6:  num = { 3'd2, 2'd0 };
        7:  num = { 3'd2, 2'd1 };
        8:  num = { 3'd2, 2'd2 };
        9:  num = { 3'd3, 2'd0 };
        10: num = { 3'd3, 2'd1 };
        11: num = { 3'd3, 2'd2 };
        12: num = { 3'd4, 2'd0 };
        13: num = { 3'd4, 2'd1 };
        14: num = { 3'd4, 2'd2 };
        15: num = { 3'd5, 2'd0 };
        16: num = { 3'd5, 2'd1 };
        default: num = { 3'd0, 2'd0 };
    endcase

    if ({ 1'b0, a[1:0] } >= { 1'b0, num[1:0] }) begin
        diff3 = { 1'b0, a[1:0] } - { 1'b0, num[1:0] };
        sub_offset.words = a.words - { 21'd0, num[4:2] };
        sub_offset.sub = diff3[1:0];
    end else begin
        diff3 = { 1'b0, a[1:0] } + 3'd3 - { 1'b0, num[1:0] };
        sub_offset.words = a.words - { 21'd0, num[4:2] } - 1'b1;
        sub_offset.sub = diff3[1:0];
    end
end
endfunction

function automatic arom_offset_t inc_offset(input arom_offset_t a, input [4:0] b);
begin
    inc_offset = spr_y_flip ? sub_offset(a, b) : add_offset(a, b);
end
endfunction


reg pixel0_wr, pixel1_wr;
reg pixel_prio;
reg [4:0] pixel_palette;
reg [10:0] pixel_column;
reg [10:0] pixel_next;
reg [7:0] draw_line;
arom_offset_t pixel0_offset, pixel1_offset;
wire buffer_ready;
reg draw_complete;
reg [15:0] initial_addr_low;

// tmp_* are temporary
// spr_* are immutable per sprite values
// spr.* are mutable per sprite values
always_ff @(posedge clk) begin
    reg [5:0] tmp_x;
    reg [15:0] tmp_shifter;
    reg [3:0] tmp_shift_count;
    reg [22:0] tmp_brom_addr;
    reg tmp_y_flip;
    reg [31:0] tmp_addr32;


    if (reset) begin
        cpu_br_n <= 1;
        cpu_bgack_n <= 1;
        dma_state <= DMA_IDLE;
        draw_complete <= 1;
    end else begin
        pixel0_wr <= 0;
        pixel1_wr <= 0;

        if (spr_x_flip ^ spr_y_flip) begin
            pixel_column <= (spr_x + spr_scaled_width[10:0]) - (pixel_next + 2);  // TODO - truncating spr_scaled_width
        end else begin
            pixel_column <= spr_x + pixel_next;
        end

        if (spr_load) begin
            reg [5:0] tmp_width;
            reg [8:0] tmp_height;
            reg [4:0] tmp_scale_x, tmp_scale_y;
            spr_x <= sprite_d0[sprite_index][10:0];
            spr_x_zoom <= sprite_d0[sprite_index][15];
            spr_y <= sprite_d1[sprite_index][9:0];
            spr_y_zoom <= sprite_d1[sprite_index][15];
            tmp_y_flip = sprite_d2[sprite_index][14];
            tmp_height = sprite_d4[sprite_index][8:0];
            tmp_width = sprite_d4[sprite_index][14:9];
            tmp_brom_addr = { sprite_d2[sprite_index][6:0], sprite_d3[sprite_index] };
            if (tmp_y_flip) begin
                spr_brom_base_addr <= tmp_brom_addr + 32'd3 + ({17'b0, tmp_width} * {14'b0, tmp_height});
            end else begin
                spr_brom_base_addr <= tmp_brom_addr;
            end
            spr_prio <= sprite_d2[sprite_index][7];
            spr_palette <= sprite_d2[sprite_index][12:8];
            spr_x_flip <= sprite_d2[sprite_index][13];
            spr_y_flip <= tmp_y_flip;
            spr_height <= tmp_height;
            spr_width <= tmp_width;

            tmp_scale_x = sprite_d0[sprite_index][15:11];
            tmp_scale_y = sprite_d1[sprite_index][15:11];
            spr_scaled_width <= scaled_width(tmp_scale_x, tmp_width);

            spr <= sprite_state[sprite_index];
            spr_saved <= sprite_state[sprite_index];
           
            spr_x_scale_bits <= scale_pattern[tmp_scale_x];
            spr_y_scale_bits <= scale_pattern[tmp_scale_y];
        end else if (spr_store) begin
            sprite_state[sprite_index] <= spr;
        end
                
        case(dma_state)
            DMA_IDLE: begin
                draw_complete <= 1;
                // DMA was never triggered, skip the dma and go to prescan
                if (frame_reset) begin
                    sprite_index <= 0;
                    dma_state <= PRESCAN_LOAD;
                end

            end

            DMA_BUS_REQUEST: begin
                if (~cpu_bg_n & cpu_as_n & ~cpu_dtack_n) begin
                    cpu_bgack_n <= 0;
                    cpu_br_n <= 1;
                    dma_state <= DMA_READ0;
                    dma_addr <= 0;
                    sprite_index <= 0;
                    sprite_component_index <= 0;
                end
            end

            DMA_READ0: dma_state <= DMA_READ1;
            DMA_READ1: dma_state <= DMA_READ2;
            DMA_READ2: dma_state <= DMA_READ3;
            DMA_READ3: begin
                case(sprite_component_index)
                    0: sprite_d0[sprite_index] <= dma_din;
                    1: sprite_d1[sprite_index] <= dma_din;
                    2: sprite_d2[sprite_index] <= dma_din;
                    3: sprite_d3[sprite_index] <= dma_din;
                    4: sprite_d4[sprite_index] <= dma_din;
                    default: begin end
                endcase
                sprite_component_index <= sprite_component_index + 1;
                dma_state <= DMA_READ0;
                dma_addr <= dma_addr + 1;

                if (sprite_component_index == 4) begin
                    if (~|dma_din[14:0]) begin // early out
                        dma_state <= DMA_FINISH;
                    end else if (sprite_index == 255) begin
                        dma_state <= DMA_FINISH;
                    end else begin
                        sprite_component_index <= 0;
                        sprite_index <= sprite_index + 1;
                    end
                end
            end

            DMA_FINISH: begin
                cpu_bgack_n <= 1;
                sprite_count <= sprite_index;
                sprite_index <= 0;
                dma_state <= PRESCAN_LOAD;
            end

            PRESCAN_LOAD: begin
                if (sprite_index == sprite_count) begin
                    dma_state <= DRAW_INIT;
                end else begin
                    dma_state <= PRESCAN_INITIAL_BROM;
                end
            end

            PRESCAN_INITIAL_BROM: begin
                spr.brom_offset <= 0;
                brom_req <= ~brom_req;
                tmp_x <= 0;
                spr.screen_line <= spr_y;
                spr.source_line <= 0;
                dma_state <= PRESCAN_INITIAL_BROM_WAIT;
            end

            PRESCAN_INITIAL_BROM_WAIT: begin
                if (brom_req == brom_ack) begin
                    spr.brom_cache <= brom_data;
                    spr_saved.brom_cache <= brom_data;
                    spr.active <= 1;
                    spr.repeated <= 0;
                    initial_addr_low <= brom_extract(brom_data, 0);
                    if (brom_is_last_in_cache(0)) begin
                        spr.brom_offset <= 1;
                        spr_saved.brom_offset <= 1;
                        brom_req <= ~brom_req;
                        dma_state <= PRESCAN_INITIAL_NEXT;
                    end else begin
                        tmp_addr32 = { brom_extract(brom_data, 1), brom_extract(brom_data, 0) };
                        spr.arom_offset.words <= tmp_addr32[25:2];
                        spr.arom_offset.sub <= tmp_addr32[1:0];
                        spr.brom_offset <= 2;
                        spr_saved.arom_offset.words <= tmp_addr32[25:2];
                        spr_saved.arom_offset.sub <= tmp_addr32[1:0];
                        spr_saved.brom_offset <= 2;
                         
                        if (brom_is_last_in_cache(1)) begin
                            brom_req <= ~brom_req;
                            dma_state <= PRESCAN_BROM_WAIT;
                        end else begin
                            dma_state <= PRESCAN_SCAN_TO_START;
                        end
                    end
                end
            end

            PRESCAN_INITIAL_NEXT: begin
                if (brom_req == brom_ack) begin
                    spr.brom_cache <= brom_data;
                    spr_saved.brom_cache <= brom_data;
                    tmp_addr32 = { brom_extract(brom_data, 1), initial_addr_low };
                    spr.arom_offset.words <= tmp_addr32[25:2];
                    spr.arom_offset.sub <= tmp_addr32[1:0];
                    spr.brom_offset <= 2;
                    spr_saved.arom_offset.words <= tmp_addr32[25:2];
                    spr_saved.arom_offset.sub <= tmp_addr32[1:0];
                    spr_saved.brom_offset <= 2;
                    dma_state <= PRESCAN_SCAN_TO_START;
                end
            end

            PRESCAN_SCAN_TO_START: begin
                if (~spr.screen_line[9]) begin // if y position is no long negative we are good
                    dma_state <= PRESCAN_NEXT;
                end else if (tmp_x == spr_width) begin
                    if (spr.source_line == spr_y_end) begin
                        spr.active <= 0;
                        dma_state <= PRESCAN_NEXT; // override BROM_WAIT state
                    end

                    if (spr_y_zoom) begin
                        spr.screen_line <= spr.screen_line + 1;
                        spr.repeated <= 0;
                        if (spr.repeated | ~spr_y_scale_bits[spr.source_line[4:0]]) begin
                            spr.source_line <= spr.source_line + 1;
                            spr_saved <= spr;
                        end else begin
                            spr.repeated <= 1;
                            spr.arom_offset <= spr_saved.arom_offset;
                            spr.brom_offset <= spr_saved.brom_offset;
                            spr.brom_cache  <= spr_saved.brom_cache;
                        end
                    end else begin
                        spr.source_line <= spr.source_line + 1;
                        if (~spr_y_scale_bits[spr.source_line[4:0]]) spr.screen_line <= spr.screen_line + 1;
                        spr_saved <= spr;
                    end
                    tmp_x <= 0;
                end else begin
                    spr.arom_offset <= inc_offset(spr.arom_offset, count_zeros16(spr_brom_data));
                    spr.brom_offset <= spr.brom_offset + 1;
                    tmp_x <= tmp_x + 1;
                    
                    if (brom_is_last_in_cache(spr.brom_offset)) begin
                        brom_req <= ~brom_req;
                        dma_state <= PRESCAN_BROM_WAIT;
                    end
                end
            end

            PRESCAN_BROM_WAIT: begin
                if (brom_req == brom_ack) begin
                    spr.brom_cache <= brom_data;
                    if (tmp_x == 0) spr_saved.brom_cache <= brom_data;
                    dma_state <= PRESCAN_SCAN_TO_START;
                end
            end


            PRESCAN_NEXT: begin
                sprite_index <= sprite_index + 1;
                dma_state <= PRESCAN_LOAD;
            end

            DRAW_INIT: begin
                sprite_index <= 0;
                draw_line <= 0;
                draw_complete <= 0;
                dma_state <= DRAW_SEARCH_ACTIVE_LOAD;
            end

            DRAW_SEARCH_ACTIVE_LOAD: begin
                if (sprite_index == sprite_count) begin
                    draw_line <= draw_line + 1;
                    sprite_index <= 0;
                    if (draw_line == 223) begin
                        dma_state <= DMA_IDLE;
                    end else begin
                        dma_state <= DRAW_SEARCH_ACTIVE_LOAD; // load correct sprite index
                    end
                end else begin
                    dma_state <= DRAW_SEARCH_ACTIVE_CHECK;
                end
            end

            DRAW_SEARCH_ACTIVE_CHECK: begin
                if (spr.active && spr.screen_line == draw_line) begin
                    dma_state <= DRAW_ROW;
                    tmp_x <= 0;
                    pixel_next <= 0;
                end else begin
                    sprite_index <= sprite_index + 1;
                    dma_state <= DRAW_SEARCH_ACTIVE_LOAD;
                end
            end

            DRAW_ROW: begin
                tmp_shifter <= spr_y_flip ? reverse_bits16(spr_brom_data) : spr_brom_data;
                tmp_shift_count <= 0;
                dma_state <= DRAW_SPAN;
                if (tmp_x == spr_width) begin
                    if (spr_y_zoom) begin
                        spr.screen_line <= spr.screen_line + 1;
                        spr.repeated <= 0;
                        if (spr.repeated | ~spr_y_scale_bits[spr.source_line[4:0]]) begin
                            spr.source_line <= spr.source_line + 1;
                        end else begin
                            spr.repeated <= 1;
                            spr.arom_offset <= spr_saved.arom_offset;
                            spr.brom_offset <= spr_saved.brom_offset;
                            spr.brom_cache  <= spr_saved.brom_cache;
                        end
                    end else begin
                        spr.screen_line <= spr.screen_line + 1;
                        spr.source_line <= spr.source_line + 1;
                    end
                    if (spr.source_line == spr_y_end) begin
                        spr.active <= 0;
                    end
                    dma_state <= DRAW_ROW_END;

                    if (~spr_y_zoom & spr_y_scale_bits[spr.source_line[4:0]]) begin
                        dma_state <= SKIP_ROW;
                        tmp_x <= 0;
                    end
                end
            end

            DRAW_SPAN: begin
                if (buffer_ready) begin
                    reg [1:0] input_count;
                    reg [1:0] output_count;
                    reg [1:0] arom_count;
                    reg [2:0] pos_count;
                    reg [4:0] next_shift_count;
                    reg       has_second;
                    reg       bit0_transparent;
                    reg       bit1_transparent;
                    reg       repeat0;
                    reg       repeat1;
                    reg       skip0;
                    reg       skip1;
                    reg       process_second;
                    arom_offset_t src_offset;

                    pixel_prio <= spr_prio;
                    pixel_palette <= spr_palette;
                    pixel0_wr <= 0;
                    pixel1_wr <= 0;
                    pixel0_offset <= spr.arom_offset;
                    pixel1_offset <= spr.arom_offset;

                    input_count = 0;
                    output_count = 0;
                    arom_count = 0;
                    bit0_transparent = tmp_shifter[0];
                    bit1_transparent = tmp_shifter[1];
                    repeat0 = spr_x_zoom & spr_x_scale_bits[0];
                    repeat1 = spr_x_zoom & spr_x_scale_bits[1];
                    skip0 = ~spr_x_zoom & spr_x_scale_bits[0];
                    skip1 = ~spr_x_zoom & spr_x_scale_bits[1];
                    has_second = (tmp_shift_count != 4'd15);
                    process_second = 0;

                    input_count = 1;
                    if (~bit0_transparent) begin
                        src_offset = inc_offset(spr.arom_offset, { 3'd0, arom_count });
                    end
                    if (spr_x_zoom) begin
                        pos_count = repeat0 ? 3'd2 : 3'd1;
                    end else begin
                        pos_count = skip0 ? 3'd0 : 3'd1;
                    end
                    if (pos_count != 0) begin
                        if (~bit0_transparent) begin
                            pixel0_offset <= src_offset;
                            pixel0_wr <= 1;
                            if (pos_count == 3'd2) begin
                                pixel1_offset <= src_offset;
                                pixel1_wr <= 1;
                            end
                        end
                        output_count = pos_count[1:0];
                    end
                    if (~bit0_transparent) begin
                        arom_count = arom_count + 1'b1;
                    end

                    if (has_second) begin
                        if (spr_x_zoom) begin
                            process_second = ~repeat0 & ~repeat1;
                        end else begin
                            process_second = 1;
                        end
                    end

                    if (process_second) begin
                        input_count = input_count + 1'b1;
                        if (~bit1_transparent) begin
                            src_offset = inc_offset(spr.arom_offset, { 3'd0, arom_count });
                        end
                        pos_count = skip1 ? 3'd0 : 3'd1;
                        if (pos_count != 0) begin
                            if (~bit1_transparent) begin
                                if (output_count == 0) begin
                                    pixel0_offset <= src_offset;
                                    pixel0_wr <= 1;
                                end else begin
                                    pixel1_offset <= src_offset;
                                    pixel1_wr <= 1;
                                end
                            end
                            output_count = output_count + pos_count[1:0];
                        end
                        if (~bit1_transparent) begin
                            arom_count = arom_count + 1'b1;
                        end
                    end

                    spr.arom_offset <= inc_offset(spr.arom_offset, { 3'd0, arom_count });
                    pixel_next <= pixel_next + { 9'd0, output_count };

                    case(input_count)
                        2'd1: begin
                            tmp_shifter <= { 1'b0, tmp_shifter[15:1] };
                            spr_x_scale_bits <= { spr_x_scale_bits[0], spr_x_scale_bits[31:1] };
                        end
                        2'd2: begin
                            tmp_shifter <= { 2'b0, tmp_shifter[15:2] };
                            spr_x_scale_bits <= { spr_x_scale_bits[1:0], spr_x_scale_bits[31:2] };
                        end
                        default: begin end
                    endcase

                    next_shift_count = { 1'b0, tmp_shift_count } + { 3'd0, input_count };
                    tmp_shift_count <= next_shift_count[3:0];
                    if (next_shift_count >= 5'd16) begin
                        spr.brom_offset <= spr.brom_offset + 1;
                        tmp_x <= tmp_x + 1;
                        if (brom_is_last_in_cache(spr.brom_offset)) begin
                            brom_req <= ~brom_req;
                            dma_state <= DRAW_BROM_WAIT;
                        end else begin
                            dma_state <= DRAW_ROW;
                        end
                    end
                end
            end

            DRAW_BROM_WAIT: begin
                if (brom_req == brom_ack) begin
                    spr.brom_cache <= brom_data;
                    dma_state <= DRAW_ROW;
                end
            end

            DRAW_ROW_END: begin
                sprite_index <= sprite_index + 1;
                dma_state <= DRAW_SEARCH_ACTIVE_LOAD;
            end

            SKIP_ROW: begin
                if (tmp_x == spr_width) begin
                    spr.source_line <= spr.source_line + 1;
                    if (spr.source_line == spr_y_end) begin
                        spr.active <= 0;
                    end
                    dma_state <= DRAW_ROW_END;
                end else begin
                    spr.arom_offset <= inc_offset(spr.arom_offset, count_zeros16(spr_brom_data));
                    spr.brom_offset <= spr.brom_offset + 1;
                    tmp_x <= tmp_x + 1;
                    
                    if (brom_is_last_in_cache(spr.brom_offset)) begin
                        brom_req <= ~brom_req;
                        dma_state <= SKIP_ROW_BROM_WAIT;
                    end
                end
            end

            SKIP_ROW_BROM_WAIT: begin
                if (brom_req == brom_ack) begin
                    spr.brom_cache <= brom_data;
                    dma_state <= SKIP_ROW;
                end
            end

            default: dma_state <= DMA_IDLE;

        endcase

        if (dma_start) begin
            dma_state <= DMA_BUS_REQUEST;
            draw_complete <= 1;
            cpu_br_n <= 0;
        end

    end
end

IGS023_Buffer line_buffer(
    .clk,
    .ce_pixel,
    .scan_active,
    .frame_reset,
    .next_line,
    .draw_complete,

    .scan_color(color_out),

    .wr0(spr_x_flip ^ spr_y_flip ? pixel1_wr : pixel0_wr),
    .wr1(spr_x_flip ^ spr_y_flip ? pixel0_wr : pixel1_wr),
    .column(pixel_column),
    .prio(pixel_prio),
    .palette(pixel_palette),
    .arom_offset0(spr_x_flip ^ spr_y_flip ? pixel1_offset : pixel0_offset),
    .arom_offset1(spr_x_flip ^ spr_y_flip ? pixel0_offset : pixel1_offset),
    .line(draw_line),
    .ready(buffer_ready),

    .ddr(ddr)
);


endmodule
