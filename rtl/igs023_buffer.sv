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


typedef struct packed
{
    arom_offset_t arom_offset;
    logic           prio;
    logic [4:0]     palette;
    logic [8:0]     column;
    logic [1:0]     line;
} write_entry_t;

write_entry_t wq_in;
write_entry_t wq_tail;
assign wq_in.palette = palette;
assign wq_in.arom_offset = arom_offset;
assign wq_in.prio = prio;
assign wq_in.column = column;
assign wq_in.line = line[1:0];

reg [12:0] write_queue_head;
reg [12:0] write_queue_tail;

dualport_ram_unreg #(.WIDTH($bits(write_entry_t)), .WIDTHAD(13)) write_queue(
    .clock_a(clk),
    .wren_a(wr),
    .address_a(write_queue_head),
    .data_a(wq_in),
    .q_a(),

    .clock_b(clk),
    .wren_b(0),
    .address_b(write_queue_tail),
    .data_b(0),
    .q_b(wq_tail)
);


reg [8:0] scan_column;
reg [1:0] scan_buffer;

always_ff @(posedge clk) begin
    if (frame_reset) begin
        scan_buffer <= 2'b11;
    end else if (next_line) begin
        scan_buffer <= scan_buffer + 1;
        scan_column <= 0;
    end

    if (scan_active & ce_pixel) begin
        scan_column <= scan_column + 1;
    end
end


typedef enum bit[1:0]
{
    IDLE,
    READ,
    WAIT
} queue_state_t;

queue_state_t queue_state = IDLE;

assign ddr.write = 0;
assign ddr.burstcnt = 1;
assign ddr.byteenable = 8'hff;
assign ddr.acquire = (write_queue_tail != write_queue_head) || (queue_state != IDLE);

logic [4:0] color_value;

always_comb begin
    case({wq_tail.arom_offset.words[1:0], wq_tail.arom_offset.sub[1:0]})
        4'b0000: color_value = ddr.rdata[4:0];
        4'b0001: color_value = ddr.rdata[9:5];
        4'b0010: color_value = ddr.rdata[14:10];
        4'b0100: color_value = ddr.rdata[20:16];
        4'b0101: color_value = ddr.rdata[25:21];
        4'b0110: color_value = ddr.rdata[30:26];
        4'b1000: color_value = ddr.rdata[36:32];
        4'b1001: color_value = ddr.rdata[41:37];
        4'b1010: color_value = ddr.rdata[46:42];
        4'b1100: color_value = ddr.rdata[52:48];
        4'b1101: color_value = ddr.rdata[57:53];
        4'b1110: color_value = ddr.rdata[62:58];
        default: color_value = 5'h1f;
    endcase
end

reg line_wr;
wire [31:0] ddr_addr = CART_A_ROM_DDR_BASE + { 7'd0, wq_tail.arom_offset.words[23:2], 3'd0 };

always_ff @(posedge clk) begin
    if (wr) begin
        write_queue_head <= write_queue_head + 1;
    end

    line_wr <= 0;

    case(queue_state)
        IDLE: begin
            if (write_queue_tail != write_queue_head) begin
                queue_state <= READ;
            end
        end

        READ: begin
            if (ddr_addr == ddr.addr) begin
                line_wr <= 1;
                queue_state <= IDLE;
                write_queue_tail <= write_queue_tail + 1;
            end else if (~ddr.busy) begin
                ddr.read <= 1;
                ddr.addr <= CART_A_ROM_DDR_BASE + { 7'd0, wq_tail.arom_offset.words[23:2], 3'd0 };
                queue_state <= WAIT;
            end
        end

        WAIT: begin
            if (~ddr.busy) begin
                ddr.read <= 0;
                if (ddr.rdata_ready) begin
                    line_wr <= 1;
                    write_queue_tail <= write_queue_tail + 1;
                    queue_state <= IDLE;
                end
            end
        end

        default: queue_state <= IDLE;
    endcase
end

wire [1:0] erase_buffer = scan_buffer - 2'b01;
assign line_writable = (line[1:0] != scan_buffer) && (line[1:0] != erase_buffer);

logic [3:0] buf_wr;
logic [8:0] buf_addr[4];
logic [11:0] buf_data[4];
logic [11:0] buf_q[4];

singleport_ram #(.WIDTH(12), .WIDTHAD(9)) buf0( .clock(clk), .wren(buf_wr[0]), .address(buf_addr[0]), .data(buf_data[0]), .q(buf_q[0]));
singleport_ram #(.WIDTH(12), .WIDTHAD(9)) buf1( .clock(clk), .wren(buf_wr[1]), .address(buf_addr[1]), .data(buf_data[1]), .q(buf_q[1]));
singleport_ram #(.WIDTH(12), .WIDTHAD(9)) buf2( .clock(clk), .wren(buf_wr[2]), .address(buf_addr[2]), .data(buf_data[2]), .q(buf_q[2]));
singleport_ram #(.WIDTH(12), .WIDTHAD(9)) buf3( .clock(clk), .wren(buf_wr[3]), .address(buf_addr[3]), .data(buf_data[3]), .q(buf_q[3]));

always_comb begin
    for( int i = 0; i < 4; i++ ) begin
        buf_wr[i] = 0;
        buf_addr[i] = wq_tail.column;
    end

    buf_wr[erase_buffer] = 1;
    buf_data[erase_buffer] = 0;
    buf_addr[erase_buffer] = scan_column;

    buf_addr[scan_buffer] = scan_column;
    scan_color = buf_q[scan_buffer];

    if (line_wr) begin
        buf_data[wq_tail.line[1:0]] = { 1'b1, wq_tail.prio, wq_tail.palette, color_value };
        buf_wr[wq_tail.line[1:0]] = 1;
    end
end


endmodule




