import system_consts::*;

module address_translator(
    input game_t game,

    input [1:0]  cpu_ds_n,
    input [23:0] cpu_word_addr,
    input        ss_override,

    output logic ROMn,
    output logic PROGn,
    output logic WORKRAMn,
    output logic IGS023n,
    output logic IGS026_Z80n,
    output logic IOn,
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
    PROGn = 1;
    WORKRAMn = 1;
    IGS023n = 1;
    IGS026_Z80n = 1;
    IOn = 1;

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
        IGS026_Z80n = match_addr_n(cpu_word_addr, 16'hc000, 16'hfe00);
        IOn = match_addr_n(cpu_word_addr, 16'hc080, 16'hffff);
        
    end
end
/* verilator lint_on CASEX */


endmodule


