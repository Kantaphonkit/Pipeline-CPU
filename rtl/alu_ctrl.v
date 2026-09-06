`timescale 1ns / 1ps
//=============================================================================
// alu_ctrl.v -- second-level ALU decode
//
// Contract: docs/INTERFACES.md Sections 8.2 and 9.  Maps the main decoder's
// alu_class plus the instruction's funct3 / inst[30] onto the 4-bit ALU
// opcode of rtl/alu.v.
//
//   alu_class | meaning                    | alu_op
//   ----------+----------------------------+--------------------------------
//   0         | ADD (address / auipc /     | ADD, unconditionally
//             | jal / jalr / branch / CSR) |
//   1         | R-type                     | funct3 table, inst[30] selects
//             |                            | sub (000) and sra (101)
//   2         | I-type arithmetic          | same table, inst[30] consulted
//             |                            | ONLY for funct3 = 101
//   3         | LUI                        | PASSB (y = b = U-immediate)
//
// THE classic bug this module exists to avoid: `addi rd,rs1,imm` with a
// negative immediate has inst[30] = 1 (e.g. addi x1,x0,-1 = 0xfff00093), so a
// decoder that consults inst[30] for every I-type op turns it into `sub`.
// Class 2 therefore ignores funct7_b30 for funct3 = 000.
//
// The illegal funct7 patterns (e.g. 0x20 with funct3 = 100 on an R-type, or
// slli with inst[31:25] = 0x20) never reach this module as class 1/2: control.v
// checks the full funct7 and emits illegal + alu_class = 0, so alu_ctrl stays a
// pure 4-bit table with no error state of its own.
//
// Verilog-2001, synthesizable, no vendor primitives.
//=============================================================================

module alu_ctrl (
    input  wire [1:0] alu_class,
    input  wire [2:0] funct3,
    input  wire       funct7_b30,     // inst[30]
    output reg  [3:0] alu_op
);

    // ALU opcodes -- INTERFACES.md Section 8.2
    localparam [3:0] ALU_ADD   = 4'd0;
    localparam [3:0] ALU_SUB   = 4'd1;
    localparam [3:0] ALU_SLL   = 4'd2;
    localparam [3:0] ALU_SLT   = 4'd3;
    localparam [3:0] ALU_SLTU  = 4'd4;
    localparam [3:0] ALU_XOR   = 4'd5;
    localparam [3:0] ALU_SRL   = 4'd6;
    localparam [3:0] ALU_SRA   = 4'd7;
    localparam [3:0] ALU_OR    = 4'd8;
    localparam [3:0] ALU_AND   = 4'd9;
    localparam [3:0] ALU_PASSB = 4'd10;

    localparam [1:0] CLASS_ADD   = 2'd0;
    localparam [1:0] CLASS_RTYPE = 2'd1;
    localparam [1:0] CLASS_ITYPE = 2'd2;
    localparam [1:0] CLASS_LUI   = 2'd3;

    always @(*) begin
        case (alu_class)

        CLASS_RTYPE:
            case (funct3)
            3'b000:  alu_op = funct7_b30 ? ALU_SUB : ALU_ADD;   // add / sub
            3'b001:  alu_op = ALU_SLL;
            3'b010:  alu_op = ALU_SLT;
            3'b011:  alu_op = ALU_SLTU;
            3'b100:  alu_op = ALU_XOR;
            3'b101:  alu_op = funct7_b30 ? ALU_SRA : ALU_SRL;   // srl / sra
            3'b110:  alu_op = ALU_OR;
            default: alu_op = ALU_AND;                          // 3'b111
            endcase

        CLASS_ITYPE:
            case (funct3)
            3'b000:  alu_op = ALU_ADD;                          // addi -- never SUB
            3'b001:  alu_op = ALU_SLL;                          // slli
            3'b010:  alu_op = ALU_SLT;                          // slti
            3'b011:  alu_op = ALU_SLTU;                         // sltiu
            3'b100:  alu_op = ALU_XOR;                          // xori
            3'b101:  alu_op = funct7_b30 ? ALU_SRA : ALU_SRL;   // srli / srai
            3'b110:  alu_op = ALU_OR;                           // ori
            default: alu_op = ALU_AND;                          // andi
            endcase

        CLASS_LUI:
            alu_op = ALU_PASSB;

        default:                                                // CLASS_ADD
            alu_op = ALU_ADD;
        endcase
    end

endmodule
