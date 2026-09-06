# jalr.s -- I-jalr: rd = PC+4, PC = (rs1 + imm) & ~1 (LSB always cleared).
# Two cases: rd = x0 (link discarded) and an odd effective target address
# (forcing the hardware to clear bit0).

la      x5, TGT1          # x5 = address of TGT1 (word-aligned, LSB = 0)
nop
nop
nop
addi    x5, x5, 1         # force an odd address: LSB = 1
nop
nop
nop
jalr    x0, x5, 0         # rd = x0 (no link written); target = (x5+0) & ~1 = TGT1
nop
nop
nop
addi    x11, x0, 0xBB     # fall-through; must not run if LSB-clear works
TGT1:
addi    x12, x0, 1        # confirms target reached

la      x6, TGT2
nop
nop
nop
jalr    x13, x6, 1        # imm=1 makes (x6+1) odd; hardware must clear LSB
                            # back to TGT2. rd = x13 gets the link (PC+4).
nop
nop
nop
addi    x14, x0, 0xBB
TGT2:
addi    x15, x0, 1

ebreak
