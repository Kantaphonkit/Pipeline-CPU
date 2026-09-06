# lbu.s -- I-load lbu: zero-extend byte. Same word as lb.s (bytes >=0x80) to
# contrast the extension behaviour.

li      x5, 0x40
li      x6, 0x84838281      # bytes (LE): [0]=0x81 [1]=0x82 [2]=0x83 [3]=0x84
nop
nop
nop
sw      x6, 0(x5)

nop
nop
nop
lbu     x10, 0(x5)          # 0x81 -> zero-extend -> 0x00000081
lbu     x11, 1(x5)          # -> 0x00000082
lbu     x12, 2(x5)          # -> 0x00000083
lbu     x13, 3(x5)          # -> 0x00000084

ebreak
