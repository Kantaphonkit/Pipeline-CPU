# bu_trap.s -- step-4 bring-up: ecall trap entry and mret return.
# Every control transfer (ecall, the handler's mret, and the branch that skips
# the handler) is followed by 2 NOPs -- the shadow the step-4 machine cannot
# flush.  Run with +NOTRACE: the RTL retires those shadow NOPs, the ISS does
# not, so the traces differ by construction until step 5.
#
# Synchronous trap semantics under test:
#   mepc   <- PC of the ecall (NOT PC+4) -- the handler must add 4 itself
#   mcause <- 11 (environment call from M-mode)
#   MPIE   <- MIE, MIE <- 0 on entry;  MIE <- MPIE, MPIE <- 1 on mret
#   PC     <- mtvec (direct mode, low 2 bits ignored)

        .text
        lui     x5, %hi(HANDLER)
        nop
        nop
        nop
        addi    x5, x5, %lo(HANDLER)
        nop
        nop
        nop
        csrrw   x0, mtvec, x5       # install the handler
        addi    x28, x0, 8
        nop
        nop
        nop
        csrrs   x0, mstatus, x28    # MIE = 1, so the trap can clear it
        addi    x10, x0, 0x11       # marker written before the trap
        nop
        nop
        nop

        ecall                       # traps; this instruction does not retire
        nop
        nop
        addi    x20, x0, 1          # mepc+4 lands on the first NOP above, so
                                    # execution resumes and reaches here
        nop
        nop
        nop
        beq     x0, x0, DONE
        nop
        nop
        addi    x29, x0, 0xBB       # poison

HANDLER:
        csrrs   x6, mcause, x0      # must be 11
        nop
        nop
        nop
        csrrs   x7, mepc, x0        # PC of the ecall
        nop
        nop
        nop
        csrrs   x8, mstatus, x0     # MIE cleared, MPIE set -> 0x80
        addi    x9, x7, 4           # skip past the ecall
        nop
        nop
        nop
        csrrw   x0, mepc, x9
        nop
        nop
        nop
        mret
        nop
        nop
        addi    x30, x0, 0xBB       # poison

DONE:
        csrrs   x11, mstatus, x0    # after mret: MIE restored to 1, MPIE = 1
        addi    x21, x0, 1
        ebreak
