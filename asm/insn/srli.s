# srli.s -- I-shift srli: rd = rs1 >> shamt (logical, imm[4:0])

li      x5, 0x80000000
nop
nop
nop
srli    x10, x5, 4         # logical -> 0x08000000 (no sign fill)
srli    x11, x5, 31        # -> 1
srli    x12, x5, 0         # shamt 0 -> unchanged
srli    x13, x0, 5         # x0 operand -> 0

ebreak
