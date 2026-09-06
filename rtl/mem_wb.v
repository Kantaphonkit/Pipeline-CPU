`timescale 1ns/1ps
//=============================================================================
// mem_wb.v -- MEM/WB pipeline register.
//
// `res` is the non-memory result (ALU / PC+4 / CSR) carried over from EX/MEM;
// the load data is NOT registered here -- dmem.v registers the memory word
// internally on the MEM posedge and presents the lane-selected, extended value
// combinationally during WB, so cpu_top's write-back mux picks between `res`
// and dmem.rdata.
//
// `mem_val` is dmem's `wmask_data` (store data masked to width, unshifted)
// captured at MEM purely for the commit-trace port; it has no datapath role.
//
// Bubble = all fields zero (see id_ex.v).  flush has priority over stall.
// Build step 4 drives stall = flush = 0.
//=============================================================================

module mem_wb (
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
    input  wire        mem_we_d,
    input  wire [31:0] mem_val_d,
    input  wire        ebreak_d,

    output reg         valid_q,
    output reg         illegal_q,
    output reg  [31:0] pc_q,
    output reg  [31:0] inst_q,
    output reg  [4:0]  rd_addr_q,
    output reg         reg_we_q,
    output reg  [1:0]  wb_sel_q,
    output reg  [31:0] res_q,
    output reg         mem_we_q,
    output reg  [31:0] mem_val_q,
    output reg         ebreak_q
);

    localparam PW = 1+1+32+32+5+1+2+32+1+32+1;

    always @(posedge clk) begin
        if (rst || flush) begin
            {valid_q, illegal_q, pc_q, inst_q, rd_addr_q, reg_we_q, wb_sel_q,
             res_q, mem_we_q, mem_val_q, ebreak_q} <= {PW{1'b0}};
        end else if (!stall) begin
            {valid_q, illegal_q, pc_q, inst_q, rd_addr_q, reg_we_q, wb_sel_q,
             res_q, mem_we_q, mem_val_q, ebreak_q} <=
            {valid_d, illegal_d, pc_d, inst_d, rd_addr_d, reg_we_d, wb_sel_d,
             res_d, mem_we_d, mem_val_d, ebreak_d};
        end
    end

endmodule
