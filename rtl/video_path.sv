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

module video_path(
    input             CLK_VIDEO,

    // Configuration inputs
    input       [4:0] hoffset,
    input       [4:0] voffset,
    input             hscale_en,
    input       [4:0] hscale,
    input             forced_scandoubler,
    input       [2:0] scandoubler_fx,
    input       [1:0] ar,
    input       [1:0] scale,
    input             rotate,
    input             rotate_ccw,
    input             flip,
    input      [11:0] crop_size,
    input       [4:0] crop_off,
    output            video_rotated,

    // Core video signal
    input             core_ce_pix,
    input             core_hs,
    input             core_vs,
    input             core_hb,
    input             core_vb,
    input       [7:0] core_r,
    input       [7:0] core_g,
    input       [7:0] core_b,

    // Scaler info in/out
    input      [11:0] HDMI_WIDTH,
    input      [11:0] HDMI_HEIGHT,
    output     [12:0] VIDEO_ARX,
    output     [12:0] VIDEO_ARY,

    // Gamma
    inout      [21:0] gamma_bus,

    // Framebuffer signals for rotation
    output            FB_EN,
    output      [4:0] FB_FORMAT,
    output reg [11:0] FB_WIDTH,
    output reg [11:0] FB_HEIGHT,
    output     [31:0] FB_BASE,
    output     [13:0] FB_STRIDE,
    input             FB_VBL,
    input             FB_LL,

    // DDR for rotation
    ddr_if.to_host    ddr,

    // Final output
    output            CE_PIXEL,
    output      [7:0] VGA_R,
    output      [7:0] VGA_G,
    output      [7:0] VGA_B,
    output            VGA_HS,
    output            VGA_VS,
    output            VGA_DE,
    output      [1:0] VGA_SL
);

wire resync_hs, resync_vs;

// H/V offset
jtframe_resync #(5) jtframe_resync
(
    .clk(CLK_VIDEO),
    .pxl_cen(core_ce_pix),
    .hs_in(core_hs),
    .vs_in(core_vs),
    .LVBL(~core_vb),
    .LHBL(~core_hb),
    .hoffset(-hoffset), // flip the sign
    .voffset(-voffset),
    .hs_out(resync_hs),
    .vs_out(resync_vs)
);

// Horizontal scaler for consumer CRT width correction. Outputs one pixel
// per CLK_VIDEO cycle and bypasses video_mixer entirely: the scandoubler
// can't double a full-rate stream and gamma_corr only advances on ce_pix
// rising edges (and needs 4 clocks per pixel), so neither can sit behind
// it. Gamma is therefore not applied while the scaler is enabled. The
// H-Pos resync offset is superseded by the scaler's own offset control.
// Intended for the analog 15kHz output; the HDMI scaler can't handle the
// resulting line widths (up to 2660 pixels).
wire hsc_en_lat;
wire [7:0] hsc_r, hsc_g, hsc_b;
wire hsc_hs, hsc_hb, hsc_vs, hsc_vb;

video_hscale video_hscale(
    .clk(CLK_VIDEO),

    .enable(hscale_en),
    .scale(hscale),
    .offset(-hoffset),
    .en_lat(hsc_en_lat),

    .ce_pix_in(core_ce_pix),
    .r_in(core_r),
    .g_in(core_g),
    .b_in(core_b),
    .hs_in(core_hs),
    .hb_in(core_hb),
    .vb_in(core_vb),
    .vs_in(resync_vs),

    .r_out(hsc_r),
    .g_out(hsc_g),
    .b_out(hsc_b),
    .hs_out(hsc_hs),
    .hb_out(hsc_hb),
    .vs_out(hsc_vs),
    .vb_out(hsc_vb)
);

wire mixer_ce_pixel, mixer_de;
wire [7:0] mixer_r, mixer_g, mixer_b;
wire mixer_hs, mixer_vs;

wire VGA_DE_MIXER = hsc_en_lat ? ~(hsc_hb | hsc_vb) : mixer_de;
wire [2:0] sl = scandoubler_fx ? scandoubler_fx - 1'd1 : 3'd0;
wire use_scandoubler = ~hsc_en_lat && (scandoubler_fx || forced_scandoubler);

assign VGA_SL  = sl[1:0];

assign CE_PIXEL = hsc_en_lat ? 1'b1   : mixer_ce_pixel;
assign VGA_R    = hsc_en_lat ? hsc_r  : mixer_r;
assign VGA_G    = hsc_en_lat ? hsc_g  : mixer_g;
assign VGA_B    = hsc_en_lat ? hsc_b  : mixer_b;
assign VGA_HS   = hsc_en_lat ? hsc_hs : mixer_hs;
assign VGA_VS   = hsc_en_lat ? hsc_vs : mixer_vs;

