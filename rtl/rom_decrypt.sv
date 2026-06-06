import system_consts::*;

module rom_decrypt(
    input  game_t        game,
    input  logic  [22:0] word_addr,
    input  logic  [15:0] rom_word_in,
    output logic  [15:0] rom_word_out
);

localparam logic [7:0] KOVSH_TAB[256] = '{
    8'he7, 8'h06, 8'ha3, 8'h70, 8'hf2, 8'h58, 8'he6, 8'h59, 8'he4, 8'hcf, 8'hc2, 8'h79, 8'h1d, 8'he3, 8'h71, 8'h0e,
    8'hb6, 8'h90, 8'h9a, 8'h2a, 8'h8c, 8'h41, 8'hf7, 8'h82, 8'h9b, 8'hef, 8'h99, 8'h0c, 8'hfa, 8'h2f, 8'hf1, 8'hfe,
    8'h8f, 8'h70, 8'hf4, 8'hc1, 8'hb5, 8'h3d, 8'h7c, 8'h60, 8'h4c, 8'h09, 8'hf4, 8'h2e, 8'h7c, 8'h87, 8'h63, 8'h5f,
    8'hce, 8'h99, 8'h84, 8'h95, 8'h06, 8'h9a, 8'h20, 8'h23, 8'h5a, 8'hb9, 8'h52, 8'h95, 8'h48, 8'h2c, 8'h84, 8'h60,
    8'h69, 8'he3, 8'h93, 8'h49, 8'hb9, 8'hd6, 8'hbb, 8'hd6, 8'h9e, 8'hdc, 8'h96, 8'h12, 8'hfa, 8'h60, 8'hda, 8'h5f,
    8'h55, 8'h5d, 8'h5b, 8'h20, 8'h07, 8'h1e, 8'h97, 8'h42, 8'h77, 8'hea, 8'h1d, 8'he0, 8'h70, 8'hfb, 8'h6a, 8'h00,
    8'h77, 8'h9a, 8'hef, 8'h1b, 8'he0, 8'hf9, 8'h0d, 8'hc1, 8'h2e, 8'h2f, 8'hef, 8'h25, 8'h29, 8'he5, 8'hd8, 8'h2c,
    8'haf, 8'h01, 8'hd9, 8'h6c, 8'h31, 8'hce, 8'h5c, 8'hea, 8'hab, 8'h1c, 8'h92, 8'h16, 8'h61, 8'hbc, 8'he4, 8'h7c,
    8'h5a, 8'h76, 8'he9, 8'h92, 8'h39, 8'h5b, 8'h97, 8'h60, 8'hea, 8'h57, 8'h83, 8'h9c, 8'h92, 8'h29, 8'ha7, 8'h12,
    8'ha9, 8'h71, 8'h7a, 8'hf9, 8'h07, 8'h68, 8'ha7, 8'h45, 8'h88, 8'h10, 8'h81, 8'h12, 8'h2c, 8'h67, 8'h4d, 8'h55,
    8'h33, 8'hf0, 8'hfa, 8'hd7, 8'h1d, 8'h4d, 8'h0e, 8'h63, 8'h03, 8'h34, 8'h65, 8'he2, 8'h76, 8'h0f, 8'h98, 8'ha9,
    8'h5f, 8'h9a, 8'hd3, 8'hca, 8'hdd, 8'hc1, 8'h5b, 8'h3d, 8'h4d, 8'hf8, 8'h40, 8'h08, 8'hdc, 8'h05, 8'h38, 8'h00,
    8'hcb, 8'h24, 8'h02, 8'hff, 8'h39, 8'he2, 8'h9e, 8'h04, 8'h9a, 8'h08, 8'h63, 8'hc8, 8'h2b, 8'h5a, 8'h34, 8'h06,
    8'h62, 8'hc1, 8'hbb, 8'h8a, 8'hd0, 8'h54, 8'h4c, 8'h43, 8'h21, 8'h4e, 8'h4c, 8'h99, 8'h80, 8'hc2, 8'h3d, 8'hce,
    8'h2a, 8'h7b, 8'h09, 8'h62, 8'h1a, 8'h91, 8'h9b, 8'hc3, 8'h41, 8'h24, 8'ha0, 8'hfd, 8'hb5, 8'h67, 8'h93, 8'h07,
    8'ha7, 8'hb8, 8'h85, 8'h8a, 8'ha1, 8'h1e, 8'h4f, 8'hb6, 8'h75, 8'h38, 8'h65, 8'h8a, 8'hf9, 8'h7c, 8'h00, 8'ha0
};

