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

// Horizontal scaler for consumer CRT width correction.
//
//   * line total      - clks between hblank rising edges
//   * hblank width     - clks hb_in stays high (== active start, line_clk 0 = hb rise)
//   * active width     - count of ce_pix_in pulses during ~hb_in (input pixels)
//   * hsync start/width- hs_in (active high) leading/trailing edges
//   * pixel period     - clks per ce_pix_in pulse
module video_hscale(
    input clk, // CLK_VIDEO

    input enable,
    input signed [4:0] scale,  // k: active width = active_px * (16*clkpp+k)/(16*clkpp)
    input signed [4:0] offset, // hsync position adjust, input pixels

    output reg en_lat, // enable latched at vblank, for downstream muxes

    // Input stream at ce_pix_in rate
    input ce_pix_in,
    input [7:0] r_in,
    input [7:0] g_in,
    input [7:0] b_in,
    input hs_in,   // input hsync (active high), measured for sync width/position
    input hb_in,
    input vb_in,
    input vs_in,

    // Output stream, one pixel per clk
    output reg [7:0] r_out,
    output reg [7:0] g_out,
    output reg [7:0] b_out,
    output reg hs_out,
    output reg hb_out,
    output reg vs_out,
    output reg vb_out
);

localparam [11:0] RD_LEAD = 12'd16;

reg hb_in_d, vb_in_d, hs_in_d;
wire line_start = hb_in & ~hb_in_d;

reg [11:0] line_clk;

// ---- Per-line measurement (all in clk units except m_actpx in input pixels).
//      Held registers carry the last completed line; the transient counters
//      accumulate the line in progress.  Seeded to 0 (no hardcoded geometry);
//      valid measured values are present long before the first vblank latch. ----
reg [11:0] m_total = 0;   // input line length
reg [11:0] m_hbw   = 0;   // hblank width == active start
reg [9:0]  m_actpx = 0;   // active pixels
reg [11:0] m_hss   = 0;   // hsync start
reg [11:0] m_hsw   = 0;   // hsync width
reg [3:0]  m_clkpp = 0;   // clks per input pixel

reg [11:0] meas_lc   = 0; // free line counter (reset at line_start only)
reg [9:0]  meas_apx  = 0; // active pixel accumulator
reg [11:0] meas_hss  = 0; // captured hsync start of the line in progress
reg [3:0]  meas_cpp  = 0; // clks since last ce_pix_in
reg        meas_cpp_seen = 0;

// Parameters latched at vblank rising edge so geometry only changes
// between frames
reg [7:0]  step;        // 16*clkpp + k, output clocks per input pixel * 16
reg [12:0] active_len;  // active_px * step / 16 output clocks
reg [11:0] rd_start;    // line_clk where readout begins
reg [11:0] hs_start;
reg [11:0] hs_end;
reg [11:0] blank_lc;    // line_clk in the next line where the active spill ends
reg [11:0] f_total;     // input line total, for the line_clk safety wrap

wire signed [5:0] k = {scale[4], scale};
wire [5:0] abs_k = scale[4] ? -k[5:0] : k[5:0];

