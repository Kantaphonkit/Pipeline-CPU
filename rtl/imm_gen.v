`timescale 1ns / 1ps
//=============================================================================
// imm_gen.v -- RV32I immediate generator
//
// Contract: docs/INTERFACES.md Section 8.1 (binding).  Pure combinational; the
// bit assembly below is transcribed bit-for-bit from that table and from the
// RISC-V Unprivileged ISA spec Fig. 2.4 ("immediate variants").
//
//   imm_sel | fmt | value
//   --------+-----+---------------------------------------------------------
//   3'd0    | I   | {{20{inst[31]}}, inst[31:20]}
//   3'd1    | S   | {{20{inst[31]}}, inst[31:25], inst[11:7]}
//   3'd2    | B   | {{19{inst[31]}}, inst[31], inst[7], inst[30:25],
//           |     |  inst[11:8], 1'b0}
//   3'd3    | U   | {inst[31:12], 12'b0}
//   3'd4    | J   | {{11{inst[31]}}, inst[31], inst[19:12], inst[20],
//           |     |  inst[30:21], 1'b0}
//   3'd5    | Z   | {27'b0, inst[19:15]}          (CSR zimm, ZERO-extended)
//   others  | --  | 32'b0
//
// Notes
//  * I is also used for jalr, loads and the shift-immediates.  For slli/srli/
//    srai this deliberately yields the raw sign-extended inst[31:20] (so
//    `srai rd,rs1,31` gives 0x0000041f, funct7 bits included) -- the ALU uses
//    only b[4:0] as the shift amount, so the upper bits are don't-care.
//  * B and J immediates already include the implicit 1'b0 LSB, i.e. they are
//    byte offsets, not half-word offsets.
//  * Z is the only zero-extended immediate.
//
// Verilog-2001, synthesizable, no vendor primitives.
//=============================================================================

module imm_gen (
    input  wire [31:0] inst,
    input  wire [2:0]  imm_sel,
    output reg  [31:0] imm
);

    localparam [2:0] IMM_I = 3'd0;
    localparam [2:0] IMM_S = 3'd1;
    localparam [2:0] IMM_B = 3'd2;
    localparam [2:0] IMM_U = 3'd3;
    localparam [2:0] IMM_J = 3'd4;
    localparam [2:0] IMM_Z = 3'd5;

    always @(*) begin
        case (imm_sel)
            IMM_I:   imm = {{20{inst[31]}}, inst[31:20]};
            IMM_S:   imm = {{20{inst[31]}}, inst[31:25], inst[11:7]};
            IMM_B:   imm = {{19{inst[31]}}, inst[31], inst[7],
                            inst[30:25], inst[11:8], 1'b0};
            IMM_U:   imm = {inst[31:12], 12'b0};
            IMM_J:   imm = {{11{inst[31]}}, inst[31], inst[19:12],
                            inst[20], inst[30:21], 1'b0};
            IMM_Z:   imm = {27'b0, inst[19:15]};
            default: imm = 32'b0;
        endcase
    end

endmodule
