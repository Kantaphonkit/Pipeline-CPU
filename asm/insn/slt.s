# slt.s -- R-type slt: rd = (signed) rs1 < rs2 ? 1 : 0

li      x5, -1
li      x6, 1
nop
nop
nop
slt     x10, x5, x6        # -1 < 1 -> 1

nop
nop
nop
slt     x11, x6, x5        # 1 < -1 -> 0

li      x7, 5
li      x8, 5
nop
nop
nop
slt     x12, x7, x8        # 5 < 5 -> 0

nop
nop
nop
slt     x13, x0, x6        # 0 < 1 -> 1
slt     x14, x6, x0        # 1 < 0 -> 0

ebreak
