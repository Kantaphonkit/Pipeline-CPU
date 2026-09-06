# lh.s -- I-load lh: sign-extend halfword. Both halves have bit15 set.

li      x5, 0x40
li      x6, 0x84838281      # low half = 0x8281, high half = 0x8483
nop
nop
nop
sw      x6, 0(x5)

nop
nop
nop
lh      x10, 0(x5)          # 0x8281 -> sign-extend -> 0xFFFF8281
lh      x11, 2(x5)          # 0x8483 -> sign-extend -> 0xFFFF8483

ebreak
