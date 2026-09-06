# slti.s -- I-arith slti: rd = (signed) rs1 < sext(imm) ? 1 : 0

li      x5, -5
nop
nop
nop
slti    x10, x5, 0         # -5 < 0 -> 1
slti    x11, x5, -10       # -5 < -10 -> 0

li      x6, 5
nop
nop
nop
slti    x12, x6, 5         # 5 < 5 -> 0
slti    x13, x0, 1         # 0 < 1 -> 1

ebreak
