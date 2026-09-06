# slli.s -- I-shift slli: rd = rs1 << shamt, shamt = imm[4:0] (immediate, NOT
# rs2 -- exercises the "immediate shifts use imm[4:0]" rule).

li      x5, 1
nop
nop
nop
slli    x10, x5, 0         # shamt 0 -> 1
slli    x11, x5, 31        # shamt 31 -> 0x80000000
slli    x12, x5, 4         # shamt 4 -> 16
slli    x13, x0, 5         # x0 operand -> 0

ebreak
