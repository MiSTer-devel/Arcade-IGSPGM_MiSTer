//============================================================================
//  Irem M107 for MiSTer FPGA - ROM loading
//
//  Copyright (C) 2023 Martin Donlon
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

import system_consts::*;

module rom_loader
(
    input sys_clk,

    input ioctl_wr,
    input [7:0] ioctl_data,

    output reg ioctl_wait,

    output reg [26:0] sdr_addr,
    output reg [15:0] sdr_data,
    output reg [1:0] sdr_be,
    output reg sdr_req,
    input sdr_ack,
    output reg sdr_rw,

    ddr_if.to_host ddr,

    output [23:0] bram_addr,
    output [7:0] bram_data,
    output bram_wr,

    output board_cfg_t board_cfg
);


reg [31:0] base_addr;
reg reorder_64;
reg [24:0] offset;
reg [23:0] size;
region_encoding_t encoding;
region_storage_t storage;

typedef enum {
    BOARD_CFG_0,
    BOARD_CFG_1,
    REGION_IDX,
    SIZE_0,
    SIZE_1,
    SIZE_2,
    SDR_DATA,
    SDR_DATA_WAIT,
    DDR_DATA,
    DDR_DATA_WRITE,
    DDR_DATA_WAIT,
    BRAM_DATA
} stage_t;

stage_t stage = BOARD_CFG_0;

int region = 0;

reg write_rq = 0;
reg write_ack = 0;
reg [7:0] bc0;

reg [63:0] ddr_buffer;
reg [15:0] sdr_buffer;
assign ddr.burstcnt = 1;
assign ddr.read = 0;
assign ddr.byteenable = 8'hff;

