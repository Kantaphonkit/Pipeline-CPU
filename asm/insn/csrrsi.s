# csrrsi.s -- csrrsi: new = old | zimm. If zimm == 0 the write must NOT
# happen (unlike csrrwi, which always writes).

csrrwi  x0, mcause, 4      # seed mcause = 4
nop
nop
nop
csrrsi  x5, mcause, 0      # zimm=0 -> no write; rd = old = 4
nop
nop
nop
csrrs   x6, mcause, x0     # confirm unchanged -> 4

csrrsi  x7, mcause, 3      # zimm=3 (nonzero) -> writes: new = 4 | 3 = 7
                            # rd = old = 4
nop
nop
nop
csrrs   x8, mcause, x0     # readback -> 7

ebreak