// Combinational geometry from the latest measured line, sampled at the vblank
// edge below.  step = 16*clkpp + k (the 16*clkpp base is "100% width").
wire signed [9:0]  step_s = $signed({1'b0, m_clkpp, 4'b0}) + $signed({{4{k[5]}}, k});
wire [7:0]         step_w = step_s[7:0];
wire [17:0]        al_prod = m_actpx * step_w;        // active_px * step
wire [15:0]        sc_prod = m_actpx * {10'b0, abs_k}; // active_px * |k|
// Auto-center shift = half the width delta = active_px*|k|/32; user offset in
// input pixels = clkpp clocks each.  Signed throughout so negative offsets
// sign-extend rather than zero-extend.
wire signed [12:0] hs_pos = $signed({1'b0, m_hss})
                          + $signed({2'b0, sc_prod[15:5]})
                          + $signed({1'b0, m_clkpp}) * $signed(offset);

always_ff @(posedge clk) begin
    vb_in_d <= vb_in;
    if (vb_in & ~vb_in_d) begin
        en_lat <= enable;
        f_total    <= m_total;
        step       <= step_w;
        active_len <= al_prod[16:4];
        // Readout must trail the input pixel writes. Downscale reads faster
        // than 1px/clkpp, so it starts later to avoid underrunning at the end
        // of the line. Max buffer occupancy stays < 128 px.
        rd_start   <= m_hbw + RD_LEAD + (scale[4] ? sc_prod[15:4] : 12'd0);
        hs_start   <= hs_pos[11:0];
        hs_end     <= hs_pos[11:0] + m_hsw;
        // Where the readout (and its spill into the next line) finishes:
        // RD_LEAD for downscale/100%, plus the upscale spill active_px*k/16.
        blank_lc   <= RD_LEAD + (scale[4] ? 12'd0 : sc_prod[15:4]);
    end
end

// Output vblank/vsync are regenerated, not passed through: each line's
// input vblank/vsync is captured at line_start, then applied at the point
// where this scaled line's active readout actually ends (blank_lc into
// the line). This aligns the vertical blanking edges with the spilled
// active region so the DE waveform has one clean pulse per line.
reg vbl_line, vsl_line;

// Write side: store input pixels at ce_pix_in during active video
reg [8:0] wr_idx;
wire wr_en = ce_pix_in & ~hb_in;

// Read side: Bresenham DDA, advances the read index every step/16 clocks.
// acc/step is the sub-pixel phase, available here if interpolation between
// adjacent pixels is ever wanted.
reg [12:0] active_cnt;
reg [8:0] rd_idx;
reg [7:0] acc;
reg reading_cur_line; // readout spills past the line wrap at high scales

wire rd_active = |active_cnt;
// Don't start a readout on vblank lines: they carry no visible content,
// and a vblank-line readout would spill garbage into the first active
// line right where vb_out releases, leaving a short DE sliver. (A real
// active line's spill into the first vblank line is fine - vb_out rises
// over it.) vbl_line is latched at line_start, valid well before rd_start.
wire rd_load = (line_clk == rd_start) & ~vbl_line;

wire [23:0] rd_q;

dualport_ram_unreg #(.WIDTH(24), .WIDTHAD(7)) line_buf(
    .clock_a(clk),
    .wren_a(wr_en),
    .address_a(wr_idx[6:0]),
    .data_a({r_in, g_in, b_in}),
    .q_a(),

    .clock_b(clk),
    .wren_b(0),
    .address_b(rd_idx[6:0]),
    .data_b(0),
    .q_b(rd_q)
);

// Output pipeline: address (0) -> ram q (1) -> registered output (2).
// The first address cycle is one clock after rd_load, so hsync gets an
// extra delay stage to keep the same alignment with the active region.
reg rd_active_d1;
reg hs_d1, hs_d2;

reg debug_underrun /* verilator public_flat */;
reg debug_overflow /* verilator public_flat */;

always_ff @(posedge clk) begin
    hb_in_d <= hb_in;
    hs_in_d <= hs_in;

    // -------- Per-line geometry measurement --------
    if (line_start) begin
        meas_lc <= 12'd0;
        m_total <= meas_lc + 12'd1;     // length of the just-finished line
        m_actpx <= meas_apx;            // its active pixel count
        meas_apx <= 10'd0;
    end else begin
        meas_lc <= meas_lc + 12'd1;
        if (wr_en) meas_apx <= meas_apx + 10'd1;
    end
    // hblank width: hb falling edge == active start
    if (hb_in_d & ~hb_in) m_hbw <= meas_lc;
    // hsync start/width from hs_in (active high)
    if (hs_in & ~hs_in_d) begin m_hss <= meas_lc; meas_hss <= meas_lc; end
    if (~hs_in & hs_in_d) m_hsw <= meas_lc - meas_hss;
    // clks per input pixel
    if (ce_pix_in) begin
        if (meas_cpp_seen) m_clkpp <= meas_cpp + 4'd1;
        meas_cpp <= 4'd0;
        meas_cpp_seen <= 1'b1;
    end else begin
        meas_cpp <= meas_cpp + 4'd1;
    end

    // -------- Output line timing --------
    if (line_start) begin
        line_clk <= 0;
        wr_idx <= 0;
        reading_cur_line <= 0;
        // Capture this line's vblank/vsync (valid at the line boundary)
        vbl_line <= vb_in;
        vsl_line <= vs_in;
    end else begin
        line_clk <= (line_clk >= f_total - 12'd1) ? 12'd0 : line_clk + 12'd1;
    end

    // Flip the regenerated vertical blanking where the active spill ends
    if (line_clk == blank_lc) begin
        vb_out <= vbl_line;
        vs_out <= vsl_line;
    end

    if (wr_en) begin
        wr_idx <= wr_idx + 9'd1;
    end

    if (rd_load) begin
        active_cnt <= active_len;
        rd_idx <= 0;
        acc <= 0;
        reading_cur_line <= 1;
    end else if (rd_active) begin
        active_cnt <= active_cnt - 13'd1;
        if (acc + 8'd16 >= step) begin
            acc <= acc + 8'd16 - step;
            rd_idx <= rd_idx + 9'd1;
        end else begin
            acc <= acc + 8'd16;
        end
    end

    if (reading_cur_line & rd_active & (rd_idx >= wr_idx)) debug_underrun <= 1;
    if (reading_cur_line & ((wr_idx - rd_idx) >= 9'd128)) debug_overflow <= 1;

    rd_active_d1 <= rd_active;
    hs_d1 <= line_clk >= hs_start && line_clk < hs_end;
    hs_d2 <= hs_d1;

    {r_out, g_out, b_out} <= rd_q;
    hb_out <= ~rd_active_d1;
    hs_out <= hs_d2;
end

endmodule
