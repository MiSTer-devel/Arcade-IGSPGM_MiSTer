import system_consts::*;

// One 64KB IGS027A 68k/ARM shared-RAM "chip", DDR-backed via a ram_cache, with a
// 3-client owner arbiter (priority 68k > ARM > SS).  Real hardware is single-port;
// here exactly one client owns the chip at a time.  The owner is held until its
// request drops, so a cache miss is never re-routed to another client mid-fill.
//
//   - type3: the ARM and 68k are always on opposite chips, so a given chip only
//     ever has one CPU active (no real contention).
//   - type1/2: both CPUs share chip0 -> the 68k wins on simultaneous access.
//   - SS (savestate): the only client while the ARM is frozen.
//
// Each client presents a 16-bit byte offset within the chip; CHIP_BASE is the
// chip's DDR window base.  A client's *_ready is high when it has no request or
// when it owns the chip and the cache has completed the access.
module share_cache #(
    parameter [31:0] CHIP_BASE = 32'h0,
    parameter int    LINES     = 256
)(
    input  logic        clk,
    input  logic        reset,

    // ARM client (separate read/write offsets: a load and a store can overlap)
    input  logic        arm_rd,
    input  logic [15:0] arm_rd_off,
    input  logic        arm_wr,
    input  logic [15:0] arm_wr_off,
    input  logic [31:0] arm_wdata,
    input  logic [3:0]  arm_be,
    output logic [31:0] arm_q,
    output logic        arm_ready,

    // 68k client (read or write, one offset)
    input  logic        m68k_rd,
    input  logic        m68k_wr,
    input  logic [15:0] m68k_off,
    input  logic [31:0] m68k_wdata,
    input  logic [3:0]  m68k_be,
    output logic [31:0] m68k_q,
    output logic        m68k_ready,

    // savestate client
    input  logic        ss_rd,
    input  logic        ss_wr,
    input  logic [15:0] ss_off,
    input  logic [31:0] ss_wdata,
    output logic [31:0] ss_q,
    output logic        ss_ready,

    ddr_if.to_host      ddr
);
    localparam logic [1:0] OWN_NONE = 2'd0, OWN_ARM = 2'd1, OWN_M68K = 2'd2, OWN_SS = 2'd3;

    wire arm_want  = arm_rd  | arm_wr;
    wire m68k_want = m68k_rd | m68k_wr;
    wire ss_want   = ss_rd   | ss_wr;

    logic [1:0] owner;
    wire owner_want = (owner == OWN_ARM)  ? arm_want
                    : (owner == OWN_M68K) ? m68k_want
                    : (owner == OWN_SS)   ? ss_want
                    :                       1'b0;
    always_ff @(posedge clk) begin
        if (reset) owner <= OWN_NONE;
        else if (~owner_want)
            owner <= m68k_want ? OWN_M68K
                   : arm_want  ? OWN_ARM
                   : ss_want   ? OWN_SS
                   :             OWN_NONE;
    end

    // owner -> cache ports (rd and wr have independent offsets for the ARM)
    logic        c_rd_req, c_wr_req;
    logic [15:0] c_rd_off, c_wr_off;
    logic [31:0] c_wdata;
    logic [3:0]  c_be;
    always_comb begin
        c_rd_req = 1'b0; c_wr_req = 1'b0;
        c_rd_off = 16'd0; c_wr_off = 16'd0; c_wdata = 32'd0; c_be = 4'd0;
        case (owner)
            OWN_ARM:  begin c_rd_req=arm_rd;  c_rd_off=arm_rd_off; c_wr_req=arm_wr;  c_wr_off=arm_wr_off; c_wdata=arm_wdata;  c_be=arm_be;  end
            OWN_M68K: begin c_rd_req=m68k_rd; c_rd_off=m68k_off;   c_wr_req=m68k_wr; c_wr_off=m68k_off;   c_wdata=m68k_wdata; c_be=m68k_be; end
            OWN_SS:   begin c_rd_req=ss_rd;   c_rd_off=ss_off;     c_wr_req=ss_wr;   c_wr_off=ss_off;     c_wdata=ss_wdata;   c_be=4'hf;    end
            default: ;
        endcase
    end

    wire [31:0] rd_data;
    wire        rd_ready, wr_ready;
    ram_cache #(.LINES(LINES)) cache (
        .clk(clk), .reset(reset),
        .rd_req(c_rd_req), .rd_addr(CHIP_BASE + {16'd0, c_rd_off}),
        .rd_data(rd_data), .rd_ready(rd_ready),
        .wr_req(c_wr_req), .wr_addr(CHIP_BASE + {16'd0, c_wr_off}),
        .wr_data(c_wdata), .wr_be(c_be), .wr_ready(wr_ready),
        .ddr(ddr)
    );

    wire cache_ready = rd_ready & wr_ready;
    assign arm_q  = rd_data;
    assign m68k_q = rd_data;
    assign ss_q   = rd_data;
    assign arm_ready  = ~arm_want  | (owner == OWN_ARM  & cache_ready);
    assign m68k_ready = ~m68k_want | (owner == OWN_M68K & cache_ready);
    assign ss_ready   = ~ss_want   | (owner == OWN_SS   & cache_ready);

endmodule
