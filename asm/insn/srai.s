# srai.s -- I-shift srai: rd = rs1 >>> shamt (arithmetic, imm[4:0], sign fill)

li      x5, 0x80000000     # negative
nop
nop
nop
srai    x10, x5, 4         # sign-extend -> 0xF8000000
srai    x11, x5, 31        # -> 0xFFFFFFFF

li      x6, 16             # positive
nop
nop
nop
srai    x12, x6, 2         # same as logical for positive -> 4
srai    x13, x0, 5         # x0 operand -> 0

ebreak
