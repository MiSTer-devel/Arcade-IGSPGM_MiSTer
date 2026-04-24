//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
    //Master input clock
    input         CLK_50M,

    //Async reset from top-level module.
    //Can be used as initial reset.
    input         RESET,

    //Must be passed to hps_io module
    inout  [48:0] HPS_BUS,

    //Base video clock. Usually equals to CLK_SYS.
    output        CLK_VIDEO,

    //Multiple resolutions are supported using different CE_PIXEL rates.
    //Must be based on CLK_VIDEO
    output        CE_PIXEL,

    //Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
    //if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
    output [12:0] VIDEO_ARX,
    output [12:0] VIDEO_ARY,

    output  [7:0] VGA_R,
    output  [7:0] VGA_G,
    output  [7:0] VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    output        VGA_DE,    // = ~(VBlank | HBlank)
    output        VGA_F1,
    output [1:0]  VGA_SL,
    output        VGA_SCALER, // Force VGA scaler
    output        VGA_DISABLE, // analog out is off

    input  [11:0] HDMI_WIDTH,
    input  [11:0] HDMI_HEIGHT,
    output        HDMI_FREEZE,
    output        HDMI_BLACKOUT,

`ifdef MISTER_FB
    // Use framebuffer in DDRAM
    // FB_FORMAT:
    //    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
    //    [3]   : 0=16bits 565 1=16bits 1555
    //    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
    //
    // FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
    output        FB_EN,
    output  [4:0] FB_FORMAT,
    output [11:0] FB_WIDTH,
    output [11:0] FB_HEIGHT,
    output [31:0] FB_BASE,
    output [13:0] FB_STRIDE,
    input         FB_VBL,
    input         FB_LL,
    output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
    // Palette control for 8bit modes.
    // Ignored for other video modes.
    output        FB_PAL_CLK,
    output  [7:0] FB_PAL_ADDR,
    output [23:0] FB_PAL_DOUT,
    input  [23:0] FB_PAL_DIN,
    output        FB_PAL_WR,
`endif
`endif

    output        LED_USER,  // 1 - ON, 0 - OFF.

    // b[1]: 0 - LED status is system status OR'd with b[0]
    //       1 - LED status is controled solely by b[0]
    // hint: supply 2'b00 to let the system control the LED.
    output  [1:0] LED_POWER,
    output  [1:0] LED_DISK,

    // I/O board button press simulation (active high)
    // b[1]: user button
    // b[0]: osd button
    output  [1:0] BUTTONS,

    input         CLK_AUDIO, // 24.576 MHz
    output [15:0] AUDIO_L,
    output [15:0] AUDIO_R,
    output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
    output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

    //ADC
    inout   [3:0] ADC_BUS,

    //SD-SPI
    output        SD_SCK,
    output        SD_MOSI,
    input         SD_MISO,
    output        SD_CS,
    input         SD_CD,

    //High latency DDR3 RAM interface
    //Use for non-critical time purposes
    output        DDRAM_CLK,
    input         DDRAM_BUSY,
    output  [7:0] DDRAM_BURSTCNT,
    output [28:0] DDRAM_ADDR,
    input  [63:0] DDRAM_DOUT,
    input         DDRAM_DOUT_READY,
    output        DDRAM_RD,
    output [63:0] DDRAM_DIN,
    output  [7:0] DDRAM_BE,
    output        DDRAM_WE,

    //SDRAM interface with lower latency
    output        SDRAM_CLK,
    output        SDRAM_CKE,
    output [12:0] SDRAM_A,
    output  [1:0] SDRAM_BA,
    inout  [15:0] SDRAM_DQ,
    output        SDRAM_DQML,
    output        SDRAM_DQMH,
    output        SDRAM_nCS,
    output        SDRAM_nCAS,
    output        SDRAM_nRAS,
    output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
    //Secondary SDRAM
    //Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
    input         SDRAM2_EN,
    output        SDRAM2_CLK,
    output [12:0] SDRAM2_A,
    output  [1:0] SDRAM2_BA,
    inout  [15:0] SDRAM2_DQ,
    output        SDRAM2_nCS,
    output        SDRAM2_nCAS,
    output        SDRAM2_nRAS,
    output        SDRAM2_nWE,
`endif

    input         UART_CTS,
    output        UART_RTS,
    input         UART_RXD,
    output        UART_TXD,
    output        UART_DTR,
    input         UART_DSR,

    // Open-drain User port.
    // 0 - D+/RX
    // 1 - D-/TX
    // 2..6 - USR2..USR6
    // Set USER_OUT to 1 to read from USER_IN.
    input   [6:0] USER_IN,
    output  [6:0] USER_OUT,

    input         OSD_STATUS
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;

