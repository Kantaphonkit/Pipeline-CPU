# or.s -- R-type or

li      x5, 0x0F0F0000
li      x6, 0x0000F0F0
nop
nop
nop
or      x10, x5, x6        # 0x0F0FF0F0

nop
nop
nop
or      x11, x5, x0        # or with x0 -> unchanged
or      x12, x0, x0        # 0 | 0 -> 0

li      x7, -1
nop
nop
nop
or      x13, x7, x6        # or with all-ones -> all ones

ebreak
