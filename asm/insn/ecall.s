# ecall.s -- SYSTEM ecall: synchronous trap. mepc <- PC of ecall,
# mcause <- 11, MPIE <- MIE, MIE <- 0, PC <- mtvec. The handler must advance
# mepc by 4 itself before mret, or it would re-execute the ecall forever.

la      x5, HANDLER
nop
nop
nop
csrrw   x0, mtvec, x5      # install the trap handler

addi    x10, x0, 0x11      # marker set before the trap, to check it survives
ecall                       # traps to HANDLER; this instruction does not retire
nop
nop
nop
addi    x20, x0, 1         # mainline code resumed right after the ecall
                            # (mepc+4 lands exactly here)
j       DONE

HANDLER:
csrrs   x6, mcause, x0     # expect 11 (synchronous ecall-from-M-mode)
nop
nop
nop
csrrs   x7, mepc, x0       # x7 = faulting PC (address of the ecall)
addi    x7, x7, 4          # skip past the ecall so mret doesn't re-trap
nop
nop
nop
csrrw   x0, mepc, x7
nop
nop
nop
mret

DONE:
addi    x21, x0, 1         # marks the whole round trip completed
ebreak
