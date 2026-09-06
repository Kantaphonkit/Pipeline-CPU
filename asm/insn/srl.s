# srl.s -- R-type srl: rd = rs1 >> rs2[4:0], logical (zero-fill)

li      x5, 0x80000000     # negative if interpreted signed
li      x6, 4
nop
nop
nop
srl     x10, x5, x6        # logical shift -> 0x08000000 (no sign fill)

li      x7, 0xFFFFFFE1     # junk upper bits, low5 = shamt 1
nop
nop
nop
srl     x11, x5, x7        # shamt = 1 -> 0x40000000

li      x8, 31
nop
nop
nop
srl     x12, x5, x8        # shamt 31 -> 1

nop
nop
nop
srl     x13, x0, x6        # x0 operand -> 0

ebreak
