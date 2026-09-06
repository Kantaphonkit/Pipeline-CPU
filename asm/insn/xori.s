# xori.s -- I-arith xori (also the `not` pseudo-op idiom: xori rd,rs,-1)

li      x5, 0x0F0F0F0F
nop
nop
nop
xori    x10, x5, 0x0F0     # flips low 8 bits (12-bit imm, sign-extended positive)
not     x11, x5            # xori x11,x5,-1 -> bitwise NOT of x5
xori    x12, x0, -1        # NOT of 0 -> 0xFFFFFFFF

ebreak