localparam logic [7:0] PHOTOY2K_TAB [256] = '{
    8'hd9, 8'h92, 8'hb2, 8'hbc, 8'ha5, 8'h88, 8'he3, 8'h48, 8'h7d, 8'heb, 8'hc5, 8'h4d, 8'h31, 8'he4, 8'h82, 8'hbc,
    8'h82, 8'hcf, 8'he7, 8'hf3, 8'h15, 8'hde, 8'h8f, 8'h91, 8'hef, 8'hc6, 8'hb8, 8'h81, 8'h97, 8'he3, 8'hdf, 8'h4d,
    8'h88, 8'hbf, 8'he4, 8'h05, 8'h25, 8'h73, 8'h1e, 8'hd0, 8'hcf, 8'h1e, 8'heb, 8'h4d, 8'h18, 8'h4e, 8'h6f, 8'h9f,
    8'h00, 8'h72, 8'hc3, 8'h74, 8'hbe, 8'h02, 8'h09, 8'h0a, 8'hb0, 8'hb1, 8'h8e, 8'h9b, 8'h08, 8'hed, 8'h68, 8'h6d,
    8'h25, 8'he8, 8'h28, 8'h94, 8'ha6, 8'h44, 8'ha6, 8'hfa, 8'h95, 8'h69, 8'h72, 8'hd3, 8'h6d, 8'hb6, 8'hff, 8'hf3,
    8'h45, 8'h4e, 8'ha3, 8'h60, 8'hf2, 8'h58, 8'he7, 8'h59, 8'he4, 8'h4f, 8'h70, 8'hd2, 8'hdd, 8'hc0, 8'h6e, 8'hf3,
    8'hd7, 8'hb2, 8'hdc, 8'h1e, 8'ha8, 8'h41, 8'h07, 8'h5d, 8'h60, 8'h15, 8'hea, 8'hcf, 8'hdb, 8'hc1, 8'h1d, 8'h4d,
    8'hb7, 8'h42, 8'hec, 8'hc4, 8'hca, 8'ha9, 8'h40, 8'h30, 8'h0f, 8'h3c, 8'he2, 8'h81, 8'he0, 8'h5c, 8'h51, 8'h07,
    8'hb0, 8'h1e, 8'h4a, 8'hb3, 8'h64, 8'h3e, 8'h1c, 8'h62, 8'h17, 8'hcd, 8'hf2, 8'he4, 8'h14, 8'h9d, 8'ha6, 8'hd4,
    8'h64, 8'h36, 8'ha5, 8'he8, 8'h7e, 8'h84, 8'h0e, 8'hb3, 8'h5d, 8'h79, 8'h57, 8'hea, 8'hd7, 8'had, 8'hbc, 8'h9e,
    8'h2d, 8'h90, 8'h03, 8'h9e, 8'h0e, 8'hc6, 8'h98, 8'hdb, 8'he3, 8'hb6, 8'h9f, 8'h9b, 8'hf6, 8'h21, 8'he6, 8'h98,
    8'h94, 8'h77, 8'hb7, 8'h2b, 8'haa, 8'hc9, 8'hff, 8'hef, 8'h7a, 8'hf2, 8'h71, 8'h4e, 8'h52, 8'h06, 8'h85, 8'h37,
    8'h81, 8'h8e, 8'h86, 8'h64, 8'h39, 8'h92, 8'h2a, 8'hca, 8'hf3, 8'h3e, 8'h87, 8'hb5, 8'h0c, 8'h7b, 8'h42, 8'h5e,
    8'h04, 8'ha7, 8'hfb, 8'hd7, 8'h13, 8'h7f, 8'h83, 8'h6a, 8'h77, 8'h0f, 8'ha7, 8'h34, 8'h51, 8'h88, 8'h9c, 8'hac,
    8'h23, 8'h90, 8'h4d, 8'h4d, 8'h72, 8'h4e, 8'ha3, 8'h26, 8'h1a, 8'h45, 8'h61, 8'h0e, 8'h10, 8'h24, 8'h8a, 8'h27,
    8'h92, 8'h14, 8'h23, 8'hae, 8'h4b, 8'h80, 8'hae, 8'h6a, 8'h56, 8'h01, 8'hac, 8'h55, 8'hf7, 8'h6d, 8'h9b, 8'h6d
};

