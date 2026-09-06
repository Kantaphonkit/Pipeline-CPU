# csrrci.s -- csrrci: new = old & ~zimm. If zimm == 0 the write must NOT
# happen.

csrrwi  x0, mcause, 0x1F   # seed mcause = 31
nop
nop
nop
csrrci  x5, mcause, 0      # zimm=0 -> no write; rd = old = 31
nop
nop
nop
csrrs   x6, mcause, x0     # confirm unchanged -> 31

csrrci  x7, mcause, 5      # zimm=5 (0b00101) -> new = 31 & ~5 = 26
                            # rd = old = 31
nop
nop
nop
csrrs   x8, mcause, x0     # readback -> 26

ebreak
