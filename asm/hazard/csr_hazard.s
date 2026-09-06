# csr_hazard.s -- CSR read-after-write hazards. csr.v forwards its own
# freshly-written value combinationally within EX, so a csrw immediately
# followed by a csrr of the same CSR needs no stall, and an mret right
# after a csrw mepc must see the freshly-written mepc.

la      x5, LABEL_A
csrw    mtvec, x5           # csrw mtvec <- x5
csrr    x6, mtvec           # immediately read it back -> must see x5's
                            # value, not a stale one

la      x7, TARGET
csrw    mepc, x7            # csrw mepc <- address of TARGET
mret                        # mret right after csrw mepc: must redirect to
                            # the freshly-written mepc, not a stale value
addi    x9, x0, 0xBB        # poison; must be flushed if mret works
TARGET:
csrr    x8, mepc            # readback after the jump -> address of TARGET
addi    x10, x0, 1          # confirms TARGET reached

LABEL_A:
nop

# csrrw then a dependent ALU op on the destination register
csrrw   x11, mie, x0        # x11 = old mie
addi    x12, x11, 1         # immediately consumes x11 (EX/MEM forward)

ebreak
