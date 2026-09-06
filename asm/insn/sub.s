# sub.s -- R-type sub: rd = rs1 - rs2

li      x5, 50
li      x6, 8
nop
nop
nop
sub     x10, x5, x6        # positive result = 42

li      x7, 3
nop
nop
nop
sub     x11, x6, x7        # 8 - 3 = 5

li      x8, 3
li      x9, 10
nop
nop
nop
sub     x12, x8, x9        # negative result: 3 - 10 = -7

li      x13, 0x80000000    # INT_MIN
li      x14, 1
nop
nop
nop
sub     x15, x13, x14      # underflow wrap: 0x80000000 - 1 = 0x7fffffff

nop
nop
nop
sub     x16, x6, x0        # x0 operand -> 8
sub     x17, x0, x6        # 0 - 8 = -8

ebreak
