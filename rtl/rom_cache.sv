import system_consts::*;

module rom_cache(
    input clk,
    input reset,

    output reg [26:0]   sdr_addr,
    input [63:0]        sdr_data,
    output reg          sdr_req,
    input               sdr_ack,

    input               cart_present,
    input  [22:0]       cart_base_addr,

    input               as_n,
    output              dtack_n,
    input  [22:0]       cpu_addr,
    output logic [15:0] data
);

localparam CACHE_WIDTH = 8;

wire [22-CACHE_WIDTH:0] tag = { version, cpu_addr[22:CACHE_WIDTH+2] };
wire [CACHE_WIDTH-1:0] index = cpu_addr[CACHE_WIDTH+1:2];

reg [1:0] version;
reg [63:0] cache_data[2**CACHE_WIDTH];
reg [22-CACHE_WIDTH:0] cache_tag[2**CACHE_WIDTH];

reg [63:0] cache_line;
reg [22-CACHE_WIDTH:0] cached_tag;

always_comb begin
    unique case(cpu_addr[1:0])
    2'b00: data = cache_line[15:0];
    2'b01: data = cache_line[31:16];
    2'b10: data = cache_line[47:32];
    2'b11: data = cache_line[63:48];
    endcase
end

enum { IDLE, CACHE_CHECK, SDR_WAIT, READY } state = IDLE;

assign dtack_n = ~( state == IDLE || state == READY );

reg prev_reset;

always_ff @(posedge clk) begin
    cache_line <= cache_data[index];
    cached_tag <= cache_tag[index];

    prev_reset <= reset;

    if (reset) begin
        state <= IDLE;
        if (~prev_reset) version <= version + 2'd1;
    end else begin
        if (~as_n && state == IDLE) begin
            state <= CACHE_CHECK;
        end else if (state == CACHE_CHECK) begin
            if (cached_tag == tag) begin
                state <= READY;
            end else begin
                if (cart_present && (cpu_addr >= cart_base_addr)) begin
                    sdr_addr <= CART_PROG_ROM_SDR_BASE[26:0] + { 3'b0, cpu_addr[22:2] - cart_base_addr[22:2], 3'b000 };
                end else begin
                    sdr_addr <= BIOS_PROG_ROM_SDR_BASE[26:0] + { 3'b0, cpu_addr[22:2], 3'b000 };
                end
                sdr_req <= ~sdr_req;
                state <= SDR_WAIT;
            end
        end else if (state == SDR_WAIT) begin
            if (sdr_req == sdr_ack) begin
                cache_tag[index] <= tag;
                cache_data[index] <= sdr_data;
                cache_line <= sdr_data;
                state <= READY;
            end
        end else if (as_n && state == READY) begin
            state <= IDLE;
        end
    end
end

endmodule

module rom_cache2(
    input clk,

    output reg [26:0]   sdr_addr,
    input [63:0]        sdr_data,
    output reg          sdr_req,
    input               sdr_ack,

    input  [26:0]       addr,
    input               read,
    output logic [15:0] data,
    output              data_valid
);

localparam CACHE_WIDTH = 10;

wire [26-CACHE_WIDTH-3:0] tag = addr[26:CACHE_WIDTH+3];
wire [CACHE_WIDTH-1:0] index = addr[CACHE_WIDTH+2:3];

reg [63:0] cache_data[2**CACHE_WIDTH];
reg [26-CACHE_WIDTH-3:0] cache_tag[2**CACHE_WIDTH];

reg [63:0] cache_line;
reg [26-CACHE_WIDTH-3:0] cached_tag;
reg [CACHE_WIDTH-1:0] cached_index;

always_comb begin
    unique case(addr[2:1])
    2'b00: data = cache_line[15:0];
    2'b01: data = cache_line[31:16];
    2'b10: data = cache_line[47:32];
    2'b11: data = cache_line[63:48];
    endcase
end

enum { IDLE, CACHE_CHECK, SDR_WAIT } state = IDLE;

reg [26:0] addr2;
assign data_valid = (index == cached_index) && (tag == cached_tag);

always_ff @(posedge clk) begin
    cache_line   <= cache_data[index];
    cached_tag   <= cache_tag[index];
    cached_index <= index;

    if (read && state == IDLE) begin
        state <= CACHE_CHECK;
    end else if (state == CACHE_CHECK) begin
        if ((cached_index == index) && (cached_tag == tag)) begin
            state <= IDLE;
        end else begin
            sdr_addr <= { addr[26:3], 3'b000 };
            addr2 <= addr;
            sdr_req <= ~sdr_req;
            state <= SDR_WAIT;
        end
    end else if (state == SDR_WAIT) begin
        if (sdr_req == sdr_ack) begin
            cache_tag[addr2[CACHE_WIDTH+2:3]] <= addr2[26:CACHE_WIDTH+3];
            cache_data[addr2[CACHE_WIDTH+2:3]] <= sdr_data;
            cache_line <= sdr_data;
            cached_tag <= addr2[26:CACHE_WIDTH+3];
            cached_index <= addr2[CACHE_WIDTH+2:3];
            state <= IDLE;
        end
    end
end

endmodule

module audio_rom_cache(
    input clk,

    input [4:0]         channel,

    output reg [26:0]   sdr_addr,
    input [63:0]        sdr_data,
    output reg          sdr_req,
    input               sdr_ack,

    input  [26:0]       addr,
    input               read,
    output logic [15:0] data,
    output              data_valid
);

localparam N_SLOTS    = 64;

reg [63:0] cached_data[N_SLOTS];
reg [26:3] cached_tags[N_SLOTS];

reg [63:0] cache_data;
reg [26:3] cache_tag;
reg [5:0] cache_slot_idx;

wire [5:0] slot_idx = { channel, addr[3] };

always_comb begin
    unique case(addr[2:1])
    2'b00: data = cache_data[15:0];
    2'b01: data = cache_data[31:16];
    2'b10: data = cache_data[47:32];
    2'b11: data = cache_data[63:48];
    endcase
end

typedef enum bit[1:0] { IDLE, CACHE_CHECK, SDR_WAIT } state_t;
state_t state = IDLE;

assign data_valid = (cache_tag == addr[26:3]) && (slot_idx == cache_slot_idx);

always_ff @(posedge clk) begin
    case(state)
        IDLE: begin
            cache_data <= cached_data[slot_idx];
            cache_tag <= cached_tags[slot_idx];
            cache_slot_idx <= slot_idx;

            if (read & ~data_valid) begin
                state <= CACHE_CHECK;
            end
        end
        CACHE_CHECK: begin
            if (data_valid) begin
                state <= IDLE;
            end else begin
                sdr_addr <= { addr[26:3], 3'b000 };
                sdr_req <= ~sdr_req;
                state <= SDR_WAIT;
            end
        end
        SDR_WAIT: begin
            if (sdr_req == sdr_ack) begin
                cached_tags[slot_idx] <= addr[26:3];
                cached_data[slot_idx] <= sdr_data;
                cache_data <= sdr_data;
                cache_tag <= sdr_addr[26:3];
                state <= IDLE;
            end
        end
        default: state <= IDLE;
    endcase
end

endmodule
