# sra.s -- R-type sra: rd = rs1 >>> rs2[4:0], arithmetic (sign-fill)

li      x5, 0x80000000     # negative
li      x6, 0xFFFFFFE4     # junk in bits[31:5], low5 = shamt 4
nop
nop
nop
sra     x10, x5, x6        # sign-extend shift by 4 -> 0xF8000000

li      x7, 31
nop
nop
nop
sra     x11, x5, x7        # shamt 31 on negative -> 0xFFFFFFFF

li      x8, 8               # positive value
li      x9, 2
nop
nop
nop
sra     x12, x8, x9        # positive shift, same as logical -> 2

ebreak
