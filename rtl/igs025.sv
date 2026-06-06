// IGS025 protection device (The Killing Blade, Dragon World 3).
// Converted from MAME src/mame/igs/igs025.cpp + pgmprot_igs025_igs022.cpp.  copyright-holders: David Haywood, ElSemi.
//
// Accessed as two 16-bit words: offset 0 = command (kb_cmd), offset 1 = data/
// result.  Some commands pulse `trigger` to run the companion IGS022 command.

import system_consts::*;

module igs025 #(
    parameter int SS_IDX = -1
)(
    input  logic        clk,
    input  logic        reset,

    input  game_t       game,        // selects table set + game_id formula
    input  logic [7:0]  region,      // raw "Region" byte (World by default)

    // 68000-style 16-bit interface.  cpu_addr is the low nibble of the byte
    // address; bit[1] selects word offset 0 (cmd) vs 1 (data).
    input  logic [3:0]  cpu_addr,
    input  logic [15:0] cpu_din,
    output logic [15:0] cpu_dout,
    input  logic        cpu_uds_n,
    input  logic        cpu_lds_n,
    input  logic        cpu_rw,      // 1 = read, 0 = write
    input  logic        cpu_cs_n,

    output logic        trigger,     // 1-cycle pulse -> igs022.handle_command

    ssbus_if.slave ssbus
);

    logic [15:0] kb_cmd;
    logic [15:0] kb_reg;
    logic [15:0] kb_ptr;
    logic [15:0] kb_swap;
    logic [15:0] kb_prot_hold;
    logic [15:0] kb_prot_hilo;
    logic [7:0]  kb_prot_hilo_select;
    logic [7:0]  kb_region;
    logic [31:0] kb_game_id;

    logic write_active_d;
    logic read_active_d;

    localparam int SS_WORD_COUNT = 4;
    localparam int SS_WORD_CMDREG = 0;
    localparam int SS_WORD_PTRSWAP = 1;
    localparam int SS_WORD_HOLDHILO = 2;
    localparam int SS_WORD_MISC = 3;

    wire ss_access = ssbus.access(SS_IDX);

    wire access_active = !cpu_cs_n && (!cpu_uds_n || !cpu_lds_n);
    wire write_active  = access_active && !cpu_rw;
    wire read_active   = access_active &&  cpu_rw;
    wire write_pulse   = write_active && !write_active_d;
    wire read_pulse    = read_active  && !read_active_d;
    wire offset        = cpu_addr[1];   // 0 = command word, 1 = data word

    wire killbld_tables = (game == GAME_KILLBLD);

    // Region/game-id values latched at reset (MACHINE_RESET in MAME).
    wire [7:0]  reset_kb_region = killbld_tables ? (region - 8'h16) : region;
    wire [31:0] reset_game_id   = killbld_tables ? (32'h89911400 | {24'd0, region})
                                                 : (32'h00060000 | {24'd0, region});

    // killbld_protection_calculate_hold:
    // h = rol1(old); h^=0x2bad; h^=bit(z,y); h^=bit(old,7); h^=bit(~old,13)<<4;
    // h^=bit(old,3)<<11; h^=(hilo & ~0x0408)<<1;
    function automatic logic [15:0] calc_hold(
        input logic [15:0] old_hold,
        input logic [15:0] old_hilo,
        input logic [3:0]  y,
        input logic [7:0]  z
    );
        logic [15:0] h;
        logic        zb;
        h  = {old_hold[14:0], old_hold[15]};
        h  = h ^ 16'h2bad;
        zb = z[y[2:0]];
        h  = h ^ {15'd0, zb};
        h  = h ^ {15'd0, old_hold[7]};
        h  = h ^ ({15'd0, ~old_hold[13]} << 4);
        h  = h ^ ({15'd0, old_hold[3]} << 11);
        h  = h ^ (((old_hilo & 16'hfbf7) << 1) & 16'hffff);  // ~0x0408 = 0xfbf7
        return h;
    endfunction

    // source table (killbld_protection_calculate_hilo):
    // select advances first, then table[region][select] updates hi/lo byte.
    wire [7:0] hilo_next_sel = (kb_prot_hilo_select >= 8'heb)
                             ? 8'd0 : (kb_prot_hilo_select + 8'd1);
    wire [7:0] src_byte;

    igs025_src_tables tables(
        .killbld(killbld_tables),
        .region(kb_region[3:0]),
        .select(hilo_next_sel),
        .data(src_byte)
    );

    // read mux:
    // bitswap<8>((kb_swap+1)&0x7f, 0,1,2,3,4,5,6,7) -> bit-reverse the byte.
    wire [7:0] swap_in = (kb_swap[7:0] + 8'd1) & 8'h7f;
    wire [7:0] read_cmd00 = {swap_in[0], swap_in[1], swap_in[2], swap_in[3],
                             swap_in[4], swap_in[5], swap_in[6], swap_in[7]};
    // bitswap<8>(hold, 5,2,9,7,10,13,12,15)
    wire [7:0] hold_bs = {kb_prot_hold[5], kb_prot_hold[2], kb_prot_hold[9], kb_prot_hold[7],
                          kb_prot_hold[10], kb_prot_hold[13], kb_prot_hold[12], kb_prot_hold[15]};

    logic [15:0] read_val;
    always_comb begin
        read_val = 16'h0000;
        if (offset) begin
            unique case (kb_cmd[7:0])
                8'h00: read_val = {8'd0, read_cmd00};
                8'h01: read_val = kb_reg & 16'h007f;
                8'h03: read_val = 16'h0000;                 // kb_cmd3 (olds only)
                8'h05: begin
                    unique case (kb_ptr)
                        16'd1: read_val = 16'h3f00 | {8'd0, kb_game_id[7:0]};
                        16'd2: read_val = 16'h3f00 | {8'd0, kb_game_id[15:8]};
                        16'd3: read_val = 16'h3f00 | {8'd0, kb_game_id[23:16]};
                        16'd4: read_val = 16'h3f00 | {8'd0, kb_game_id[31:24]};
                        default: read_val = 16'h3f00 | {8'd0, hold_bs};
                    endcase
                end
                8'h40: read_val = 16'h0000;                 // side-effect handled below
                default: read_val = 16'h0000;
            endcase
        end
    end

    assign cpu_dout = read_val;

    always_ff @(posedge clk) begin
        if (reset) begin
            kb_cmd <= 16'd0;
            kb_reg <= 16'd0;
            kb_ptr <= 16'd0;
            kb_swap <= 16'd0;
            kb_prot_hold <= 16'd0;
            kb_prot_hilo <= 16'd0;
            kb_prot_hilo_select <= 8'd0;
            kb_region <= reset_kb_region;
            kb_game_id <= reset_game_id;
            write_active_d <= 1'b0;
            read_active_d <= 1'b0;
            trigger <= 1'b0;
        end else begin
            write_active_d <= write_active;
            read_active_d <= read_active;
            trigger <= 1'b0;

            ssbus.setup(SS_IDX, SS_WORD_COUNT[31:0], 2);

            if (ss_access) begin
                if (ssbus.read) begin
                    unique case (ssbus.addr)
                        SS_WORD_CMDREG:   ssbus.read_response(SS_IDX, {32'd0, kb_reg, kb_cmd});
                        SS_WORD_PTRSWAP:  ssbus.read_response(SS_IDX, {32'd0, kb_swap, kb_ptr});
                        SS_WORD_HOLDHILO: ssbus.read_response(SS_IDX, {32'd0, kb_prot_hilo, kb_prot_hold});
                        SS_WORD_MISC:     ssbus.read_response(SS_IDX, {56'd0, kb_prot_hilo_select});
                        default:          ssbus.read_response(SS_IDX, 64'd0);
                    endcase
                end else if (ssbus.write) begin
                    unique case (ssbus.addr)
                        SS_WORD_CMDREG:   begin kb_cmd <= ssbus.data[15:0]; kb_reg <= ssbus.data[31:16]; end
                        SS_WORD_PTRSWAP:  begin kb_ptr <= ssbus.data[15:0]; kb_swap <= ssbus.data[31:16]; end
                        SS_WORD_HOLDHILO: begin kb_prot_hold <= ssbus.data[15:0]; kb_prot_hilo <= ssbus.data[31:16]; end
                        SS_WORD_MISC:     kb_prot_hilo_select <= ssbus.data[7:0];
                        default: ;
                    endcase
                    ssbus.write_ack(SS_IDX);
                end
            end else begin
                if (write_pulse) begin
`ifdef IGS_PROT_DEBUG
                    $display("[IGS025] wr off=%0d cmd=%02x data=%04x", offset, kb_cmd[7:0], cpu_din);
`endif
                    if (!offset) begin
                        kb_cmd <= cpu_din;
                    end else begin
                        unique case (kb_cmd[7:0])
                            8'h00: kb_reg <= cpu_din;
                            8'h01: if (cpu_din == 16'h0002) trigger <= 1'b1;      // drgw3
                            8'h02: if (cpu_din == 16'h0001) begin                 // killbld
                                       trigger <= 1'b1;
                                       kb_reg <= kb_reg + 16'd1;
                                   end
                            8'h03: kb_swap <= cpu_din;
                            8'h20, 8'h21, 8'h22, 8'h23,
                            8'h24, 8'h25, 8'h26, 8'h27: begin
                                kb_ptr <= kb_ptr + 16'd1;
                                kb_prot_hold <= calc_hold(kb_prot_hold, kb_prot_hilo,
                                                          kb_cmd[3:0], cpu_din[7:0]);
                            end
                            default: ;
                        endcase
                    end
                end

                // read cmd 0x40 has a side effect: advance the hilo machine.
                if (read_pulse && offset && (kb_cmd[7:0] == 8'h40)) begin
                    kb_prot_hilo_select <= hilo_next_sel;
                    if (hilo_next_sel[0])
                        kb_prot_hilo <= {src_byte, kb_prot_hilo[7:0]};
                    else
                        kb_prot_hilo <= {kb_prot_hilo[15:8], src_byte};
                end
            end
        end
    end

endmodule