assign AUDIO_R = AUDIO_L;
assign AUDIO_S = 1;
assign AUDIO_MIX = 3;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

`include "build_id.v"
localparam CONF_STR = {
    "IGSPGM;SS3E000000:400000;",
    "-;",
    "P1,Video Settings;",
    "P1O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "P1O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "P1O[7:6],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
    "P1-;",
    "P1O[8],Orientation,Horz,Vert;",
    "P1-;",
    "P1O[19],Consumer CRT Sync,On,Off;",
    "P1O[13:9],Analog Video H-Pos,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "P1O[18:14],Analog Video V-Pos,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "-;",
    "O[33:32],Rotary Input,Joystick,Paddle,Spinner,D-Pad;",
    "O[36:34],Rotary Sensitivity,100%,50%,25%,12%,6%,200%,150%,125%;",
    "O[37],Rotary Invert,No,Yes;",
    "-;",
    "O[38],OSD Pause,No,Yes;",
    "O[39],Pause Dim,Yes,No;",
    "-;",
    "O[42:41],Savestate Slot,1,2,3,4;",
    "O[40],Autoincrement Slot,Off,On;",
    "R[43],Save state (Alt-F1);",
    "R[44],Restore state (F1);",
    "-;",
    "DIP;",
    "-;",
    "T[0],Reset;",
    "R[0],Reset and close OSD;",
    "I,",
    "Load=DPAD Up|Save=Down|Slot=L+R,",
    "Active Slot 1,",
    "Active Slot 2,",
    "Active Slot 3,",
    "Active Slot 4,",
    "Save to state 1,",
    "Restore state 1,",
    "Save to state 2,",
    "Restore state 2,",
    "Save to state 3,",
    "Restore state 3,",
    "Save to state 4,",
    "Restore state 4;",
    "DEFMRA,/_Development/PGM.mra;",
    "v,1;",
    "V,v",`BUILD_DATE
};

localparam BTN_START = 10;
localparam BTN_COIN = 11;
localparam BTN_PAUSE = 12;
localparam BTN_SS = 13;

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

wire ioctl_rom_wait;
/*wire ioctl_hs_upload_req;
wire ioctl_m107_upload_req;
wire [7:0] ioctl_hs_din;
wire [7:0] ioctl_m107_din;*/

wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req = 0; //ioctl_hs_upload_req | ioctl_m107_upload_req;
wire  [7:0] ioctl_index;
wire  [7:0] ioctl_upload_index;
wire        ioctl_wr;
wire        ioctl_rd;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_din = 0; // = ioctl_m107_din | ioctl_hs_din;
wire        ioctl_wait = ioctl_rom_wait;

wire [15:0] joystick_p1, joystick_p2, joystick_p3, joystick_p4;
wire [7:0] analog_x_p1, analog_y_p1, analog_x_p2, analog_y_p2;
wire [7:0] paddle_p1, paddle_p2;
wire [8:0] spinner_p1, spinner_p2;

wire [3:0] kb_start, kb_coin;
wire [7:0] kb_p1, kb_p2, kb_p3, kb_p4;
wire kb_pause;

