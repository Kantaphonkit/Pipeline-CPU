# csrrc.s -- csrrc: new = old & ~rs1. If rs1 == x0 the write must NOT happen;
# rd always gets the pre-write value.

li      x5, 0xFFFFFFFC     # all ones except low 2 bits (mtvec masks those anyway)
csrrw   x0, mtvec, x5      # seed mtvec = 0xFFFFFFFC
nop
nop
nop
csrrc   x6, mtvec, x0      # rs1=x0 -> no write; rd = old = 0xFFFFFFFC
nop
nop
nop
csrrs   x7, mtvec, x0      # confirm unchanged -> 0xFFFFFFFC

li      x8, 0x000000F0
nop
nop
nop
csrrc   x9, mtvec, x8      # clears bits 4-7: new = 0xFFFFFFFC & ~0xF0 = 0xFFFFFF0C
                            # rd = old = 0xFFFFFFFC
nop
nop
nop
csrrs   x10, mtvec, x0     # readback -> 0xFFFFFF0C

ebreak
