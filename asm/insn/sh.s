# sh.s -- S-type sh: mem[rs1+imm] = rs2[15:0], other half untouched.

li      x5, 0x40
li      x6, 0x11223344
nop
nop
nop
sw      x6, 0(x5)          # pre-existing word = 0x11223344

li      x7, 0xBEEF
nop
nop
nop
sh      x7, 0(x5)          # overwrite low half -> 0x1122BEEF
sh      x7, 2(x5)          # overwrite high half -> 0xBEEFBEEF

nop
nop
nop
lw      x10, 0(x5)         # readback -> 0xBEEFBEEF
lhu     x11, 0(x5)         # low half -> 0xBEEF
lhu     x12, 2(x5)         # high half -> 0xBEEF

ebreak