wire [15:0] mame_p1, mame_p2, mame_p3, mame_p4;

assign mame_p1[7:0] = kb_p1;
assign mame_p1[BTN_PAUSE] = kb_pause;
assign mame_p1[BTN_COIN] = kb_coin[0];
assign mame_p1[BTN_START] = kb_start[0];

assign mame_p2[7:0] = kb_p2;
assign mame_p2[BTN_PAUSE] = kb_pause;
assign mame_p2[BTN_COIN] = kb_coin[1];
assign mame_p2[BTN_START] = kb_start[1];

assign mame_p3[7:0] = kb_p3;
assign mame_p3[BTN_PAUSE] = kb_pause;
assign mame_p3[BTN_COIN] = kb_coin[2];
assign mame_p3[BTN_START] = kb_start[2];

assign mame_p4[7:0] = kb_p4;
assign mame_p4[BTN_PAUSE] = kb_pause;
assign mame_p4[BTN_COIN] = kb_coin[3];
assign mame_p4[BTN_START] = kb_start[3];

wire [15:0] input_p1 = joystick_p1 | mame_p1;
wire [15:0] input_p2 = joystick_p2 | mame_p2;
wire [15:0] input_p3 = joystick_p3 | mame_p3;
wire [15:0] input_p4 = joystick_p4 | mame_p4;

wire [15:0] input_combined = input_p1 | input_p2 | input_p3 | input_p4;

wire [21:0] gamma_bus;
wire        direct_video;
wire        video_rotated;

wire        autosave = 0; //status[8];

wire        info_req;
wire [7:0]  info_index;

wire [127:0] status_in = { status[127:43], ss_slot, status[40:0] };

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),
    .EXT_BUS(),
    .gamma_bus(gamma_bus),
    .direct_video(direct_video),

    .forced_scandoubler(forced_scandoubler),
    .new_vmode(0),
    .video_rotated(video_rotated),

    .buttons(buttons),
    .status(status),
    .status_menumask({direct_video}),
    .status_in(status_in),
    .status_set(ss_status_set),

    .ioctl_download(ioctl_download),
    .ioctl_upload(ioctl_upload),
    .ioctl_upload_index(ioctl_upload_index),
    .ioctl_upload_req(ioctl_upload_req & autosave),
    .ioctl_wr(ioctl_wr),
    .ioctl_rd(ioctl_rd),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_din(ioctl_din),
    .ioctl_index(ioctl_index),
    .ioctl_wait(ioctl_wait),

    .info_req,
    .info(info_index),

    .joystick_0(joystick_p1),
    .joystick_1(joystick_p2),
    .joystick_2(joystick_p3),
    .joystick_3(joystick_p4),

    .joystick_l_analog_0({analog_y_p1, analog_x_p1}),
    .joystick_l_analog_1({analog_y_p2, analog_x_p2}),

    .paddle_0(paddle_p1),
    .paddle_1(paddle_p2),

    .spinner_0(spinner_p1),
    .spinner_1(spinner_p2),


    .ps2_key(ps2_key)
);

