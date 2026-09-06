# andi.s -- I-arith andi

li      x5, 0xFFFFFFFF
nop
nop
nop
andi    x10, x5, 0x0FF     # mask low byte -> 0x000000FF
andi    x11, x5, -1        # and with -1 (all ones) -> unchanged
andi    x12, x0, -1        # 0 and -1 -> 0

ebreak
