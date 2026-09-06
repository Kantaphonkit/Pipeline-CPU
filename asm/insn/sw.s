# sw.s -- S-type sw: mem[rs1+imm] = rs2 (word), verified by loading back.

li      x5, 0x40           # base scratch address
li      x6, 0x12345678
nop
nop
nop
sw      x6, 0(x5)          # store word at 0x40

li      x7, -1             # 0xFFFFFFFF
nop
nop
nop
sw      x7, 4(x5)          # store word at 0x44, negative offset test on imm side is
                            # separate (imm12 can be negative too):
sw      x6, -4(x5)         # store at 0x40 + (-4) = 0x3C using a negative imm

nop
nop
nop
lw      x10, 0(x5)         # readback -> 0x12345678
lw      x11, 4(x5)         # readback -> 0xFFFFFFFF
lw      x12, -4(x5)        # readback -> 0x12345678

ebreak