always_comb begin
    logic [22:0] i;
    logic [15:0] x;
    x = 16'd0;
    i = 23'd0;
    if (word_addr >= 23'h080000) begin
        i = word_addr - 23'h080000;
        case (game)
            GAME_KILLBLD: begin // rom_size 0x200000 bytes -> 0x100000 words
                if (word_addr < 23'h180000) begin
                    if (((i & 23'h006d00) == 23'h000400) || ((i & 23'h006c80) == 23'h000880)) x = x ^ 16'h0008;
                    if (((i & 23'h007500) == 23'h002400) || ((i & 23'h007600) == 23'h003200)) x = x ^ 16'h1000;
                end
            end
            GAME_DRGW3: begin // rom_size 0x100000 bytes -> 0x80000 words
                if (word_addr < 23'h100000) begin
                    if (((i & 23'h005460) == 23'h001400) || ((i & 23'h005450) == 23'h001040)) x = x ^ 16'h0100;
                    if (((i & 23'h005e00) == 23'h001c00) || ((i & 23'h005580) == 23'h001100)) x = x ^ 16'h0040;
                end
            end
            GAME_KOVSH: begin // rom_size 0x400000 bytes -> 0x200000 words
                if (word_addr < 23'h280000) begin
                    if ((i & 23'h040080) != 23'h000080)                                  x = x ^ 16'h0001;
                    if (((i & 23'h004008) == 23'h004008) && ((i & 23'h180000) != 23'd0)) x = x ^ 16'h0002;
                    if ((i & 23'h000030) == 23'h000010)                                  x = x ^ 16'h0004;
                    if ((i & 23'h000242) != 23'h000042)                                  x = x ^ 16'h0008;
                    if ((i & 23'h008100) == 23'h008000)                                  x = x ^ 16'h0010;
                    if ((i & 23'h002004) != 23'h000004)                                  x = x ^ 16'h0020;
                    if ((i & 23'h011800) != 23'h010000)                                  x = x ^ 16'h0040;
                    if ((i & 23'h000820) == 23'h000820)                                  x = x ^ 16'h0080;
                    x = x ^ {KOVSH_TAB[i[7:0]], 8'h00};
                end
            end
            GAME_PHOTOY2K: begin // rom_size 0x400000 region
                if (word_addr < 23'h280000) begin
                    if ((i & 23'h040080) != 23'h000080)                                  x = x ^ 16'h0001;
                    if ((i & 23'h084008) == 23'h084008)                                  x = x ^ 16'h0002;
                    if ((i & 23'h000030) == 23'h000010)                                  x = x ^ 16'h0004;
                    if ((i & 23'h000242) != 23'h000042)                                  x = x ^ 16'h0008;
                    if ((i & 23'h048100) == 23'h048000)                                  x = x ^ 16'h0010;
                    if ((i & 23'h002004) != 23'h000004)                                  x = x ^ 16'h0020;
                    if ((i & 23'h001800) != 23'd0)                                       x = x ^ 16'h0040;
                    if ((i & 23'h004820) == 23'h004820)                                  x = x ^ 16'h0080;
                    x = x ^ {PHOTOY2K_TAB[i[7:0]], 8'h00};
                end
            end
            default: x = 16'h0000;
        endcase
    end

    rom_word_out = {rom_word_in[7:0], rom_word_in[15:8]} ^ x;
end

endmodule


