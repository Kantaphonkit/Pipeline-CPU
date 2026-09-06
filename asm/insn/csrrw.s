# csrrw.s -- csrrw always writes (unlike csrrs/csrrc). rd gets the OLD value.
# Exercises mtvec/mepc (low 2 bits always read back 0), mstatus (only bits
# 3 and 7 stick) and mie (only bit 11 sticks).

li      x5, 0x00001000
csrrw   x6, mtvec, x5      # x6 = old mtvec (0); mtvec <- 0x1000
nop
nop
nop
csrrs   x7, mtvec, x0      # readback -> 0x1000

li      x8, 0x00002003     # low 2 bits = 11 -- must be masked to 0 on read
csrrw   x9, mepc, x8       # x9 = old mepc (0, untouched so far)
nop
nop
nop
csrrs   x10, mepc, x0      # readback -> 0x00002000 (low 2 bits forced to 0)

li      x13, 0xFFFFFFFF
csrrw   x0, mstatus, x13   # only bits 3 (MIE) and 7 (MPIE) stick
nop
nop
nop
csrrs   x14, mstatus, x0   # readback -> 0x88

li      x15, 0xFFFFFFFF
csrrw   x0, mie, x15       # only bit 11 (MEIE) sticks
nop
nop
nop
csrrs   x16, mie, x0       # readback -> 0x800

ebreak