always @(posedge sys_clk) begin
    bram_wr <= 0;
    ddr.acquire <= 0;

    case (stage)
        BOARD_CFG_0: if (ioctl_wr) begin
            bc0 <= ioctl_data;
            stage <= BOARD_CFG_1;
        end
        BOARD_CFG_1: if (ioctl_wr) begin
            board_cfg <= board_cfg_t'({bc0, ioctl_data});
            stage <= REGION_IDX;
        end
        REGION_IDX: if (ioctl_wr) begin
            if (ioctl_data == 8'hff) region <= region + 1;
            else region <= int'(ioctl_data[3:0]);
            stage <= SIZE_0;
        end
        SIZE_0: if (ioctl_wr) begin size[23:16] <= ioctl_data; stage <= SIZE_1; end
        SIZE_1: if (ioctl_wr) begin size[15:8] <= ioctl_data; stage <= SIZE_2; end
        SIZE_2: if (ioctl_wr) begin
            size[7:0] <= ioctl_data;
            base_addr <= LOAD_REGIONS[region].base_addr;
            storage <= LOAD_REGIONS[region].storage;
            encoding <= LOAD_REGIONS[region].encoding;
            offset <= 25'd0;

            if ({size[23:8], ioctl_data} == 24'd0)
                stage <= REGION_IDX;
            else if (LOAD_REGIONS[region].storage == STORAGE_SDR)
                stage <= SDR_DATA;
            else if (LOAD_REGIONS[region].storage == STORAGE_DDR)
                stage <= DDR_DATA;
            else
                stage <= BRAM_DATA;
        end
        SDR_DATA: if (ioctl_wr) begin
            sdr_buffer[7:0] <= ioctl_data;
            offset <= offset + 25'd1;
            if (offset[0] == 1'b1) begin
                sdr_addr <= { base_addr[26:0] + {2'b0, offset[24:1], 1'b0} };
                sdr_data <= {ioctl_data, sdr_buffer[7:0]};
                sdr_be <= 2'b11;
                sdr_rw <= 0; // write
                sdr_req <= ~sdr_req;
                ioctl_wait <= 1;
                stage <= SDR_DATA_WAIT;
            end

        end
        SDR_DATA_WAIT: begin
            if (sdr_req == sdr_ack) begin
                ioctl_wait <= 0;
                sdr_rw <= 1;
                if (offset >= 25'(size))
                    stage <= REGION_IDX;
                else
                    stage <= SDR_DATA;
            end
        end
        DDR_DATA: if (ioctl_wr) begin
            ddr_buffer[55:0] <= ddr_buffer[63:8];
            ddr_buffer[63:56] <= ioctl_data;
            offset <= offset + 25'd1;
            if (offset[2:0] == 3'b111) begin
                ddr.addr <= base_addr[31:0] + { 7'd0, offset[24:3], 3'd0 };
                ddr.write <= 0;
                ddr.acquire <= 1;
                ioctl_wait <= 1;
                stage <= DDR_DATA_WRITE;
            end
        end
        DDR_DATA_WRITE: begin
            ddr.acquire <= 1;
            if (~ddr.busy) begin
                ddr.wdata <= ddr_buffer;
                ddr.write <= 1;
                stage <= DDR_DATA_WAIT;
            end
        end
        DDR_DATA_WAIT: begin
            ddr.acquire <= 1;
            if (~ddr.busy) begin
                ddr.write <= 0;
                ioctl_wait <= 0;
                if (offset >= 25'(size))
                    stage <= REGION_IDX;
                else
                    stage <= DDR_DATA;
            end
        end
        BRAM_DATA: if (ioctl_wr) begin
            bram_addr <= base_addr[23:0] + offset[23:0];
            bram_data <= ioctl_data;
            bram_wr <= 1;
            offset <= offset + 25'd1;

            if (offset == ( size - 1)) stage <= REGION_IDX;
        end

        default: begin
        end
    endcase
end

endmodule

module ddr_rom_loader_adaptor #(
    parameter bit [31:0] DDR_DOWNLOAD_ADDR = 32'h3000_0000
)(
    input clk,

    // HPS ioctl interface
    input ioctl_download,
    input [24:0] ioctl_addr,
    input [7:0] ioctl_index,
    input ioctl_wr,
    input [7:0] ioctl_data,
    output logic ioctl_wait,

    output logic busy,

    input data_wait,
    output logic data_strobe,
    output logic [7:0] data,

    ddr_if.to_host ddr
);

localparam [7:0] ROM_INDEX = 8'd0;

assign ddr.write = 0;
assign ddr.byteenable = 8'hff;
assign ddr.burstcnt = 8'd1;

typedef enum {
    IDLE,
    DDR_READ,
    DDR_WAIT,
    OUTPUT_DATA
} state_t;

state_t state = IDLE;

reg prev_download = 0;
reg wr_detected = 0;

reg active = 0;
reg [24:0] length;
reg [24:0] offset;

reg [63:0] buffer;

reg [7:0] ddr_byte;
reg ddr_strobe;

wire valid_index = ROM_INDEX == ioctl_index;

// pass-through ioctl signals if DDR is not active
always_comb begin
    if (state == IDLE) begin
        ioctl_wait = data_wait;
        data_strobe = valid_index & ioctl_download & ioctl_wr;
        data = ioctl_data;
        busy = valid_index & ioctl_download;
    end else begin
        ioctl_wait = 0;
        data_strobe = ddr_strobe;
        data = ddr_byte;
        busy = offset != length;
    end
end


always_ff @(posedge clk) begin
    prev_download <= ioctl_download;
    ddr_strobe <= 0;

    if (valid_index && ioctl_download && ioctl_wr) wr_detected <= 1;

    case(state)
        IDLE: begin
            ddr.acquire <= 0;
            if (valid_index && prev_download && ~ioctl_download) begin
                if (~wr_detected) begin
                    ddr.acquire <= 1;
                    length <= ioctl_addr;
                    offset <= 0;
                    state <= DDR_READ;
                end
            end
        end

        DDR_READ: begin
            ddr.acquire <= 1;
            if (~ddr.busy) begin
                ddr.addr <= DDR_DOWNLOAD_ADDR + 32'(offset);
                ddr.read <= 1;
                state <= DDR_WAIT;
            end
        end

        DDR_WAIT: begin
            ddr.acquire <= 1;
            if (~ddr.busy) begin
                ddr.read <= 0;
                if (ddr.rdata_ready) begin
                    buffer <= ddr.rdata;
                    ddr.acquire <= 0;
                    state <= OUTPUT_DATA;
                end
            end
        end

        OUTPUT_DATA: begin
            ddr.acquire <= 0;
            if (~data_wait & !ddr_strobe) begin
                if (offset == length) begin
                    state <= IDLE;
                end else begin
                    offset <= offset + 25'd1;
                    if (&offset[2:0]) state <= DDR_READ;
                    ddr_strobe <= 1;
                    ddr_byte <= buffer[(offset[2:0] * 8) +: 8];
                end
            end
        end

        default: state <= IDLE;
    endcase
end


endmodule

