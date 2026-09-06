# lb.s -- I-load lb: sign-extend byte. Word stored has every byte lane >=0x80.

li      x5, 0x40
li      x6, 0x84838281      # bytes (LE): [0]=0x81 [1]=0x82 [2]=0x83 [3]=0x84
nop
nop
nop
sw      x6, 0(x5)

nop
nop
nop
lb      x10, 0(x5)          # 0x81 -> sign-extend -> 0xFFFFFF81
lb      x11, 1(x5)          # 0x82 -> 0xFFFFFF82
lb      x12, 2(x5)          # 0x83 -> 0xFFFFFF83
lb      x13, 3(x5)          # 0x84 -> 0xFFFFFF84

ebreak
