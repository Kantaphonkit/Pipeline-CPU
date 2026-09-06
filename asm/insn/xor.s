# xor.s -- R-type xor

li      x5, 0x0F0F0F0F
li      x6, 0xFF00FF00
nop
nop
nop
xor     x10, x5, x6        # 0xF00FF00F

nop
nop
nop
xor     x11, x5, x5        # self xor -> 0

nop
nop
nop
xor     x12, x5, x0        # xor with x0 -> unchanged
xor     x13, x0, x0        # 0 ^ 0 -> 0

ebreak