mame_keys mame_keys(
    .clk(clk_sys),
    .reset,

    .ps2_key,

    .start(kb_start),
    .coin(kb_coin),
    .p1(kb_p1),
    .p2(kb_p2),
    .p3(kb_p3),
    .p4(kb_p4),
    .pause(kb_pause)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys, clk_sdr, pll_locked;
pll pll
(
    .refclk(CLK_50M),
    .rst(0),
    .locked(pll_locked),
    .outclk_0(clk_sdr),
    .outclk_1(clk_sys)
);

wire reset = RESET | status[0] | buttons[1] | rom_load_busy;

wire [26:0] sdr_ch1_addr, sdr_ch2_addr, sdr_ch4_addr;
wire sdr_ch1_req, sdr_ch2_req, sdr_ch4_req;
wire sdr_ch1_ack, sdr_ch2_ack, sdr_ch4_ack;
wire [31:0] sdr_ch1_dout;

wire [63:0] sdr_ch2_dout;

wire [63:0] sdr_ch3_dout;
wire sdr_ch3_ack;

wire [63:0] sdr_ch4_dout;

wire [26:0] sdr_cpu_addr, sdr_rom_addr;
wire [15:0] sdr_cpu_din, sdr_rom_din;
wire [1:0] sdr_cpu_be, sdr_rom_be;
wire sdr_cpu_req, sdr_rom_req;
wire sdr_cpu_rw, sdr_rom_rw;

wire [26:0] sdr_ch3_addr = rom_load_busy ? sdr_rom_addr : sdr_cpu_addr;
wire [15:0] sdr_ch3_din = sdr_rom_din;
wire [63:0] sdr_cpu_dout = sdr_ch3_dout;
wire [1:0] sdr_ch3_be = rom_load_busy ? sdr_rom_be : 2'b00;
wire sdr_ch3_req = rom_load_busy ? sdr_rom_req : sdr_cpu_req;
wire sdr_cpu_ack = rom_load_busy ? sdr_cpu_req : sdr_ch3_ack; // FIXME, wtf to do with this in unknown state?
wire sdr_rom_ack = rom_load_busy ? sdr_ch3_ack : sdr_rom_req;
wire sdr_ch3_rnw = rom_load_busy ? sdr_rom_rw  : 1;

sdram sdram
(
    .init(~pll_locked),        // reset to initialize RAM
    .clk(clk_sdr),         // clock 64MHz

    .doRefresh(core_hb | core_vb),

    .SDRAM_DQ,    // 16 bit bidirectional data bus
    .SDRAM_A,     // 13 bit multiplexed address bus
    .SDRAM_DQML,  // two byte masks
    .SDRAM_DQMH,  //
    .SDRAM_BA,    // two banks
    .SDRAM_nCS,   // a single chip select
    .SDRAM_nWE,   // write enable
    .SDRAM_nRAS,  // row address select
    .SDRAM_nCAS,  // columns address select
    .SDRAM_CKE,   // clock enable
    .SDRAM_CLK,   // clock for chip

    .ch1_addr(sdr_ch1_addr),    // 25 bit address for 8bit mode. addr[0] = 0 for 16bit mode for correct operations.
    .ch1_dout(sdr_ch1_dout),    // data output to cpu
    .ch1_req(sdr_ch1_req),     // request
    .ch1_ack(sdr_ch1_ack),

    .ch2_addr(sdr_ch2_addr),
    .ch2_dout(sdr_ch2_dout),
    .ch2_req(sdr_ch2_req),
    .ch2_ack(sdr_ch2_ack),

    .ch3_addr(sdr_ch3_addr),
    .ch3_dout(sdr_ch3_dout),
    .ch3_din(sdr_ch3_din),
    .ch3_be(sdr_ch3_be),
    .ch3_req(sdr_ch3_req),
    .ch3_rnw(sdr_ch3_rnw),     // 1 - read, 0 - write
    .ch3_ack(sdr_ch3_ack),

    .ch4_addr(sdr_ch4_addr),
    .ch4_dout(sdr_ch4_dout),
    .ch4_req(sdr_ch4_req),
    .ch4_ack(sdr_ch4_ack)
);

ddr_if ddr_host(), ddr_romload(), ddr_x(), ddr_romload_adaptor(), ddr_romload_loader(), ddr_f2(), ddr_rotate();

ddr_mux ddr_mux(
    .clk(clk_sys),
    .x(ddr_host),
    .a(ddr_f2),
    .b(ddr_x)
);

ddr_mux ddr_mux2(
    .clk(clk_sys),
    .x(ddr_romload),
    .a(ddr_romload_adaptor),
    .b(ddr_romload_loader)
);

ddr_mux ddr_mux3(
    .clk(clk_sys),
    .x(ddr_x),
    .a(ddr_rotate),
    .b(ddr_romload)
);

wire rom_load_busy;
wire rom_data_wait;
wire rom_data_strobe;
wire [7:0] rom_data;

wire rom_set_map_base;
wire [3:0] rom_base_idx;
wire [31:0] rom_map_base;

wire [23:0] bram_addr;
wire  [7:0] bram_data;
wire        bram_wr;

board_cfg_t board_cfg;

reg cart_present;
reg [23:0] cart_tile_base;
reg [23:0] cart_prog_base;
reg [23:0] cart_music_base;


ddr_rom_loader_adaptor ddr_rom_loader(
    .clk(clk_sys),

    .ioctl_download,
    .ioctl_addr,
    .ioctl_index,
    .ioctl_wr,
    .ioctl_data(ioctl_dout),
    .ioctl_wait(ioctl_rom_wait),

    .busy(rom_load_busy),

    .data_wait(rom_data_wait),
    .data_strobe(rom_data_strobe),
    .data(rom_data),

    .ddr(ddr_romload_adaptor)
);

rom_loader rom_loader(
    .sys_clk(clk_sys),

    .ioctl_wr(rom_data_strobe),
    .ioctl_data(rom_data),
    .ioctl_wait(rom_data_wait),

    .sdr_addr(sdr_rom_addr),
    .sdr_data(sdr_rom_din),
    .sdr_be(sdr_rom_be),
    .sdr_req(sdr_rom_req),
    .sdr_ack(sdr_rom_ack),
    .sdr_rw(sdr_rom_rw),

    .ddr(ddr_romload_loader),

    .bram_addr(bram_addr),
    .bram_data(bram_data),
    .bram_wr(bram_wr),

    .board_cfg(board_cfg),

    .set_map_base(rom_set_map_base),
    .map_base(rom_map_base),
    .base_idx(rom_base_idx)
);

reg prev_rom_load_busy;

always_ff @(posedge clk_sys) begin
    prev_rom_load_busy <= rom_load_busy;

    if (rom_load_busy & ~prev_rom_load_busy) begin
        cart_present <= 0;
    end

    if (rom_set_map_base) begin
        case (rom_base_idx)
            1: begin
                cart_prog_base <= rom_map_base[23:0];
                cart_present <= 1;
            end
            2: begin
                cart_tile_base <= rom_map_base[23:0];
                cart_present <= 1;
            end
            3: begin
                cart_music_base <= rom_map_base[23:0];
                cart_present <= 1;
            end
            default: begin end
        endcase
    end
end

// DIP SWITCHES
reg [7:0] dip_sw[8];    // Active-LOW
always @(posedge clk_sys) begin
    if(ioctl_wr && (ioctl_index==254) && !ioctl_addr[24:3])
        dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end


wire [7:0] core_r, core_g, core_b;
wire core_hb, core_vb, core_hs, core_vs;
wire core_ce_pix;

wire [31:0] DDRAM_ADDR_32 = ddr_host.addr;

assign DDRAM_ADDR = ddr_host.addr[31:3];
assign DDRAM_BE = ddr_host.byteenable;
assign DDRAM_WE = ddr_host.write;
assign DDRAM_RD = ddr_host.read;
assign DDRAM_DIN = ddr_host.wdata;
assign DDRAM_BURSTCNT = ddr_host.burstcnt;
assign ddr_host.rdata = DDRAM_DOUT;
assign ddr_host.rdata_ready = DDRAM_DOUT_READY;
assign ddr_host.busy = DDRAM_BUSY;

wire sync_fix = ~status[19];


reg [7:0] analog_p1, analog_p2;
reg [1:0] prev_spinner;
reg analog_inc, analog_abs;
wire [1:0] analog_mode = status[33:32];
wire [2:0] analog_sens = status[36:34];
wire analog_invert = status[37];

function bit [7:0] sens(input [7:0] d);
    bit [7:0] r;
    unique case (analog_sens)
        3'b000: r = d;
        3'b001: r = {d[7], d[7:1]};
        3'b010: r = {d[7], d[7], d[7:2]};
        3'b011: r = {d[7], d[7], d[7], d[7:3]};
        3'b100: r = {d[7], d[7], d[7], d[7], d[7:4]};
        3'b101: r = d + d;
        3'b110: r = d + { d[7], d[7:1] };
        3'b111: r = d + { d[7], d[7], d[7:2] };
    endcase
    return analog_invert ? (r ? ~r : r) : r;
endfunction

always_ff @(posedge clk_sys) begin
    prev_spinner <= { spinner_p2[8], spinner_p1[8] };
    analog_p1 <= 0;
    analog_p2 <= 0;
    analog_inc <= 0;
    analog_abs <= 0;
    unique case(analog_mode)
        2'b00: begin
            analog_p1 <= sens(analog_x_p1);
            analog_p2 <= sens(analog_x_p2);
            analog_abs <= 1;
        end
        2'b01: begin
            analog_p1 <= sens(paddle_p1 - 8'h7f);
            analog_p2 <= sens(paddle_p2 - 8'h7f);
            analog_abs <= 1;
        end
        2'b10: begin
            if (prev_spinner[0] ^ spinner_p1[8]) begin
                analog_p1 <= sens(spinner_p1[7:0]);
                analog_inc <= 1;
            end
            if (prev_spinner[1] ^ spinner_p2[8]) begin
                analog_p2 <= sens(spinner_p2[7:0]);
                analog_inc <= 1;
            end
        end
        2'b11: begin
            analog_p1 <= sens(input_p1[0] ? 8'h40 : input_p1[1] ? 8'hc0 : 8'h00);
            analog_p2 <= sens(input_p2[0] ? 8'h40 : input_p2[1] ? 8'hc0 : 8'h00);
            analog_abs <= 1;
        end
    endcase
end

PGM pgm_inst(
    .clk_50m(clk_sys),
    .reset(reset),

    .pause(system_pause),

    .game(board_cfg.game),

    .ce_pixel(core_ce_pix),
    .hsync(core_hs),
    .hblank(core_hb),
    .vsync(core_vs),
    .vblank(core_vb),
    .red(core_r),
    .green(core_g),
    .blue(core_b),

    .dswa(~dip_sw[0]),
    .dswb(~dip_sw[1]),

    .joystick_p1(input_p1[9:0]),
    .joystick_p2(input_p2[9:0]),
    .joystick_p3(input_p3[9:0]),
    .joystick_p4(input_p4[9:0]),

    .analog_abs(analog_abs),
    .analog_inc(analog_inc),
    .analog_p1(analog_p1),
    .analog_p2(analog_p2),

    .start({input_p4[BTN_START], input_p3[BTN_START], input_p2[BTN_START], input_p1[BTN_START]}),
    .coin(coin),

    .audio_out(AUDIO_L),

    .sdr_cpu_addr(sdr_cpu_addr),
    .sdr_cpu_q(sdr_cpu_dout),
    .sdr_cpu_req(sdr_cpu_req),
    .sdr_cpu_ack(sdr_cpu_ack),

    .sdr_tile_addr(sdr_ch1_addr),
    .sdr_tile_q(sdr_ch1_dout),
    .sdr_tile_req(sdr_ch1_req),
    .sdr_tile_ack(sdr_ch1_ack),

    .sdr_audio_addr(sdr_ch2_addr),
    .sdr_audio_q(sdr_ch2_dout),
    .sdr_audio_req(sdr_ch2_req),
    .sdr_audio_ack(sdr_ch2_ack),

    .cart_present,
    .cart_prog_base,
    .cart_tile_base,
    .cart_music_base,

    .sdr_sprite_addr(sdr_ch4_addr),
    .sdr_sprite_q(sdr_ch4_dout),
    .sdr_sprite_req(sdr_ch4_req),
    .sdr_sprite_ack(sdr_ch4_ack),

    .ddr(ddr_f2),

    .obj_debug_idx(13'h1fff),

    .ss_index(ss_slot),
    .ss_do_save(ss_save),
    .ss_do_restore(ss_load),
    .ss_state_out(),

    .bram_addr,
    .bram_data,
    .bram_wr,

    .sync_fix
);

assign CLK_VIDEO = clk_sys;
assign DDRAM_CLK = clk_sys;

wire [1:0] ar             = status[2:1];
wire [2:0] scandoubler_fx = status[5:3];
wire [1:0] scale          = status[7:6];
wire       rotate         = status[8];
wire [4:0] hoffset        = status[13:9];
wire [4:0] voffset        = status[18:14];

wire       osd_pause      = status[38];
wire       pause_dim      = ~status[39];

wire [7:0] pause_r, pause_g, pause_b;
wire system_pause;

pause #(.CLKSPD(53)) pause(
    .clk_sys,
    .reset,
    .user_button(input_combined[BTN_PAUSE]),
    .pause_request(0),
    .options({pause_dim, osd_pause}),

    .OSD_STATUS,
    .r(core_r), .g(core_g), .b(core_b),

    .pause_cpu(system_pause),

    .r_out(pause_r),
    .g_out(pause_g),
    .b_out(pause_b)
);

wire [3:0] coin;
coin_pulse cp0(.clk(clk_sys), .vblank(core_vb), .button(input_p1[BTN_COIN]), .pulse(coin[0]));
coin_pulse cp1(.clk(clk_sys), .vblank(core_vb), .button(input_p2[BTN_COIN]), .pulse(coin[1]));
coin_pulse cp2(.clk(clk_sys), .vblank(core_vb), .button(input_p3[BTN_COIN]), .pulse(coin[2]));
coin_pulse cp3(.clk(clk_sys), .vblank(core_vb), .button(input_p4[BTN_COIN]), .pulse(coin[3]));

video_path video_path(
    .CLK_VIDEO,

    .hoffset, .voffset,

    .forced_scandoubler, .scandoubler_fx,
    .ar, .scale,

    .rotate, .rotate_ccw(1), .flip(0),
    .video_rotated,

    .core_ce_pix,
    .core_hs, .core_vs, .core_hb, .core_vb,
    .core_r(pause_r), .core_g(pause_g), .core_b(pause_b),

    .HDMI_WIDTH, .HDMI_HEIGHT,
    .VIDEO_ARX, .VIDEO_ARY,

    .gamma_bus,

    .FB_EN, .FB_FORMAT,
    .FB_WIDTH, .FB_HEIGHT,
    .FB_BASE, .FB_STRIDE,
    .FB_VBL, .FB_LL,

    .ddr(ddr_rotate),

    .CE_PIXEL,
    .VGA_R, .VGA_G, .VGA_B,
    .VGA_HS, .VGA_VS, .VGA_DE,
    .VGA_SL
);

wire ss_load, ss_save;
wire [1:0] ss_slot;
wire ss_status_set;

savestate_ui #(.INFO_TIMEOUT_BITS(25)) savestate_ui
(
    .clk            (clk_sys),
    .ps2_key        (ps2_key[10:0]),
    .allow_ss       (1),
    .joySS          (input_combined[BTN_SS]),
    .joyRight       (input_combined[0]),
    .joyLeft        (input_combined[1]),
    .joyDown        (input_combined[2]),
    .joyUp          (input_combined[3]),
    .joyRewind      (0),
    .rewindEnable   (0),
    .status_slot    (status[42:41]),
    .autoincslot    (status[40]),
    .OSD_saveload   (status[44:43]),
    .ss_save        (ss_save),
    .ss_load        (ss_load),
    .ss_info_req    (info_req),
    .ss_info        (info_index),
    .statusUpdate   (ss_status_set),
    .selected_slot  (ss_slot)
);

endmodule
