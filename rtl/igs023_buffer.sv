//============================================================================
//  Copyright (C) 2026 Martin Donlon
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//============================================================================

import system_consts::*;

module IGS023_Buffer(
    input clk,

    input ce_pixel,
    input scan_active,
    input frame_reset,
    input next_line,
    input draw_complete,

    output logic [11:0] scan_color,

    input       wr0,
    input       wr1,
    output      ready,
    input [7:0] sprite_index,
    input [10:0] column,
    input [7:0] line,
    input [4:0] palette,
    input       prio,
    input       arom_offset_t arom_offset0,
    input       arom_offset_t arom_offset1,

    // Sprite A-ROM (colour) read over SDRAM, toggle handshake (mirrors B-ROM).
    // arom_address is a relative byte address into the A-ROM region; PGM.sv adds
    // CART_A_ROM_SDR_BASE.
    output reg [25:0] arom_address,
    input      [63:0] arom_data,
    output reg        arom_req,
    input             arom_ack
);

localparam int NUM_LINE_BUFFERS = 8'd32;
localparam int LINE_BUF_BITS = $clog2(NUM_LINE_BUFFERS);

initial begin
    if (NUM_LINE_BUFFERS < 4) begin
        $fatal(1, "IGS023_Buffer requires at least 4 line buffers");
    end
    if ((NUM_LINE_BUFFERS & (NUM_LINE_BUFFERS - 1)) != 0) begin
        $fatal(1, "IGS023_Buffer requires NUM_LINE_BUFFERS to be a power of two");
    end
end


typedef struct packed
{
    logic [1:0]     wr;
    arom_offset_t   arom_offset0;
    arom_offset_t   arom_offset1;
    logic           prio;
    logic [4:0]     palette;
    logic [8:0]     column;
    logic [7:0]     line;
    logic [7:0]     sprite_index;
} write_entry_t;

write_entry_t wq_in;
write_entry_t wq_fetch_data;
write_entry_t wq_fifo0;
write_entry_t wq_fifo1;
write_entry_t wq_cur;
assign wq_in.palette = palette;
assign wq_in.arom_offset0 = arom_offset0;
assign wq_in.arom_offset1 = arom_offset1;
assign wq_in.prio = prio;
assign wq_in.column = column[8:0];
assign wq_in.line = line;
assign wq_in.wr = {wr1, wr0};
assign wq_in.sprite_index = sprite_index;
assign wq_cur = wq_fifo0;

wire valid_wr = (wr0 | wr1) && (column < 448 || &column);

localparam QUEUE_DEPTH = 12;

reg [QUEUE_DEPTH:0] write_queue_head = 0;
reg [QUEUE_DEPTH:0] write_queue_tail = 0;
reg [QUEUE_DEPTH:0] write_queue_fetch = 0;
reg        write_queue_fetch_pending = 0;
reg  [1:0] write_queue_fifo_count = 0;

assign ready = (write_queue_head - write_queue_tail) < ((1 << QUEUE_DEPTH) - 2);

dualport_ram_unreg #(.WIDTH($bits(write_entry_t)), .WIDTHAD(QUEUE_DEPTH)) write_queue(
    .clock_a(clk),
    .wren_a(valid_wr),
    .address_a(write_queue_head[QUEUE_DEPTH-1:0]),
    .data_a(wq_in),
    .q_a(),

    .clock_b(clk),
    .wren_b(0),
    .address_b(write_queue_fetch[QUEUE_DEPTH-1:0]),
    .data_b(0),
    .q_b(wq_fetch_data)
);


reg [8:0] scan_column;
reg [7:0] scan_line;


always_ff @(posedge clk) begin
    if (frame_reset) begin
        scan_line <= 8'hff;
    end else if (next_line) begin
        scan_line <= scan_line + 1;
        scan_column <= 0;
    end

    if (scan_active & ce_pixel) begin
        scan_column <= scan_column + 1;
    end
end


