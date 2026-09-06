# sll.s -- R-type sll: rd = rs1 << rs2[4:0] (register shift amount)

li      x5, 1
li      x6, 4
nop
nop
nop
sll     x10, x5, x6        # 1 << 4 = 16

li      x7, 0xFFFFFFE0     # junk in bits[31:5], low 5 bits = 0 -> shamt 0
nop
nop
nop
sll     x11, x5, x7        # shamt = 0 (masked) -> 1

li      x8, 0xFFFFFFFF     # junk in upper bits, low 5 bits = 31
nop
nop
nop
sll     x12, x5, x8        # shamt = 31 -> 0x80000000

li      x9, 31
nop
nop
nop
sll     x13, x0, x9        # x0 operand -> 0

ebreak
