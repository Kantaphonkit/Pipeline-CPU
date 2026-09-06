# csrrwi.s -- csrrwi: like csrrw but the write source is zimm = inst[19:15]
# zero-extended (5 bits, 0..31), and it always writes.

csrrwi  x0, mcause, 8      # mcause <- 8
nop
nop
nop
csrrs   x5, mcause, x0     # readback -> 8

csrrwi  x6, mcause, 31     # x6 = old mcause (8); mcause <- 31
nop
nop
nop
csrrs   x7, mcause, x0     # readback -> 31

csrrwi  x0, mcause, 0      # mcause <- 0 (zimm = 0 still writes for csrrwi)
nop
nop
nop
csrrs   x8, mcause, x0     # readback -> 0

ebreak
