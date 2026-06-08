import system_consts::*;

module address_translator(
    input game_t game,

    input [1:0]  cpu_ds_n,
    input [23:0] cpu_word_addr,
    input        ss_override,

    output logic ROMn,
    output logic WORKRAMn,
    output logic IGS023n,
    output logic IGS026_Xn,
    output logic IOn,
    output logic IGS025n,
    output logic IGS022_RAMn,
    output logic ARM_SHAREn,
    output logic ARM_LATCHn,
    output logic ARM_NMIn,
    output logic SS_SAVEn,
    output logic SS_RESETn,
    output logic SS_VECn
);

function bit match_addr_n(input [23:0] addr, input [15:0] value, input [15:0] mask);
    bit r;
    r = (addr[23:8] & mask[15:0]) == value[15:0];
    return ~r;
endfunction


/* verilator lint_off CASEX */

always_comb begin
    ROMn = 1;
    WORKRAMn = 1;
    IGS023n = 1;
    IGS026_Xn = 1;
    IOn = 1;
    IGS025n = 1;
    IGS022_RAMn = 1;
    ARM_SHAREn = 1;
    ARM_LATCHn = 1;
    ARM_NMIn = 1;

    SS_SAVEn = 1;
    SS_RESETn = 1;
    SS_VECn = 1;

    if (ss_override) begin
        if (~&cpu_ds_n) begin
            casex(cpu_word_addr)
                24'h00000x: begin
                    SS_RESETn = 0;
                end
                24'h00007c: begin
                    SS_VECn = 0;
                end
                24'h00007e: begin
                    SS_VECn = 0;
                end
                24'hff00xx: begin
                    SS_SAVEn = 0;
                end
                default: begin end
            endcase
        end
    end

    if (~&cpu_ds_n) begin
        ROMn = match_addr_n(cpu_word_addr, 16'h0000, 16'h8000);
        WORKRAMn = match_addr_n(cpu_word_addr, 16'h8000, 16'hf000);
        IGS023n = match_addr_n(cpu_word_addr, 16'h9000, 16'hff00) & match_addr_n(cpu_word_addr, 16'ha000, 16'hff00) & match_addr_n(cpu_word_addr, 16'hb000, 16'hff00);
        IGS026_Xn = match_addr_n(cpu_word_addr, 16'hc000, 16'hfe00);
        IOn = match_addr_n(cpu_word_addr, 16'hc080, 16'hffff);

        // IGS022/IGS025 protection (The Killing Blade / Dragon World 3).
        if (game == GAME_KILLBLD || game == GAME_DRGW3) begin
            // Shared protection RAM: 0x300000-0x303fff.
            IGS022_RAMn = ~(cpu_word_addr[23:14] == 10'h0c0);
            // Exclude the shared-RAM window from the ROM decode.
            ROMn = ROMn | ~IGS022_RAMn;
        end

        // IGS025: killbld @ 0xd40000-0xd40003, drgw3 @ 0xda5610-0xda5613.
        if (game == GAME_KILLBLD)
            IGS025n = ~(cpu_word_addr[23:2] == 22'h350000);
        else if (game == GAME_DRGW3)
            IGS025n = ~(cpu_word_addr[23:2] == 22'h369584);

        // IGS027A ARM (kovsh / type1): shared RAM @0x4f0000-0x4f003f,
        // command/response latch @0x500000-0x500003.
        if (game == GAME_KOVSH || game == GAME_PHOTOY2K) begin
            ARM_SHAREn = ~(cpu_word_addr[23:6] == 18'h13c00);  // 0x4f0000-0x4f003f
            ARM_LATCHn = ~(cpu_word_addr[23:2] == 22'h140000); // 0x500000-0x500003
            ROMn = ROMn | ~ARM_SHAREn | ~ARM_LATCHn;           // carve out of ROM window
        end

        // IGS027A type2 (kov2/kov2p/ddp2/martmast/dw2001/dwpc): shared RAM
        // 0xd00000-0xd0ffff (64KB), latch 0xd10000-0xd10001.  Above ROM space,
        // no carve-out.
        if (game == GAME_KOV2 || game == GAME_KOV2P || game == GAME_DDP2 ||
            game == GAME_MARTMAST || game == GAME_DW2001 || game == GAME_DWPC) begin
            ARM_SHAREn = ~(cpu_word_addr[23:16] == 8'hd0);     // 0xd00000-0xd0ffff
            ARM_LATCHn = ~(cpu_word_addr[23:1] == 23'h688000); // 0xd10000-0xd10001
        end

        // IGS027A type3 (dmnfrnt/theglad): shared RAM 0x500000-0x50ffff (64KB,
        // double-buffered), command latch 0x5c0300-0x5c0301, ARM FIQ pulse on a
        // write to 0x5c0000-0x5c0001.  All sit inside the ROM window -> carve out.
        if (game == GAME_DMNFRNT || game == GAME_THEGLAD) begin
            ARM_SHAREn = ~(cpu_word_addr[23:16] == 8'h50);     // 0x500000-0x50ffff
            ARM_LATCHn = ~(cpu_word_addr[23:1]  == 23'h2e0180);// 0x5c0300-0x5c0301
            ARM_NMIn   = ~(cpu_word_addr[23:1]  == 23'h2e0000);// 0x5c0000-0x5c0001
            ROMn = ROMn | ~ARM_SHAREn | ~ARM_LATCHn | ~ARM_NMIn;
        end
    end
end
/* verilator lint_on CASEX */


endmodule


