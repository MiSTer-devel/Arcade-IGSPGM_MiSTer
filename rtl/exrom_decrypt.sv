import system_consts::*;

// IGS027A external ARM ROM address-bit XOR ("svg" / MAME pgm_<game>_decrypt).
// Combinational, applied at ROM LOAD time (rtl/rom_loader.sv) to each 16-bit
// word of the external ARM ROM, keyed on the game and the 16-bit word index.
// (The runtime xor_table layer is separate and stays in the ARM read path.)
//
// MUST match the C++ DecryptArmExrom() in sim/games.cpp.
module exrom_decrypt(
    input  game_t       game,
    input  logic [21:0] word_idx,   // 16-bit word index within the external ROM
    input  logic [15:0] word_in,
    output logic [15:0] word_out
);

    // IGS27_CRYPT* primitives (MAME pgmcrypt.cpp): each returns 1 when the
    // corresponding output bit must be XORed for word index i.
    function automatic logic c1   (input logic [21:0] i); c1   = ((i & 22'h040480) != 22'h000080); endfunction
    function automatic logic c1a  (input logic [21:0] i); c1a  = ((i & 22'h040080) != 22'h000080); endfunction
    function automatic logic c1a2 (input logic [21:0] i); c1a2 = ((i & 22'h000480) != 22'h000080); endfunction
    function automatic logic c2   (input logic [21:0] i); c2   = ((i & 22'h104008) == 22'h104008); endfunction
    function automatic logic c2a  (input logic [21:0] i); c2a  = ((i & 22'h004008) == 22'h004008); endfunction
    function automatic logic c3   (input logic [21:0] i); c3   = ((i & 22'h080030) == 22'h080010); endfunction
    function automatic logic c3a2 (input logic [21:0] i); c3a2 = ((i & 22'h000030) == 22'h000010); endfunction
    function automatic logic c4   (input logic [21:0] i); c4   = ((i & 22'h000242) != 22'h000042); endfunction
    function automatic logic c4a  (input logic [21:0] i); c4a  = ((i & 22'h000042) != 22'h000042); endfunction
    function automatic logic c5   (input logic [21:0] i); c5   = ((i & 22'h008100) == 22'h008000); endfunction
    function automatic logic c5a  (input logic [21:0] i); c5a  = ((i & 22'h048100) == 22'h048000); endfunction
    function automatic logic c6   (input logic [21:0] i); c6   = ((i & 22'h002004) != 22'h000004); endfunction
    function automatic logic c6a  (input logic [21:0] i); c6a  = ((i & 22'h022004) != 22'h000004); endfunction
    function automatic logic c7   (input logic [21:0] i); c7   = ((i & 22'h011800) != 22'h010000); endfunction
    function automatic logic c7a  (input logic [21:0] i); c7a  = ((i & 22'h001800) != 22'h000000); endfunction
    function automatic logic c8   (input logic [21:0] i); c8   = ((i & 22'h004820) == 22'h004820); endfunction
    function automatic logic c8a  (input logic [21:0] i); c8a  = ((i & 22'h000820) == 22'h000820); endfunction

    // type3 (55857G) high-byte tables (MAME pgmcrypt.cpp dfront_tab/theglad_tab),
    // indexed by (word_idx >> 1) & 0xff = i[8:1].  Must match DFRONT_TAB/THEGLAD_TAB
    // in sim/games.cpp.
    localparam logic [7:0] DFRONT_TAB[256] = '{
        8'h51,8'hc4,8'he3,8'h10,8'h1c,8'had,8'h8a,8'h39,8'h8c,8'he0,8'ha5,8'h04,8'h0f,8'he4,8'h35,8'hc3,
        8'h2d,8'h6b,8'h32,8'he2,8'h60,8'h54,8'h63,8'h06,8'ha3,8'hf1,8'h0b,8'h5f,8'h6c,8'h5c,8'hb3,8'hec,
        8'h77,8'h61,8'h69,8'he7,8'h3c,8'hb7,8'h42,8'h72,8'h1a,8'h70,8'hb0,8'h96,8'ha4,8'h28,8'hc0,8'hfb,
        8'h0a,8'h00,8'hcb,8'h15,8'h49,8'h48,8'hd3,8'h94,8'h58,8'hcf,8'h41,8'h86,8'h17,8'h71,8'hb1,8'hbd,
        8'h21,8'h01,8'h37,8'h1e,8'hba,8'heb,8'hf3,8'h59,8'hf6,8'ha7,8'h29,8'h4f,8'hb5,8'hca,8'h4c,8'h34,
        8'h20,8'ha2,8'h62,8'h4b,8'h93,8'h9e,8'h47,8'h9f,8'h8d,8'h0e,8'h1b,8'hb6,8'h4d,8'h82,8'hd5,8'hf4,
        8'h85,8'h79,8'h53,8'h92,8'h9b,8'hf7,8'hea,8'h44,8'h76,8'h1f,8'h22,8'h45,8'hed,8'hbe,8'h11,8'h55,
        8'haf,8'hf5,8'hf8,8'h50,8'h07,8'he6,8'hc7,8'h5e,8'hd7,8'hde,8'he5,8'h26,8'h2b,8'hf2,8'h6a,8'h8b,
        8'hb8,8'h98,8'h89,8'hdb,8'h14,8'h5b,8'hc5,8'h78,8'hdc,8'hd0,8'h87,8'h5d,8'hc1,8'h0d,8'h95,8'h97,
        8'h7e,8'ha8,8'h24,8'h3d,8'he1,8'hd1,8'h19,8'ha6,8'h99,8'hd8,8'h83,8'h1d,8'hff,8'h30,8'h9d,8'h05,
        8'hd4,8'h02,8'h27,8'h7b,8'h13,8'hb2,8'h7f,8'h40,8'h12,8'ha0,8'h68,8'h67,8'h4e,8'h3a,8'h46,8'hb9,
        8'hee,8'hdf,8'h66,8'hd6,8'h8f,8'ha9,8'h0c,8'h91,8'h65,8'h18,8'h52,8'h56,8'hd9,8'h74,8'h09,8'h6e,
        8'hc6,8'h73,8'hc9,8'hfc,8'h03,8'h43,8'hef,8'haa,8'h7c,8'hbb,8'h2c,8'h90,8'hcc,8'hce,8'he8,8'hae,
        8'h2a,8'hf9,8'h57,8'h88,8'hc8,8'he9,8'h5a,8'hdd,8'h2e,8'h7d,8'h64,8'hc2,8'h6d,8'h3e,8'hfa,8'h80,
        8'h16,8'hcd,8'h6f,8'h84,8'h8e,8'h9c,8'hf0,8'hac,8'hb4,8'h9a,8'h2f,8'hbc,8'h31,8'h23,8'hfe,8'h38,
        8'h08,8'h75,8'ha1,8'h33,8'hab,8'hd2,8'hda,8'h81,8'hbf,8'h7a,8'h3b,8'h3f,8'h4a,8'hfd,8'h25,8'h36
    };

    localparam logic [7:0] THEGLAD_TAB[256] = '{
        8'h49,8'h47,8'h53,8'h30,8'h30,8'h30,8'h35,8'h52,8'h44,8'h31,8'h30,8'h32,8'h31,8'h32,8'h30,8'h33,
        8'hc4,8'ha3,8'h46,8'h78,8'h30,8'hb3,8'h8b,8'hd5,8'h2f,8'hc4,8'h44,8'hbf,8'hdb,8'h76,8'hdb,8'hea,
        8'hb4,8'heb,8'h95,8'h4d,8'h15,8'h21,8'h99,8'ha1,8'hd7,8'h8c,8'h40,8'h1d,8'h43,8'hf3,8'h9f,8'h71,
        8'h3d,8'h8c,8'h52,8'h01,8'haf,8'h5b,8'h8b,8'h63,8'h34,8'hc8,8'h5c,8'h1b,8'h06,8'h7f,8'h41,8'h96,
        8'h2a,8'h8d,8'hf1,8'h64,8'hda,8'hb8,8'h67,8'hba,8'h33,8'h1f,8'h2b,8'h28,8'h20,8'h13,8'he6,8'h96,
        8'h86,8'h34,8'h25,8'h85,8'hb0,8'hd0,8'h6d,8'h85,8'hfe,8'h78,8'h81,8'hf1,8'hca,8'he4,8'hef,8'hf2,
        8'h9b,8'h09,8'he1,8'hb4,8'h8d,8'h79,8'h22,8'he2,8'h00,8'hfb,8'h6f,8'h68,8'h80,8'h6a,8'h00,8'h69,
        8'hf5,8'hd3,8'h57,8'h7e,8'h0c,8'hca,8'h48,8'h31,8'he5,8'h0d,8'h4a,8'hb9,8'hfd,8'h5c,8'hfd,8'hf8,
        8'h5f,8'h98,8'hfb,8'hb3,8'h07,8'h1a,8'he3,8'h10,8'h96,8'h56,8'ha3,8'h56,8'h3d,8'hb1,8'h07,8'he0,
        8'he3,8'h9f,8'h7f,8'h62,8'h99,8'h01,8'h35,8'h60,8'h40,8'hbe,8'h4f,8'heb,8'h79,8'ha0,8'h82,8'h9f,
        8'hcd,8'h71,8'hd8,8'hda,8'h1e,8'h56,8'hc2,8'h3e,8'h4e,8'h6b,8'h60,8'h69,8'h2d,8'h9f,8'h10,8'hf4,
        8'ha9,8'hd3,8'h36,8'haa,8'h31,8'h2e,8'h4c,8'h0a,8'h69,8'hc3,8'h2a,8'hff,8'h15,8'h67,8'h96,8'hde,
        8'h3f,8'hcc,8'h0f,8'ha1,8'hac,8'he2,8'hd6,8'h62,8'h7e,8'h6f,8'h3e,8'h1b,8'h2a,8'hed,8'h36,8'h9c,
        8'h9d,8'ha4,8'h14,8'hcd,8'haa,8'h08,8'ha4,8'h26,8'hb7,8'h55,8'h70,8'h6c,8'ha9,8'h69,8'h52,8'hae,
        8'h0c,8'he1,8'h38,8'h7f,8'h87,8'h78,8'h38,8'h75,8'h80,8'h9c,8'hd4,8'he2,8'h0b,8'h52,8'h8f,8'hd2,
        8'h19,8'h4c,8'hb0,8'h45,8'hde,8'h48,8'h55,8'hae,8'h82,8'hab,8'hbc,8'hab,8'h0c,8'h5e,8'hce,8'h07
    };

    function automatic logic [15:0] addr_xor(input game_t g, input logic [21:0] i);
        logic [15:0] m;
        begin
            m = 16'd0;
            case (g)
                GAME_KOV2:    m = {8'd0, c8a(i),c7a(i),c6a(i),c5a(i),c4a(i),c3(i),  1'b0,   c1a(i)};
                GAME_KOV2P:   m = {8'd0, c8a(i),c7(i), c6(i), c5(i), c4(i), c3(i),  c2a(i), c1a(i)};
                GAME_DDP2:    m = {8'd0, c8a(i),c7a(i),c6(i), c5(i), c4a(i),1'b0,   1'b0,   c1a2(i)};
                // martmast + dw2001 share pgm_mm_decrypt
                GAME_MARTMAST,
                GAME_DW2001:  m = {8'd0, c8a(i),c7(i), c6a(i),c5(i), c4(i), c3a2(i),c2a(i), c1(i)};
                GAME_DWPC:    m = {8'd0, c8(i), c7a(i),c6(i), c5a(i),c4a(i),c3(i),  c2(i),  c1a(i)};
                // type3: high byte from per-game table indexed by i[8:1]
                GAME_DMNFRNT: m = {DFRONT_TAB[i[8:1]],  c8(i), c7(i), c6(i), c5(i), c4a(i),c3(i), c2(i), c1a(i)};
                GAME_THEGLAD: m = {THEGLAD_TAB[i[8:1]], c8a(i),c7(i), c6a(i),c5(i), c4a(i),c3(i), c2(i), c1a(i)};
                default:      m = 16'd0;
            endcase
            addr_xor = m;
        end
    endfunction

    assign word_out = word_in ^ addr_xor(game, word_idx);

endmodule
