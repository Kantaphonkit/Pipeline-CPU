# mret.s -- SYSTEM mret: PC <- mepc, MIE <- MPIE, MPIE <- 1.
# Tested directly (mepc/mstatus pre-set by software) without going through
# an actual trap -- ecall.s and irq_demo.s cover the full trap round trip.

la      x5, TARGET
nop
nop
nop
csrrw   x0, mepc, x5       # mepc <- address of TARGET

li      x6, 0x80           # MPIE (bit7) = 1, MIE (bit3) = 0
csrrw   x0, mstatus, x6
nop
nop
nop
mret                        # PC <- mepc; MIE <- MPIE(1); MPIE <- 1
nop
nop
nop
addi    x11, x0, 0xBB      # fall-through; must not run if mret redirects

TARGET:
csrrs   x12, mstatus, x0   # expect MIE=1, MPIE=1 -> 0x88
addi    x13, x0, 1         # confirms TARGET reached

ebreak
