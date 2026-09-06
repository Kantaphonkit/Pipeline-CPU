# and.s -- R-type and

li      x5, 0x0FF00FF0
li      x6, 0xFFFF0000
nop
nop
nop
and     x10, x5, x6        # masks upper half -> 0x0FF00000

nop
nop
nop
and     x11, x5, x0        # and with x0 -> 0
and     x12, x0, x0        # 0 & 0 -> 0

li      x7, -1
nop
nop
nop
and     x13, x7, x5        # and with all-ones -> unchanged (x5)

ebreak
