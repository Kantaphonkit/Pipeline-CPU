# lhu.s -- I-load lhu: zero-extend halfword. Same word as lh.s.

li      x5, 0x40
li      x6, 0x84838281      # low half = 0x8281, high half = 0x8483
nop
nop
nop
sw      x6, 0(x5)

nop
nop
nop
lhu     x10, 0(x5)          # -> 0x00008281
lhu     x11, 2(x5)          # -> 0x00008483

ebreak
