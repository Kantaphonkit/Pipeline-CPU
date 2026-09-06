# addi.s -- I-arith addi: rd = rs1 + sext(imm)
# Classic bug check: alu_ctrl must NOT decode inst[30] for addi (funct3=000).
# A negative immediate (inst[30] happens to be 1 in the imm field's top bit
# region for many negative encodings) must still ADD, never SUB.

li      x5, 10
nop
nop
nop
addi    x10, x5, 5         # positive imm -> 15
addi    x11, x5, -1        # negative imm -> 9  (must ADD, not SUB)
addi    x12, x0, -1        # x0 + (-1) -> 0xFFFFFFFF, the direct alu_ctrl trap:
                            # if inst[30] were wrongly consulted this could
                            # decode as SUB(x0 - (-1)) which is coincidentally
                            # also 1, so also test a case where add/sub differ:
addi    x13, x5, 2047      # max positive imm -> 2057
addi    x14, x5, -2048     # min negative imm -> 10 - 2048 = -2038

ebreak