video_mixer #(.LINE_LENGTH(324), .HALF_DEPTH(0), .GAMMA(1)) video_mixer
(
    .CLK_VIDEO(CLK_VIDEO),
    .ce_pix(core_ce_pix),
    .CE_PIXEL(mixer_ce_pixel),

    .scandoubler(use_scandoubler),
    .hq2x(0), // TODO - disabled due to memory pressure
    .gamma_bus(gamma_bus),

    .HBlank(core_hb),
    .VBlank(core_vb),
    .HSync(resync_hs),
    .VSync(resync_vs),

    .R(core_r),
    .G(core_g),
    .B(core_b),

    .VGA_R(mixer_r),
    .VGA_G(mixer_g),
    .VGA_B(mixer_b),
    .VGA_VS(mixer_vs),
    .VGA_HS(mixer_hs),
    .VGA_DE(mixer_de)
);

video_freak video_freak(
    .CLK_VIDEO(CLK_VIDEO),
    .CE_PIXEL(CE_PIXEL),
    .VGA_VS(VGA_VS),
    .HDMI_WIDTH(HDMI_WIDTH),
    .HDMI_HEIGHT(HDMI_HEIGHT),
    .VGA_DE(VGA_DE),
    .VIDEO_ARX(VIDEO_ARX),
    .VIDEO_ARY(VIDEO_ARY),

    .VGA_DE_IN(VGA_DE_MIXER),
    .ARX((!ar) ? ( rotate ? 12'd3 : 12'd4 ) : (ar - 1'd1)),
    .ARY((!ar) ? ( rotate ? 12'd4 : 12'd3 ) : 12'd0),
    .CROP_SIZE(crop_size),
    .CROP_OFF(crop_off),
    .SCALE(scale)
);

wire [28:0] rotate_addr;
wire [63:0] rotate_data;
wire rotate_wr;
wire [7:0] rotate_be;

screen_rotate screen_rotate(
    .CLK_VIDEO,
    .CE_PIXEL,

    .VGA_R, .VGA_G, .VGA_B,
    .VGA_HS, .VGA_VS, .VGA_DE,

    .rotate_ccw, // MJD_TODO
    .no_rotate(~rotate),
    .flip(flip),
    .video_rotated,

    .FB_EN,
    .FB_FORMAT, .FB_WIDTH, .FB_HEIGHT,
    .FB_BASE, .FB_STRIDE,
    .FB_VBL, .FB_LL,

    .DDRAM_CLK(), // it's clk_sys and clk_video
    .DDRAM_BUSY(0),
    .DDRAM_BURSTCNT(),
    .DDRAM_ADDR(rotate_addr),
    .DDRAM_DIN(rotate_data),
    .DDRAM_BE(rotate_be),
    .DDRAM_WE(rotate_wr),
    .DDRAM_RD()
);

reg [9:0] fifo_wr_addr, fifo_rd_addr;
wire [63:0] fifo_out;

assign ddr.read = 0;
assign ddr.burstcnt = 1;
assign ddr.addr = { fifo_out[63:35], 3'b0 };
assign ddr.wdata = { fifo_out[31:0], fifo_out[31:0] };
assign ddr.byteenable = {{4{fifo_out[33]}}, {4{fifo_out[32]}}};

dualport_ram_unreg #(.WIDTH(64), .WIDTHAD(10)) rotate_fifo
(
    // Port A
    .clock_a(CLK_VIDEO),
    .wren_a(rotate_wr),
    .address_a(fifo_wr_addr),
    .data_a({rotate_addr, 1'b0, rotate_be[4], rotate_be[0], rotate_data[31:0]}),
    .q_a(),

    // Port B
    .clock_b(CLK_VIDEO),
    .wren_b(0),
    .address_b(fifo_rd_addr),
    .data_b(0),
    .q_b(fifo_out)
);

always_ff @(posedge CLK_VIDEO) begin
    if (rotate_wr) begin
        fifo_wr_addr <= fifo_wr_addr + 1;
    end

    if (fifo_wr_addr != fifo_rd_addr) begin
        ddr.acquire <= 1;
    end

    if (~ddr.busy & ddr.acquire) begin
        if (ddr.write) begin
            if (fifo_rd_addr != fifo_wr_addr) begin
                fifo_rd_addr <= fifo_rd_addr + 1;
            end else begin
                ddr.write <= 0;
                ddr.acquire <= 0;
            end
        end else begin
            if (fifo_rd_addr != fifo_wr_addr) begin
                ddr.write <= 1;
                fifo_rd_addr <= fifo_rd_addr + 1;
            end
        end
    end
end

endmodule
