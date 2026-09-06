# csrrs.s -- csrrs: new = old | rs1. If rs1 == x0 the write must NOT happen
# (only the read side executes); rd always gets the pre-write value.

li      x5, 0x00001000
csrrw   x0, mtvec, x5      # seed mtvec = 0x1000
nop
nop
nop
csrrs   x6, mtvec, x0      # rs1=x0 -> no write; rd = old = 0x1000
nop
nop
nop
csrrs   x7, mtvec, x0      # read again -> still 0x1000 (proves no write happened)

li      x8, 0x00002000
nop
nop
nop
csrrs   x9, mtvec, x8      # rs1=x8 (nonzero) -> writes: new = 0x1000 | 0x2000 = 0x3000
                            # rd = old = 0x1000
nop
nop
nop
csrrs   x10, mtvec, x0     # readback -> 0x3000

ebreak
