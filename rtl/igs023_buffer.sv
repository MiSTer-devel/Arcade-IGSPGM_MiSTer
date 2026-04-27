import system_consts::*;

module IGS023_Buffer(
    input clk,

    input ce_pixel,
    input scan_active,
    input frame_reset,
    input next_line,

    output logic [11:0] scan_color,

    input wr,
    input [8:0] column,
    input [4:0] palette,
    input       prio,
    input       arom_offset_t arom_offset,

    input [7:0] line,
    output line_writable,

    ddr_if.to_host ddr
);

localparam int NUM_LINE_BUFFERS = 8;
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
    arom_offset_t arom_offset;
    logic                 prio;
    logic [4:0]           palette;
    logic [8:0]           column;
    logic [LINE_BUF_BITS-1:0] line;
} write_entry_t;

write_entry_t wq_in;
write_entry_t wq_fetch_data;
write_entry_t wq_fifo0;
write_entry_t wq_fifo1;
write_entry_t wq_cur;
assign wq_in.palette = palette;
assign wq_in.arom_offset = arom_offset;
assign wq_in.prio = prio;
assign wq_in.column = column;
assign wq_in.line = line[LINE_BUF_BITS-1:0];
assign wq_cur = wq_fifo0;

reg [12:0] write_queue_head = 0;
reg [12:0] write_queue_tail = 0;
reg [12:0] write_queue_fetch = 0;
reg        write_queue_fetch_pending = 0;
reg  [1:0] write_queue_fifo_count = 0;

dualport_ram_unreg #(.WIDTH($bits(write_entry_t)), .WIDTHAD(13)) write_queue(
    .clock_a(clk),
    .wren_a(wr),
    .address_a(write_queue_head),
    .data_a(wq_in),
    .q_a(),

    .clock_b(clk),
    .wren_b(0),
    .address_b(write_queue_fetch),
    .data_b(0),
    .q_b(wq_fetch_data)
);


reg [8:0] scan_column;
reg [LINE_BUF_BITS-1:0] scan_buffer;

always_ff @(posedge clk) begin
    if (frame_reset) begin
        scan_buffer <= NUM_LINE_BUFFERS - 1;
    end else if (next_line) begin
        scan_buffer <= scan_buffer + 1;
        scan_column <= 0;
    end

    if (scan_active & ce_pixel) begin
        scan_column <= scan_column + 1;
    end
end


typedef enum bit[0:0]
{
    IDLE,
    WAIT
} queue_state_t;

queue_state_t queue_state = IDLE;

assign ddr.write = 0;
assign ddr.burstcnt = 1;
assign ddr.byteenable = 8'hff;

wire queue_valid = |write_queue_fifo_count;
wire queue_prefetch_busy = queue_valid || write_queue_fetch_pending || (write_queue_fetch != write_queue_head);
assign ddr.acquire = queue_prefetch_busy || (queue_state != IDLE);

reg        ddr_cache_valid = 0;
reg [31:0] ddr_cache_addr;
reg [63:0] ddr_cache_data;
wire [31:0] ddr_addr = CART_A_ROM_DDR_BASE + { 7'd0, wq_cur.arom_offset.words[23:2], 3'd0 };
wire        ddr_cache_hit = ddr_cache_valid && (ddr_addr == ddr_cache_addr);
wire [63:0] color_source = ((queue_state == WAIT) && ~ddr.busy && ddr.rdata_ready) ? ddr.rdata : ddr_cache_data;

logic [4:0] color_value;

always_comb begin
    color_value = 5'h1f;
    case({wq_cur.arom_offset.words[1:0], wq_cur.arom_offset.sub[1:0]})
        4'b0000: color_value = color_source[4:0];
        4'b0001: color_value = color_source[9:5];
        4'b0010: color_value = color_source[14:10];
        4'b0100: color_value = color_source[20:16];
        4'b0101: color_value = color_source[25:21];
        4'b0110: color_value = color_source[30:26];
        4'b1000: color_value = color_source[36:32];
        4'b1001: color_value = color_source[41:37];
        4'b1010: color_value = color_source[46:42];
        4'b1100: color_value = color_source[52:48];
        4'b1101: color_value = color_source[57:53];
        4'b1110: color_value = color_source[62:58];
        default: color_value = 5'h1f;
    endcase
end

reg         line_wr;
write_entry_t line_wr_entry;
reg   [4:0] line_wr_color;

