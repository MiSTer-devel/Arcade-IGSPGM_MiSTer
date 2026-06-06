// Unified DDR cache shared by the (mutually exclusive) IGS protection engines:
//   - igs027a: internal ROM (read), external ARM ROM (read), iram (read/write)
//   - igs022 : private data ROM (read)
// Caller presents a full 32-bit DDR byte address, held stable while `ready` is
// low.  Block-RAM data store with a registered read, so even a hit costs one
// settle cycle (gated by data_valid).  Phase 1: read-only (write inputs ignored).

module prot_cache (
    input  logic        clk,
    input  logic        reset,

    // request port (single; the active engine owns it, mux'd in PGM.sv)
    input  logic        req,        // access this cycle
    input  logic        write,      // 1 = write (Phase 2)
    input  logic [31:0] addr,       // full DDR byte address
    input  logic [31:0] wdata,      // write data (Phase 2)
    input  logic [3:0]  byteena,    // write byte enables (Phase 2)
    output logic [31:0] rdata,      // word at addr (valid when ready & ~write)
    output logic        ready,      // 1 = rdata valid (read) / write accepted

    ddr_if.to_host      ddr
);
    localparam int LINE_BYTES = 32;                  // 4 x 64-bit DDR beats
    localparam int BEATS      = LINE_BYTES / 8;      // 4
    localparam int OFFB       = 5;                    // log2(LINE_BYTES)
    localparam int LINES      = 512;                  // 16KB of data block RAM
    localparam int IDXB       = 9;                    // log2(LINES)
    localparam int TAGB       = 32 - OFFB - IDXB;     // 18

    // Tag/valid in registers (combinational hit, bulk-reset valid).
    logic [TAGB-1:0] cache_tag  [0:LINES-1];
    logic            cache_valid[0:LINES-1];

    wire [IDXB-1:0] idx      = addr[OFFB+IDXB-1 : OFFB];
    wire [TAGB-1:0] tag      = addr[31 : OFFB+IDXB];
    wire [2:0]      word_sel = addr[4:2];                 // 8 words/line
    wire            hit      = req & cache_valid[idx] & (cache_tag[idx] == tag);

    // miss / fill FSM
    typedef enum logic [1:0] { IDLE, REQ, FILL } state_t;
    state_t          state;
    logic [IDXB-1:0] fill_idx;
    logic [TAGB-1:0] fill_tag;
    logic [1:0]      fill_beat;
    logic [31:0]     fill_addr;        // line base byte address in DDR

    // line-data block RAM (LINES*8 x 32)
    // 32-bit wide so a write-hit (Phase 2) is a clean byte-enabled 1-cycle
    // port-A write.  Line fills write BOTH 32-bit words of each 64-bit DDR beat
    // using both ports (port A = low word, port B = high word); the ARM read is
    // stalled during a fill, so port B is free for the high-word write.
    wire        fill_we = (state == FILL) & ddr.rdata_ready;
    wire [31:0] data_q;
    dualport_ram_be #(.BYTES(4), .WIDTHAD(IDXB+3)) cache_data(
        .clock_a(clk), .wren_a(fill_we), .byteena_a(4'b1111),
        .address_a({fill_idx, fill_beat, 1'b0}), .data_a(ddr.rdata[31:0]), .q_a(),
        .clock_b(clk), .wren_b(fill_we), .byteena_b(4'b1111),
        .address_b(fill_we ? {fill_idx, fill_beat, 1'b1} : {idx, word_sel}),
        .data_b(ddr.rdata[63:32]), .q_b(data_q)
    );
    assign rdata = data_q;

    // Serve only when the word address has been stable since last cycle AND was
    // a hit then, so data_q reflects settled line contents (not a same-cycle write).
    logic [31:2] waddr_d;
    logic        hit_d;
    wire data_valid = hit & hit_d & (addr[31:2] == waddr_d);

    assign ready = ~req | data_valid;

    assign ddr.acquire    = (state != IDLE);
    assign ddr.write      = 1'b0;       // Phase 1: read-only
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
            waddr_d <= addr[31:2];
            hit_d   <= hit;

            case (state)
                IDLE: begin
                    ddr.read <= 1'b0;
                    if (req & ~hit) begin
                        fill_idx  <= idx;
                        fill_tag  <= tag;
                        fill_beat <= 2'd0;
                        fill_addr <= {addr[31:OFFB], {OFFB{1'b0}}};
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
                        // both line words written via the cache_data ports
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