typedef enum bit[0:0]
{
    RUN,    // pipeline: present next entry / compare cmp_entry's registered BRAM read
    FETCH   // a miss is being serviced over SDRAM; fill the cache, then re-look-up
} queue_state_t;

queue_state_t queue_state = RUN;

wire queue_valid = |write_queue_fifo_count;

write_entry_t cmp_entry;
reg           cmp_valid = 0;

reg [7:0]  fill_sprite;
reg [1:0]  fill_slot;
reg [19:0] fill_tag;

reg [31:0] ddr_cache_hits_frame   /* verilator public_flat */ = 0;
reg [31:0] ddr_cache_misses_frame /* verilator public_flat */ = 0;
reg [31:0] ddr_cache_hits_acc   = 0;
reg [31:0] ddr_cache_misses_acc = 0;
reg        ddr_cache_counted = 0;

// Relative byte address of the 64-bit A-ROM word holding this pixel.  PGM.sv
// adds CART_A_ROM_SDR_BASE before driving the SDRAM channel.
function automatic [25:0] arom_word_addr(input arom_offset_t ofs);
begin
    arom_word_addr = { ofs.words[24:2], 3'd0 };
end
endfunction


function automatic [4:0] color_extract(input [63:0] color_source, input arom_offset_t ofs);
begin
    color_extract = 5'h1f;
    case({ofs.words[1:0], ofs.sub[1:0]})
        4'b0000: color_extract = color_source[4:0];
        4'b0001: color_extract = color_source[9:5];
        4'b0010: color_extract = color_source[14:10];
        4'b0100: color_extract = color_source[20:16];
        4'b0101: color_extract = color_source[25:21];
        4'b0110: color_extract = color_source[30:26];
        4'b1000: color_extract = color_source[36:32];
        4'b1001: color_extract = color_source[41:37];
        4'b1010: color_extract = color_source[46:42];
        4'b1100: color_extract = color_source[52:48];
        4'b1101: color_extract = color_source[57:53];
        4'b1110: color_extract = color_source[62:58];
        default: color_extract = 5'h1f;
    endcase
end
endfunction


wire [19:0] tag_q_a,  tag_q_b;     // offset0 / offset1 tags
wire [63:0] data_q_a, data_q_b;    // offset0 / offset1 64-bit colour words

wire hit0 = (tag_q_a == cmp_entry.arom_offset0.words[23:4]);
wire hit1 = (tag_q_b == cmp_entry.arom_offset1.words[23:4]);
wire cmp_writable = (cmp_entry.line >= free_line_begin) && (cmp_entry.line < free_line_end);
wire cmp_active   = cmp_valid && (queue_state == RUN) && cmp_writable;
wire consume_now  = cmp_active &&  (hit0 && hit1);
wire miss_now     = cmp_active && ~(hit0 && hit1);

wire pop_entry_c  = consume_now;
wire push_entry_c = write_queue_fetch_pending;
logic [1:0]   fifo_count_next_c;
write_entry_t fifo0_next_c;
write_entry_t fifo1_next_c;
always_comb begin
    fifo_count_next_c = write_queue_fifo_count;
    fifo0_next_c      = wq_fifo0;
    fifo1_next_c      = wq_fifo1;
    if (pop_entry_c) begin
        if (write_queue_fifo_count == 2'd2) fifo0_next_c = wq_fifo1;
        if (write_queue_fifo_count != 2'd0) fifo_count_next_c = write_queue_fifo_count - 1'b1;
    end
    if (push_entry_c) begin
        case(fifo_count_next_c)
            2'd0: fifo0_next_c = wq_fetch_data;
            2'd1: fifo1_next_c = wq_fetch_data;
            default: ;
        endcase
        if (fifo_count_next_c != 2'd2) fifo_count_next_c = fifo_count_next_c + 1'b1;
    end
end

write_entry_t present_entry;
assign present_entry = fifo0_next_c;
wire present_valid = (queue_state == RUN) && ~miss_now && (fifo_count_next_c != 2'd0);

wire cache_fill_we = (queue_state == FETCH) && (arom_req == arom_ack);

wire [9:0] cache_addr_a = cache_fill_we ? {fill_sprite, fill_slot}
                                        : {present_entry.sprite_index, present_entry.arom_offset0.words[3:2]};
wire [9:0] cache_addr_b = {present_entry.sprite_index, present_entry.arom_offset1.words[3:2]};

dualport_ram_unreg #(.WIDTH(20), .WIDTHAD(10)) ddr_cache_tag (
    .clock_a(clk), .wren_a(cache_fill_we), .address_a(cache_addr_a), .data_a(fill_tag),  .q_a(tag_q_a),
    .clock_b(clk), .wren_b(1'b0),          .address_b(cache_addr_b), .data_b(20'd0),     .q_b(tag_q_b)
);

dualport_ram_unreg #(.WIDTH(64), .WIDTHAD(10)) ddr_cache_data (
    .clock_a(clk), .wren_a(cache_fill_we), .address_a(cache_addr_a), .data_a(arom_data), .q_a(data_q_a),
    .clock_b(clk), .wren_b(1'b0),          .address_b(cache_addr_b), .data_b(64'd0),     .q_b(data_q_b)
);


reg   [1:0]   line_wr;
write_entry_t line_wr_entry;
reg   [4:0] line_wr_color0;
reg   [4:0] line_wr_color1;
reg         prev_draw_complete;
always_ff @(posedge clk) begin
    prev_draw_complete <= draw_complete;
    if (~draw_complete & prev_draw_complete) begin
        line_wr <= 0;
        line_wr_entry <= '0;
        line_wr_color0 <= 0;
        line_wr_color1 <= 0;
        queue_state <= RUN;
        cmp_valid <= 0;

        write_queue_head <= 0;
        write_queue_tail <= 0;
        write_queue_fetch <= 0;
        write_queue_fetch_pending <= 0;
        write_queue_fifo_count <= 0;

        ddr_cache_hits_frame   <= ddr_cache_hits_acc;
        ddr_cache_misses_frame <= ddr_cache_misses_acc;
        ddr_cache_hits_acc   <= 0;
        ddr_cache_misses_acc <= 0;
        ddr_cache_counted    <= 0;
    end else begin
        if (valid_wr) begin
            write_queue_head <= write_queue_head + 1;
        end

        line_wr <= 0;

        cmp_entry <= present_entry;
        cmp_valid <= present_valid;

        if (cmp_active) begin
            if (!ddr_cache_counted) begin
                ddr_cache_hits_acc   <= ddr_cache_hits_acc   + {31'd0, hit0} + {31'd0, hit1};
                ddr_cache_misses_acc <= ddr_cache_misses_acc + {31'd0, ~hit0} + {31'd0, ~hit1};
                ddr_cache_counted <= 1;
            end

            if (consume_now) begin
                line_wr        <= cmp_entry.wr;
                line_wr_entry  <= cmp_entry;
                line_wr_color0 <= color_extract(data_q_a, cmp_entry.arom_offset0);
                line_wr_color1 <= color_extract(data_q_b, cmp_entry.arom_offset1);
                ddr_cache_counted <= 0;   // next entry may be counted
            end else begin
                // Miss: capture the missing word's slot/tag, kick the A-ROM fetch,
                // and go FETCH; the entry stays at the FIFO head and is re-looked-up.
                if (!hit0) begin
                    fill_sprite  <= cmp_entry.sprite_index;
                    fill_slot    <= cmp_entry.arom_offset0.words[3:2];
                    fill_tag     <= cmp_entry.arom_offset0.words[23:4];
                    arom_address <= arom_word_addr(cmp_entry.arom_offset0);
                end else begin
                    fill_sprite  <= cmp_entry.sprite_index;
                    fill_slot    <= cmp_entry.arom_offset1.words[3:2];
                    fill_tag     <= cmp_entry.arom_offset1.words[23:4];
                    arom_address <= arom_word_addr(cmp_entry.arom_offset1);
                end
                arom_req <= ~arom_req;
                queue_state <= FETCH;
            end
        end

        if (queue_state == FETCH && (arom_req == arom_ack)) begin
            queue_state <= RUN;
        end

        wq_fifo0 <= fifo0_next_c;
        wq_fifo1 <= fifo1_next_c;
        write_queue_fifo_count <= fifo_count_next_c;

        if (pop_entry_c) begin
            write_queue_tail <= write_queue_tail + 1;
            ddr_cache_counted <= 0;
        end

        write_queue_fetch_pending <= 0;
        if ((write_queue_fetch != write_queue_head) && (fifo_count_next_c < 2)) begin
            write_queue_fetch <= write_queue_fetch + 1;
            write_queue_fetch_pending <= 1;
        end
    end
end

wire [7:0] free_line_begin = scan_line + 8'd1;
wire [7:0] free_line_end = scan_line + 8'(NUM_LINE_BUFFERS) - 8'd1;
wire [7:0] erase_line = scan_line - 8'b1;

logic [NUM_LINE_BUFFERS-1:0] buf_wr0;
logic [NUM_LINE_BUFFERS-1:0] buf_wr1;
logic [8:0] buf_addr0[NUM_LINE_BUFFERS];
logic [8:0] buf_addr1[NUM_LINE_BUFFERS];
logic [11:0] buf_data0[NUM_LINE_BUFFERS];
logic [11:0] buf_data1[NUM_LINE_BUFFERS];
logic [11:0] buf_q[NUM_LINE_BUFFERS];

genvar buf_i;
generate
    for (buf_i = 0; buf_i < NUM_LINE_BUFFERS; buf_i++) begin : gen_line_buf
        dualport_ram_unreg #(.WIDTH(12), .WIDTHAD(9)) line_buf_inst(
            .clock_a(clk),
            .wren_a(buf_wr0[buf_i]),
            .address_a(buf_addr0[buf_i]),
            .data_a(buf_data0[buf_i]),
            .q_a(buf_q[buf_i]),

            .clock_b(clk),
            .wren_b(buf_wr1[buf_i]),
            .address_b(buf_addr1[buf_i]),
            .data_b(buf_data1[buf_i]),
            .q_b()
        );
    end
endgenerate

function automatic [LINE_BUF_BITS-1:0] lb(input [7:0] line);
begin
    lb = line[LINE_BUF_BITS-1:0];
end
endfunction


always_comb begin
    for (int i = 0; i < NUM_LINE_BUFFERS; i++) begin
        buf_wr0[i] = 0;
        buf_wr1[i] = 0;
        buf_addr0[i] = queue_valid ? wq_cur.column : 9'd0;
        buf_addr1[i] = queue_valid ? (wq_cur.column + 1) : 9'd0;
        buf_data0[i] = 0;
        buf_data1[i] = 0;
    end

    buf_wr0[lb(erase_line)] = 1;
    buf_data0[lb(erase_line)] = 0;
    buf_addr0[lb(erase_line)] = scan_column;

    buf_addr0[lb(scan_line)] = scan_column;
    scan_color = buf_q[lb(scan_line)];

    if (|line_wr) begin
        buf_addr0[lb(line_wr_entry.line)] = line_wr_entry.column;
        buf_data0[lb(line_wr_entry.line)] = { 1'b1, line_wr_entry.prio, line_wr_entry.palette, line_wr_color0 };
        buf_addr1[lb(line_wr_entry.line)] = line_wr_entry.column + 1;
        buf_data1[lb(line_wr_entry.line)] = { 1'b1, line_wr_entry.prio, line_wr_entry.palette, line_wr_color1 };
        buf_wr0[lb(line_wr_entry.line)] = line_wr[0];
        buf_wr1[lb(line_wr_entry.line)] = line_wr[1];
    end
end


endmodule