always_ff @(posedge clk) begin
    logic        pop_entry;
    logic        push_entry;
    logic [1:0]  fifo_count_next;
    write_entry_t fifo0_next;
    write_entry_t fifo1_next;

    if (frame_reset) begin
        line_wr <= 0;
        line_wr_entry <= '0;
        line_wr_color <= 0;
        queue_state <= IDLE;

        write_queue_head <= 0;
        write_queue_tail <= 0;
        write_queue_fetch <= 0;
        write_queue_fetch_pending <= 0;
        write_queue_fifo_count <= 0;

        ddr_cache_valid <= 0;
        ddr.read <= 0;
        ddr.addr <= 0;
    end else begin
        if (wr) begin
            write_queue_head <= write_queue_head + 1;
        end

        line_wr <= 0;
        pop_entry = 0;
        push_entry = write_queue_fetch_pending;
        fifo_count_next = write_queue_fifo_count;
        fifo0_next = wq_fifo0;
        fifo1_next = wq_fifo1;

        case(queue_state)
            IDLE: begin
                if (queue_valid) begin
                    if (ddr_cache_hit) begin
                        line_wr <= 1;
                        line_wr_entry <= wq_cur;
                        line_wr_color <= color_value;
                        pop_entry = 1;
                    end else if (~ddr.busy) begin
                        ddr.read <= 1;
                        ddr.addr <= ddr_addr;
                        queue_state <= WAIT;
                    end
                end
            end

            WAIT: begin
                if (~ddr.busy) begin
                    ddr.read <= 0;
                    if (ddr.rdata_ready) begin
                        ddr_cache_valid <= 1;
                        ddr_cache_addr <= ddr_addr;
                        ddr_cache_data <= ddr.rdata;
                        line_wr <= 1;
                        line_wr_entry <= wq_cur;
                        line_wr_color <= color_value;
                        pop_entry = 1;
                        queue_state <= IDLE;
                    end
                end
            end

            default: queue_state <= IDLE;
        endcase

        // Update the 2-entry staging FIFO in two simple steps:
        // 1. pop the current entry if the consumer accepted it
        // 2. push the newly fetched BRAM entry if one arrived this cycle
        //
        // Doing it in this order naturally handles the simultaneous pop+push case.
        if (pop_entry) begin
            if (write_queue_fifo_count == 2'd2) begin
                fifo0_next = wq_fifo1;
            end

            if (write_queue_fifo_count != 2'd0) begin
                fifo_count_next = write_queue_fifo_count - 1'b1;
            end
        end

        if (push_entry) begin
            case(fifo_count_next)
                2'd0: fifo0_next = wq_fetch_data;
                2'd1: fifo1_next = wq_fetch_data;
                default: begin end
            endcase

            if (fifo_count_next != 2'd2) begin
                fifo_count_next = fifo_count_next + 1'b1;
            end
        end

        wq_fifo0 <= fifo0_next;
        wq_fifo1 <= fifo1_next;
        write_queue_fifo_count <= fifo_count_next;

        if (pop_entry) begin
            write_queue_tail <= write_queue_tail + 1;
        end

        write_queue_fetch_pending <= 0;
        if ((write_queue_fetch != write_queue_head) && (fifo_count_next < 2)) begin
            write_queue_fetch <= write_queue_fetch + 1;
            write_queue_fetch_pending <= 1;
        end
    end
end

wire [LINE_BUF_BITS-1:0] erase_buffer = scan_buffer - 1'b1;
assign line_writable = (line[LINE_BUF_BITS-1:0] != scan_buffer) && (line[LINE_BUF_BITS-1:0] != erase_buffer);

logic [NUM_LINE_BUFFERS-1:0] buf_wr;
logic [8:0] buf_addr[NUM_LINE_BUFFERS];
logic [11:0] buf_data[NUM_LINE_BUFFERS];
logic [11:0] buf_q[NUM_LINE_BUFFERS];

genvar buf_i;
generate
    for (buf_i = 0; buf_i < NUM_LINE_BUFFERS; buf_i++) begin : gen_line_buf
        singleport_ram #(.WIDTH(12), .WIDTHAD(9)) line_buf_inst(
            .clock(clk),
            .wren(buf_wr[buf_i]),
            .address(buf_addr[buf_i]),
            .data(buf_data[buf_i]),
            .q(buf_q[buf_i])
        );
    end
endgenerate

always_comb begin
    for (int i = 0; i < NUM_LINE_BUFFERS; i++) begin
        buf_wr[i] = 0;
        buf_addr[i] = queue_valid ? wq_cur.column : 9'd0;
    end

    buf_wr[erase_buffer] = 1;
    buf_data[erase_buffer] = 0;
    buf_addr[erase_buffer] = scan_column;

    buf_addr[scan_buffer] = scan_column;
    scan_color = buf_q[scan_buffer];

    if (line_wr) begin
        buf_addr[line_wr_entry.line] = line_wr_entry.column;
        buf_data[line_wr_entry.line] = { 1'b1, line_wr_entry.prio, line_wr_entry.palette, line_wr_color };
        buf_wr[line_wr_entry.line] = 1;
    end
end


endmodule




