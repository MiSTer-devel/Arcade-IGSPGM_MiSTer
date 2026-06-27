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

module memory_stream #(parameter COUNT = 32)
(
    input               clk,
    input               reset,

    ddr_if.to_host      ddr,

    // 8-bit stream interface for reading from memory
    output reg          write_req,
    output reg [63:0]   write_data,
    input               data_ack,

    // 8-bit stream interface for writing to memory
    output reg          read_req,
    input      [63:0]   read_data,

    // Control signals
    input      [31:0]   start_addr,
    input      [31:0]   length,
    input               read_start,
    input               write_start,

    output reg          query_req,
    output reg [31:0]   chunk_address,
    output      [7:0]   chunk_select,

    output              busy
);

    typedef enum
    {
        IDLE,
        READ_MEM_REQ,
        READ_MEM_WAIT,
        READ_STREAM,
        WRITE_GATHER,
        WRITE_MEM_REQ,
        WRITE_MEM_FINAL_REQ,
        WRITE_MEM_FINAL_WAIT,
        WRITE_MEM_WAIT,
        QUERY_GATHER_FIRST,
        QUERY_GATHER_NEXT,
        QUERY_GATHER_WAIT,
        QUERY_SCATTER_WAIT,
        READ_HEADER,
        READ_HEADER_WAIT,
        WRITE_HEADER,
        WRITE_HEADER_WAIT
    } state_t;

    state_t state;

    assign busy = state != IDLE;

    parameter CHUNK_BITS = $clog2(COUNT);

    logic [2:0] word_end[4] = '{ 3'b111, 3'b011, 3'b001, 3'b000 };

    // Counters for reading/writing
    reg [31:0] end_addr;
    reg [31:0] current_addr;
    reg [2:0]  word_counter;  // 0-7 for tracking position in 64-bit word
    reg [63:0] buffer;        // Buffer for read/write operations
    reg [31:0] chunk_remaining;
    reg [3:0]  query_delay;
    reg [1:0]  chunk_width;
    reg [CHUNK_BITS-1:0] chunk_index;
    reg        is_reading;

    reg [31:0] next_chunk_address;
    wire chunk_data_ack = data_ack;
    wire [63:0] chunk_read_data = read_data;

    reg [63:0] header_data;

    always_comb begin
        chunk_select = 0;
        if (busy) begin
            chunk_select = 8'(chunk_index);
        end
    end

    // Only hold the DDR bus while actually issuing/awaiting a DDR read or write.
    // The gather/scatter/query states wait on the ssbus, not DDR, so we release
    // acquire there; this lets other DDR clients (e.g. the iram write-back cache,
    // which must fill/writeback to serve an ssbus word) use the bus between our
    // accesses.  We re-acquire on the next DDR op and, being highest priority,
    // reclaim it at the requester's transaction boundary.
    assign ddr.acquire = (state == READ_HEADER)         || (state == READ_HEADER_WAIT)  ||
                         (state == WRITE_HEADER)        || (state == WRITE_HEADER_WAIT) ||
                         (state == READ_MEM_REQ)        || (state == READ_MEM_WAIT)     ||
                         (state == WRITE_MEM_REQ)       || (state == WRITE_MEM_WAIT)    ||
                         (state == WRITE_MEM_FINAL_REQ) || (state == WRITE_MEM_FINAL_WAIT);

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            ddr.read <= 0;
            ddr.write <= 0;
            ddr.burstcnt <= 8'd1; // Initialize to 1 for non-burst operations
            ddr.byteenable <= 8'hFF; // All bytes enabled by default
            write_req <= 0;
            read_req <= 0;
            word_counter <= 0;
            query_req <= 0;
            chunk_index <= 0;
            is_reading <= 0;
        end
        else begin
            case (state)
                IDLE: begin
                    // Default signals
                    ddr.read <= 0;
                    ddr.write <= 0;
                    ddr.burstcnt <= 8'd1; // Always set to 1 for non-burst operations
                    ddr.byteenable <= 8'hFF; // All bytes enabled by default
                    write_req <= 0;
                    read_req <= 0;
                    chunk_index <= 0;
                    chunk_remaining <= 0;
                    current_addr <= start_addr + 32'd8;
                    end_addr <= start_addr + length;
                    word_counter <= 0;
                    buffer <= 64'h0;

                    // Check for start signals
                    if (read_start) begin
                        state <= READ_HEADER;
                        is_reading <= 1;
                    end else if (write_start) begin
                        state <= READ_HEADER;
                        is_reading <= 0;
                    end
                end

                READ_HEADER: begin
                    if (~ddr.busy) begin
                        ddr.read <= 1;
                        ddr.addr <= start_addr;
                        state <= READ_HEADER_WAIT;
                    end
                end

                READ_HEADER_WAIT: begin
                    if (~ddr.busy) ddr.read <= 0;
                    if (ddr.rdata_ready) begin
                        header_data <= ddr.rdata;

                        if (is_reading) begin
                            end_addr <= current_addr + { ddr.rdata[61:32], 2'b00 };
                            state <= READ_MEM_REQ;
                        end else begin
                            state <= QUERY_GATHER_FIRST;
                        end
                    end
                end

                WRITE_HEADER: begin
                    bit [31:0] len;
                    if (~ddr.busy) begin
                        ddr.write <= 1;
                        ddr.addr <= start_addr;
                        len = current_addr - (start_addr + 32'd8);
                        ddr.wdata[63:32] <= { 2'b00, len[31:2] };
                        ddr.wdata[31:0] <= header_data[31:0] + 32'd1;
                        state <= WRITE_HEADER_WAIT;
                    end
                end

                WRITE_HEADER_WAIT: begin
                    if (~ddr.busy) begin
                        ddr.write <= 0;
                        state <= IDLE;
                    end
                end

                READ_MEM_REQ: begin
                    if (current_addr >= end_addr) begin
                        state <= IDLE;
                    end else if (!ddr.busy) begin
                        ddr.addr <= current_addr & 32'hFFFFFFF8; // Align to 8-byte boundary
                        current_addr <= current_addr + 8;
                        ddr.read <= 1;
                        state <= READ_MEM_WAIT;
                    end
                end

                READ_MEM_WAIT: begin
                    if (~ddr.busy) ddr.read <= 0;
                    if (ddr.rdata_ready) begin
                        buffer <= ddr.rdata;
                        if (chunk_remaining == 0) begin
                            // handle corrupt states
                            if (&ddr.rdata[63:56] ||
                                (ddr.rdata[31:0] > (end_addr - current_addr))) begin
                                state <= IDLE;
                            end else begin
                                chunk_remaining <= ddr.rdata[31:0];
                                chunk_width <= ddr.rdata[33:32];
                                chunk_index <= ddr.rdata[56+CHUNK_BITS-1:56];
                                write_req <= 1;
                                query_req <= 1;
                                query_delay <= 0;
                                state <= QUERY_SCATTER_WAIT;
                            end
                        end else begin
                            state <= READ_STREAM;
                        end
                    end
                end

                QUERY_SCATTER_WAIT: begin
                    if (chunk_data_ack) begin
                        // TODO check size and width
                        query_req <= 0;
                        write_req <= 0;
                        state <= READ_MEM_REQ;
                        next_chunk_address <= 0;
                    end else if (&query_delay) begin
                        write_req <= 0;
                        query_req <= 0;
                        current_addr <= current_addr + ((chunk_remaining + 32'd7) & 32'hFFFFFFF8);
                        chunk_remaining <= 0;
                        state <= READ_MEM_REQ;
                    end else begin
                        query_delay <= query_delay + 1;
                    end
                end

                READ_STREAM: begin
                    if (chunk_remaining == 0) begin
                        // Done with all reading
                        state <= READ_MEM_REQ;
                        write_req <= 0;
                    end else begin
                        case(chunk_width)
                            0: case (word_counter)
                                3'd0: write_data[7:0] <= buffer[7:0];
                                3'd1: write_data[7:0] <= buffer[15:8];
                                3'd2: write_data[7:0] <= buffer[23:16];
                                3'd3: write_data[7:0] <= buffer[31:24];
                                3'd4: write_data[7:0] <= buffer[39:32];
                                3'd5: write_data[7:0] <= buffer[47:40];
                                3'd6: write_data[7:0] <= buffer[55:48];
                                3'd7: write_data[7:0] <= buffer[63:56];
                                default: begin end
                            endcase
                            1: case (word_counter)
                                3'd0: write_data[15:0] <= buffer[15:0];
                                3'd1: write_data[15:0] <= buffer[31:16];
                                3'd2: write_data[15:0] <= buffer[47:32];
                                3'd3: write_data[15:0] <= buffer[63:48];
                                default: begin end
                            endcase
                            2: case (word_counter)
                                3'd0: write_data[31:0] <= buffer[31:0];
                                3'd1: write_data[31:0] <= buffer[63:32];
                                default: begin end
                            endcase
                            3: begin
                                write_data[63:0] <= buffer[63:0];
                            end
                        endcase

                        if (chunk_data_ack & write_req) begin
                            // Advance to next byte
                            if (word_counter == word_end[chunk_width]) begin
                                // Need to fetch next word
                                word_counter <= 0;
                                state <= READ_MEM_REQ;
                            end
                            else begin
                                word_counter <= word_counter + 1;
                            end

                            chunk_remaining <= chunk_remaining - 1;
                            next_chunk_address <= chunk_address + 1;
                            write_req <= 0;
                        end else if (~write_req & ~chunk_data_ack) begin
                            write_req <= 1;
                            chunk_address <= next_chunk_address;
                        end
                    end
                end

                QUERY_GATHER_FIRST: begin
                    chunk_index <= 0;
                    read_req <= 1;
                    query_req <= 1;
                    state <= QUERY_GATHER_WAIT;
                    query_delay <= 0;
                end

                QUERY_GATHER_NEXT: begin
                    if ((chunk_index + 1) == COUNT) begin
                        state <= WRITE_MEM_FINAL_REQ;
                    end else begin
                        chunk_index <= chunk_index + 1;
                        read_req <= 1;
                        query_req <= 1;
                        state <= QUERY_GATHER_WAIT;
                        query_delay <= 0;
                    end
                end

                QUERY_GATHER_WAIT: begin
                    if (chunk_data_ack) begin
                        buffer<= 0;
                        chunk_remaining <= chunk_read_data[31:0];
                        chunk_width <= chunk_read_data[33:32];
                        buffer[33:0] <= chunk_read_data[33:0];
                        buffer[56+CHUNK_BITS-1:56] <= chunk_index[CHUNK_BITS-1:0];
                        next_chunk_address <= 0;
                        query_req <= 0;
                        read_req <= 0;
                        state <= WRITE_MEM_REQ;
                    end else if (&query_delay) begin
                        state <= QUERY_GATHER_NEXT;
                    end else begin
                        query_delay <= query_delay + 1;
                    end
                end

                WRITE_GATHER: begin
                    // Wait for incoming data
                    if (chunk_remaining == 0) begin
                        // Check if we have partially filled buffer to write
                        if (word_counter != 0) begin
                            state <= WRITE_MEM_REQ;
                        end
                        else begin
                            state <= QUERY_GATHER_NEXT;
                        end
                    end
                    else if (chunk_data_ack & read_req) begin
                        // Store incoming byte in buffer
                        case (chunk_width)
                            0: case (word_counter)
                                3'd0: buffer[7:0] <= chunk_read_data[7:0];
                                3'd1: buffer[15:8] <= chunk_read_data[7:0];
                                3'd2: buffer[23:16] <= chunk_read_data[7:0];
                                3'd3: buffer[31:24] <= chunk_read_data[7:0];
                                3'd4: buffer[39:32] <= chunk_read_data[7:0];
                                3'd5: buffer[47:40] <= chunk_read_data[7:0];
                                3'd6: buffer[55:48] <= chunk_read_data[7:0];
                                3'd7: buffer[63:56] <= chunk_read_data[7:0];
                                default: begin end
                            endcase
                            1: case (word_counter)
                                3'd0: buffer[15:0] <= chunk_read_data[15:0];
                                3'd1: buffer[31:16] <= chunk_read_data[15:0];
                                3'd2: buffer[47:32] <= chunk_read_data[15:0];
                                3'd3: buffer[63:48] <= chunk_read_data[15:0];
                                default: begin end
                            endcase
                            2: case (word_counter)
                                3'd0: buffer[31:0] <= chunk_read_data[31:0];
                                3'd1: buffer[63:32] <= chunk_read_data[31:0];
                                default: begin end
                            endcase
                            3: begin
                                buffer[63:0] <= chunk_read_data[63:0];
                            end
                        endcase

                        if (word_counter == word_end[chunk_width]) begin
                            // Buffer full, write to memory
                            word_counter <= 0;
                            state <= WRITE_MEM_REQ;
                        end
                        else begin
                            word_counter <= word_counter + 1;
                        end

                        next_chunk_address <= chunk_address + 1;
                        chunk_remaining <= chunk_remaining - 1;
                        read_req <= 0;
                    end else if (~read_req & ~chunk_data_ack) begin
                        chunk_address <= next_chunk_address;
                        read_req <= 1;
                    end
                end

                WRITE_MEM_REQ: begin
                    if (current_addr >= end_addr) begin
                        state <= IDLE;
                    end else if (!ddr.busy) begin
                        ddr.addr <= current_addr & 32'hFFFFFFF8; // Align to 8-byte boundary
                        current_addr <= current_addr + 8;
                        ddr.wdata <= buffer;
                        ddr.write <= 1;
                        state <= WRITE_MEM_WAIT;
                    end
                end

                WRITE_MEM_FINAL_REQ: begin
                    if (current_addr >= end_addr) begin
                        state <= IDLE;
                    end else if (!ddr.busy) begin
                        ddr.addr <= current_addr & 32'hFFFFFFF8; // Align to 8-byte boundary
                        ddr.wdata <= ~64'd0;
                        ddr.write <= 1;
                        current_addr <= current_addr + 32'd8;
                        state <= WRITE_MEM_FINAL_WAIT;
                    end
                end

                WRITE_MEM_FINAL_WAIT: begin
                    if (!ddr.busy) begin
                        ddr.write <= 0;
                        state <= WRITE_HEADER;
                    end
                end


                WRITE_MEM_WAIT: begin
                    if (!ddr.busy) begin
                        ddr.write <= 0;
                        if (chunk_remaining == 0) begin
                            state <= QUERY_GATHER_NEXT;
                        end
                        else begin
                            state <= WRITE_GATHER;
                            buffer <= 64'h0;
                        end
                    end
                end

                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule

