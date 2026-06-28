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

// Write-back, write-allocate DDR cache for the IGS027A internal RAM (iram),
// separate from the read-only ROM cache (prot_cache) so code and data never
// evict each other.  On a hit it mirrors the dual-port block RAM it replaces
// (port B = ARM read, registered 1-cycle settle; port A = byte-enabled write +
// dirty); on a miss the FSM writes back the dirty victim, fills, then hits.

module ram_cache #(
    parameter int    LINES    = 512,
    parameter [31:0] DDR_BASE = 32'h0      // unused; addresses are full DDR
)(
    input  logic        clk,
    input  logic        reset,

    // ARM read port (current access)
    input  logic        rd_req,
    input  logic [31:0] rd_addr,
    output logic [31:0] rd_data,
    output logic        rd_ready,

    // ARM write port (deferred store commit)
    input  logic        wr_req,
    input  logic [31:0] wr_addr,
    input  logic [31:0] wr_data,
    input  logic [3:0]  wr_be,
    output logic        wr_ready,

    ddr_if.to_host      ddr
);
    localparam int OFFB = 5;                      // 32B line
    localparam int BEATS = 4;                     // 4 x 64-bit
    localparam int IDXB = $clog2(LINES);
    localparam int TAGB = 32 - OFFB - IDXB;
    localparam int AW   = IDXB + 3;               // data store address: {idx, word[2:0]}

    logic            cvalid[0:LINES-1];
    logic            cdirty[0:LINES-1];

    wire [IDXB-1:0] rd_idx  = rd_addr[OFFB+IDXB-1:OFFB];
    wire [TAGB-1:0] rd_tag  = rd_addr[31:OFFB+IDXB];
    wire [2:0]      rd_wsel = rd_addr[4:2];
    wire [IDXB-1:0] wr_idx  = wr_addr[OFFB+IDXB-1:OFFB];
    wire [TAGB-1:0] wr_tag  = wr_addr[31:OFFB+IDXB];
    wire [2:0]      wr_wsel = wr_addr[4:2];


    logic [31:2] rd_word_d, wr_word_d;
    always_ff @(posedge clk) begin
        rd_word_d <= rd_addr[31:2];
        wr_word_d <= wr_addr[31:2];
    end
    wire rd_stable = (rd_addr[31:2] == rd_word_d);
    wire wr_stable = (wr_addr[31:2] == wr_word_d);

    // miss / writeback / fill FSM
    typedef enum logic [2:0] { IDLE, WB_RD, WB_DDR, FILL_REQ, FILL } state_t;
    state_t          state /* verilator public_flat */;
    logic            m_write;            // current miss is the write port (else read)
    logic [IDXB-1:0] m_idx;
    logic [TAGB-1:0] m_tag;
    logic [31:0]     m_base;             // DDR line base of the new line
    logic [31:0]     v_base;             // DDR line base of the dirty victim
    logic [1:0]      beat;
    logic [3:0]      wbw;                // writeback read word counter (0..8)
    logic [63:0]     wb_beat [0:BEATS-1];// victim line buffered as 4x64-bit beats

    wire is_idle = (state == IDLE);
    wire fill_we = (state == FILL) & ddr.rdata_ready;

    logic just_filled;

    // data store (LINES*8 x 32, dual-port byte-enabled)
    logic        pa_we, pb_we;
    logic [AW-1:0] pa_addr, pb_addr;
    logic [31:0] pa_data, pb_data;
    logic [3:0]  pa_be,  pb_be;
    wire  [31:0] pa_q,   pb_q;
    dualport_ram_be #(.BYTES(4), .WIDTHAD(AW)) cdata(
        .clock_a(clk), .wren_a(pa_we), .byteena_a(pa_be), .address_a(pa_addr), .data_a(pa_data), .q_a(pa_q),
        .clock_b(clk), .wren_b(pb_we), .byteena_b(pb_be), .address_b(pb_addr), .data_b(pb_data), .q_b(pb_q)
    );

    wire tag_we = (state == FILL) & ddr.rdata_ready & (beat == BEATS[1:0]-2'd1);
    wire [TAGB-1:0] rd_tag_q, wr_tag_q;
    dualport_ram_unreg #(.WIDTH(TAGB), .WIDTHAD(IDXB)) ctag_rd(
        .clock_a(clk), .wren_a(tag_we), .address_a(m_idx),  .data_a(m_tag), .q_a(),
        .clock_b(clk), .wren_b(1'b0),   .address_b(rd_idx), .data_b('0),    .q_b(rd_tag_q)
    );
    dualport_ram_unreg #(.WIDTH(TAGB), .WIDTHAD(IDXB)) ctag_wr(
        .clock_a(clk), .wren_a(tag_we), .address_a(m_idx),  .data_a(m_tag), .q_a(),
        .clock_b(clk), .wren_b(1'b0),   .address_b(wr_idx), .data_b('0),    .q_b(wr_tag_q)
    );
    wire rd_hit = rd_req & rd_stable & cvalid[rd_idx] & (rd_tag_q == rd_tag);
    wire wr_hit = wr_req & wr_stable & cvalid[wr_idx] & (wr_tag_q == wr_tag);

    wire [1:0] m_wbeat = wr_wsel[2:1];
    wire       m_whalf = wr_wsel[0];
    function automatic logic [31:0] bmerge(input logic [31:0] o, input logic [31:0] n, input logic [3:0] be);
        bmerge = { be[3] ? n[31:24] : o[31:24], be[2] ? n[23:16] : o[23:16],
                   be[1] ? n[15:8]  : o[15:8],  be[0] ? n[7:0]   : o[7:0] };
    endfunction
    wire fill_wr_lo = m_write & (beat == m_wbeat) & ~m_whalf;
    wire fill_wr_hi = m_write & (beat == m_wbeat) &  m_whalf;

    // Port muxing: IDLE = ARM access; WB_RD = stream victim out port B;
    // FILL = write both words of each beat via A (low) + B (high), merging the
    // pending store on its word.
    always_comb begin
        pa_we = 1'b0; pa_addr = {wr_idx, wr_wsel}; pa_data = wr_data; pa_be = wr_be;
        pb_we = 1'b0; pb_addr = {rd_idx, rd_wsel}; pb_data = 32'd0;   pb_be = 4'hf;
        unique case (state)
            IDLE:  pa_we = wr_hit;                       // commit write-hit (line already valid)
            WB_RD: pb_addr = {m_idx, wbw[2:0]};          // read victim word
            FILL: begin
                pa_we = fill_we; pa_addr = {m_idx, beat, 1'b0};
                pa_data = fill_wr_lo ? bmerge(ddr.rdata[31:0], wr_data, wr_be) : ddr.rdata[31:0];
                pa_be = 4'hf;
                pb_we = fill_we; pb_addr = {m_idx, beat, 1'b1};
                pb_data = fill_wr_hi ? bmerge(ddr.rdata[63:32], wr_data, wr_be) : ddr.rdata[63:32];
                pb_be = 4'hf;
            end
            default: ;
        endcase
    end


    assign rd_data  = pb_q;
    assign rd_ready = ~rd_req | (is_idle & rd_hit & ~just_filled);


    logic wr_ready_r;
    always_ff @(posedge clk) wr_ready_r <= reset ? 1'b0 : (is_idle & wr_hit & ~just_filled);
    assign wr_ready = ~wr_req | wr_ready_r;

    assign ddr.acquire    = (state != IDLE);
    assign ddr.byteenable = 8'hff;

    integer i;
    always_ff @(posedge clk) begin
        if (reset) begin
            state      <= IDLE;
            ddr.read   <= 1'b0;
            ddr.write  <= 1'b0;
            ddr.addr   <= 32'd0;
            ddr.wdata  <= 64'd0;
            ddr.burstcnt <= 8'd0;
            just_filled <= 1'b0;
            for (i = 0; i < LINES; i = i + 1) begin
                cvalid[i] <= 1'b0;
                cdirty[i] <= 1'b0;
            end
        end else begin
            just_filled <= 1'b0;
            unique case (state)
                IDLE: begin
                    ddr.read  <= 1'b0;
                    ddr.write <= 1'b0;
                    // write-hit commits via port A (above); mark dirty
                    if (wr_hit) cdirty[wr_idx] <= 1'b1;
                    // miss: write port has priority over read port.  Gate on the
                    // line being stable so the registered tag (hence ~hit) is
                    // valid for the current index before declaring a miss.  The
                    // victim tag is the just-read tag BRAM output (rd/wr_tag_q).
                    if (wr_req & wr_stable & ~wr_hit & ~just_filled) begin
                        m_write <= 1'b1; m_idx <= wr_idx; m_tag <= wr_tag;
                        m_base  <= {wr_addr[31:OFFB], {OFFB{1'b0}}};
                        v_base  <= {wr_tag_q, wr_idx, {OFFB{1'b0}}};
                        wbw     <= 4'd0; beat <= 2'd0;
                        state   <= (cvalid[wr_idx] & cdirty[wr_idx]) ? WB_RD : FILL_REQ;
                    end else if (rd_req & rd_stable & ~rd_hit & ~just_filled) begin
                        m_write <= 1'b0; m_idx <= rd_idx; m_tag <= rd_tag;
                        m_base  <= {rd_addr[31:OFFB], {OFFB{1'b0}}};
                        v_base  <= {rd_tag_q, rd_idx, {OFFB{1'b0}}};
                        wbw     <= 4'd0; beat <= 2'd0;
                        state   <= (cvalid[rd_idx] & cdirty[rd_idx]) ? WB_RD : FILL_REQ;
                    end
                end

                // Stream the 8 victim words out of port B into wb_beat (1-cycle
                // read latency: word presented at wbw is captured at wbw+1).
                WB_RD: begin
                    if (wbw != 4'd0) wb_beat[(wbw-4'd1)>>1][((wbw-4'd1)&4'd1)*32 +: 32] <= pb_q;
                    if (wbw == 4'd8) begin
                        beat <= 2'd0;
                        state <= WB_DDR;
                    end else begin
                        wbw <= wbw + 4'd1;
                    end
                end

                // Burst-write the dirty victim back to DDR (4 x 64-bit beats).
                WB_DDR: begin
                    if (~ddr.busy) begin
                        ddr.write    <= 1'b1;
                        ddr.addr     <= v_base + { 27'd0, beat, 3'b0 };
                        ddr.burstcnt <= 1;
                        ddr.wdata    <= wb_beat[beat];
                        if (beat == BEATS[1:0]-2'd1) begin
                            beat  <= 2'd0;
                            state <= FILL_REQ;
                        end else begin
                            beat <= beat + 2'd1;
                        end
                    end
                end

                FILL_REQ: begin
                    if (~ddr.busy) begin
                        ddr.write    <= 1'b0;
                        ddr.read     <= 1'b1;
                        ddr.addr     <= m_base;
                        ddr.burstcnt <= BEATS[7:0];
                        state        <= FILL;
                    end
                end

                FILL: begin
                    if (~ddr.busy) ddr.read <= 1'b0;
                    if (ddr.rdata_ready) begin
                        // both words written via cdata ports A/B (above)
                        beat <= beat + 2'd1;
                        if (beat == BEATS[1:0]-2'd1) begin
                            // tag written to both tag BRAMs via tag_we (above)
                            cvalid[m_idx] <= 1'b1;
                            // write-allocate merged the store into the fill, so
                            // the line is dirty; a read fill is clean.
                            cdirty[m_idx] <= m_write;
                            just_filled   <= 1'b1;   // suppress 1-cycle re-fill
                            state         <= IDLE;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
