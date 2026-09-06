`timescale 1ns/1ps
//=============================================================================
// id_ex.v -- ID/EX pipeline register.
//
// Carries the decoded control word, the two register-file read values, the
// immediate and the bookkeeping fields (valid / pc / inst) used by the commit
// trace and the trap (mepc) path.
//
// Bubble encoding: every field zero.  That is a genuine NOP control word --
// reg_we = mem_re = mem_we = csr_en = csr_we = branch = jalr = mret = ecall =
// ebreak = 0 and valid = 0 -- so a flushed slot has no architectural effect and
// is neither retired nor traced.  Both the flush path and reset use it.
//
//   stall  hold (used by the load-use interlock in step 5)
//   flush  insert a bubble; priority over stall (a redirect from EX kills the
//          instruction in ID, so any stall it raised is moot)
//
// Build step 4 drives stall = flush = 0 (hazard_unit.v is a stub); step 5 fills
// the hazard unit in and this module is unchanged.
//=============================================================================

module id_ex (
    input  wire        clk,
    input  wire        rst,
    input  wire        stall,
    input  wire        flush,

    // ---- bookkeeping ----
    input  wire        valid_d,
    input  wire        illegal_d,
    input  wire [31:0] pc_d,
    input  wire [31:0] inst_d,
    // ---- register addresses (forwarding + write-back) ----
    input  wire [4:0]  rs1_addr_d,
    input  wire [4:0]  rs2_addr_d,
    input  wire [4:0]  rd_addr_d,
    // ---- data ----
    input  wire [31:0] rs1_val_d,
    input  wire [31:0] rs2_val_d,
    input  wire [31:0] imm_d,
    // ---- EX control ----
    input  wire [3:0]  alu_op_d,
    input  wire        alu_src_a_d,
    input  wire        alu_src_b_d,
    input  wire [2:0]  funct3_d,
    input  wire        branch_d,
    input  wire        jalr_d,
    // ---- MEM control ----
    input  wire        mem_re_d,
    input  wire        mem_we_d,
    // ---- WB control ----
    input  wire        reg_we_d,
    input  wire [1:0]  wb_sel_d,
    // ---- CSR / system ----
    input  wire        csr_en_d,
    input  wire        csr_we_d,
    input  wire        csr_imm_d,
    input  wire [11:0] csr_addr_d,
    input  wire        mret_d,
    input  wire        ecall_d,
    input  wire        ebreak_d,

    output reg         valid_q,
    output reg         illegal_q,
    output reg  [31:0] pc_q,
    output reg  [31:0] inst_q,
    output reg  [4:0]  rs1_addr_q,
    output reg  [4:0]  rs2_addr_q,
    output reg  [4:0]  rd_addr_q,
    output reg  [31:0] rs1_val_q,
    output reg  [31:0] rs2_val_q,
    output reg  [31:0] imm_q,
    output reg  [3:0]  alu_op_q,
    output reg         alu_src_a_q,
    output reg         alu_src_b_q,
    output reg  [2:0]  funct3_q,
    output reg         branch_q,
    output reg         jalr_q,
    output reg         mem_re_q,
    output reg         mem_we_q,
    output reg         reg_we_q,
    output reg  [1:0]  wb_sel_q,
    output reg         csr_en_q,
    output reg         csr_we_q,
    output reg         csr_imm_q,
    output reg  [11:0] csr_addr_q,
    output reg         mret_q,
    output reg         ecall_q,
    output reg         ebreak_q
);

    // Total payload width; only used to build the all-zero bubble constant.
    localparam PW = 1+1+32+32+5+5+5+32+32+32+4+1+1+3+1+1+1+1+1+2+1+1+1+12+1+1+1;

    always @(posedge clk) begin
        if (rst || flush) begin
            {valid_q, illegal_q, pc_q, inst_q,
             rs1_addr_q, rs2_addr_q, rd_addr_q,
             rs1_val_q, rs2_val_q, imm_q,
             alu_op_q, alu_src_a_q, alu_src_b_q, funct3_q, branch_q, jalr_q,
             mem_re_q, mem_we_q,
             reg_we_q, wb_sel_q,
             csr_en_q, csr_we_q, csr_imm_q, csr_addr_q,
             mret_q, ecall_q, ebreak_q} <= {PW{1'b0}};
        end else if (!stall) begin
            {valid_q, illegal_q, pc_q, inst_q,
             rs1_addr_q, rs2_addr_q, rd_addr_q,
             rs1_val_q, rs2_val_q, imm_q,
             alu_op_q, alu_src_a_q, alu_src_b_q, funct3_q, branch_q, jalr_q,
             mem_re_q, mem_we_q,
             reg_we_q, wb_sel_q,
             csr_en_q, csr_we_q, csr_imm_q, csr_addr_q,
             mret_q, ecall_q, ebreak_q} <=
            {valid_d, illegal_d, pc_d, inst_d,
             rs1_addr_d, rs2_addr_d, rd_addr_d,
             rs1_val_d, rs2_val_d, imm_d,
             alu_op_d, alu_src_a_d, alu_src_b_d, funct3_d, branch_d, jalr_d,
             mem_re_d, mem_we_d,
             reg_we_d, wb_sel_d,
             csr_en_d, csr_we_d, csr_imm_d, csr_addr_d,
             mret_d, ecall_d, ebreak_d};
        end
    end

endmodule
