# sltiu.s -- I-arith sltiu: rd = (unsigned) rs1 < sext(imm) ? 1 : 0
# Corner: the immediate is sign-extended to 32 bits *before* the unsigned
# compare, so a small register value is always "less than" imm = -1.

li      x5, 5
nop
nop
nop
sltiu   x10, x5, -1        # 5 < 0xFFFFFFFF (unsigned) -> 1
sltiu   x11, x0, 1         # 0 < 1 -> 1
sltiu   x12, x5, 0         # 5 < 0 -> 0

li      x6, -1
nop
nop
nop
sltiu   x13, x6, -1        # 0xFFFFFFFF < 0xFFFFFFFF -> 0

ebreak
