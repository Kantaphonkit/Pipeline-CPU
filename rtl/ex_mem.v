`timescale 1ns/1ps
//=============================================================================
// ex_mem.v -- EX/MEM pipeline register.
//
// `res` is the already-selected non-memory result of the instruction: the ALU
// output for ALU ops, PC+4 for jal/jalr, the pre-write CSR value for CSR ops.
// Selecting those three in EX (rather than in WB) is what makes the EX/MEM
// forwarding source correct for jal/jalr/CSR consumers -- forwarding the raw
// ALU output would forward a jump target instead of a link address.  The WB
// stage then only has to choose between `res` and the load data.
//
// For a store, `res` is the effective byte address and `store_data` is the
// (forwarded) rs2 value.
//
// Bubble = all fields zero (see id_ex.v).  flush has priority over stall.
// Build step 4 drives stall = flush = 0.
//=============================================================================

module ex_mem (
    input  wire        clk,
    input  wire        rst,
    input  wire        stall,
    input  wire        flush,

    input  wire        valid_d,
    input  wire        illegal_d,
    input  wire [31:0] pc_d,
    input  wire [31:0] inst_d,
    input  wire [4:0]  rd_addr_d,
    input  wire        reg_we_d,
    input  wire [1:0]  wb_sel_d,
    input  wire [31:0] res_d,
    input  wire [31:0] store_data_d,
    input  wire [2:0]  funct3_d,
    input  wire        mem_re_d,
    input  wire        mem_we_d,
    input  wire        ebreak_d,

    output reg         valid_q,
    output reg         illegal_q,
    output reg  [31:0] pc_q,
    output reg  [31:0] inst_q,
    output reg  [4:0]  rd_addr_q,
    output reg         reg_we_q,
    output reg  [1:0]  wb_sel_q,
    output reg  [31:0] res_q,
    output reg  [31:0] store_data_q,
    output reg  [2:0]  funct3_q,
    output reg         mem_re_q,
    output reg         mem_we_q,
    output reg         ebreak_q
);

    localparam PW = 1+1+32+32+5+1+2+32+32+3+1+1+1;

    always @(posedge clk) begin
        if (rst || flush) begin
            {valid_q, illegal_q, pc_q, inst_q, rd_addr_q, reg_we_q, wb_sel_q,
             res_q, store_data_q, funct3_q, mem_re_q, mem_we_q, ebreak_q}
                <= {PW{1'b0}};
        end else if (!stall) begin
            {valid_q, illegal_q, pc_q, inst_q, rd_addr_q, reg_we_q, wb_sel_q,
             res_q, store_data_q, funct3_q, mem_re_q, mem_we_q, ebreak_q} <=
            {valid_d, illegal_d, pc_d, inst_d, rd_addr_d, reg_we_d, wb_sel_d,
             res_d, store_data_d, funct3_d, mem_re_d, mem_we_d, ebreak_d};
        end
    end

endmodule
