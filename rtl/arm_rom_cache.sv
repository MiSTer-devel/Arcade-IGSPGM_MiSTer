module arm_rom_cache #(
    parameter int      ADDR_BITS = 23,        // external ROM window (8MB)
    parameter [31:0]   DDR_BASE  = 32'h0       // byte base of the ROM in DDR
)(
    input  logic                 clk,
    input  logic                 reset,

    input  logic [ADDR_BITS-1:0] addr,         // byte address
    input  logic                 req,
    output logic [31:0]          rdata,
    output logic                 ready,

    ddr_if.to_host               ddr
);

    localparam int LINE_BYTES = 32;
    localparam int BEATS      = LINE_BYTES / 8;
    localparam int OFFB       = $clog2(LINE_BYTES);
    localparam int LINES      = 128;
    localparam int IDXB       = $clog2(LINES);
    localparam int TAGB       = ADDR_BITS - OFFB - IDXB;

    logic [TAGB-1:0]   cache_tag  [0:LINES-1];
    logic              cache_valid[0:LINES-1];

    wire [IDXB-1:0] idx = addr[OFFB+IDXB-1 : OFFB];
    wire [TAGB-1:0] tag = addr[ADDR_BITS-1 : OFFB+IDXB];
    wire            hit = req & cache_valid[idx] & (cache_tag[idx] == tag);

    wire [1:0] beat_sel = addr[4:3];   // which 64-bit beat in the line
    wire       hi_sel   = addr[2];     // high/low 32 bits of the beat

    typedef enum logic [1:0] { IDLE, REQ, FILL } state_t;
    state_t          state;
    logic [IDXB-1:0] fill_idx;
    logic [TAGB-1:0] fill_tag;
    logic [1:0]      fill_beat;
    logic [31:0]     fill_addr;         // byte addr of the line base in DDR

    // Port A: line fill writes.  Port B: ARM read (registered, addr = idx:beat).
    wire [63:0] data_q;
    wire        fill_we = (state == FILL) & ddr.rdata_ready;
    dualport_ram_unreg #(.WIDTH(64), .WIDTHAD(IDXB+2)) cache_data(
        .clock_a(clk), .wren_a(fill_we), .address_a({fill_idx, fill_beat}), .data_a(ddr.rdata), .q_a(),
        .clock_b(clk), .wren_b(1'b0),    .address_b({idx, beat_sel}),       .data_b(64'd0),     .q_b(data_q)
    );
    assign rdata = hi_sel ? data_q[63:32] : data_q[31:0];

    // TODO - check if we need this hit_d delay
    logic [ADDR_BITS-1:2] waddr_d;
    logic                 hit_d;
    wire data_valid = hit & hit_d & (addr[ADDR_BITS-1:2] == waddr_d);

    assign ready = ~req | data_valid;

    assign ddr.acquire    = (state != IDLE);
    assign ddr.write      = 1'b0;
    assign ddr.wdata      = 64'd0;
    assign ddr.byteenable = 8'hff;

    integer i;
    always_ff @(posedge clk) begin
        if (reset) begin
            state    <= IDLE;
            ddr.read <= 1'b0;
            ddr.addr <= 32'd0;
            ddr.burstcnt <= 8'd0;
            waddr_d  <= '0;
            hit_d    <= 1'b0;
            for (i = 0; i < LINES; i = i + 1) cache_valid[i] <= 1'b0;
        end else begin
            waddr_d <= addr[ADDR_BITS-1:2];
            hit_d   <= hit;

            case (state)
                IDLE: begin
                    ddr.read <= 1'b0;
                    if (req & ~hit) begin
                        fill_idx  <= idx;
                        fill_tag  <= tag;
                        fill_beat <= 2'd0;
                        // line base byte address in DDR
                        fill_addr <= DDR_BASE + { {(32-ADDR_BITS){1'b0}},
                                                  addr[ADDR_BITS-1:OFFB], {OFFB{1'b0}} };
                        state     <= REQ;
                    end
                end
                REQ: begin
                    if (~ddr.busy) begin
                        ddr.read     <= 1'b1;
                        ddr.addr     <= fill_addr;
                        ddr.burstcnt <= BEATS[7:0];
                        state        <= FILL;
                    end
                end
                FILL: begin
                    if (~ddr.busy) ddr.read <= 1'b0;
                    if (ddr.rdata_ready) begin
                        // line word written via the cache_data port (fill_we)
                        fill_beat <= fill_beat + 2'd1;
                        if (fill_beat == BEATS[1:0] - 2'd1) begin
                            cache_tag[fill_idx]   <= fill_tag;
                            cache_valid[fill_idx] <= 1'b1;
                            state                 <= IDLE;
                        end
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule
