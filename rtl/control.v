`timescale 1ns / 1ps
//=============================================================================
// control.v -- RV32I main decoder (ID stage)
//
// Contract: docs/INTERFACES.md Section 9 (port list is binding).  Purely
// combinational: opcode/funct3/funct7 in, control signals out.  All 46
// encodings of INTERFACES.md Section 1 are decoded; every other opcode/funct
// combination raises `illegal` and forces the remaining outputs to 0, which is
// exactly the NOP encoding of the control word (spec: illegal instructions are
// NOPs, no trap).
//
// Field sources (from the instruction word in ID):
//   opcode   = inst[6:0]
//   funct3   = inst[14:12]
//   funct7   = inst[31:25]          (also inst[31:25] of a shift-immediate)
//   rs1      = inst[19:15]          (== zimm for csrrwi/csrrsi/csrrci)
//   csr_addr = inst[31:20]          (also the ecall/ebreak/mret selector)
//
// Legality rules implemented here so that alu_ctrl.v can stay a small table:
//   * R-type  : funct7 = 0x00 (any funct3), or 0x20 with funct3 = 000 (sub)
//               or 101 (sra).  Everything else illegal.
//   * shift-I : slli needs inst[31:25] = 0x00; srli 0x00; srai 0x20.
//   * other I : funct7 is part of the immediate -- NOT decoded (classic bug:
//               `addi rd,rs1,-1` has inst[30] = 1 and must stay ADD).
//   * loads   : funct3 011/110/111 illegal (no ld/lwu in RV32I).
//   * stores  : funct3 011..111 illegal.
//   * branches: funct3 010/011 illegal.
//   * jalr    : funct3 must be 000.
//   * SYSTEM  : funct3 000 -> csr_addr 0x000 ecall, 0x001 ebreak, 0x302 mret,
//               anything else (incl. 0x105 wfi) illegal.  funct3 100 illegal.
//               funct3 001/010/011 = csrrw/csrrs/csrrc, 101/110/111 = the
//               immediate forms.
//
// Signal conventions (see docs/DESIGN.md Section 3 for the full truth table):
//   alu_src_a  0 = rs1, 1 = PC            (1 only for auipc)
//   alu_src_b  0 = rs2, 1 = immediate     (0 only for R-type and branches)
//   imm_sel    0 I, 1 S, 2 B, 3 U, 4 J, 5 Z   (INTERFACES Section 8.1)
//   alu_class  0 ADD, 1 R-type table, 2 I-type table, 3 PASSB (lui)
//   wb_sel     0 ALU, 1 MEM, 2 PC+4, 3 CSR
//   csr_we     write side of a CSR op actually happens: csrrw/csrrwi always,
//              csrrs/csrrc/csrrsi/csrrci only when rs1 (== zimm) != 0.
//
// Don't-cares are driven to a fixed value rather than left floating so the
// decoder is a pure function of the instruction word and the testbench can
// compare every bit:  alu_src_b = ~(R-type | branch) is applied uniformly,
// hence ecall/ebreak/mret/CSR ops also read 1 even though they never use the
// ALU B operand (reg_we = 0 or wb_sel = CSR).
//
// Verilog-2001, synthesizable, no vendor primitives.
//=============================================================================

module control (
    input  wire [6:0]  opcode,
    input  wire [2:0]  funct3,
    input  wire [6:0]  funct7,
    input  wire [4:0]  rs1,
    input  wire [11:0] csr_addr,

    output reg         reg_we,
    output reg         alu_src_a,
    output reg         alu_src_b,
    output reg  [2:0]  imm_sel,
    output reg  [1:0]  alu_class,
    output reg         mem_re,
    output reg         mem_we,
    output reg  [1:0]  wb_sel,
    output reg         branch,
    output reg         jal,
    output reg         jalr,
    output reg         csr_en,
    output reg         csr_we,
    output reg         csr_imm,
    output reg         mret,
    output reg         ecall,
    output reg         ebreak,
    output reg         illegal
);

    // ---- opcodes -----------------------------------------------------------
    localparam [6:0] OP_R      = 7'h33;
    localparam [6:0] OP_IARITH = 7'h13;
    localparam [6:0] OP_LOAD   = 7'h03;
    localparam [6:0] OP_STORE  = 7'h23;
    localparam [6:0] OP_BRANCH = 7'h63;
    localparam [6:0] OP_LUI    = 7'h37;
    localparam [6:0] OP_AUIPC  = 7'h17;
    localparam [6:0] OP_JAL    = 7'h6F;
    localparam [6:0] OP_JALR   = 7'h67;
    localparam [6:0] OP_SYSTEM = 7'h73;

    // ---- immediate selects (INTERFACES Section 8.1) -------------------------
    localparam [2:0] IMM_I = 3'd0;
    localparam [2:0] IMM_S = 3'd1;
    localparam [2:0] IMM_B = 3'd2;
    localparam [2:0] IMM_U = 3'd3;
    localparam [2:0] IMM_J = 3'd4;
    localparam [2:0] IMM_Z = 3'd5;

    // ---- alu_class ---------------------------------------------------------
    localparam [1:0] CLASS_ADD   = 2'd0;
    localparam [1:0] CLASS_RTYPE = 2'd1;
    localparam [1:0] CLASS_ITYPE = 2'd2;
    localparam [1:0] CLASS_LUI   = 2'd3;

    // ---- wb_sel ------------------------------------------------------------
    localparam [1:0] WB_ALU = 2'd0;
    localparam [1:0] WB_MEM = 2'd1;
    localparam [1:0] WB_PC4 = 2'd2;
    localparam [1:0] WB_CSR = 2'd3;

    // ---- SYSTEM csr_addr selectors for the three fixed encodings -----------
    localparam [11:0] CSR_ECALL  = 12'h000;
    localparam [11:0] CSR_EBREAK = 12'h001;
    localparam [11:0] CSR_MRET   = 12'h302;

    always @(*) begin
        // Defaults = the NOP / illegal control word.  Every legal branch of the
        // case below overrides exactly the signals it needs.
        reg_we    = 1'b0;
        alu_src_a = 1'b0;
        alu_src_b = 1'b0;
        imm_sel   = IMM_I;
        alu_class = CLASS_ADD;
        mem_re    = 1'b0;
        mem_we    = 1'b0;
        wb_sel    = WB_ALU;
        branch    = 1'b0;
        jal       = 1'b0;
        jalr      = 1'b0;
        csr_en    = 1'b0;
        csr_we    = 1'b0;
        csr_imm   = 1'b0;
        mret      = 1'b0;
        ecall     = 1'b0;
        ebreak    = 1'b0;
        illegal   = 1'b0;

        case (opcode)

        //--------------------------------------------------------------------
        // R-type: add sub sll slt sltu xor srl sra or and
        //--------------------------------------------------------------------
        OP_R: begin
            if ((funct7 == 7'h00) ||
                (funct7 == 7'h20 && (funct3 == 3'b000 || funct3 == 3'b101))) begin
                reg_we    = 1'b1;
                alu_src_b = 1'b0;          // rs2
                alu_class = CLASS_RTYPE;
                wb_sel    = WB_ALU;
            end else begin
                illegal = 1'b1;
            end
        end

        //--------------------------------------------------------------------
        // I-arith: addi slti sltiu xori ori andi slli srli srai
        //--------------------------------------------------------------------
        OP_IARITH: begin
            if ((funct3 == 3'b001 && funct7 != 7'h00) ||                     // slli
                (funct3 == 3'b101 && funct7 != 7'h00 && funct7 != 7'h20)) begin // srli/srai
                illegal = 1'b1;
            end else begin
                reg_we    = 1'b1;
                alu_src_b = 1'b1;          // immediate
                imm_sel   = IMM_I;
                alu_class = CLASS_ITYPE;
                wb_sel    = WB_ALU;
            end
        end

        //--------------------------------------------------------------------
        // Loads: lb lh lw lbu lhu   (address = rs1 + I-imm, class ADD)
        //--------------------------------------------------------------------
        OP_LOAD: begin
            if (funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111) begin
                illegal = 1'b1;
            end else begin
                reg_we    = 1'b1;
                alu_src_b = 1'b1;
                imm_sel   = IMM_I;
                alu_class = CLASS_ADD;
                mem_re    = 1'b1;
                wb_sel    = WB_MEM;
            end
        end

        //--------------------------------------------------------------------
        // Stores: sb sh sw
        //--------------------------------------------------------------------
        OP_STORE: begin
            if (funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b010) begin
                reg_we    = 1'b0;
                alu_src_b = 1'b1;
                imm_sel   = IMM_S;
                alu_class = CLASS_ADD;
                mem_we    = 1'b1;
                wb_sel    = WB_ALU;
            end else begin
                illegal = 1'b1;
            end
        end

        //--------------------------------------------------------------------
        // Branches: beq bne blt bge bltu bgeu   (compare in branch_unit, EX)
        //--------------------------------------------------------------------
        OP_BRANCH: begin
            if (funct3 == 3'b010 || funct3 == 3'b011) begin
                illegal = 1'b1;
            end else begin
                reg_we    = 1'b0;
                alu_src_b = 1'b0;          // rs2 (ALU result unused)
                imm_sel   = IMM_B;
                alu_class = CLASS_ADD;
                branch    = 1'b1;
            end
        end

        //--------------------------------------------------------------------
        // U-type
        //--------------------------------------------------------------------
        OP_LUI: begin
            reg_we    = 1'b1;
            alu_src_a = 1'b0;
            alu_src_b = 1'b1;
            imm_sel   = IMM_U;
            alu_class = CLASS_LUI;         // PASSB: y = imm
            wb_sel    = WB_ALU;
        end

        OP_AUIPC: begin
            reg_we    = 1'b1;
            alu_src_a = 1'b1;              // PC
            alu_src_b = 1'b1;
            imm_sel   = IMM_U;
            alu_class = CLASS_ADD;         // PC + U-imm
            wb_sel    = WB_ALU;
        end

        //--------------------------------------------------------------------
        // Jumps
        //--------------------------------------------------------------------
        OP_JAL: begin
            reg_we    = 1'b1;
            alu_src_b = 1'b1;
            imm_sel   = IMM_J;
            alu_class = CLASS_ADD;
            wb_sel    = WB_PC4;
            jal       = 1'b1;              // resolves in ID
        end

        OP_JALR: begin
            if (funct3 != 3'b000) begin
                illegal = 1'b1;
            end else begin
                reg_we    = 1'b1;
                alu_src_b = 1'b1;
                imm_sel   = IMM_I;
                alu_class = CLASS_ADD;     // rs1 + I-imm
                wb_sel    = WB_PC4;
                jalr      = 1'b1;          // resolves in EX
            end
        end

        //--------------------------------------------------------------------
        // SYSTEM: ecall ebreak mret + the six CSR ops
        //--------------------------------------------------------------------
        OP_SYSTEM: begin
            case (funct3)
            3'b000: begin
                case (csr_addr)
                CSR_ECALL:  begin alu_src_b = 1'b1; ecall  = 1'b1; end
                CSR_EBREAK: begin alu_src_b = 1'b1; ebreak = 1'b1; end
                CSR_MRET:   begin alu_src_b = 1'b1; mret   = 1'b1; end
                default:    illegal = 1'b1;         // wfi, sret, dret, ...
                endcase
            end
            3'b001, 3'b010, 3'b011: begin           // csrrw / csrrs / csrrc
                reg_we    = 1'b1;
                alu_src_b = 1'b1;
                imm_sel   = IMM_I;                  // unused, fixed for testability
                alu_class = CLASS_ADD;
                wb_sel    = WB_CSR;
                csr_en    = 1'b1;
                csr_imm   = 1'b0;
                // csrrw always writes; csrrs/csrrc write only when rs1 != x0
                csr_we    = (funct3 == 3'b001) ? 1'b1 : (rs1 != 5'd0);
            end
            3'b101, 3'b110, 3'b111: begin           // csrrwi / csrrsi / csrrci
                reg_we    = 1'b1;
                alu_src_b = 1'b1;
                imm_sel   = IMM_Z;                  // zimm = inst[19:15]
                alu_class = CLASS_ADD;
                wb_sel    = WB_CSR;
                csr_en    = 1'b1;
                csr_imm   = 1'b1;
                // csrrwi always writes; csrrsi/csrrci only when zimm != 0
                csr_we    = (funct3 == 3'b101) ? 1'b1 : (rs1 != 5'd0);
            end
            default: illegal = 1'b1;                // funct3 = 100
            endcase
        end

        //--------------------------------------------------------------------
        default: illegal = 1'b1;
        endcase

        // Safety net: an illegal instruction is a pure NOP -- no architectural
        // side effect can leak out of the decoder.
        if (illegal) begin
            reg_we    = 1'b0;
            alu_src_a = 1'b0;
            alu_src_b = 1'b0;
            imm_sel   = IMM_I;
            alu_class = CLASS_ADD;
            mem_re    = 1'b0;
            mem_we    = 1'b0;
            wb_sel    = WB_ALU;
            branch    = 1'b0;
            jal       = 1'b0;
            jalr      = 1'b0;
            csr_en    = 1'b0;
            csr_we    = 1'b0;
            csr_imm   = 1'b0;
            mret      = 1'b0;
            ecall     = 1'b0;
            ebreak    = 1'b0;
        end
    end

endmodule
