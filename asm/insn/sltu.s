# sltu.s -- R-type sltu: rd = (unsigned) rs1 < rs2 ? 1 : 0

li      x5, -1              # 0xFFFFFFFF, huge unsigned
li      x6, 1
nop
nop
nop
sltu    x10, x5, x6        # 0xFFFFFFFF < 1 (unsigned) -> 0

nop
nop
nop
sltu    x11, x6, x5        # 1 < 0xFFFFFFFF (unsigned) -> 1

li      x7, 0
li      x8, 0
nop
nop
nop
sltu    x12, x7, x8        # 0 < 0 -> 0

nop
nop
nop
sltu    x13, x0, x6        # 0 < 1 -> 1
sltu    x14, x6, x0        # 1 < 0 -> 0

ebreak
