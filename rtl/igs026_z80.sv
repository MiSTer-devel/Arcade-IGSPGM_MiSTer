module IGS026_Z80(
    input clk,

    // CPU interface
    input [23:0] cpu_addr,
    input [15:0] cpu_din,
    output logic [15:0] cpu_dout,
    input cpu_lds_n,
    input cpu_uds_n,
    input cpu_rw,
    input cpu_cs_n,


    output logic v3021_cs_n,
    output logic v3021_wr_n,
    output logic v3021_dout,
    input  v3021_din,

    output logic aram_lds_n,
    output logic aram_uds_n,
    output logic [14:0] aram_addr,
    input  logic [15:0] aram_din,
    output logic [15:0] aram_dout
);

reg [15:0] latch[8];

wire io_access_n = cpu_cs_n | cpu_addr[16];
wire ram_access_n = cpu_cs_n | ~cpu_addr[16];

always_comb begin
    v3021_dout = cpu_din[0];
    
    cpu_dout = 16'h0;

    v3021_cs_n = 1;
    v3021_wr_n = 1;

    aram_uds_n = 1;
    aram_lds_n = 1;
    aram_addr = cpu_addr[15:1];
    aram_dout = cpu_din;

    if (~io_access_n) begin
        case(cpu_addr[3:0])
            4'h2: cpu_dout = latch[1];
            4'h4: cpu_dout = latch[2];
            4'h6: begin
                v3021_cs_n = 0;
                v3021_wr_n = cpu_rw;
                cpu_dout[0] = v3021_din;
            end
            4'h8: cpu_dout = latch[4];
            4'ha: cpu_dout = latch[5];
            4'hc: cpu_dout = latch[6];
            default: begin
            end
        endcase
    end else if (~ram_access_n) begin
        cpu_dout = aram_din;
        aram_lds_n = cpu_lds_n | cpu_rw;
        aram_uds_n = cpu_uds_n | cpu_rw;
    end
end

always_ff @(posedge clk) begin
    if (~io_access_n) begin
        if (~cpu_rw & ~cpu_lds_n) begin
            case(cpu_addr[3:0])
                4'h2: latch[1] <= cpu_din;
                4'h4: latch[2] <= cpu_din;
                4'h8: latch[4] <= cpu_din;
                4'ha: latch[5] <= cpu_din;
                4'hc: latch[6] <= cpu_din;
                default: begin
                end
            endcase
        end
    end
end
endmodule



